#include "common.h"
#include "ast.h"
#include "parser.h"

#include <stdarg.h>

typedef struct {
    Token *toks;
    int pos;
    int count;
    int fn_body; /* inside a function body: trailing expr = implicit return */
} Parser;

static void parse_error(Token *tk, const char *fmt, ...) {
    va_list ap;
    fputs("slang: parse error at line ", stderr);
    fprintf(stderr, "%d", tk->line);
    fputs(": ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc(10, stderr);
    exit(1);
}

static Token *peek(Parser *p) { return &p->toks[p->pos]; }

static Token *advance(Parser *p) {
    if (peek(p)->type != T_EOF)
        p->pos++;
    return &p->toks[p->pos - 1];
}

static int check(Parser *p, TokenType t) { return peek(p)->type == t; }

static int match(Parser *p, TokenType t) {
    if (check(p, t)) {
        p->pos++;
        return 1;
    }
    return 0;
}

static Token *expect(Parser *p, TokenType t, const char *what) {
    if (!check(p, t))
        parse_error(peek(p), "expected %s but found %s", what,
                    token_type_name(peek(p)->type));
    return advance(p);
}

/* ---- AST constructors ---- */

static Expr *new_expr(ExprKind kind, int line) {
    Expr *e = (Expr *)xmalloc(sizeof(Expr));
    memset(e, 0, sizeof(Expr));
    e->kind = kind;
    e->line = line;
    return e;
}

static Stmt *new_stmt(StmtKind kind, int line) {
    Stmt *s = (Stmt *)xmalloc(sizeof(Stmt));
    memset(s, 0, sizeof(Stmt));
    s->kind = kind;
    s->line = line;
    return s;
}

static Block *new_block(void) {
    Block *b = (Block *)xmalloc(sizeof(Block));
    b->stmts = NULL;
    b->count = 0;
    b->cap = 0;
    return b;
}

static void block_push(Block *b, Stmt *s) {
    if (b->count == b->cap) {
        b->cap = b->cap ? b->cap * 2 : 8;
        b->stmts = (Stmt **)xrealloc(b->stmts, b->cap * sizeof(Stmt *));
    }
    b->stmts[b->count++] = s;
}

/* The '.' character as a string of one, avoiding escape sequences. */
static const char p_dot_str[2] = {'.', 0};

static void sb_putc(StrBuf *sb, char c) { sb_append_n(sb, &c, 1); }

static void call_push_arg(Expr *call, Expr *arg) {
    int n = call->as.call.nargs;
    call->as.call.args =
        (Expr **)xrealloc(call->as.call.args, (n + 1) * sizeof(Expr *));
    call->as.call.args[n] = arg;
    call->as.call.nargs = n + 1;
}

/* ---- expressions (precedence climbing) ---- */

static Expr *parse_expression(Parser *p);
static Expr *parse_expr_source(const char *src, int line);
static Expr *parse_interp_string(Token *tk);

static Expr *parse_primary(Parser *p) {
    Token *tk = peek(p);
    switch (tk->type) {
    case T_INT: {
        advance(p);
        Expr *e = new_expr(EX_INT, tk->line);
        e->as.int_lit.value = tk->int_val;
        return e;
    }
    case T_FLOAT: {
        advance(p);
        Expr *e = new_expr(EX_FLOAT, tk->line);
        e->as.float_lit.value = tk->float_val;
        return e;
    }
    case T_STRING: {
        advance(p);
        return parse_interp_string(tk);
    }
    case T_KW_TRUE:
    case T_KW_FALSE: {
        advance(p);
        Expr *e = new_expr(EX_BOOL, tk->line);
        e->as.bool_lit.value = (tk->type == T_KW_TRUE);
        return e;
    }
    case T_IDENT: {
        advance(p);
        /* qualified name: pkg.member (one dot only) */
        char *name = tk->text;
        if (check(p, T_DOT)) {
            advance(p);
            Token *member = expect(p, T_IDENT, "a member name after '.'");
            StrBuf sb;
            sb_init(&sb);
            sb_append(&sb, tk->text);
            sb_append(&sb, p_dot_str);
            sb_append(&sb, member->text);
            name = sb.data;
        }
        if (check(p, T_LPAREN)) {
            advance(p); /* '(' */
            Expr *call = new_expr(EX_CALL, tk->line);
            call->as.call.name = name;
            if (!check(p, T_RPAREN)) {
                for (;;) {
                    call_push_arg(call, parse_expression(p));
                    if (!match(p, T_COMMA))
                        break;
                }
            }
            expect(p, T_RPAREN, "')' to close argument list");
            return call;
        }
        Expr *e = new_expr(EX_IDENT, tk->line);
        e->as.ident.name = name;
        return e;
    }
    case T_LPAREN: {
        advance(p);
        Expr *e = parse_expression(p);
        expect(p, T_RPAREN, "')'");
        return e;
    }
    default:
        parse_error(tk, "expected an expression but found %s",
                    token_type_name(tk->type));
    }
    return NULL; /* unreachable */
}

static Expr *parse_unary(Parser *p) {
    Token *tk = peek(p);
    if (tk->type == T_MINUS || tk->type == T_BANG) {
        advance(p);
        Expr *operand = parse_unary(p);
        Expr *e = new_expr(EX_UNARY, tk->line);
        e->as.unary.op = xstrdup(tk->type == T_MINUS ? "-" : "!");
        e->as.unary.operand = operand;
        return e;
    }
    return parse_primary(p);
}

/* Raw operator symbol for a token type (token_type_name adds quotes). */
static const char *op_text(TokenType t) {
    switch (t) {
    case T_PLUS:    return "+";
    case T_MINUS:   return "-";
    case T_STAR:    return "*";
    case T_SLASH:   return "/";
    case T_PERCENT: return "%";
    case T_EQEQ:    return "==";
    case T_BANGEQ:  return "!=";
    case T_LT:      return "<";
    case T_GT:      return ">";
    case T_LTE:     return "<=";
    case T_GTE:     return ">=";
    default:        return "?";
    }
}

static Expr *make_binary(char *op, Expr *lhs, Expr *rhs, int line) {
    Expr *e = new_expr(EX_BINARY, line);
    e->as.binary.op = op;
    e->as.binary.lhs = lhs;
    e->as.binary.rhs = rhs;
    return e;
}

static Expr *parse_factor(Parser *p) {
    Expr *lhs = parse_unary(p);
    while (check(p, T_STAR) || check(p, T_SLASH) || check(p, T_PERCENT)) {
        Token *op = advance(p);
        Expr *rhs = parse_unary(p);
        lhs = make_binary(xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_term(Parser *p) {
    Expr *lhs = parse_factor(p);
    while (check(p, T_PLUS) || check(p, T_MINUS)) {
        Token *op = advance(p);
        Expr *rhs = parse_factor(p);
        lhs = make_binary(xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_comparison(Parser *p) {
    Expr *lhs = parse_term(p);
    while (check(p, T_LT) || check(p, T_GT) || check(p, T_LTE) ||
           check(p, T_GTE)) {
        Token *op = advance(p);
        Expr *rhs = parse_term(p);
        lhs = make_binary(xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_equality(Parser *p) {
    Expr *lhs = parse_comparison(p);
    while (check(p, T_EQEQ) || check(p, T_BANGEQ)) {
        Token *op = advance(p);
        Expr *rhs = parse_comparison(p);
        lhs = make_binary(xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_and(Parser *p) {
    Expr *lhs = parse_equality(p);
    while (match(p, T_ANDAND)) {
        Expr *rhs = parse_equality(p);
        lhs = make_binary(xstrdup("&&"), lhs, rhs, peek(p)->line);
    }
    return lhs;
}

static Expr *parse_or(Parser *p) {
    Expr *lhs = parse_and(p);
    while (match(p, T_OROR)) {
        Expr *rhs = parse_and(p);
        lhs = make_binary(xstrdup("||"), lhs, rhs, peek(p)->line);
    }
    return lhs;
}

static Expr *parse_expression(Parser *p) { return parse_or(p); }

/* Parse an expression embedded in a string interpolation. The source
 * substring is lexed and parsed independently. */
static Expr *parse_expr_source(const char *src, int line) {
    (void)line;
    Lexer lx;
    lexer_init(&lx, src);

    int cap = 16, n = 0;
    Token *toks = (Token *)xmalloc(cap * sizeof(Token));
    for (;;) {
        if (n == cap) {
            cap *= 2;
            toks = (Token *)xrealloc(toks, cap * sizeof(Token));
        }
        toks[n++] = lexer_next(&lx);
        if (toks[n - 1].type == T_EOF)
            break;
    }

    Parser sub;
    sub.toks = toks;
    sub.pos = 0;
    sub.count = n;
    sub.fn_body = 0;

    Expr *e = parse_expression(&sub);
    if (!check(&sub, T_EOF))
        parse_error(peek(&sub), "unexpected token in interpolation");
    return e;
}

/* Build the expression tree for a (possibly interpolated) string
 * literal. Interpolation segments were stored between marker bytes by
 * the lexer; each becomes a sub-expression joined with '+'. */
static Expr *parse_interp_string(Token *tk) {
    const char *s = tk->text;
    int has_marker = 0;
    for (const char *q = s; *q; q++) {
        if (*q == 1) {
            has_marker = 1;
            break;
        }
    }
    if (!has_marker) {
        Expr *e = new_expr(EX_STRING, tk->line);
        e->as.str_lit.value = xstrdup(s);
        return e;
    }

    StrBuf seg;
    sb_init(&seg);
    Expr *acc = NULL;
    int in_expr = 0;
    for (const char *q = s;; q++) {
        if (*q == 1 || *q == '\0') {
            char *text = xstrdup(seg.data);
            Expr *part;
            if (in_expr) {
                part = parse_expr_source(text, tk->line);
            } else {
                part = new_expr(EX_STRING, tk->line);
                part->as.str_lit.value = text;
            }
            if (!acc) {
                acc = part;
            } else {
                acc = make_binary(xstrdup("+"), acc, part, tk->line);
            }
            seg.len = 0;
            seg.data[0] = '\0';
            in_expr = !in_expr;
            if (*q == '\0')
                break;
            continue;
        }
        sb_putc(&seg, *q);
    }
    return acc;
}

/* ---- statements ---- */

static const char *parse_type_name(Parser *p) {
    Token *tk = peek(p);
    switch (tk->type) {
    case T_TY_INT:   advance(p); return "int";
    case T_TY_FLOAT: advance(p); return "float";
    case T_TY_STR:   advance(p); return "str";
    case T_TY_BOOL:  advance(p); return "bool";
    default:
        parse_error(tk, "expected a type name (int, float, str, bool)");
    }
    return NULL; /* unreachable */
}

static Stmt *parse_if_stmt(Parser *p);
static Stmt *parse_statement(Parser *p);

static Block *parse_block(Parser *p, int fn_body) {
    expect(p, T_LBRACE, "'{'");
    Block *blk = new_block();
    int saved = p->fn_body;
    p->fn_body = fn_body;
    while (!check(p, T_RBRACE)) {
        if (check(p, T_EOF))
            parse_error(peek(p), "unexpected end of file inside block");
        block_push(blk, parse_statement(p));
    }
    p->fn_body = saved;
    expect(p, T_RBRACE, "'}'");
    return blk;
}

static Stmt *parse_let_stmt(Parser *p) {
    Token *kw = advance(p); /* 'let' */
    Token *name = expect(p, T_IDENT, "a variable name");
    expect(p, T_ASSIGN, "'='");
    Expr *init = parse_expression(p);
    expect(p, T_SEMI, "';'");

    Stmt *s = new_stmt(ST_LET, kw->line);
    s->as.let.name = name->text;
    s->as.let.init = init;
    return s;
}

static Stmt *parse_if_stmt(Parser *p) {
    Token *kw = advance(p); /* 'if' */
    Expr *cond = parse_expression(p);
    Block *then_blk = parse_block(p, 0);

    Stmt *s = new_stmt(ST_IF, kw->line);
    s->as.if_stmt.cond = cond;
    s->as.if_stmt.then_blk = then_blk;
    s->as.if_stmt.else_blk = NULL;

    if (match(p, T_KW_ELSE)) {
        Block *else_blk = new_block();
        if (check(p, T_KW_IF)) {
            block_push(else_blk, parse_if_stmt(p));
        } else {
            else_blk = parse_block(p, 0);
        }
        s->as.if_stmt.else_blk = else_blk;
    }
    return s;
}

static Stmt *parse_while_stmt(Parser *p) {
    Token *kw = advance(p); /* 'while' */
    Expr *cond = parse_expression(p);
    Block *body = parse_block(p, 0);

    Stmt *s = new_stmt(ST_WHILE, kw->line);
    s->as.while_stmt.cond = cond;
    s->as.while_stmt.body = body;
    return s;
}

/* guard <cond> else { ... }  ==  if !<cond> { ... } */
static Stmt *parse_guard_stmt(Parser *p) {
    Token *kw = advance(p);
    Expr *cond = parse_expression(p);
    expect(p, T_KW_ELSE, "'else'");
    Block *body = parse_block(p, 0);

    Stmt *s = new_stmt(ST_IF, kw->line);
    Expr *neg = new_expr(EX_UNARY, kw->line);
    neg->as.unary.op = xstrdup("!");
    neg->as.unary.operand = cond;
    s->as.if_stmt.cond = neg;
    s->as.if_stmt.then_blk = body;
    s->as.if_stmt.else_blk = NULL;
    return s;
}

/* for <name> in <start>..[=]<end> { ... } */
static Stmt *parse_for_stmt(Parser *p) {
    Token *kw = advance(p);
    Token *name = expect(p, T_IDENT, "a loop variable name");
    expect(p, T_KW_IN, "'in'");
    Expr *start = parse_expression(p);

    int inclusive;
    if (match(p, T_DOTDOTEQ)) {
        inclusive = 1;
    } else {
        expect(p, T_DOTDOT, "'..' or '..='");
        inclusive = 0;
    }

    Expr *end = parse_expression(p);
    Block *body = parse_block(p, 0);

    Stmt *s = new_stmt(ST_FOR, kw->line);
    s->as.for_stmt.name = name->text;
    s->as.for_stmt.start = start;
    s->as.for_stmt.end = end;
    s->as.for_stmt.inclusive = inclusive;
    s->as.for_stmt.body = body;
    return s;
}

static Stmt *parse_return_stmt(Parser *p) {
    Token *kw = advance(p); /* 'return' */
    Stmt *s = new_stmt(ST_RETURN, kw->line);
    if (!check(p, T_SEMI))
        s->as.ret.value = parse_expression(p);
    expect(p, T_SEMI, "';'");
    return s;
}

static Stmt *parse_statement(Parser *p) {
    Token *tk = peek(p);
    switch (tk->type) {
    case T_KW_LET:
        return parse_let_stmt(p);
    case T_KW_IF:
        return parse_if_stmt(p);
    case T_KW_WHILE:
        return parse_while_stmt(p);
    case T_KW_FOR:
        return parse_for_stmt(p);
    case T_KW_GUARD:
        return parse_guard_stmt(p);
    case T_KW_RETURN:
        return parse_return_stmt(p);
    case T_KW_PUB:
        parse_error(tk,
                    "'pub' is only allowed on top-level functions and "
                    "variables");
        return NULL; /* unreachable */
    default: {
        /* expression or assignment statement */
        Expr *expr = parse_expression(p);
        if (match(p, T_ASSIGN)) {
            if (expr->kind != EX_IDENT)
                parse_error(tk, "invalid assignment target");
            Expr *value = parse_expression(p);
            expect(p, T_SEMI, "';'");
            Stmt *s = new_stmt(ST_ASSIGN, tk->line);
            s->as.assign.name = expr->as.ident.name;
            s->as.assign.value = value;
            return s;
        }
        /* implicit return: last expression in a function body */
        if (p->fn_body && check(p, T_RBRACE)) {
            Stmt *s = new_stmt(ST_RETURN, tk->line);
            s->as.ret.value = expr;
            return s;
        }
        expect(p, T_SEMI, "';'");
        Stmt *s = new_stmt(ST_EXPR, tk->line);
        s->as.expr_stmt.expr = expr;
        return s;
    }
    }
}

/* ---- declarations ---- */

static FuncDecl *parse_fn_decl(Parser *p) {
    Token *kw = advance(p); /* 'fn' */
    Token *name = expect(p, T_IDENT, "a function name");
    expect(p, T_LPAREN, "'('");

    FuncDecl *f = (FuncDecl *)xmalloc(sizeof(FuncDecl));
    memset(f, 0, sizeof(FuncDecl));
    f->name = name->text;
    f->line = kw->line;

    int pcap = 0;
    if (!check(p, T_RPAREN)) {
        for (;;) {
            Token *pname = expect(p, T_IDENT, "a parameter name");
            expect(p, T_COLON, "':' followed by a type");
            const char *pty = parse_type_name(p);
            if (f->nparams == pcap) {
                pcap = pcap ? pcap * 2 : 4;
                f->params =
                    (char **)xrealloc(f->params, pcap * sizeof(char *));
                f->param_types =
                    (char **)xrealloc(f->param_types, pcap * sizeof(char *));
            }
            f->params[f->nparams] = pname->text;
            f->param_types[f->nparams] = xstrdup(pty);
            f->nparams++;
            if (!match(p, T_COMMA))
                break;
        }
    }
    expect(p, T_RPAREN, "')'");

    if (match(p, T_ARROW))
        f->ret_type = xstrdup(parse_type_name(p));

    f->body = parse_block(p, 1);
    return f;
}

static void program_push_import(Program *prog, char *path) {
    if (prog->nimports == prog->icap) {
        prog->icap = prog->icap ? prog->icap * 2 : 8;
        prog->import_paths = (char **)xrealloc(
            prog->import_paths, prog->icap * sizeof(char *));
    }
    prog->import_paths[prog->nimports++] = path;
}

/* import "path/to/pkg" ; */
static void parse_import(Parser *p, Program *prog) {
    advance(p); /* 'import' */
    Token *path = expect(p, T_STRING, "a package path string");
    expect(p, T_SEMI, "';'");
    program_push_import(prog, path->text);
}

Program *parse_program(Token *tokens, int ntokens) {
    Parser p;
    p.toks = tokens;
    p.pos = 0;
    p.count = ntokens;
    p.fn_body = 0;

    Program *prog = (Program *)xmalloc(sizeof(Program));
    memset(prog, 0, sizeof(Program));
    prog->main_body = new_block();

    while (!check(&p, T_EOF)) {
        int is_pub = 0;
        if (match(&p, T_KW_PUB))
            is_pub = 1;

        if (check(&p, T_KW_IMPORT)) {
            if (is_pub)
                parse_error(peek(&p), "'pub' cannot precede 'import'");
            parse_import(&p, prog);
            continue;
        }

        if (check(&p, T_KW_FN)) {
            FuncDecl *f = parse_fn_decl(&p);
            f->is_pub = is_pub;
            if (prog->nfuncs == prog->fcap) {
                prog->fcap = prog->fcap ? prog->fcap * 2 : 8;
                prog->funcs = (FuncDecl **)xrealloc(
                    prog->funcs, prog->fcap * sizeof(FuncDecl *));
            }
            prog->funcs[prog->nfuncs++] = f;
            continue;
        }

        if (is_pub) {
            Stmt *s = parse_statement(&p);
            if (s->kind != ST_LET)
                parse_error(peek(&p),
                            "'pub' can only precede a function or a "
                            "top-level 'let'");
            s->as.let.is_pub = 1;
            block_push(prog->main_body, s);
            continue;
        }

        block_push(prog->main_body, parse_statement(&p));
    }
    return prog;
}
