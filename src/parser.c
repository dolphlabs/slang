#include "common.h"
#include "ast.h"
#include "parser.h"

#include <ctype.h>
#include <stdarg.h>

typedef struct {
    Token *toks;
    int pos;
    int count;
    int fn_body; /* inside a function body: trailing expr = implicit return */
    int in_unsafe;
    /* A statement that must be emitted immediately BEFORE the one
     * parse_statement is about to return. Used by compound assignment to
     * hoist a side-effecting index into its own `let`. It has to land in
     * the enclosing block as a sibling, not nested inside the assignment:
     * liveness/escape/move all assume a `let` appears directly in a
     * Block ("internal: ST_LET reached live_stmt directly"). */
    Stmt *pending;
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

static Expr *new_expr(Parser *p, ExprKind kind, int line) {
    Expr *e = (Expr *)xmalloc(sizeof(Expr));
    memset(e, 0, sizeof(Expr));
    e->kind = kind;
    e->line = line;
    e->in_unsafe = p->in_unsafe;
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
    memset(b, 0, sizeof(Block));
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

static void method_push_arg(Expr *m, Expr *arg) {
    int n = m->as.method.nargs;
    m->as.method.args =
        (Expr **)xrealloc(m->as.method.args, (n + 1) * sizeof(Expr *));
    m->as.method.args[n] = arg;
    m->as.method.nargs = n + 1;
}

static void call_push_arg(Expr *call, Expr *arg) {
    int n = call->as.call.nargs;
    call->as.call.args =
        (Expr **)xrealloc(call->as.call.args, (n + 1) * sizeof(Expr *));
    call->as.call.args[n] = arg;
    call->as.call.nargs = n + 1;
}

/* ---- expressions (precedence climbing) ---- */

static Expr *parse_expression(Parser *p);
static Type *parse_type(Parser *p);
static const char *parse_type_name(Parser *p);
static char *parse_type_args(Parser *p);
static FuncDecl *parse_fn_decl(Parser *p, int is_extern);
static int parse_lt_params(Parser *p, char ***out);
static int parse_type_params(Parser *p, char ***out);

static int next_is(Parser *p, TokenType t) {
    if (p->pos + 1 >= p->count)
        return 0;
    return p->toks[p->pos + 1].type == t;
}

static Type *ty_new(TypeKind k) {
    Type *t = (Type *)xmalloc(sizeof(Type));
    memset(t, 0, sizeof(Type));
    t->kind = k;
    return t;
}

static Type *ty_named(char *name) {
    Type *t = ty_new(TY_NAMED);
    t->as.name = name;
    return t;
}

static Type *ty_wrap(TypeKind k, Type *inner) {
    Type *t = ty_new(k);
    t->as.inner = inner;
    return t;
}

static char *type_string(Type *t) {
    switch (t->kind) {
    case TY_NAMED:
        return xstrdup(t->as.name);
    case TY_ARRAY:
        return xasprintf("[%s]", type_string(t->as.inner));
    case TY_MAP:
        return xasprintf("map[%s]%s", type_string(t->as.map.key),
                         type_string(t->as.map.val));
    case TY_OPT:
        return xasprintf("opt[%s]", type_string(t->as.inner));
    case TY_RESULT:
        return xasprintf("result[%s,%s]", type_string(t->as.result.ok),
                         type_string(t->as.result.err));
    case TY_CHAN:
        return xasprintf("chan[%s]", type_string(t->as.inner));
    case TY_JOIN:
        return xasprintf("join[%s]", type_string(t->as.inner));
    case TY_REF:
        if (t->lt)
            return xasprintf("&'%s %s", t->lt, type_string(t->as.inner));
        return xasprintf("&%s", type_string(t->as.inner));
    case TY_REFMUT:
        if (t->lt)
            return xasprintf("&'%s mut %s", t->lt, type_string(t->as.inner));
        return xasprintf("&mut %s", type_string(t->as.inner));
    case TY_OWN:
        return xasprintf("own %s", type_string(t->as.inner));
    case TY_GC:
        return xasprintf("gc %s", type_string(t->as.inner));
    case TY_PTR:
        return xasprintf("ptr[%s]", type_string(t->as.inner));
    case TY_RAW:
        return xasprintf("*%s", type_string(t->as.inner));
    case TY_RAWMUT:
        return xasprintf("*mut %s", type_string(t->as.inner));
    }
    return NULL;
}

static void list_push_elem(Expr *list, Expr *elem) {
    int n = list->as.list.nelems;
    list->as.list.elems =
        (Expr **)xrealloc(list->as.list.elems, (n + 1) * sizeof(Expr *));
    list->as.list.elems[n] = elem;
    list->as.list.nelems = n + 1;
}

static void maplit_push_pair(Expr *m, Expr *k, Expr *v) {
    int n = m->as.maplit.npairs;
    m->as.maplit.keys =
        (Expr **)xrealloc(m->as.maplit.keys, (n + 1) * sizeof(Expr *));
    m->as.maplit.vals =
        (Expr **)xrealloc(m->as.maplit.vals, (n + 1) * sizeof(Expr *));
    m->as.maplit.keys[n] = k;
    m->as.maplit.vals[n] = v;
    m->as.maplit.npairs = n + 1;
}

/* Token two positions ahead of the cursor (peek2 = toks[pos+1]). */
static Token *peek_at(Parser *p, int off) {
    int i = p->pos + off;
    if (i >= p->count)
        i = p->count - 1;
    return &p->toks[i];
}
static Expr *parse_expr_source(const char *src, int line, int in_unsafe);
static Expr *parse_interp_string(Parser *p, Token *tk);

/* A member name after '.' may be spelled the same as a keyword:
 * `strings.join` collides with the `join[T]` type, `x.map` with
 * `map[K]V`, `r.result` with `result[T,E]`. There is no ambiguity in
 * this position -- whatever follows a dot is a name -- so accept any
 * identifier-shaped token rather than making package authors memorise
 * a list of words they may not use.
 *
 * Tested by shape rather than by token range: every keyword now carries
 * its spelling (see the KW macro in lexer.c), and a range check over
 * the T_TY_* block silently excluded `chan` and `join` because those
 * two sit after T_TY_LINK in the enum. A range would break again the
 * next time a type token is appended. */
static int ident_shaped(const Token *tk) {
    if (!tk->text || !tk->text[0])
        return 0;
    if (!isalpha((unsigned char)tk->text[0]) && tk->text[0] != '_')
        return 0;
    for (const char *p = tk->text; *p; p++)
        if (!isalnum((unsigned char)*p) && *p != '_')
            return 0;
    return 1;
}

static Token *expect_member(Parser *p, const char *what) {
    Token *tk = peek(p);
    if (tk->type == T_IDENT || ident_shaped(tk))
        return advance(p);
    return expect(p, T_IDENT, what);
}

/* At a '[' after a name: is this `[type arguments] { field:` rather than
 * an index? Scans to the matching ']' (types nest brackets and parens) and
 * then applies the same 'ident {' + 'ident :' test a plain struct literal
 * uses, which a block after an index expression never satisfies. */
static int generic_literal_ahead(Parser *p) {
    int depth = 0;
    for (int i = p->pos; i < p->count; i++) {
        switch (p->toks[i].type) {
        case T_LBRACKET:
        case T_LPAREN:
            depth++;
            break;
        case T_RPAREN:
            depth--;
            break;
        case T_RBRACKET:
            if (--depth == 0) {
                if (i + 3 >= p->count)
                    return 0;
                return p->toks[i + 1].type == T_LBRACE &&
                       p->toks[i + 2].type == T_IDENT &&
                       p->toks[i + 3].type == T_COLON;
            }
            break;
        case T_SEMI:
        case T_LBRACE:
        case T_RBRACE:
        case T_EOF:
            return 0;
        default:
            break;
        }
    }
    return 0;
}

static Expr *parse_primary(Parser *p) {
    Token *tk = peek(p);
    switch (tk->type) {
    case T_INT: {
        advance(p);
        Expr *e = new_expr(p, EX_INT, tk->line);
        e->as.int_lit.value = tk->int_val;
        e->as.int_lit.big_u64 = tk->big_u64;
        return e;
    }
    case T_FLOAT: {
        advance(p);
        Expr *e = new_expr(p, EX_FLOAT, tk->line);
        e->as.float_lit.value = tk->float_val;
        return e;
    }
    case T_STRING: {
        advance(p);
        return parse_interp_string(p, tk);
    }
    case T_BYTES: {
        advance(p);
        Expr *e = new_expr(p, EX_BYTES, tk->line);
        e->as.bytes_lit.data = tk->byte_val;
        e->as.bytes_lit.len = tk->byte_len;
        return e;
    }
    case T_LBRACKET: {
        advance(p);
        Expr *e = new_expr(p, EX_LIST, tk->line);
        if (!check(p, T_RBRACKET)) {
            for (;;) {
                list_push_elem(e, parse_expression(p));
                if (!match(p, T_COMMA))
                    break;
            }
        }
        expect(p, T_RBRACKET, "']' to close list literal");
        return e;
    }
    case T_LBRACE: {
        /* map literal: {key: value, ...} */
        advance(p);
        Expr *e = new_expr(p, EX_MAPLIT, tk->line);
        if (!check(p, T_RBRACE)) {
            for (;;) {
                Expr *k = parse_expression(p);
                expect(p, T_COLON, "':' between key and value in map "
                                   "literal");
                Expr *v = parse_expression(p);
                maplit_push_pair(e, k, v);
                if (!match(p, T_COMMA))
                    break;
            }
        }
        expect(p, T_RBRACE, "'}' to close map literal");
        return e;
    }
    case T_KW_TRUE:
    case T_KW_FALSE: {
        advance(p);
        Expr *e = new_expr(p, EX_BOOL, tk->line);
        e->as.bool_lit.value = (tk->type == T_KW_TRUE);
        return e;
    }
    case T_KW_SPAWN: {
        Token *kw = advance(p);
        Expr *call = parse_primary(p);
        if (call->kind != EX_CALL)
            parse_error(kw, "'spawn' requires a function call, e.g. "
                            "'spawn handle(conn)'");
        Expr *e = new_expr(p, EX_SPAWN, kw->line);
        e->as.spawn.call = call;
        return e;
    }
    case T_IDENT: {
        advance(p);
        /* qualified name: pkg.member (one dot only) */
        char *name = tk->text;
        if (check(p, T_DOT)) {
            advance(p);
            Token *member = expect_member(p, "a member name after '.'");
            StrBuf sb;
            sb_init(&sb);
            sb_append(&sb, tk->text);
            sb_append(&sb, p_dot_str);
            sb_append(&sb, member->text);
            name = sb.data;
        }
        /* `Box[int] { ... }`. `Box[int]` is otherwise an index expression,
         * so the type arguments are only taken when the matching ']' is
         * followed by the struct-literal opening below. */
        if (check(p, T_LBRACKET) && generic_literal_ahead(p))
            name = xasprintf("%s%s", name, parse_type_args(p));
        /* struct literal: Name { field: value, ... } — recognized by the
         * 'ident {' + 'ident :' lookahead so it can't collide with
         * blocks following conditions like 'while running {'. */
        if (check(p, T_LBRACE) && peek_at(p, 1)->type == T_IDENT &&
            peek_at(p, 2)->type == T_COLON) {
            advance(p); /* '{' */
            Expr *sl = new_expr(p, EX_STRUCTLIT, tk->line);
            sl->as.structlit.tyname = name;
            int nf = 0;
            for (;;) {
                Token *f = expect(p, T_IDENT, "a field name");
                expect(p, T_COLON, "':' between field and value");
                Expr *v = parse_expression(p);
                sl->as.structlit.fields = (char **)xrealloc(
                    sl->as.structlit.fields, (nf + 1) * sizeof(char *));
                sl->as.structlit.vals = (Expr **)xrealloc(
                    sl->as.structlit.vals, (nf + 1) * sizeof(Expr *));
                sl->as.structlit.fields[nf] = f->text;
                sl->as.structlit.vals[nf] = v;
                nf++;
                if (!match(p, T_COMMA))
                    break;
            }
            sl->as.structlit.nfields = nf;
            expect(p, T_RBRACE, "'}' to close struct literal");
            return sl;
        }
        if (check(p, T_LPAREN)) {
            advance(p); /* '(' */
            Expr *call = new_expr(p, EX_CALL, tk->line);
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
        Expr *e = new_expr(p, EX_IDENT, tk->line);
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

/* Indexing, slicing, and field access:
 * base[i], base[a..b], base[a..=b], base.field */
static Expr *parse_postfix(Parser *p) {
    Expr *e = parse_primary(p);
    for (;;) {
        if (check(p, T_DOT)) {
            /* `.name(` is a method call on whatever `e` evaluated to. A
             * bare `ident.name(` never reaches here -- parse_primary folds
             * it into a dotted-name EX_CALL itself -- so `e` is a call, an
             * index, a field of a field (`a.b.c()`), or a parenthesised
             * expression. A fn-typed FIELD called this way
             * (`routes[i].handler(req)`) also lands here; which one it is
             * depends on the receiver's type, so infer_method decides. */
            Token *nm = peek_at(p, 1);
            if ((nm->type == T_IDENT || ident_shaped(nm)) &&
                peek_at(p, 2)->type == T_LPAREN) {
                advance(p); /* '.' */
                Token *mt = expect_member(p, "a method name after '.'");
                advance(p); /* '(' */
                Expr *m = new_expr(p, EX_METHOD, mt->line);
                m->as.method.recv = e;
                m->as.method.name = mt->text;
                if (!check(p, T_RPAREN)) {
                    for (;;) {
                        method_push_arg(m, parse_expression(p));
                        if (!match(p, T_COMMA))
                            break;
                    }
                }
                expect(p, T_RPAREN, "')' to close argument list");
                e = m;
                continue;
            }
            advance(p); /* '.' */
            Token *f = expect_member(p, "a field name after '.'");
            Expr *fl = new_expr(p, EX_FIELD, f->line);
            fl->as.field.base = e;
            fl->as.field.name = f->text;
            e = fl;
            continue;
        }
        if (check(p, T_LPAREN)) {
            /* A call through whatever `e` evaluated to. A plain or
             * dotted NAME never reaches here -- parse_primary consumes
             * its '(' itself -- so this is only ever a field, index or
             * parenthesised expression holding a function value. */
            advance(p); /* '(' */
            Expr *call = new_expr(p, EX_CALL, e->line);
            /* `callee` is the discriminator; `name` still gets a
             * non-NULL sentinel so that the many passes which read it
             * unconditionally (strcmp, split_dotted, sig lookups) stay
             * safe. It cannot collide with a real identifier, so every
             * one of those lookups simply fails to match -- which is
             * the right answer for a call that has no name. */
            call->as.call.name = xstrdup("<function value>");
            call->as.call.callee = e;
            if (!check(p, T_RPAREN)) {
                for (;;) {
                    call_push_arg(call, parse_expression(p));
                    if (!match(p, T_COMMA))
                        break;
                }
            }
            expect(p, T_RPAREN, "')' to close argument list");
            e = call;
            continue;
        }
        if (!check(p, T_LBRACKET))
            break;
        advance(p); /* '[' */
        Expr *start = NULL;
        if (!check(p, T_DOTDOT) && !check(p, T_DOTDOTEQ))
            start = parse_expression(p);
        if (check(p, T_DOTDOT) || check(p, T_DOTDOTEQ)) {
            int inclusive;
            if (match(p, T_DOTDOTEQ)) {
                inclusive = 1;
            } else {
                advance(p); /* '..' */
                inclusive = 0;
            }
            Expr *end = NULL;
            if (!check(p, T_RBRACKET))
                end = parse_expression(p);
            expect(p, T_RBRACKET, "']' to close slice");
            Expr *s = new_expr(p, EX_SLICE, e->line);
            s->as.slice.base = e;
            s->as.slice.start = start;
            s->as.slice.end = end;
            s->as.slice.inclusive = inclusive;
            e = s;
        } else {
            expect(p, T_RBRACKET, "']' to close index");
            Expr *ix = new_expr(p, EX_INDEX, e->line);
            ix->as.index.base = e;
            ix->as.index.index = start;
            e = ix;
        }
    }
    return e;
}

static Expr *parse_unary(Parser *p) {
    Token *tk = peek(p);
    if (tk->type == T_MINUS || tk->type == T_BANG || tk->type == T_TILDE) {
        advance(p);
        Expr *operand = parse_unary(p);
        Expr *e = new_expr(p, EX_UNARY, tk->line);
        e->as.unary.op = xstrdup(tk->type == T_MINUS ? "-"
                                 : tk->type == T_TILDE ? "~" : "!");
        e->as.unary.operand = operand;
        return e;
    }
    if (tk->type == T_AMP) {
        advance(p);
        int mut = match(p, T_KW_MUT);
        Expr *operand = parse_unary(p);
        Expr *e = new_expr(p, EX_UNARY, tk->line);
        e->as.unary.op = xstrdup(mut ? "&mut" : "&");
        e->as.unary.operand = operand;
        return e;
    }
    if (tk->type == T_STAR) {
        advance(p);
        Expr *operand = parse_unary(p);
        Expr *e = new_expr(p, EX_UNARY, tk->line);
        e->as.unary.op = xstrdup("*");
        e->as.unary.operand = operand;
        return e;
    }
    Expr *e = parse_postfix(p);
    /* explicit casts: expr as T (the only way to narrow) */
    while (match(p, T_KW_AS)) {
        const char *ty = parse_type_name(p);
        Expr *c = new_expr(p, EX_CAST, e->line);
        c->as.cast.ty = xstrdup(ty);
        c->as.cast.operand = e;
        e = c;
    }
    return e;
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
    case T_AMP:     return "&";
    case T_PIPE:    return "|";
    case T_CARET:   return "^";
    case T_SHL:     return "<<";
    case T_SHR:     return ">>";
    default:        return "?";
    }
}

static Expr *make_binary(Parser *p, char *op, Expr *lhs, Expr *rhs, int line) {
    Expr *e = new_expr(p, EX_BINARY, line);
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
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_term(Parser *p) {
    Expr *lhs = parse_factor(p);
    while (check(p, T_PLUS) || check(p, T_MINUS)) {
        Token *op = advance(p);
        Expr *rhs = parse_factor(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

/* Bitwise precedence follows C exactly, so an expression copied out of
 * an RFC or a C reference implementation means the same thing here:
 *   ||  <  &&  <  |  <  ^  <  &  <  == !=  <  relational  <  << >>
 *   <  + -  <  * / %  <  unary
 * Infix '&' is unambiguous against the '&x' / '&mut x' borrow forms
 * because those are parsed in prefix position by parse_unary. */
static Expr *parse_shift(Parser *p) {
    Expr *lhs = parse_term(p);
    while (check(p, T_SHL) || check(p, T_SHR)) {
        Token *op = advance(p);
        Expr *rhs = parse_term(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_comparison(Parser *p) {
    Expr *lhs = parse_shift(p);
    while (check(p, T_LT) || check(p, T_GT) || check(p, T_LTE) ||
           check(p, T_GTE)) {
        Token *op = advance(p);
        Expr *rhs = parse_shift(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_equality(Parser *p) {
    Expr *lhs = parse_comparison(p);
    while (check(p, T_EQEQ) || check(p, T_BANGEQ)) {
        Token *op = advance(p);
        Expr *rhs = parse_comparison(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_bitand(Parser *p) {
    Expr *lhs = parse_equality(p);
    while (check(p, T_AMP)) {
        Token *op = advance(p);
        Expr *rhs = parse_equality(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_bitxor(Parser *p) {
    Expr *lhs = parse_bitand(p);
    while (check(p, T_CARET)) {
        Token *op = advance(p);
        Expr *rhs = parse_bitand(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_bitor(Parser *p) {
    Expr *lhs = parse_bitxor(p);
    while (check(p, T_PIPE)) {
        Token *op = advance(p);
        Expr *rhs = parse_bitxor(p);
        lhs = make_binary(p, xstrdup(op_text(op->type)), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_and(Parser *p) {
    Expr *lhs = parse_bitor(p);
    while (match(p, T_ANDAND)) {
        Expr *rhs = parse_bitor(p);
        lhs = make_binary(p, xstrdup("&&"), lhs, rhs, peek(p)->line);
    }
    return lhs;
}

static Expr *parse_or(Parser *p) {
    Expr *lhs = parse_and(p);
    while (match(p, T_OROR)) {
        Expr *rhs = parse_and(p);
        lhs = make_binary(p, xstrdup("||"), lhs, rhs, peek(p)->line);
    }
    return lhs;
}

/* null-coalescing: binds tighter than ||, right-associative */
static Expr *parse_coalesce(Parser *p) {
    Expr *lhs = parse_or(p);
    if (check(p, T_QQ)) {
        Token *op = advance(p);
        Expr *rhs = parse_coalesce(p);
        lhs = make_binary(p, xstrdup("??"), lhs, rhs, op->line);
    }
    return lhs;
}

static Expr *parse_expression(Parser *p) { return parse_coalesce(p); }

/* Parse an expression embedded in a string interpolation. The source
 * substring is lexed and parsed independently. */
static Expr *parse_expr_source(const char *src, int line, int in_unsafe) {
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
    memset(&sub, 0, sizeof(sub));
    sub.toks = toks;
    sub.count = n;
    sub.in_unsafe = in_unsafe;

    Expr *e = parse_expression(&sub);
    if (!check(&sub, T_EOF))
        parse_error(peek(&sub), "unexpected token in interpolation");
    return e;
}

/* Build the expression tree for a (possibly interpolated) string
 * literal. Interpolation segments were stored between marker bytes by
 * the lexer; each becomes a sub-expression joined with '+'. */
static Expr *parse_interp_string(Parser *p, Token *tk) {
    const char *s = tk->text;
    int has_marker = 0;
    for (const char *q = s; *q; q++) {
        if (*q == 1) {
            has_marker = 1;
            break;
        }
    }
    if (!has_marker) {
        Expr *e = new_expr(p, EX_STRING, tk->line);
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
                part = parse_expr_source(text, tk->line, p->in_unsafe);
            } else {
                part = new_expr(p, EX_STRING, tk->line);
                part->as.str_lit.value = text;
            }
            if (!acc) {
                acc = part;
            } else {
                acc = make_binary(p, xstrdup("+"), acc, part, tk->line);
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

static Type *parse_type_atom(Parser *p) {
    Token *tk = peek(p);
    switch (tk->type) {
    case T_TY_INT:   advance(p); return ty_named(xstrdup("int"));
    case T_TY_FLOAT: advance(p); return ty_named(xstrdup("float"));
    case T_TY_STR:   advance(p); return ty_named(xstrdup("str"));
    case T_TY_BOOL:  advance(p); return ty_named(xstrdup("bool"));
    case T_TY_BYTES: advance(p); return ty_named(xstrdup("bytes"));
    case T_TY_I8:    advance(p); return ty_named(xstrdup("i8"));
    case T_TY_I16:   advance(p); return ty_named(xstrdup("i16"));
    case T_TY_I32:   advance(p); return ty_named(xstrdup("i32"));
    case T_TY_I64:   advance(p); return ty_named(xstrdup("i64"));
    case T_TY_U8:    advance(p); return ty_named(xstrdup("u8"));
    case T_TY_U16:   advance(p); return ty_named(xstrdup("u16"));
    case T_TY_U32:   advance(p); return ty_named(xstrdup("u32"));
    case T_TY_U64:   advance(p); return ty_named(xstrdup("u64"));
    case T_TY_F32:   advance(p); return ty_named(xstrdup("f32"));
    case T_TY_MAP: {
        advance(p);
        expect(p, T_LBRACKET, "'[' after 'map'");
        Type *k = parse_type(p);
        expect(p, T_RBRACKET, "']' between key and value types");
        Type *v = parse_type(p);
        Type *t = ty_new(TY_MAP);
        t->as.map.key = k;
        t->as.map.val = v;
        return t;
    }
    case T_TY_OPT: {
        advance(p);
        expect(p, T_LBRACKET, "'[' after 'opt'");
        Type *inner = parse_type(p);
        expect(p, T_RBRACKET, "']' to close opt type");
        return ty_wrap(TY_OPT, inner);
    }
    case T_TY_CHAN: {
        advance(p);
        expect(p, T_LBRACKET, "'[' after 'chan'");
        Type *inner = parse_type(p);
        expect(p, T_RBRACKET, "']' to close chan type");
        return ty_wrap(TY_CHAN, inner);
    }
    case T_TY_JOIN: {
        advance(p);
        expect(p, T_LBRACKET, "'[' after 'join'");
        Type *inner = parse_type(p);
        expect(p, T_RBRACKET, "']' to close join type");
        return ty_wrap(TY_JOIN, inner);
    }
    case T_TY_RESULT: {
        advance(p);
        expect(p, T_LBRACKET, "'[' after 'result'");
        Type *ok = parse_type(p);
        expect(p, T_COMMA, "',' between value and error types");
        Type *err = parse_type(p);
        expect(p, T_RBRACKET, "']' to close result type");
        Type *t = ty_new(TY_RESULT);
        t->as.result.ok = ok;
        t->as.result.err = err;
        return t;
    }
    case T_TY_DURATION:
        advance(p);
        return ty_named(xstrdup("duration"));
    case T_TY_RAWPTR:
        advance(p);
        return ty_named(xstrdup("rawptr"));
    case T_TY_ARENA:
        advance(p);
        return ty_named(xstrdup("arena"));
    case T_TY_WIRE:
        advance(p);
        return ty_named(xstrdup("wire"));
    case T_TY_UNTIL:
        advance(p);
        return ty_named(xstrdup("until"));
    case T_TY_FAULT:
        advance(p);
        return ty_named(xstrdup("fault"));
    case T_TY_PEER:
        advance(p);
        return ty_named(xstrdup("peer"));
    case T_TY_TRIP:
        advance(p);
        return ty_named(xstrdup("trip"));
    case T_KW_LINK:
    case T_TY_LINK:
        advance(p);
        return ty_named(xstrdup("link"));
    case T_KW_FN: {
        /* fn(A, B) -> R, or fn(A) for one returning nothing. The value
         * is a plain function pointer: slang has no closures, so there
         * is no captured environment for this type to describe. */
        StrBuf b;
        advance(p);
        expect(p, T_LPAREN, "'(' after 'fn' in a type");
        sb_init(&b);
        sb_append(&b, "fn(");
        if (!check(p, T_RPAREN)) {
            int first = 1;
            do {
                Type *pt = parse_type(p);
                if (!first)
                    sb_append(&b, ",");
                sb_append(&b, type_string(pt));
                first = 0;
            } while (match(p, T_COMMA));
        }
        expect(p, T_RPAREN, "')' to close the parameter list");
        sb_append(&b, ")");
        if (match(p, T_ARROW)) {
            Type *rt = parse_type(p);
            sb_append(&b, "->");
            sb_append(&b, type_string(rt));
        }
        return ty_named(b.data);
    }
    case T_IDENT: {
        if (!strcmp(tk->text, "ptr") && next_is(p, T_LBRACKET)) {
            advance(p);
            expect(p, T_LBRACKET, "'[' after 'ptr'");
            Type *inner = parse_type(p);
            expect(p, T_RBRACKET, "']' to close ptr type");
            return ty_wrap(TY_PTR, inner);
        }
        advance(p);
        char *name = tk->text;
        if (check(p, T_DOT)) {
            advance(p);
            Token *member = expect(p, T_IDENT, "a type name after '.'");
            name = xasprintf("%s%s%s", name, p_dot_str, member->text);
        }
        /* A generic struct's arguments: Box[int], geom.Pair[str,int].
         * The result stays a plain named type -- its text is what every
         * later stage keys on -- so nothing downstream needs a new Type
         * kind. */
        if (check(p, T_LBRACKET))
            name = xasprintf("%s%s", name, parse_type_args(p));
        return ty_named(name);
    }
    case T_LBRACKET: {
        advance(p);
        Type *inner = parse_type(p);
        expect(p, T_RBRACKET, "']' to close array type");
        return ty_wrap(TY_ARRAY, inner);
    }
    default:
        parse_error(tk,
                    "expected a type name (int, float, str, bool, bytes, "
                    "i8..u64, f32, [T], map[K]V, opt[T], result[T,E], "
                    "chan[T], join[T], duration, rawptr, arena, wire, until, fault, "
                    "peer, trip, link, ptr[T], own T, gc T, "
                    "&T, &'a T, &mut T, *T, *mut T, or a struct name)");
    }
    return NULL;
}

static Type *parse_type(Parser *p) {
    if (match(p, T_KW_OWN))
        return ty_wrap(TY_OWN, parse_type(p));
    if (match(p, T_KW_GC))
        return ty_wrap(TY_GC, parse_type(p));
    if (match(p, T_AMP)) {
        char *lt = NULL;
        Type *t;
        if (check(p, T_LIFETIME))
            lt = advance(p)->text;
        if (match(p, T_KW_MUT))
            t = ty_wrap(TY_REFMUT, parse_type(p));
        else
            t = ty_wrap(TY_REF, parse_type(p));
        t->lt = lt;
        return t;
    }
    if (match(p, T_STAR)) {
        if (match(p, T_KW_MUT))
            return ty_wrap(TY_RAWMUT, parse_type(p));
        return ty_wrap(TY_RAW, parse_type(p));
    }
    return parse_type_atom(p);
}

/* `[A, B]` after a generic struct's name, as the text "[A,B]". The
 * arguments are types, so `Box[Box[int]]` and `Pair[str,[int]]` nest. */
static char *parse_type_args(Parser *p) {
    Token *open = expect(p, T_LBRACKET, "'['");
    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb, "[");
    int n = 0;
    for (;;) {
        if (n == MAX_TYPE_PARAMS)
            parse_error(open, "a generic type takes at most %d type "
                              "arguments", MAX_TYPE_PARAMS);
        if (n)
            sb_append(&sb, ",");
        sb_append(&sb, type_string(parse_type(p)));
        n++;
        if (!match(p, T_COMMA))
            break;
    }
    expect(p, T_RBRACKET, "']' to close the type arguments");
    sb_append(&sb, "]");
    return sb.data;
}

static const char *parse_type_name(Parser *p) {
    return type_string(parse_type(p));
}

static Stmt *parse_if_stmt(Parser *p);
static Stmt *parse_statement(Parser *p);
static Stmt *parse_struct_decl(Parser *p, int is_pub, int is_gc);
static Stmt *parse_enum_decl(Parser *p, int is_pub);
static Stmt *parse_impl_decl(Parser *p);

/* Parse one statement into `blk`, draining any statement the parser
 * hoisted ahead of it (compound assignment's index temporary).
 *
 * Every site that collects statements MUST go through this. Leaving the
 * drain to each caller is how the hoisted `let` ends up either dropped
 * or emitted after the statement that reads it -- and the `pub` branch
 * in parse_program did exactly that until this helper existed. */
static void parse_into_block(Parser *p, Block *blk) {
    Stmt *st = parse_statement(p);
    if (p->pending) {
        block_push(blk, p->pending);
        p->pending = NULL;
    }
    block_push(blk, st);
}

static Block *parse_block(Parser *p, int fn_body) {
    expect(p, T_LBRACE, "'{'");
    Block *blk = new_block();
    int saved = p->fn_body;
    p->fn_body = fn_body;
    while (!check(p, T_RBRACE)) {
        if (check(p, T_EOF))
            parse_error(peek(p), "unexpected end of file inside block");
        parse_into_block(p, blk);
    }
    p->fn_body = saved;
    expect(p, T_RBRACE, "'}'");
    return blk;
}

static Stmt *parse_let_stmt(Parser *p) {
    Token *kw = advance(p); /* 'let' */
    Token *name = expect(p, T_IDENT, "a variable name");

    char *type_ann = NULL;
    if (match(p, T_COLON))
        type_ann = xstrdup(parse_type_name(p));

    expect(p, T_ASSIGN, "'='");
    Expr *init = parse_expression(p);
    expect(p, T_SEMI, "';'");

    Stmt *s = new_stmt(ST_LET, kw->line);
    s->as.let.name = name->text;
    s->as.let.type_ann = type_ann;
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

/* guard <cond> else { ... }  ==  if !<cond> { ... }
 * guard let <name> = <expr> else { ... } — unwrap an opt/result,
 * binding the value; the else block must exit (return/break/...) */
static Stmt *parse_guard_stmt(Parser *p) {
    Token *kw = advance(p);

    if (check(p, T_KW_LET)) {
        advance(p); /* 'let' */
        Token *name = expect(p, T_IDENT, "a variable name");
        expect(p, T_ASSIGN, "'='");
        Expr *expr = parse_expression(p);
        expect(p, T_KW_ELSE, "'else'");
        char *err_name = NULL;
        Expr *err_expr = NULL;
        if (check(p, T_KW_LET)) {
            advance(p);
            Token *ename = expect(p, T_IDENT, "a variable name");
            expect(p, T_ASSIGN, "'='");
            err_expr = parse_expression(p);
            err_name = ename->text;
        }
        Block *body = parse_block(p, 0);

        Stmt *s = new_stmt(ST_GUARD_LET, kw->line);
        s->as.guard_let.name = name->text;
        s->as.guard_let.expr = expr;
        s->as.guard_let.err_name = err_name;
        s->as.guard_let.err_expr = err_expr;
        s->as.guard_let.body = body;
        return s;
    }

    Expr *cond = parse_expression(p);
    expect(p, T_KW_ELSE, "'else'");
    Block *body = parse_block(p, 0);

    Stmt *s = new_stmt(ST_IF, kw->line);
    Expr *neg = new_expr(p, EX_UNARY, kw->line);
    neg->as.unary.op = xstrdup("!");
    neg->as.unary.operand = cond;
    s->as.if_stmt.cond = neg;
    s->as.if_stmt.then_blk = body;
    s->as.if_stmt.else_blk = NULL;
    return s;
}

/* spawn f(args...) ; -- submit a task to the M:N pool.
 * Arguments are evaluated in the spawning context (no closures). */
static Stmt *parse_spawn_stmt(Parser *p) {
    Token *kw = advance(p); /* 'spawn' */
    Expr *call = parse_expression(p);
    if (call->kind != EX_CALL)
        parse_error(kw, "'spawn' requires a function call, e.g. "
                        "'spawn handle(conn);'");
    expect(p, T_SEMI, "';'");

    Stmt *s = new_stmt(ST_SPAWN, kw->line);
    s->as.spawn.call = call;
    return s;
}

/* select {
 *     case let v = chan_recv(ch) { ... }
 *     case chan_send(ch, v)      { ... }
 *     default                    { ... }
 * }
 *
 * The arms reuse chan_recv/chan_send rather than inventing an arrow
 * operator: they already name exactly what each arm does, and a reader
 * who knows the builtins needs no second notation for them. What they
 * are NOT here is expressions -- they are the arm's shape, matched
 * syntactically, which is why an arbitrary call is rejected below. */
static Stmt *parse_select_stmt(Parser *p) {
    Token *kw = advance(p); /* 'select' */
    expect(p, T_LBRACE, "'{' after 'select'");

    SelectCase *cases = NULL;
    int ncases = 0, cap = 0;
    Block *def = NULL;

    while (!check(p, T_RBRACE) && !check(p, T_EOF)) {
        if (check(p, T_KW_DEFAULT)) {
            Token *dk = advance(p);
            if (def)
                parse_error(dk, "'select' already has a 'default' arm");
            def = parse_block(p, 0);
            continue;
        }
        Token *ck = expect(p, T_KW_CASE,
                           "'case' or 'default' inside 'select'");
        SelectCase sc;
        sc.is_send = 0;
        sc.bind = NULL;
        sc.ch = NULL;
        sc.val = NULL;
        sc.body = NULL;
        sc.line = ck->line;

        if (match(p, T_KW_LET)) {
            Token *nm = expect(p, T_IDENT, "a name to bind the received "
                                           "value to");
            sc.bind = nm->text;
            expect(p, T_ASSIGN, "'=' after the bound name");
        }

        Expr *call = parse_expression(p);
        if (call->kind != EX_CALL)
            parse_error(ck,
                        "a 'select' arm must be 'chan_recv(ch)' or "
                        "'chan_send(ch, v)'");
        const char *fname = call->as.call.name;
        if (fname && !strcmp(fname, "chan_recv")) {
            if (call->as.call.nargs != 1)
                parse_error(ck, "chan_recv() takes exactly one argument");
            sc.is_send = 0;
            sc.ch = call->as.call.args[0];
        } else if (fname && !strcmp(fname, "chan_send")) {
            if (sc.bind)
                parse_error(ck, "a 'chan_send' arm binds nothing; drop "
                                "the 'let'");
            if (call->as.call.nargs != 2)
                parse_error(ck, "chan_send() takes exactly two arguments");
            sc.is_send = 1;
            sc.ch = call->as.call.args[0];
            sc.val = call->as.call.args[1];
        } else {
            parse_error(ck,
                        "a 'select' arm must be 'chan_recv(ch)' or "
                        "'chan_send(ch, v)'");
        }

        sc.body = parse_block(p, 0);
        if (ncases == cap) {
            cap = cap ? cap * 2 : 4;
            cases = (SelectCase *)xrealloc(cases,
                                           (size_t)cap * sizeof(*cases));
        }
        cases[ncases++] = sc;
    }
    expect(p, T_RBRACE, "'}' to close 'select'");

    if (ncases == 0)
        parse_error(kw, "'select' needs at least one 'case' arm");

    Stmt *s = new_stmt(ST_SELECT, kw->line);
    s->as.select_stmt.cases = cases;
    s->as.select_stmt.ncases = ncases;
    s->as.select_stmt.def = def;
    return s;
}

/* for <name> in <start>..[=]<end> { ... }     (range)
 * for <name> in <iterable> { ... }            (array, bytes)
 * for <k>, <v> in <map> { ... }               (map) */
static Stmt *parse_for_stmt(Parser *p) {
    Token *kw = advance(p);
    Token *name = expect(p, T_IDENT, "a loop variable name");
    char *name2 = NULL;
    if (match(p, T_COMMA)) {
        Token *n2 = expect(p, T_IDENT, "a second variable name");
        name2 = n2->text;
    }
    expect(p, T_KW_IN, "'in'");
    Expr *start = parse_expression(p);

    if (check(p, T_DOTDOTEQ) || check(p, T_DOTDOT)) {
        int inclusive;
        if (match(p, T_DOTDOTEQ)) {
            inclusive = 1;
        } else {
            advance(p);
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

    if (!check(p, T_LBRACE))
        parse_error(peek(p),
                    "expected '..' (range) or '{' (iterable) after 'in'");
    Block *body = parse_block(p, 0);

    Stmt *s = new_stmt(ST_FOR_IN, kw->line);
    s->as.for_in.name = name->text;
    s->as.for_in.name2 = name2;
    s->as.for_in.iter = start;
    s->as.for_in.body = body;
    return s;
}

/* [gc] struct Name { field: T, ... } — top level only */
static Stmt *parse_struct_decl(Parser *p, int is_pub, int is_gc) {
    Token *kw = advance(p); /* 'struct' */
    Token *name = expect(p, T_IDENT, "a struct name");
    char **tparams = NULL;
    int ntparams = parse_type_params(p, &tparams);
    char **lts = NULL;
    int nlts = parse_lt_params(p, &lts);
    if (ntparams && nlts)
        parse_error(kw, "a generic struct cannot declare lifetime "
                        "parameters yet");
    expect(p, T_LBRACE, "'{'");

    char **fields = NULL;
    char **ftypes = NULL;
    int n = 0;
    while (!check(p, T_RBRACE)) {
        if (check(p, T_EOF))
            parse_error(peek(p), "unexpected end of file inside struct");
        Token *f = expect(p, T_IDENT, "a field name");
        expect(p, T_COLON, "':' followed by a field type");
        const char *ty = parse_type_name(p);
        fields = (char **)xrealloc(fields, (n + 1) * sizeof(char *));
        ftypes = (char **)xrealloc(ftypes, (n + 1) * sizeof(char *));
        fields[n] = f->text;
        ftypes[n] = xstrdup(ty);
        n++;
        if (!match(p, T_COMMA))
            break;
    }
    expect(p, T_RBRACE, "'}'");

    Stmt *s = new_stmt(ST_STRUCT, kw->line);
    s->as.struct_decl.name = name->text;
    s->as.struct_decl.is_pub = is_pub;
    s->as.struct_decl.is_gc = is_gc;
    s->as.struct_decl.fields = fields;
    s->as.struct_decl.ftypes = ftypes;
    s->as.struct_decl.nfields = n;
    s->as.struct_decl.lts = lts;
    s->as.struct_decl.nlts = nlts;
    s->as.struct_decl.tparams = tparams;
    s->as.struct_decl.ntparams = ntparams;
    return s;
}

/* enum Name { Variant [= N], ... } — a closed, i32-backed set of named
 * constants. Ordinals auto-increment ("previous + 1", starting at 0)
 * unless a variant gives one explicitly; duplicate variant names and
 * duplicate explicit ordinals are rejected later, in collect_enum_decls
 * (src/codegen/enum.c), which sees every enum in the package at once. */
static Stmt *parse_enum_decl(Parser *p, int is_pub) {
    Token *kw = advance(p); /* 'enum' */
    Token *name = expect(p, T_IDENT, "an enum name");
    expect(p, T_LBRACE, "'{'");

    char **variants = NULL;
    int *has_explicit = NULL;
    long long *values = NULL;
    int n = 0;
    long long next_ordinal = 0;
    while (!check(p, T_RBRACE)) {
        if (check(p, T_EOF))
            parse_error(peek(p), "unexpected end of file inside enum");
        Token *v = expect(p, T_IDENT, "a variant name");
        long long val = next_ordinal;
        int explicit_val = 0;
        if (match(p, T_ASSIGN)) {
            Token *lit = expect(p, T_INT, "an integer literal");
            if (lit->big_u64 || lit->int_val < 0)
                parse_error(lit, "enum variant values must be a non-negative int32");
            val = lit->int_val;
            explicit_val = 1;
        }
        variants = (char **)xrealloc(variants, (n + 1) * sizeof(char *));
        has_explicit = (int *)xrealloc(has_explicit, (n + 1) * sizeof(int));
        values = (long long *)xrealloc(values, (n + 1) * sizeof(long long));
        variants[n] = v->text;
        has_explicit[n] = explicit_val;
        values[n] = val;
        n++;
        next_ordinal = val + 1;
        if (!match(p, T_COMMA))
            break;
    }
    expect(p, T_RBRACE, "'}'");

    Stmt *s = new_stmt(ST_ENUM, kw->line);
    s->as.enum_decl.name = name->text;
    s->as.enum_decl.is_pub = is_pub;
    s->as.enum_decl.variants = variants;
    s->as.enum_decl.has_explicit = has_explicit;
    s->as.enum_decl.values = values;
    s->as.enum_decl.nvariants = n;
    return s;
}

/* impl Name { fn ... } — methods become package functions whose first
 * parameter conventionally receives the struct ('self'). */
static Stmt *parse_impl_decl(Parser *p) {
    Token *kw = advance(p); /* 'impl' */
    Token *name = expect(p, T_IDENT, "a struct name");
    char **tparams = NULL;
    int ntparams = parse_type_params(p, &tparams);
    expect(p, T_LBRACE, "'{'");

    FuncDecl **funcs = NULL;
    int n = 0;
    while (!check(p, T_RBRACE)) {
        if (check(p, T_EOF))
            parse_error(peek(p), "unexpected end of file inside impl block");
        /* `pub fn` exports a method, as the README documents. This used to
           be rejected here while infer.c already enforced method
           visibility -- so a method was uncallable from any other
           package, and the error for trying ("add 'pub' to export it")
           sent the caller straight into this one. */
        int start = p->pos;
        int is_pub = match(p, T_KW_PUB);
        if (!check(p, T_KW_FN))
            parse_error(peek(p),
                        "only 'fn' or 'pub fn' declarations are allowed "
                        "inside 'impl'");
        FuncDecl *f = parse_fn_decl(p, 0);
        f->is_pub = is_pub;
        f->tok_pos = start; /* at `pub`, so a re-parse sees it too */
        funcs = (FuncDecl **)xrealloc(funcs, (n + 1) * sizeof(FuncDecl *));
        funcs[n++] = f;
    }
    expect(p, T_RBRACE, "'}'");

    Stmt *s = new_stmt(ST_IMPL, kw->line);
    s->as.impl.struct_name = name->text;
    s->as.impl.funcs = funcs;
    s->as.impl.nfuncs = n;
    s->as.impl.tparams = tparams;
    s->as.impl.ntparams = ntparams;
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

/* break;/continue; -- no payload; whether one actually sits inside a
 * loop is a semantic question, not a syntactic one, so it's not
 * checked here -- matches this parser's own established convention
 * (e.g. 'return' outside a function isn't rejected here either; see
 * gen_stmt's cg->in_function check in stmt.c). Checked independently
 * in both stmt.c's codegen and liveness.c's own walk, since neither
 * is guaranteed to run before the other in every code path
 * (--dump-liveness never invokes codegen at all). */
static Stmt *parse_break_stmt(Parser *p) {
    Token *kw = advance(p); /* 'break' */
    expect(p, T_SEMI, "';'");
    return new_stmt(ST_BREAK, kw->line);
}

static Stmt *parse_continue_stmt(Parser *p) {
    Token *kw = advance(p); /* 'continue' */
    expect(p, T_SEMI, "';'");
    return new_stmt(ST_CONTINUE, kw->line);
}

static Stmt *parse_unsafe_stmt(Parser *p) {
    Token *kw = advance(p);
    p->in_unsafe++;
    Block *body = parse_block(p, p->fn_body);
    p->in_unsafe--;
    Stmt *s = new_stmt(ST_UNSAFE, kw->line);
    s->as.unsafe_blk.body = body;
    return s;
}


/* ---- compound assignment ------------------------------------------
 * `x op= v` is desugared to `x = x op v`, which evaluates the TARGET
 * twice. That is only sound when re-evaluating it cannot be observed,
 * so the target is restricted to shapes built purely from names,
 * constant indices and field access. `xs[next()] += 1` is rejected with
 * a message telling the caller to write it out, rather than silently
 * calling next() twice.
 *
 * The target is deep-copied for the right-hand side: sharing one Expr
 * node in two places in the tree would have later passes annotate the
 * same node twice. */

/* Builtins with no side effect, so calling one twice is unobservable.
 * Deliberately a short allowlist rather than "builtins in general": the
 * builtin table also holds push/pop/del/chan_send/println, every one of
 * which WOULD be observable if the desugaring ran it twice. Adding to
 * this list is safe only for functions that both mutate nothing and
 * print nothing. `len` is here because `xs[len(xs) - 1] += 1` is an
 * everyday idiom that is otherwise rejected for no real reason. */
static int is_pure_builtin_call(const char *name) {
    return !strcmp(name, "len") || !strcmp(name, "has");
}

/* Does this expression need hoisting before it can be mentioned twice? */
static int expr_needs_hoist(Expr *e) {
    switch (e->kind) {
    case EX_IDENT: case EX_INT: case EX_FLOAT:
    case EX_STRING: case EX_BYTES: case EX_BOOL:
        return 0;
    case EX_FIELD:  return expr_needs_hoist(e->as.field.base);
    case EX_INDEX:  return expr_needs_hoist(e->as.index.base) ||
                           expr_needs_hoist(e->as.index.index);
    case EX_UNARY:  return expr_needs_hoist(e->as.unary.operand);
    case EX_CAST:   return expr_needs_hoist(e->as.cast.operand);
    case EX_BINARY: return expr_needs_hoist(e->as.binary.lhs) ||
                           expr_needs_hoist(e->as.binary.rhs);
    case EX_CALL:
        if (!is_pure_builtin_call(e->as.call.name))
            return 1;
        for (int i = 0; i < e->as.call.nargs; i++)
            if (expr_needs_hoist(e->as.call.args[i]))
                return 1;
        return 0;
    default: return 1;
    }
}

static int sl_ca_tmp_seq = 0;
static int compound_target_ok(Expr *e) {
    switch (e->kind) {
    case EX_IDENT: return 1;
    /* every literal form: constant, so re-evaluating costs nothing and
     * observes nothing. m["a"] += 1 and xs[0] |= 2 both land here. */
    case EX_INT: case EX_FLOAT: case EX_STRING: case EX_BYTES: case EX_BOOL:
        return 1;
    case EX_FIELD: return compound_target_ok(e->as.field.base);
    case EX_INDEX:
        /* The INDEX may be anything -- an impure one is hoisted into a
         * temporary below, so it runs once. Only the base chain has to
         * be re-evaluable, because hoisting a base would copy it, and
         * for a value-type struct that would mutate the copy. */
        return compound_target_ok(e->as.index.base);
    case EX_UNARY:
        /* every unary form here is pure: deref, negate, not, complement */
        return compound_target_ok(e->as.unary.operand);
    case EX_BINARY:
        /* arithmetic on simple parts is pure too, so xs[i + 1] and
         * xs[n - 1] are fine; a call anywhere inside still fails,
         * because EX_CALL is not in this list. */
        return compound_target_ok(e->as.binary.lhs) &&
               compound_target_ok(e->as.binary.rhs);
    case EX_CAST:
        return compound_target_ok(e->as.cast.operand);
    case EX_CALL:
        /* the callee must be pure AND every argument must be too, so
         * len(f()) is still rejected */
        if (!is_pure_builtin_call(e->as.call.name))
            return 0;
        for (int i = 0; i < e->as.call.nargs; i++)
            if (!compound_target_ok(e->as.call.args[i]))
                return 0;
        return 1;
    default: return 0;
    }
}

static Expr *clone_simple_expr(Parser *p, Expr *e) {
    Expr *c = new_expr(p, e->kind, e->line);
    switch (e->kind) {
    case EX_IDENT:
        c->as.ident.name = xstrdup(e->as.ident.name);
        break;
    case EX_INT:
        c->as.int_lit.value = e->as.int_lit.value;
        c->as.int_lit.big_u64 = e->as.int_lit.big_u64;
        break;
    case EX_FLOAT:
        c->as.float_lit.value = e->as.float_lit.value;
        break;
    case EX_BOOL:
        c->as.bool_lit.value = e->as.bool_lit.value;
        break;
    case EX_STRING:
        c->as.str_lit.value = xstrdup(e->as.str_lit.value);
        break;
    case EX_BYTES: {
        c->as.bytes_lit.len = e->as.bytes_lit.len;
        unsigned char *d = (unsigned char *)xmalloc(
            (size_t)(e->as.bytes_lit.len ? e->as.bytes_lit.len : 1));
        memcpy(d, e->as.bytes_lit.data, (size_t)e->as.bytes_lit.len);
        c->as.bytes_lit.data = d;
        break; }
    case EX_FIELD:
        c->as.field.base = clone_simple_expr(p, e->as.field.base);
        c->as.field.name = xstrdup(e->as.field.name);
        break;
    case EX_INDEX:
        c->as.index.base = clone_simple_expr(p, e->as.index.base);
        c->as.index.index = clone_simple_expr(p, e->as.index.index);
        break;
    case EX_UNARY:
        c->as.unary.op = xstrdup(e->as.unary.op);
        c->as.unary.operand = clone_simple_expr(p, e->as.unary.operand);
        break;
    case EX_BINARY:
        c->as.binary.op = xstrdup(e->as.binary.op);
        c->as.binary.lhs = clone_simple_expr(p, e->as.binary.lhs);
        c->as.binary.rhs = clone_simple_expr(p, e->as.binary.rhs);
        break;
    case EX_CAST:
        c->as.cast.ty = xstrdup(e->as.cast.ty);
        c->as.cast.operand = clone_simple_expr(p, e->as.cast.operand);
        break;
    case EX_CALL: {
        c->as.call.name = xstrdup(e->as.call.name);
        c->as.call.callee = e->as.call.callee
                                ? clone_simple_expr(p, e->as.call.callee)
                                : NULL;
        c->as.call.nargs = e->as.call.nargs;
        c->as.call.args = e->as.call.nargs
            ? (Expr **)xmalloc(sizeof(Expr *) * (size_t)e->as.call.nargs)
            : NULL;
        for (int i = 0; i < e->as.call.nargs; i++)
            c->as.call.args[i] = clone_simple_expr(p, e->as.call.args[i]);
        break; }
    default:
        break;
    }
    return c;
}

/* The binary operator a compound-assignment token stands for, or NULL. */
static const char *compound_op_text(TokenType t) {
    switch (t) {
    case T_PLUSEQ:    return "+";
    case T_MINUSEQ:   return "-";
    case T_STAREQ:    return "*";
    case T_SLASHEQ:   return "/";
    case T_PERCENTEQ: return "%";
    case T_AMPEQ:     return "&";
    case T_PIPEEQ:    return "|";
    case T_CARETEQ:   return "^";
    case T_SHLEQ:     return "<<";
    case T_SHREQ:     return ">>";
    default:          return NULL;
    }
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
    case T_KW_SPAWN:
        return parse_spawn_stmt(p);
    case T_KW_RETURN:
        return parse_return_stmt(p);
    case T_KW_BREAK:
        return parse_break_stmt(p);
    case T_KW_CONTINUE:
        return parse_continue_stmt(p);
    case T_KW_UNSAFE:
        return parse_unsafe_stmt(p);
    case T_KW_SELECT:
        return parse_select_stmt(p);
    case T_KW_STRUCT:
        parse_error(tk, "'struct' declarations are only allowed at top "
                        "level");
        return NULL; /* unreachable */
    case T_KW_ENUM:
        parse_error(tk, "'enum' declarations are only allowed at top level");
        return NULL; /* unreachable */
    case T_KW_IMPL:
        parse_error(tk, "'impl' blocks are only allowed at top level");
        return NULL; /* unreachable */
    case T_KW_PUB:
        parse_error(tk,
                    "'pub' is only allowed on top-level functions and "
                    "variables");
        return NULL; /* unreachable */
    default: {
        /* expression or assignment statement */
        Expr *expr = parse_expression(p);
        const char *cop = compound_op_text(peek(p)->type);
        if (match(p, T_ASSIGN) || cop) {
            if (expr->kind != EX_IDENT && expr->kind != EX_INDEX &&
                expr->kind != EX_FIELD &&
                !(expr->kind == EX_UNARY && !strcmp(expr->as.unary.op, "*")))
                parse_error(tk, "invalid assignment target");
            Expr *value;
            Stmt *pre = NULL;
            if (cop) {
                Token *optk = advance(p);
                if (!compound_target_ok(expr))
                    parse_error(optk,
                                "compound assignment names its target "
                                "twice, so the value being indexed or "
                                "accessed must be a name, field or index "
                                "chain -- not a call. The INDEX may be "
                                "anything (it is hoisted and evaluated "
                                "once); it is the base that must be "
                                "re-nameable. Write 'x = x <op> v' instead");
                /* An index with a side effect (xs[pop(xs)] += 1) is hoisted
                 * into its own `let` so it runs exactly once, and BOTH
                 * mentions of the target then read that temporary. */
                if (expr->kind == EX_INDEX &&
                    expr_needs_hoist(expr->as.index.index)) {
                    char *tmp = xasprintf("__ca_%d", sl_ca_tmp_seq++);
                    pre = new_stmt(ST_LET, optk->line);
                    pre->as.let.name = tmp;
                    pre->as.let.type_ann = NULL;
                    pre->as.let.init = expr->as.index.index;
                    pre->as.let.is_pub = 0;
                    pre->as.let.stack = 0;
                    Expr *ref = new_expr(p, EX_IDENT, optk->line);
                    ref->as.ident.name = xstrdup(tmp);
                    expr->as.index.index = ref;
                    p->pending = pre;   /* emitted as a sibling, see Parser */
                    pre = NULL;
                }
                Expr *rhs = parse_expression(p);
                value = make_binary(p, xstrdup(cop),
                                    clone_simple_expr(p, expr), rhs,
                                    optk->line);
            } else {
                value = parse_expression(p);
            }
            expect(p, T_SEMI, "';'");
            Stmt *s = new_stmt(ST_ASSIGN, tk->line);
            s->as.assign.target = expr;
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

/* `[T, U]` after a declaration's name: its type parameters. */
static int parse_type_params(Parser *p, char ***out) {
    char **names = NULL;
    int n = 0;
    Token *open = peek(p);
    if (!match(p, T_LBRACKET))
        return 0;
    for (;;) {
        Token *t = expect(p, T_IDENT, "a type parameter name");
        if (n == MAX_TYPE_PARAMS)
            parse_error(open, "a generic type takes at most %d type "
                              "parameters", MAX_TYPE_PARAMS);
        for (int i = 0; i < n; i++) {
            if (!strcmp(names[i], t->text))
                parse_error(t, "duplicate type parameter '%s'", t->text);
        }
        names = (char **)xrealloc(names, (size_t)(n + 1) * sizeof(char *));
        names[n++] = t->text;
        if (!match(p, T_COMMA))
            break;
    }
    expect(p, T_RBRACKET, "']' to close the type parameters");
    *out = names;
    return n;
}

static int parse_lt_params(Parser *p, char ***out) {
    char **lts = NULL;
    int n = 0;
    if (!match(p, T_LT))
        return 0;
    for (;;) {
        Token *t = expect(p, T_LIFETIME, "a lifetime");
        int i;
        for (i = 0; i < n; i++) {
            if (!strcmp(lts[i], t->text))
                parse_error(t, "duplicate lifetime '%s'", t->text);
        }
        lts = (char **)xrealloc(lts, (size_t)(n + 1) * sizeof(char *));
        lts[n++] = t->text;
        if (!match(p, T_COMMA))
            break;
    }
    expect(p, T_GT, "'>'");
    *out = lts;
    return n;
}

static FuncDecl *parse_fn_decl(Parser *p, int is_extern) {
    int start = p->pos;
    Token *kw = advance(p); /* 'fn' */
    Token *name = expect(p, T_IDENT, "a function name");
    if (check(p, T_LBRACKET))
        parse_error(peek(p), "generic functions are not supported yet");
    char **lts = NULL;
    int nlts = parse_lt_params(p, &lts);
    expect(p, T_LPAREN, "'('");

    FuncDecl *f = (FuncDecl *)xmalloc(sizeof(FuncDecl));
    memset(f, 0, sizeof(FuncDecl));
    f->name = name->text;
    f->lts = lts;
    f->nlts = nlts;
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

    if (is_extern) {
        f->is_extern = 1;
        expect(p, T_SEMI, "';'");
    } else {
        f->body = parse_block(p, 1);
    }
    f->toks = (struct Token *)p->toks;
    f->ntoks = p->count;
    f->tok_pos = start;
    return f;
}

/* Parse one `fn` (or `pub fn`) declaration again, from the token array and
 * position a FuncDecl recorded. Every instance of a generic method is a
 * fresh AST produced by this. */
FuncDecl *parse_fn_decl_again(const FuncDecl *from) {
    Parser p;
    memset(&p, 0, sizeof(p));
    p.toks = (Token *)from->toks;
    p.count = from->ntoks;
    p.pos = from->tok_pos;
    int is_pub = match(&p, T_KW_PUB) ? 1 : 0;
    FuncDecl *f = parse_fn_decl(&p, 0);
    f->is_pub = is_pub;
    f->tok_pos = from->tok_pos; /* the span it came from, pub included */
    return f;
}

static void program_push_import(Program *prog, char *path, char *alias) {
    if (prog->nimports == prog->icap) {
        int old = prog->icap;
        prog->icap = prog->icap ? prog->icap * 2 : 8;
        prog->import_paths = (char **)xrealloc(
            prog->import_paths, prog->icap * sizeof(char *));
        prog->import_aliases = (char **)xrealloc(
            prog->import_aliases, prog->icap * sizeof(char *));
        for (int i = old; i < prog->icap; i++)
            prog->import_aliases[i] = NULL;
    }
    prog->import_paths[prog->nimports] = path;
    prog->import_aliases[prog->nimports] = alias;
    prog->nimports++;
}

static void parse_import(Parser *p, Program *prog) {
    advance(p);
    Token *path = expect(p, T_STRING, "a package path string");
    char *alias = NULL;
    if (match(p, T_KW_AS)) {
        Token *id = expect(p, T_IDENT, "an import alias");
        alias = id->text;
    }
    expect(p, T_SEMI, "';'");
    program_push_import(prog, path->text, alias);
}

static void program_push_link(Program *prog, char *name) {
    if (prog->nlinks == prog->lcap) {
        prog->lcap = prog->lcap ? prog->lcap * 2 : 8;
        prog->link_libs = (char **)xrealloc(
            prog->link_libs, prog->lcap * sizeof(char *));
    }
    prog->link_libs[prog->nlinks++] = name;
}

static int is_libname_char(char c) {
    return isalnum((unsigned char)c) || c == '_' || c == '-' || c == '.' ||
           c == '+';
}

/* link "name" ; -- appends '-lname' to the final linker invocation.
 * The name is restricted to a conservative charset since it flows
 * straight into a shell command line in main.c. */
static void parse_link(Parser *p, Program *prog) {
    Token *kw = advance(p); /* 'link' */
    Token *name = expect(p, T_STRING, "a library name string");
    if (!name->text[0])
        parse_error(kw, "link: library name must not be empty");
    for (const char *c = name->text; *c; c++) {
        if (!is_libname_char(*c))
            parse_error(kw,
                        "link: invalid character '%c' in library name "
                        "'%s' (only letters, digits, '_', '-', '.', '+' "
                        "are allowed)",
                        *c, name->text);
    }
    expect(p, T_SEMI, "';'");
    program_push_link(prog, name->text);
}

Program *parse_program(Token *tokens, int ntokens) {
    /* memset, not field-by-field: a Parser field added later would
     * otherwise start as stack garbage. That is not hypothetical -- the
     * `pending` field below was added field-by-field, missed here, and
     * segfaulted slangc by block_push-ing an uninitialised pointer. */
    Parser p;
    memset(&p, 0, sizeof(p));
    p.toks = tokens;
    p.count = ntokens;

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

        if (check(&p, T_KW_LINK)) {
            if (is_pub)
                parse_error(peek(&p), "'pub' cannot precede 'link'");
            parse_link(&p, prog);
            continue;
        }

        if (check(&p, T_KW_FN)) {
            FuncDecl *f = parse_fn_decl(&p, 0);
            f->is_pub = is_pub;
            if (prog->nfuncs == prog->fcap) {
                prog->fcap = prog->fcap ? prog->fcap * 2 : 8;
                prog->funcs = (FuncDecl **)xrealloc(
                    prog->funcs, prog->fcap * sizeof(FuncDecl *));
            }
            prog->funcs[prog->nfuncs++] = f;
            continue;
        }

        if (check(&p, T_KW_EXTERN)) {
            advance(&p); /* 'extern' */
            if (!check(&p, T_KW_FN))
                parse_error(peek(&p), "expected 'fn' after 'extern'");
            FuncDecl *f = parse_fn_decl(&p, 1);
            f->is_pub = is_pub;
            if (prog->nfuncs == prog->fcap) {
                prog->fcap = prog->fcap ? prog->fcap * 2 : 8;
                prog->funcs = (FuncDecl **)xrealloc(
                    prog->funcs, prog->fcap * sizeof(FuncDecl *));
            }
            prog->funcs[prog->nfuncs++] = f;
            continue;
        }

        if (check(&p, T_KW_GC)) {
            advance(&p);
            if (!check(&p, T_KW_STRUCT))
                parse_error(peek(&p), "expected 'struct' after 'gc'");
            block_push(prog->main_body, parse_struct_decl(&p, is_pub, 1));
            continue;
        }

        if (check(&p, T_KW_STRUCT)) {
            block_push(prog->main_body, parse_struct_decl(&p, is_pub, 0));
            continue;
        }

        if (check(&p, T_KW_ENUM)) {
            block_push(prog->main_body, parse_enum_decl(&p, is_pub));
            continue;
        }

        if (check(&p, T_KW_IMPL)) {
            if (is_pub)
                parse_error(peek(&p),
                            "'pub' cannot precede 'impl'; mark the "
                            "individual 'fn's inside as 'pub'");
            block_push(prog->main_body, parse_impl_decl(&p));
            continue;
        }

        if (is_pub) {
            Stmt *s = parse_statement(&p);
            if (p.pending)
                parse_error(peek(&p),
                            "'pub' cannot precede a compound assignment");
            if (s->kind != ST_LET)
                parse_error(peek(&p),
                            "'pub' can only precede a function, struct, "
                            "or a top-level 'let'");
            s->as.let.is_pub = 1;
            block_push(prog->main_body, s);
            continue;
        }

        parse_into_block(&p, prog->main_body);
    }
    if (p.pending)
        parse_error(peek(&p),
                    "internal: a hoisted statement was never emitted");
    return prog;
}
