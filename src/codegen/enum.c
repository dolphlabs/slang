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
#include "../diag.h"

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

int is_tagged_enum(CG *cg, const char *t) {
    EnumDef *ed = t ? enum_find_canon(cg, t) : NULL;
    return ed && ed->has_payload;
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
            if (s->file)
                diag_file = s->file;
            if (enum_find_in_pkg(cg, p->name, s->as.enum_decl.name))
                cg_error(s->line,
                         "redefinition of enum '%s' in package '%s'",
                         s->as.enum_decl.name, p->name);

            int n = s->as.enum_decl.nvariants;
            int has_payload = s->as.enum_decl.has_payload;
            if (has_payload) {
                for (int a = 0; a < n; a++) {
                    if (s->as.enum_decl.has_explicit[a])
                        cg_error(s->line,
                                 "enum '%s' has payload variants and cannot "
                                 "use explicit '= N' ordinals",
                                 s->as.enum_decl.name);
                    s->as.enum_decl.values[a] = a;
                }
            }
            for (int a = 0; a < n; a++) {
                for (int b = 0; b < a; b++) {
                    if (!strcmp(s->as.enum_decl.variants[a],
                                s->as.enum_decl.variants[b]))
                        cg_error(s->line,
                                 "duplicate variant '%s' in enum '%s'",
                                 s->as.enum_decl.variants[a],
                                 s->as.enum_decl.name);
                    if (!has_payload &&
                        s->as.enum_decl.values[a] == s->as.enum_decl.values[b])
                        cg_error(s->line,
                                 "enum '%s': variants '%s' and '%s' both "
                                 "have value %lld",
                                 s->as.enum_decl.name,
                                 s->as.enum_decl.variants[b],
                                 s->as.enum_decl.variants[a],
                                 s->as.enum_decl.values[a]);
                }
                if (!has_payload &&
                    (s->as.enum_decl.values[a] > 2147483647LL ||
                     s->as.enum_decl.values[a] < 0))
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
            memset(ed, 0, sizeof(*ed));
            ed->canonical = xasprintf("%s.%s", p->name, s->as.enum_decl.name);
            ed->pkg = p->name;
            ed->name = s->as.enum_decl.name;
            ed->is_pub = s->as.enum_decl.is_pub;
            ed->variants = s->as.enum_decl.variants;
            ed->has_payload = has_payload;
            ed->v_ntypes = s->as.enum_decl.v_ntypes;
            if (has_payload && n > 0) {
                ed->v_types = (char ***)xmalloc(sizeof(char **) * (size_t)n);
                for (int a = 0; a < n; a++) {
                    int k = ed->v_ntypes ? ed->v_ntypes[a] : 0;
                    if (k > 0) {
                        ed->v_types[a] = (char **)xmalloc(sizeof(char *) * (size_t)k);
                        for (int f = 0; f < k; f++)
                            ed->v_types[a][f] = s->as.enum_decl.v_types[a][f];
                    } else {
                        ed->v_types[a] = NULL;
                    }
                }
            }
            ed->nvariants = n;
            ed->line = s->line;
            ed->values = (int32_t *)xmalloc(sizeof(int32_t) * (n ? n : 1));
            for (int a = 0; a < n; a++)
                ed->values[a] = (int32_t)s->as.enum_decl.values[a];
        }
    }
}

