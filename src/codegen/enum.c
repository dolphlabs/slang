/* User-declared `enum` types: a closed, i32-backed set of named
 * constants (bench/CURSOR.md and README.md#enums have usage). Mirrors
 * the struct machinery in core.c/program.c wherever the shapes line up
 * (enum_find_canon/enum_find_in_pkg/mangle_enum <-> struct_find_canon/
 * struct_find_in_pkg/mangle_struct); the pieces that don't have a
 * struct equivalent -- collecting variant tables and resolving
 * `Type.Variant`/`Type.from_int`/`Type.from_str` syntax -- live here.
 *
 * The resolution pass (resolve_enum_refs) is the load-bearing part: it
 * runs once, immediately after collect_decls, and rewrites every
 * `Type.Variant` reference into a plain EX_INT literal (tagged with
 * the enum's canonical name via int_lit.enum_ty) and every
 * `Type.from_int`/`Type.from_str` call into the internal sentinel call
 * names "__enum_from_int"/"__enum_from_str" (tagged via
 * call.enum_ty). Every later pass -- infer, borrow, liveness, move,
 * mir, escape, codegen -- therefore only ever sees ordinary int
 * literals and ordinary (if specially-named) calls; none of them need
 * to know enums exist as a dotted-name concept. See the "why an early
 * AST-rewrite pass" section of the enum design plan for the reasoning
 * (duplicating dotted-name resolution across the ~15 existing
 * split_dotted call sites in those passes was the alternative, and a
 * much larger, easier-to-get-wrong change). */

#include "internal.h"

#include <string.h>

EnumDef *enum_find_canon(CG *cg, const char *canon) {
    for (int i = 0; i < cg->enums.count; i++) {
        if (!strcmp(cg->enums.items[i].canonical, canon))
            return &cg->enums.items[i];
    }
    return NULL;
}

EnumDef *enum_find_in_pkg(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->enums.count; i++) {
        if (!strcmp(cg->enums.items[i].pkg, pkg) &&
            !strcmp(cg->enums.items[i].name, name))
            return &cg->enums.items[i];
    }
    return NULL;
}

int is_enum(CG *cg, const char *t) {
    return t && enum_find_canon(cg, t) != NULL;
}

char *mangle_enum(const char *canon) {
    char *l, *r;
    split_dotted(canon, &l, &r);
    return xasprintf("sl_en_%s_%s", sanitize_pkg(l), sanitize_ident(r));
}

/* Registration: one EnumDef per `enum` declaration, with auto-increment
 * ordinals resolved (the parser already resolved explicit '= N' values;
 * this just fills the gaps and checks for collisions across a whole
 * enum, which the parser -- seeing one variant at a time -- can't). */
void collect_enum_decls(CG *cg, Package *pkgs, int npkgs) {
    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_ENUM)
                continue;
            if (enum_find_in_pkg(cg, p->name, s->as.enum_decl.name))
                cg_error(s->line,
                         "redefinition of enum '%s' in package '%s'",
                         s->as.enum_decl.name, p->name);

            int n = s->as.enum_decl.nvariants;
            for (int a = 0; a < n; a++) {
                for (int b = 0; b < a; b++) {
                    if (!strcmp(s->as.enum_decl.variants[a],
                                s->as.enum_decl.variants[b]))
                        cg_error(s->line,
                                 "duplicate variant '%s' in enum '%s'",
                                 s->as.enum_decl.variants[a],
                                 s->as.enum_decl.name);
                    if (s->as.enum_decl.values[a] == s->as.enum_decl.values[b])
                        cg_error(s->line,
                                 "enum '%s': variants '%s' and '%s' both "
                                 "have value %lld",
                                 s->as.enum_decl.name,
                                 s->as.enum_decl.variants[b],
                                 s->as.enum_decl.variants[a],
                                 s->as.enum_decl.values[a]);
                }
                if (s->as.enum_decl.values[a] > 2147483647LL ||
                    s->as.enum_decl.values[a] < 0)
                    cg_error(s->line,
                             "enum '%s': variant '%s' value %lld does not "
                             "fit in the i32 backing type",
                             s->as.enum_decl.name, s->as.enum_decl.variants[a],
                             s->as.enum_decl.values[a]);
            }

            if (cg->enums.count == cg->enums.cap) {
                cg->enums.cap = cg->enums.cap ? cg->enums.cap * 2 : 8;
                cg->enums.items = (EnumDef *)xrealloc(
                    cg->enums.items, cg->enums.cap * sizeof(EnumDef));
            }
            EnumDef *ed = &cg->enums.items[cg->enums.count++];
            ed->canonical = xasprintf("%s.%s", p->name, s->as.enum_decl.name);
            ed->pkg = p->name;
            ed->name = s->as.enum_decl.name;
            ed->is_pub = s->as.enum_decl.is_pub;
            ed->variants = s->as.enum_decl.variants;
            ed->nvariants = n;
            ed->line = s->line;
            ed->values = (int32_t *)xmalloc(sizeof(int32_t) * (n ? n : 1));
            for (int a = 0; a < n; a++)
                ed->values[a] = (int32_t)s->as.enum_decl.values[a];
        }
    }
}