static int enum_payload_has_borrow(CG *cg, const char *t,
                                   const char **visiting, int nvis) {
    char *inner = NULL;
    TypeWrap w = type_wrap(t, &inner);
    if (w == TW_REF || w == TW_REFMUT || w == TW_OWN)
        return 1;
    if (type_is_arena(t) || type_is_link(t) || type_is_trip(t))
        return 1;
    if (w != TW_NONE)
        return enum_payload_has_borrow(cg, inner, visiting, nvis);
    if (is_opt(t))
        return enum_payload_has_borrow(cg, opt_inner(t), visiting, nvis);
    if (is_result(t)) {
        char *tv, *te;
        result_te(t, &tv, &te);
        return enum_payload_has_borrow(cg, tv, visiting, nvis) ||
               enum_payload_has_borrow(cg, te, visiting, nvis);
    }
    StructDef *sd = struct_find_canon(cg, t);
    if (sd && !sd->is_gc) {
        for (int i = 0; i < nvis; i++)
            if (!strcmp(visiting[i], sd->canonical))
                return 0;
        if (nvis == 64)
            return 0;
        visiting[nvis++] = sd->canonical;
        for (int j = 0; j < sd->nfields; j++)
            if (enum_payload_has_borrow(cg, sd->ftypes[j], visiting, nvis))
                return 1;
        return 0;
    }
    EnumDef *ed = enum_find_canon(cg, t);
    if (ed && ed->has_payload) {
        for (int i = 0; i < nvis; i++)
            if (!strcmp(visiting[i], ed->canonical))
                return 0;
        if (nvis == 64)
            return 0;
        visiting[nvis++] = ed->canonical;
        for (int v = 0; v < ed->nvariants; v++)
            for (int f = 0; f < ed->v_ntypes[v]; f++)
                if (enum_payload_has_borrow(cg, ed->v_types[v][f], visiting,
                                            nvis))
                    return 1;
    }
    return 0;
}

void canon_enum_payloads(CG *cg) {
    /* Pass A: canonicalize every variant payload type string before
     * checking cross-enum dependencies in Pass B. */
    for (int i = 0; i < cg->enums.count; i++) {
        EnumDef *ed = &cg->enums.items[i];
        if (!ed->has_payload)
            continue;
        const char *saved_pkg = cg->cur_pkg;
        cg->cur_pkg = ed->pkg;
        cg_lookup_reset(cg);
        for (int v = 0; v < ed->nvariants; v++) {
            for (int f = 0; f < ed->v_ntypes[v]; f++) {
                const char *ct = canon_type(cg, ed->v_types[v][f], ed->line);
                if (!strcmp(ct, "void"))
                    cg_error(ed->line,
                             "enum '%s' variant '%s' cannot have 'void' payload",
                             ed->name, ed->variants[v]);
                ed->v_types[v][f] = (char *)ct;
            }
        }
        cg->cur_pkg = saved_pkg;
    }
    /* Pass B: enforce copy/no-drop/non-borrowed payload invariant in v1. */
    for (int i = 0; i < cg->enums.count; i++) {
        EnumDef *ed = &cg->enums.items[i];
        if (!ed->has_payload)
            continue;
        for (int v = 0; v < ed->nvariants; v++) {
            for (int f = 0; f < ed->v_ntypes[v]; f++) {
                const char *pt = ed->v_types[v][f];
                const char *vis[64];
                if (!type_is_copy(cg, pt) || type_needs_drop(cg, pt) ||
                    enum_payload_has_borrow(cg, pt, vis, 0)) {
                    cg_error(ed->line,
                             "enum '%s' variant '%s' payload type '%s' "
                             "cannot be non-copy or borrowed; use a value "
                             "type or 'gc struct'",
                             ed->name, ed->variants[v], pt);
                }
            }
        }
    }
}

/* ---- resolving Type.Variant / Type.from_int / Type.from_str -------- */

static void resolve_expr(CG *cg, const char *pkg, Expr *e);

/* The enum a dotted name refers to, and the member after it.
 *
 * `Status.Paid` in this package, or `orders.Status.Paid` from another --
 * a library whose API takes an enum is useless if only its own package
 * can name the variants. The import alias is resolved against the
 * package being walked, not cg->cur_pkg, which is not set this early. */
static EnumDef *enum_ref(CG *cg, const char *pkg, const char *dotted,
                         char **member, int line) {
    char *left, *right;
    if (!split_dotted(dotted, &left, &right))
        return NULL;
    EnumDef *ed = enum_find_in_pkg(cg, pkg, left);
    if (ed) {
        *member = right;
        return ed;
    }
    char *ename, *vname;
    if (!split_dotted(right, &ename, &vname))
        return NULL;
    const char *saved = cg->cur_pkg;
    cg->cur_pkg = pkg;
    const char *target = import_try(cg, left);
    cg->cur_pkg = saved;
    if (!target)
        return NULL;
    ed = enum_find_in_pkg(cg, target, ename);
    if (!ed)
        return NULL;
    if (!ed->is_pub)
        cg_error(line,
                 "type '%s' is not exported from package '%s' (add 'pub' "
                 "to export it)",
                 ename, target);
    *member = vname;
    return ed;
}

static int enum_variant_idx(EnumDef *ed, const char *name) {
    for (int i = 0; i < ed->nvariants; i++) {
        if (!strcmp(ed->variants[i], name))
            return i;
    }
    return -1;
}

static void make_enum_ctor(Expr *e, EnumDef *ed, int idx, Expr **args, int nargs) {
    e->kind = EX_CALL;
    e->as.call.name = xstrdup("__enum_ctor");
    e->as.call.callee = NULL;
    e->as.call.args = args;
    e->as.call.nargs = nargs;
    e->as.call.enum_ty = ed->canonical;
    e->as.call.enum_variant = idx;
    e->as.call.gsig = NULL;
}

static void resolve_ident(CG *cg, const char *pkg, Expr *e) {
    char *right;
    EnumDef *ed = enum_ref(cg, pkg, e->as.ident.name, &right, e->line);
    if (!ed)
        return; /* not an enum reference -- leave for the usual
                  * package/field resolution in infer.c */
    int idx = enum_variant_idx(ed, right);
    if (idx < 0)
        cg_error(e->line, "enum '%s' has no variant '%s'", ed->name, right);
    if (ed->has_payload) {
        if (ed->v_ntypes[idx] > 0)
            cg_error(e->line,
                     "variant '%s.%s' requires %d payload argument(s)",
                     ed->name, right, ed->v_ntypes[idx]);
        make_enum_ctor(e, ed, idx, NULL, 0);
        return;
    }
    e->kind = EX_INT;
    e->as.int_lit.value = ed->values[idx];
    e->as.int_lit.big_u64 = 0;
    e->as.int_lit.enum_ty = ed->canonical;
}

static void resolve_call_name(CG *cg, const char *pkg, Expr *e) {
    if (!e->as.call.name)
        return;
    char *right;
    EnumDef *ed = enum_ref(cg, pkg, e->as.call.name, &right, e->line);
    if (!ed)
        return;
    if (!strcmp(right, "from_int") || !strcmp(right, "from_str")) {
        if (ed->has_payload)
            cg_error(e->line,
                     "'%s' is only supported on unit-only enums, not tagged "
                     "enum '%s'",
                     right, ed->name);
        e->as.call.name = xstrdup(!strcmp(right, "from_int")
                                      ? "__enum_from_int"
                                      : "__enum_from_str");
        e->as.call.enum_ty = ed->canonical;
        return;
    }
    int idx = enum_variant_idx(ed, right);
    if (idx < 0) {
        cg_error(e->line,
                 "enum '%s' has no variant or associated function '%s'",
                 ed->name, right);
    }
    if (!ed->has_payload)
        cg_error(e->line,
                 "enum '%s' variant '%s' has no payload and cannot be called "
                 "like a function",
                 ed->name, right);
    if (ed->v_ntypes[idx] == 0)
        cg_error(e->line,
                 "unit variant '%s.%s' takes no arguments; omit '()'",
                 ed->name, right);
    if (e->as.call.nargs != ed->v_ntypes[idx])
        cg_error(e->line,
                 "variant '%s.%s' expects %d argument(s), got %d",
                 ed->name, right, ed->v_ntypes[idx], e->as.call.nargs);
    e->as.call.name = xstrdup("__enum_ctor");
    e->as.call.enum_ty = ed->canonical;
    e->as.call.enum_variant = idx;
}