/* ---- resolving Type.Variant / Type.from_int / Type.from_str -------- */

static void resolve_expr(CG *cg, const char *pkg, Expr *e);

static void resolve_ident(CG *cg, const char *pkg, Expr *e) {
    char *left, *right;
    if (!split_dotted(e->as.ident.name, &left, &right))
        return;
    EnumDef *ed = enum_find_in_pkg(cg, pkg, left);
    if (!ed)
        return; /* not an enum reference -- leave for the usual
                  * package/field resolution in infer.c */
    int32_t val = 0;
    int found = 0;
    for (int i = 0; i < ed->nvariants; i++) {
        if (!strcmp(ed->variants[i], right)) {
            val = ed->values[i];
            found = 1;
            break;
        }
    }
    if (!found)
        cg_error(e->line, "enum '%s' has no variant '%s'", ed->name, right);
    e->kind = EX_INT;
    e->as.int_lit.value = val;
    e->as.int_lit.big_u64 = 0;
    e->as.int_lit.enum_ty = ed->canonical;
}

static void resolve_call_name(CG *cg, const char *pkg, Expr *e) {
    if (!e->as.call.name)
        return;
    char *left, *right;
    if (!split_dotted(e->as.call.name, &left, &right))
        return;
    EnumDef *ed = enum_find_in_pkg(cg, pkg, left);
    if (!ed)
        return;
    if (!strcmp(right, "from_int")) {
        e->as.call.name = xstrdup("__enum_from_int");
        e->as.call.enum_ty = ed->canonical;
    } else if (!strcmp(right, "from_str")) {
        e->as.call.name = xstrdup("__enum_from_str");
        e->as.call.enum_ty = ed->canonical;
    } else {
        cg_error(e->line,
                 "enum '%s' has no associated function '%s' (only "
                 "from_int/from_str)",
                 ed->name, right);
    }
}

static void resolve_expr(CG *cg, const char *pkg, Expr *e) {
    if (!e)
        return;
    switch (e->kind) {
    case EX_INT:
    case EX_FLOAT:
    case EX_STRING:
    case EX_BYTES:
    case EX_BOOL:
        return;
    case EX_IDENT:
        resolve_ident(cg, pkg, e);
        return;
    case EX_BINARY:
        resolve_expr(cg, pkg, e->as.binary.lhs);
        resolve_expr(cg, pkg, e->as.binary.rhs);
        return;
    case EX_UNARY:
        resolve_expr(cg, pkg, e->as.unary.operand);
        return;
    case EX_CALL:
        resolve_call_name(cg, pkg, e);
        resolve_expr(cg, pkg, e->as.call.callee);
        for (int i = 0; i < e->as.call.nargs; i++)
            resolve_expr(cg, pkg, e->as.call.args[i]);
        return;
    case EX_CAST:
        resolve_expr(cg, pkg, e->as.cast.operand);
        return;
    case EX_INDEX:
        resolve_expr(cg, pkg, e->as.index.base);
        resolve_expr(cg, pkg, e->as.index.index);
        return;
    case EX_SLICE:
        resolve_expr(cg, pkg, e->as.slice.base);
        resolve_expr(cg, pkg, e->as.slice.start);
        resolve_expr(cg, pkg, e->as.slice.end);
        return;
    case EX_LIST:
        for (int i = 0; i < e->as.list.nelems; i++)
            resolve_expr(cg, pkg, e->as.list.elems[i]);
        return;
    case EX_MAPLIT:
        for (int i = 0; i < e->as.maplit.npairs; i++) {
            resolve_expr(cg, pkg, e->as.maplit.keys[i]);
            resolve_expr(cg, pkg, e->as.maplit.vals[i]);
        }
        return;
    case EX_FIELD:
        resolve_expr(cg, pkg, e->as.field.base);
        return;
    case EX_STRUCTLIT:
        for (int i = 0; i < e->as.structlit.nfields; i++)
            resolve_expr(cg, pkg, e->as.structlit.vals[i]);
        return;
    case EX_SPAWN:
        resolve_expr(cg, pkg, e->as.spawn.call);
        return;
    }
}