/* The enum an `EX_IDENT` of the form `pkg.Enum` names, or NULL. */
static EnumDef *enum_of_qualified(CG *cg, const char *pkg, Expr *base,
                                  int line) {
    if (!base || base->kind != EX_IDENT)
        return NULL;
    char *alias, *ename;
    if (!split_dotted(base->as.ident.name, &alias, &ename))
        return NULL;
    if (strchr(ename, '.'))
        return NULL;
    const char *saved = cg->cur_pkg;
    cg->cur_pkg = pkg;
    const char *target = import_try(cg, alias);
    cg->cur_pkg = saved;
    if (!target)
        return NULL;
    EnumDef *ed = enum_find_in_pkg(cg, target, ename);
    if (!ed)
        return NULL;
    if (!ed->is_pub)
        cg_error(line,
                 "type '%s' is not exported from package '%s' (add 'pub' "
                 "to export it)",
                 ename, target);
    return ed;
}

/* `pkg.Enum.Variant` -> the variant's value or unit constructor. */
static int resolve_dotted_variant(CG *cg, const char *pkg, Expr *e) {
    EnumDef *ed = enum_of_qualified(cg, pkg, e->as.field.base, e->line);
    if (!ed)
        return 0;
    const char *name = e->as.field.name;
    int idx = enum_variant_idx(ed, name);
    if (idx < 0)
        cg_error(e->line, "enum '%s' has no variant '%s'", ed->name, name);
    if (ed->has_payload) {
        if (ed->v_ntypes[idx] > 0)
            cg_error(e->line,
                     "variant '%s.%s' requires %d payload argument(s)",
                     ed->name, name, ed->v_ntypes[idx]);
        make_enum_ctor(e, ed, idx, NULL, 0);
        return 1;
    }
    e->kind = EX_INT;
    e->as.int_lit.value = ed->values[idx];
    e->as.int_lit.big_u64 = 0;
    e->as.int_lit.enum_ty = ed->canonical;
    return 1;
}

/* `pkg.Enum.from_str(s)` / `from_int(n)` / `pkg.Enum.Variant(args...)`. */
static int resolve_dotted_assoc(CG *cg, const char *pkg, Expr *e) {
    EnumDef *ed = enum_of_qualified(cg, pkg, e->as.method.recv, e->line);
    if (!ed)
        return 0;
    const char *name = e->as.method.name;
    Expr **args = e->as.method.args;
    int nargs = e->as.method.nargs;
    if (!strcmp(name, "from_int") || !strcmp(name, "from_str")) {
        if (ed->has_payload)
            cg_error(e->line,
                     "'%s' is only supported on unit-only enums, not tagged "
                     "enum '%s'",
                     name, ed->name);
        for (int i = 0; i < nargs; i++)
            resolve_expr(cg, pkg, args[i]);
        e->kind = EX_CALL;
        e->as.call.name = xstrdup(!strcmp(name, "from_int")
                                      ? "__enum_from_int"
                                      : "__enum_from_str");
        e->as.call.args = args;
        e->as.call.nargs = nargs;
        e->as.call.callee = NULL;
        e->as.call.enum_ty = ed->canonical;
        return 1;
    }
    int idx = enum_variant_idx(ed, name);
    if (idx < 0)
        cg_error(e->line,
                 "enum '%s' has no variant or associated function '%s'",
                 ed->name, name);
    if (!ed->has_payload)
        cg_error(e->line,
                 "enum '%s' variant '%s' has no payload and cannot be called "
                 "like a function",
                 ed->name, name);
    if (ed->v_ntypes[idx] == 0)
        cg_error(e->line,
                 "unit variant '%s.%s' takes no arguments; omit '()'",
                 ed->name, name);
    if (nargs != ed->v_ntypes[idx])
        cg_error(e->line,
                 "variant '%s.%s' expects %d argument(s), got %d",
                 ed->name, name, ed->v_ntypes[idx], nargs);
    for (int i = 0; i < nargs; i++)
        resolve_expr(cg, pkg, args[i]);
    make_enum_ctor(e, ed, idx, args, nargs);
    return 1;
}