static void resolve_block(CG *cg, const char *pkg, Block *b);

static void resolve_stmt(CG *cg, const char *pkg, Stmt *s) {
    switch (s->kind) {
    case ST_LET:
        resolve_expr(cg, pkg, s->as.let.init);
        return;
    case ST_ASSIGN:
        resolve_expr(cg, pkg, s->as.assign.target);
        resolve_expr(cg, pkg, s->as.assign.value);
        return;
    case ST_IF:
        resolve_expr(cg, pkg, s->as.if_stmt.cond);
        resolve_block(cg, pkg, s->as.if_stmt.then_blk);
        resolve_block(cg, pkg, s->as.if_stmt.else_blk);
        return;
    case ST_WHILE:
        resolve_expr(cg, pkg, s->as.while_stmt.cond);
        resolve_block(cg, pkg, s->as.while_stmt.body);
        return;
    case ST_FOR:
        resolve_expr(cg, pkg, s->as.for_stmt.start);
        resolve_expr(cg, pkg, s->as.for_stmt.end);
        resolve_block(cg, pkg, s->as.for_stmt.body);
        return;
    case ST_FOR_IN:
        resolve_expr(cg, pkg, s->as.for_in.iter);
        resolve_block(cg, pkg, s->as.for_in.body);
        return;
    case ST_RETURN:
        resolve_expr(cg, pkg, s->as.ret.value);
        return;
    case ST_BREAK:
    case ST_CONTINUE:
        return;
    case ST_EXPR:
        resolve_expr(cg, pkg, s->as.expr_stmt.expr);
        return;
    case ST_GUARD_LET:
        resolve_expr(cg, pkg, s->as.guard_let.expr);
        resolve_expr(cg, pkg, s->as.guard_let.err_expr);
        resolve_block(cg, pkg, s->as.guard_let.body);
        return;
    case ST_SPAWN:
        resolve_expr(cg, pkg, s->as.spawn.call);
        return;
    case ST_UNSAFE:
        resolve_block(cg, pkg, s->as.unsafe_blk.body);
        return;
    case ST_SELECT:
        for (int i = 0; i < s->as.select_stmt.ncases; i++) {
            SelectCase *c = &s->as.select_stmt.cases[i];
            resolve_expr(cg, pkg, c->ch);
            resolve_expr(cg, pkg, c->val);
            resolve_block(cg, pkg, c->body);
        }
        resolve_block(cg, pkg, s->as.select_stmt.def);
        return;
    case ST_STRUCT:
    case ST_ENUM:
        return; /* no expressions inside a declaration to resolve */
    case ST_IMPL:
        for (int i = 0; i < s->as.impl.nfuncs; i++) {
            FuncDecl *f = s->as.impl.funcs[i];
            if (f->body)
                resolve_block(cg, pkg, f->body);
        }
        return;
    }
}

static void resolve_block(CG *cg, const char *pkg, Block *b) {
    if (!b)
        return;
    for (int i = 0; i < b->count; i++)
        resolve_stmt(cg, pkg, b->stmts[i]);
}

void resolve_enum_refs(CG *cg, Package *pkgs, int npkgs) {
    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (int j = 0; j < p->prog->nfuncs; j++) {
            FuncDecl *f = p->prog->funcs[j];
            if (f->body)
                resolve_block(cg, p->name, f->body);
        }
        /* main_body holds package-level lets (library globals, or a
         * program's main() locals), plus ST_STRUCT/ST_ENUM/ST_IMPL
         * declarations -- resolve_stmt walks into ST_IMPL's methods. */
        resolve_block(cg, p->name, p->prog->main_body);
    }
}

/* ---- emission -------------------------------------------------------- */

void emit_enum_tables(CG *cg) {
    for (int i = 0; i < cg->enums.count; i++) {
        EnumDef *ed = &cg->enums.items[i];
        char *m = mangle_enum(ed->canonical);
        char *names = xstrdup("");
        char *values = xstrdup("");
        for (int j = 0; j < ed->nvariants; j++) {
            const char *sep = j ? ", " : "";
            names = xasprintf("%s%s\"%s\"", names, sep, ed->variants[j]);
            values = xasprintf("%s%s%d", values, sep, ed->values[j]);
        }
        emit_line(cg, "static const char *%s_names[] = {%s};", m,
                  ed->nvariants ? names : "\"\"");
        emit_line(cg, "static const int32_t %s_values[] = {%s};", m,
                  ed->nvariants ? values : "0");
    }
}