static void resolve_switch_label(CG *cg, const char *pkg, Expr *lb) {
    if (!lb)
        return;
    if (lb->kind == EX_IDENT) {
        char *right;
        EnumDef *ed = enum_ref(cg, pkg, lb->as.ident.name, &right, lb->line);
        if (ed) {
            int idx = enum_variant_idx(ed, right);
            if (idx < 0)
                cg_error(lb->line, "enum '%s' has no variant '%s'",
                         ed->name, right);
            lb->kind = EX_INT;
            lb->as.int_lit.value = ed->values[idx];
            lb->as.int_lit.big_u64 = 0;
            lb->as.int_lit.enum_ty = ed->canonical;
            return;
        }
    } else if (lb->kind == EX_FIELD) {
        EnumDef *ed = enum_of_qualified(cg, pkg, lb->as.field.base, lb->line);
        if (ed) {
            int idx = enum_variant_idx(ed, lb->as.field.name);
            if (idx < 0)
                cg_error(lb->line, "enum '%s' has no variant '%s'",
                         ed->name, lb->as.field.name);
            lb->kind = EX_INT;
            lb->as.int_lit.value = ed->values[idx];
            lb->as.int_lit.big_u64 = 0;
            lb->as.int_lit.enum_ty = ed->canonical;
            return;
        }
    }
    resolve_expr(cg, pkg, lb);
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
        /* `orders.Status.Paid` parses as a FIELD of `orders.Status`,
           because an identifier carries at most one dot. */
        if (resolve_dotted_variant(cg, pkg, e))
            return;
        resolve_expr(cg, pkg, e->as.field.base);
        return;
    case EX_METHOD:
        /* and `orders.Status.from_str(s)` as a METHOD call on it */
        if (resolve_dotted_assoc(cg, pkg, e))
            return;
        resolve_expr(cg, pkg, e->as.method.recv);
        for (int i = 0; i < e->as.method.nargs; i++)
            resolve_expr(cg, pkg, e->as.method.args[i]);
        return;
    case EX_STRUCTLIT:
        for (int i = 0; i < e->as.structlit.nfields; i++)
            resolve_expr(cg, pkg, e->as.structlit.vals[i]);
        return;
    case EX_SPAWN:
        resolve_expr(cg, pkg, e->as.spawn.call);
        return;
    case EX_SWITCH:
        resolve_expr(cg, pkg, e->as.switch_expr.scrut);
        for (int i = 0; i < e->as.switch_expr.ncases; i++) {
            for (int j = 0; j < e->as.switch_expr.cases[i].nvals; j++)
                resolve_switch_label(cg, pkg,
                                     e->as.switch_expr.cases[i].vals[j]);
            resolve_expr(cg, pkg, e->as.switch_expr.cases[i].value);
        }
        resolve_expr(cg, pkg, e->as.switch_expr.def);
        return;
    }
}

static void resolve_block(CG *cg, const char *pkg, Block *b);

static void resolve_stmt(CG *cg, const char *pkg, Stmt *s) {
    if (s->file)
        diag_file = s->file;
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
    case ST_IF_LET:
        resolve_expr(cg, pkg, s->as.if_let.expr);
        resolve_expr(cg, pkg, s->as.if_let.err_expr);
        resolve_block(cg, pkg, s->as.if_let.then_blk);
        resolve_block(cg, pkg, s->as.if_let.else_blk);
        return;
    case ST_SPAWN:
        resolve_expr(cg, pkg, s->as.spawn.call);
        return;
    case ST_DEFER:
        resolve_expr(cg, pkg, s->as.defer_stmt.call);
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
    case ST_SWITCH:
        resolve_expr(cg, pkg, s->as.switch_stmt.scrut);
        for (int i = 0; i < s->as.switch_stmt.ncases; i++) {
            for (int j = 0; j < s->as.switch_stmt.cases[i].nvals; j++)
                resolve_switch_label(cg, pkg,
                                     s->as.switch_stmt.cases[i].vals[j]);
            resolve_block(cg, pkg, s->as.switch_stmt.cases[i].body);
        }
        resolve_block(cg, pkg, s->as.switch_stmt.def);
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

/* The same rewrite, for ONE function body.
 *
 * A generic method's instance is parsed fresh, long after the walk below
 * has finished, so its `Status.Paid` would reach the type checker as an
 * undefined variable. Every instance runs this on its own body. */
void resolve_enum_in_body(CG *cg, const char *pkg, FuncDecl *f) {
    if (f && f->body)
        resolve_block(cg, pkg, f->body);
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

void emit_enum_fwd_decls(CG *cg) {
    int any = 0;
    for (int i = 0; i < cg->enums.count; i++) {
        EnumDef *ed = &cg->enums.items[i];
        if (!ed->has_payload)
            continue;
        char *m = mangle_enum(ed->canonical);
        emit_line(cg, "typedef struct %s %s;", m, m);
        any = 1;
    }
    if (any)
        emit_line(cg, "");
}

void emit_enum_body(CG *cg, EnumDef *ed, unsigned char *sstate, int line) {
    if (!ed->has_payload)
        return;
    if (ed->body_state == 2)
        return;
    if (ed->body_state == 1)
        cg_error(line ? line : ed->line,
                 "cannot lay out enum '%s': it contains itself by value, which "
                 "would need an infinitely large value; wrap the recursive "
                 "field in a 'gc struct'",
                 ed->canonical);
    ed->body_state = 1;
    for (int v = 0; v < ed->nvariants; v++) {
        for (int f = 0; f < ed->v_ntypes[v]; f++)
            emit_value_dep(cg, ed->v_types[v][f], sstate, ed->line);
    }
    char *m = mangle_enum(ed->canonical);
    emit_line(cg, "struct %s {", m);
    cg->indent++;
    emit_line(cg, "int32_t tag;");
    emit_line(cg, "union {");
    cg->indent++;
    for (int v = 0; v < ed->nvariants; v++) {
        if (ed->v_ntypes[v] == 0)
            continue;
        emit_line(cg, "struct {");
        cg->indent++;
        for (int f = 0; f < ed->v_ntypes[v]; f++)
            emit_line(cg, "%s _%d;", ctype_of(cg, ed->v_types[v][f]), f);
        cg->indent--;
        emit_line(cg, "} v%d;", v);
    }
    cg->indent--;
    emit_line(cg, "} u;");
    cg->indent--;
    emit_line(cg, "};");
    for (int v = 0; v < ed->nvariants; v++) {
        int nf = ed->v_ntypes[v];
        StrBuf params;
        sb_init(&params);
        if (nf == 0) {
            sb_append(&params, "void");
        } else {
            for (int f = 0; f < nf; f++) {
                if (f)
                    sb_append(&params, ", ");
                sb_append(&params,
                          xasprintf("%s _a%d", ctype_of(cg, ed->v_types[v][f]),
                                    f));
            }
        }
        emit_line(cg,
                  "static inline __attribute__((unused)) %s %s_mk_v%d(%s) {",
                  m, m, v, params.data);
        cg->indent++;
        emit_line(cg, "%s _v;", m);
        emit_line(cg, "memset(&_v, 0, sizeof(_v));");
        emit_line(cg, "_v.tag = %d;", (int)ed->values[v]);
        for (int f = 0; f < nf; f++)
            emit_line(cg, "_v.u.v%d._%d = _a%d;", v, f, f);
        emit_line(cg, "return _v;");
        cg->indent--;
        emit_line(cg, "}");
    }
    emit_line(cg, "");
    ed->body_state = 2;
}

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
        if (ed->has_payload) {
            emit_line(cg, "static const char *%s_names[] __attribute__((unused)) = {%s};",
                      m, ed->nvariants ? names : "\"\"");
            continue;
        }
        emit_line(cg, "static const char *%s_names[] = {%s};", m,
                  ed->nvariants ? names : "\"\"");
        emit_line(cg, "static const int32_t %s_values[] = {%s};", m,
                  ed->nvariants ? values : "0");
    }
}
