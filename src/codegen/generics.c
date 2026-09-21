/* Generic structs: templates, instances, and type-argument inference.
 *
 * `struct Box[T] { v: T }` declares a TEMPLATE, which is not a type. A type
 * is an INSTANCE, `Box[int]`, made the first time it is named: the
 * arguments are canonicalized, the instance is entered in cg->structs like
 * any other struct, and its field types are canonicalized with the
 * parameters bound (see TypeEnv). From then on it IS an ordinary struct --
 * its C name, layout, tracer and every pass that walks structs need no
 * knowledge of generics, which is what keeps `Box[int]` exactly as fast and
 * as small as a hand-written `IntBox`.
 *
 * The instance is entered in the table BEFORE its fields are canonicalized,
 * so `struct List[T] { next: opt[List[T]] }` finds itself instead of
 * recursing. */

#include "internal.h"
#include "../parser.h"

/* `struct Bad[T] { x: Bad[[T]] }` names a new type every time it is
 * instantiated. Legitimate nesting -- Box[Box[Box[int]]] -- is a handful of
 * levels; this only has to stop the runaway before the stack does. */
#define INST_DEPTH_MAX 32

/* While an instance is being built, an error inside its declaration should
 * say which instance, and where it was asked for: the line cg_error() is
 * given is the struct's own, which alone does not tell you what `T` was. */
static const char *note_canon;
static int note_line;

void generic_error_note(const char **canon, int *line) {
    *canon = note_canon;
    *line = note_line;
}

/* Which instance body a pass is walking, so an error inside a template
 * says which T made it fail and who asked for that instance. The cursor
 * sets this on every yield -- NULL for a declared function -- so no pass
 * has to remember to. */
void generic_note_body(const char *what, int line) {
    note_canon = what;
    note_line = line;
}

/* ------------------------------------------------------------------ */
/* Templates                                                           */
/* ------------------------------------------------------------------ */

StructTmpl *tmpl_find_in_pkg(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->tmpls.count; i++) {
        StructTmpl *t = cg->tmpls.items[i];
        if (!strcmp(t->pkg, pkg) && !strcmp(t->name, name))
            return t;
    }
    return NULL;
}

void tmpl_register(CG *cg, const char *pkg, Stmt *decl) {
    const char *name = decl->as.struct_decl.name;
    if (struct_find_in_pkg(cg, pkg, name) || tmpl_find_in_pkg(cg, pkg, name))
        cg_error(decl->line, "redefinition of struct '%s' in package '%s'",
                 name, pkg);
    for (int j = 0; j < decl->as.struct_decl.nfields; j++) {
        for (int q = 0; q < j; q++) {
            if (!strcmp(decl->as.struct_decl.fields[q],
                        decl->as.struct_decl.fields[j]))
                cg_error(decl->line, "duplicate field '%s' in struct '%s.%s'",
                         decl->as.struct_decl.fields[j], pkg, name);
        }
    }
    if (cg->tmpls.count == cg->tmpls.cap) {
        cg->tmpls.cap = cg->tmpls.cap ? cg->tmpls.cap * 2 : 4;
        cg->tmpls.items = (StructTmpl **)xrealloc(
            cg->tmpls.items, cg->tmpls.cap * sizeof(StructTmpl *));
    }
    StructTmpl *t = (StructTmpl *)xmalloc(sizeof(StructTmpl));
    memset(t, 0, sizeof(*t));
    t->pkg = (char *)pkg;
    t->name = (char *)name;
    t->is_pub = decl->as.struct_decl.is_pub;
    t->is_gc = decl->as.struct_decl.is_gc;
    t->tparams = decl->as.struct_decl.tparams;
    t->ntparams = decl->as.struct_decl.ntparams;
    t->fields = decl->as.struct_decl.fields;
    t->ftypes = decl->as.struct_decl.ftypes;
    t->nfields = decl->as.struct_decl.nfields;
    t->line = decl->line;
    cg->tmpls.items[cg->tmpls.count++] = t;
}

/* `impl Box[T] { ... }`: the method declarations, kept as written against
 * the struct template. Nothing is checked here -- a method is checked once
 * per instance that uses it, with T bound. */
void tmpl_register_impl(CG *cg, Package *pkg, Stmt *decl) {
    StructTmpl *tm = tmpl_find_in_pkg(cg, pkg->name, decl->as.impl.struct_name);
    if (!tm)
        cg_error(decl->line, "impl of unknown struct '%s'",
                 decl->as.impl.struct_name);
    if (decl->as.impl.ntparams != tm->ntparams)
        cg_error(decl->line,
                 "'%s' takes %d type parameter%s, but this impl block "
                 "declares %d",
                 tm->name, tm->ntparams, tm->ntparams == 1 ? "" : "s",
                 decl->as.impl.ntparams);
    if (tm->nmethods)
        cg_error(decl->line, "duplicate impl block for '%s'", tm->name);
    for (int i = 0; i < decl->as.impl.nfuncs; i++) {
        const char *nm = decl->as.impl.funcs[i]->name;
        for (int q = 0; q < i; q++) {
            if (!strcmp(decl->as.impl.funcs[q]->name, nm))
                cg_error(decl->as.impl.funcs[i]->line,
                         "redefinition of method '%s' on '%s'", nm, tm->name);
        }
    }
    tm->owner = pkg;
    tm->methods = decl->as.impl.funcs;
    tm->nmethods = decl->as.impl.nfuncs;
    tm->mparams = decl->as.impl.tparams;
    tm->nmparams = decl->as.impl.ntparams;
    tm->impl_line = decl->line;
}

/* The template a possibly-dotted name refers to, or NULL. `line` is only
 * for the not-exported error. */
static StructTmpl *tmpl_resolve(CG *cg, const char *name, int line) {
    char *l, *r;
    if (!split_dotted(name, &l, &r))
        return tmpl_find_in_pkg(cg, cg->cur_pkg, name);
    const char *pkg = import_try(cg, l);
    if (!pkg)
        return NULL;
    StructTmpl *tm = tmpl_find_in_pkg(cg, pkg, r);
    if (tm && !tm->is_pub)
        cg_error(line,
                 "type '%s' is not exported from package '%s' (add 'pub' to "
                 "export it)",
                 r, pkg);
    return tm;
}

/* A generic struct named without its arguments: `let b: Box = ...`. */
void generic_needs_args(CG *cg, const char *pkg, const char *name, int line) {
    StructTmpl *tm = tmpl_find_in_pkg(cg, pkg, name);
    if (!tm)
        return;
    StrBuf b;
    sb_init(&b);
    for (int i = 0; i < tm->ntparams; i++) {
        if (i)
            sb_append(&b, ",");
        sb_append(&b, tm->tparams[i]);
    }
    cg_error(line,
             "'%s' is a generic struct; write its type arguments, as in "
             "%s[%s] (fields alone can infer them only in a struct literal)",
             name, name, b.data);
}

/* ------------------------------------------------------------------ */
/* Type environment                                                    */
/* ------------------------------------------------------------------ */

int tenv_lookup(CG *cg, const char *name, const char **type) {
    if (!cg->tenv)
        return 0;
    for (int i = 0; i < cg->tenv->n; i++) {
        if (!strcmp(cg->tenv->names[i], name)) {
            *type = cg->tenv->types[i];
            return 1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Instances                                                           */
/* ------------------------------------------------------------------ */

/* `Box[int,[str]]` -> base "Box" and args {"int", "[str]"}; the count, or
 * -1 when `t` is not a name followed by one bracketed list. Commas inside
 * nested brackets or parentheses belong to the argument they sit in.
 * More than MAX_TYPE_PARAMS arguments are counted but not stored. */
static int split_generic(const char *t, char **base,
                         char *args[MAX_TYPE_PARAMS]) {
    const char *open = strchr(t, '[');
    size_t n = strlen(t);
    if (t[0] == '[' || !open || open == t || t[n - 1] != ']')
        return -1;
    int depth = 0;
    const char *start = open + 1;
    int count = 0;
    for (const char *p = open; p < t + n; p++) {
        int end = 0;
        if (*p == '[' || *p == '(')
            depth++;
        else if (*p == ']' || *p == ')') {
            depth--;
            if (depth == 0) {
                if (p != t + n - 1)
                    return -1; /* `[..]` closes before the end: not ours */
                end = 1;
            }
        } else if (*p == ',' && depth == 1)
            end = 1;
        if (!end)
            continue;
        if (count < MAX_TYPE_PARAMS) {
            size_t l = (size_t)(p - start);
            args[count] = (char *)xmalloc(l + 1);
            memcpy(args[count], start, l);
            args[count][l] = '\0';
        }
        count++;
        start = p + 1;
    }
    *base = (char *)xmalloc((size_t)(open - t) + 1);
    memcpy(*base, t, (size_t)(open - t));
    (*base)[open - t] = '\0';
    return count;
}

static const char *instance_key(const StructTmpl *tm, char **args, int n) {
    StrBuf b;
    sb_init(&b);
    sb_append(&b, tm->pkg);
    sb_append(&b, ".");
    sb_append(&b, tm->name);
    sb_append(&b, "[");
    for (int i = 0; i < n; i++) {
        if (i)
            sb_append(&b, ",");
        sb_append(&b, args[i]);
    }
    sb_append(&b, "]");
    return b.data;
}

/* The instance of `tm` for these CANONICAL arguments, made on first use. */
static const char *instantiate(CG *cg, StructTmpl *tm, char **args, int n,
                               int line) {
    const char *key = instance_key(tm, args, n);
    StructDef *have = struct_find_canon(cg, key);
    if (have)
        return have->canonical;
    if (cg->inst_depth >= INST_DEPTH_MAX)
        cg_error(line,
                 "'%s' expands without end: instantiating it needs another "
                 "new instance, %d levels deep",
                 tm->name, INST_DEPTH_MAX);

    if (cg->structs.count == cg->structs.cap) {
        cg->structs.cap = cg->structs.cap ? cg->structs.cap * 2 : 8;
        cg->structs.items = (StructDef **)xrealloc(
            cg->structs.items, cg->structs.cap * sizeof(StructDef *));
    }
    StructDef *sd = (StructDef *)xmalloc(sizeof(StructDef));
    memset(sd, 0, sizeof(*sd));
    sd->canonical = (char *)key;
    sd->pkg = tm->pkg;
    sd->name = (char *)key + strlen(tm->pkg) + 1;
    sd->is_pub = tm->is_pub;
    sd->is_gc = tm->is_gc;
    sd->fields = tm->fields;
    sd->nfields = tm->nfields;
    sd->line = tm->line;
    sd->inst = 1;
    sd->ftypes = (const char **)xmalloc(sizeof(char *) *
                                        (tm->nfields ? tm->nfields : 1));
    /* Two instances must never share a C name. The hash makes that
     * astronomically unlikely; checking makes it impossible to miss. */
    char *mangled = mangle_struct(key);
    for (int i = 0; i < cg->structs.count; i++) {
        if (!strcmp(mangle_struct(cg->structs.items[i]->canonical), mangled))
            cg_error(line, "internal: '%s' and '%s' would share the C name %s",
                     key, cg->structs.items[i]->canonical, mangled);
    }
    cg->structs.items[cg->structs.count++] = sd;

    TypeEnv env;
    env.n = n;
    for (int i = 0; i < n; i++) {
        env.names[i] = tm->tparams[i];
        env.types[i] = args[i];
    }
    sd->tmpl = tm;
    sd->env = env;
    /* REPLACE the environment, do not extend it: an instance made from
     * inside another one must not see that one's parameters. */
    TypeEnv *saved_env = cg->tenv;
    const char *saved_pkg = cg->cur_pkg;
    const char *saved_note = note_canon;
    int saved_note_line = note_line;
    cg->tenv = &env;
    cg->cur_pkg = tm->pkg;
    note_canon = key;
    note_line = line;
    cg->inst_depth++;
    for (int j = 0; j < tm->nfields; j++)
        sd->ftypes[j] = canon_type(cg, tm->ftypes[j], tm->line);
    cg->inst_depth--;
    cg->tenv = saved_env;
    cg->cur_pkg = saved_pkg;
    note_canon = saved_note;
    note_line = saved_note_line;
    return sd->canonical;
}

/* Resolve `Name[args]` / `pkg.Name[args]`, or NULL if `t` is not that form. */
const char *generic_canon(CG *cg, const char *t, int line) {
    char *base;
    char *args[MAX_TYPE_PARAMS];
    int n = split_generic(t, &base, args);
    if (n < 0)
        return NULL;
    StructTmpl *tm = tmpl_resolve(cg, base, line);
    if (!tm) {
        /* Either not a type at all (canon_type says so), or a type that
         * takes no arguments. */
        canon_type(cg, base, line);
        cg_error(line, "'%s' is not generic; it takes no type arguments",
                 base);
    }
    if (n != tm->ntparams)
        cg_error(line, "'%s' takes %d type argument%s, got %d", tm->name,
                 tm->ntparams, tm->ntparams == 1 ? "" : "s", n);
    char *cargs[MAX_TYPE_PARAMS];
    for (int i = 0; i < n; i++)
        cargs[i] = (char *)canon_type(cg, args[i], line);
    return instantiate(cg, tm, cargs, n, line);
}

/* ------------------------------------------------------------------ */
/* Methods of an instance                                              */
/* ------------------------------------------------------------------ */

/* The method `name` of instance `sd`, made on first use, or NULL if the
 * template declares no such method.
 *
 * Lazy on purpose: a method is type-checked once per instance that asks
 * for it, so `Box[int].sum()` adding its values is fine even though
 * `Box[str]` exists, as long as nobody calls `sum` on `Box[str]`. That is
 * the C++ template rule, and it is what makes unbounded parameters
 * workable without interfaces. */
FuncSig *method_instantiate(CG *cg, StructDef *sd, const char *name,
                            int line) {
    StructTmpl *tm = sd->tmpl;
    if (!tm)
        return NULL;
    FuncDecl *decl = NULL;
    for (int i = 0; i < tm->nmethods; i++) {
        if (!strcmp(tm->methods[i]->name, name))
            decl = tm->methods[i];
    }
    if (!decl)
        return NULL;
    if (decl->nlts)
        cg_error(decl->line,
                 "lifetime parameters on a method of a generic struct are "
                 "not supported yet");
    /* After the passes that walk bodies have run, a new body would never
     * be checked or rooted. It cannot happen -- the real run repeats the
     * dry run's walk -- but a silent miscompile is what it would cost. */
    if (cg->insts_frozen)
        cg_error(line,
                 "internal: '%s' of '%s' was first needed after the "
                 "analysis passes; please report this program",
                 name, sd->canonical);
    if (cg->inst_depth >= INST_DEPTH_MAX)
        cg_error(line,
                 "'%s' expands without end: instantiating it needs another "
                 "new instance, %d levels deep",
                 tm->name, INST_DEPTH_MAX);

    FuncInst *fi = (FuncInst *)xmalloc(sizeof(FuncInst));
    memset(fi, 0, sizeof(*fi));
    fi->pkg = tm->owner;
    fi->fn = parse_fn_decl_again(decl);
    /* This body has never been through the enum rewrite: it did not
     * exist when that pass ran over the program. */
    resolve_enum_in_body(cg, tm->pkg, fi->fn);
    fi->recv = sd->canonical;
    fi->line = line;
    fi->note = xasprintf("%s.%s", sd->canonical, name);
    /* The impl block names the parameters itself (`impl Box[U]` is legal),
     * so bind ITS names, positionally, to this instance's arguments. */
    fi->env.n = sd->env.n;
    for (int i = 0; i < sd->env.n; i++) {
        fi->env.names[i] = i < tm->nmparams ? tm->mparams[i] : sd->env.names[i];
        fi->env.types[i] = sd->env.types[i];
    }

    FuncSig *sig = (FuncSig *)xmalloc(sizeof(FuncSig));
    memset(sig, 0, sizeof(*sig));
    sig->name = fi->fn->name;
    sig->pkg = tm->pkg;
    sig->is_pub = fi->fn->is_pub;
    sig->ret_slang = fi->fn->ret_type;
    sig->nparams = fi->fn->nparams;
    sig->method_of = sd->canonical;
    sig->line = fi->fn->line;
    sig->param_slang = (const char **)xmalloc(
        sizeof(char *) * (sig->nparams ? sig->nparams : 1));

    TypeEnv *saved_env = cg->tenv;
    const char *saved_pkg = cg->cur_pkg;
    const char *saved_note = note_canon;
    int saved_note_line = note_line;
    cg->tenv = &fi->env;
    cg->cur_pkg = tm->pkg;
    note_canon = fi->note;
    note_line = line;
    cg->inst_depth++;
    for (int m = 0; m < fi->fn->nparams; m++)
        sig->param_slang[m] =
            canon_type(cg, fi->fn->param_types[m], sig->line);
    if (sig->ret_slang)
        sig->ret_slang = canon_type(cg, sig->ret_slang, sig->line);
    cg->inst_depth--;
    cg->tenv = saved_env;
    cg->cur_pkg = saved_pkg;
    note_canon = saved_note;
    note_line = saved_note_line;

    if (cg->sigs.count == cg->sigs.cap) {
        cg->sigs.cap = cg->sigs.cap ? cg->sigs.cap * 2 : 8;
        cg->sigs.items = (FuncSig **)xrealloc(
            cg->sigs.items, cg->sigs.cap * sizeof(FuncSig *));
    }
    cg->sigs.items[cg->sigs.count++] = sig;
    fi->fn->sig_idx = cg->sigs.count;
    fi->sig = sig;

    if (cg->finsts.count == cg->finsts.cap) {
        cg->finsts.cap = cg->finsts.cap ? cg->finsts.cap * 2 : 8;
        cg->finsts.items = (FuncInst **)xrealloc(
            cg->finsts.items, cg->finsts.cap * sizeof(FuncInst *));
    }
    cg->finsts.items[cg->finsts.count++] = fi;
    return sig;
}

/* ------------------------------------------------------------------ */
/* Inference from a struct literal                                     */
/* ------------------------------------------------------------------ */

typedef struct {
    StructTmpl *tm;
    const char *bound[MAX_TYPE_PARAMS];
    int line;
} Unify;

static int tparam_index(const StructTmpl *tm, const char *name) {
    for (int i = 0; i < tm->ntparams; i++) {
        if (!strcmp(tm->tparams[i], name))
            return i;
    }
    return -1;
}

static const char *last_segment(const char *s) {
    const char *dot = strrchr(s, '.');
    return dot ? dot + 1 : s;
}

/* Walk a field's declared type `pat` (as written, mentioning the
 * parameters) alongside the type `act` the literal's value actually has,
 * binding each parameter where they meet. The walk uses the same helpers
 * that take types apart everywhere else, so there is no second type
 * grammar to keep in step.
 *
 * Where the shapes differ -- `pat` is a plain struct, or `act` is not the
 * container the field declares -- nothing is bound and no error is made
 * here: the assignability check the literal goes through next says it
 * better, with the field's name. */
static void unify(Unify *u, const char *pat, const char *act) {
    int k = tparam_index(u->tm, pat);
    if (k >= 0) {
        if (!u->bound[k])
            u->bound[k] = act;
        else if (strcmp(u->bound[k], act))
            cg_error(u->line,
                     "type parameter '%s' of '%s' is %s in one field and %s "
                     "in another; write the type arguments to choose",
                     pat, u->tm->name, u->bound[k], act);
        return;
    }
    char *pin, *ain;
    TypeWrap pw = type_wrap(pat, &pin);
    if (pw != TW_NONE) {
        TypeWrap aw = type_wrap(act, &ain);
        if (aw == pw)
            unify(u, pin, ain);
        else if (aw == TW_NONE)
            unify(u, pin, act);
        return;
    }
    if (pat[0] == '[' && act[0] == '[') {
        unify(u, arr_elem(pat), arr_elem(act));
    } else if (is_map(pat) && is_map(act)) {
        char *pk, *pv, *ak, *av;
        map_kv(pat, &pk, &pv);
        map_kv(act, &ak, &av);
        unify(u, pk, ak);
        unify(u, pv, av);
    } else if (is_opt(pat) && is_opt(act)) {
        unify(u, opt_inner(pat), opt_inner(act));
    } else if (is_result(pat) && is_result(act)) {
        char *pa, *pb, *aa, *ab;
        result_te(pat, &pa, &pb);
        result_te(act, &aa, &ab);
        unify(u, pa, aa);
        unify(u, pb, ab);
    } else if (is_chan(pat) && is_chan(act)) {
        unify(u, chan_elem(pat), chan_elem(act));
    } else if (is_join(pat) && is_join(act)) {
        unify(u, join_elem(pat), join_elem(act));
    } else if (is_fn(pat) && is_fn(act)) {
        char **pps, **aps, *pr, *ar;
        int pn = fn_parts(pat, &pps, &pr);
        int an = fn_parts(act, &aps, &ar);
        if (pn == an && pn >= 0) {
            for (int i = 0; i < pn; i++)
                unify(u, pps[i], aps[i]);
            if (pr && ar)
                unify(u, pr, ar);
        }
    } else {
        /* another generic struct: Pair[T,U] against main.Pair[int,str] */
        char *pbase, *abase;
        char *pargs[MAX_TYPE_PARAMS], *aargs[MAX_TYPE_PARAMS];
        int pn = split_generic(pat, &pbase, pargs);
        int an = split_generic(act, &abase, aargs);
        if (pn > 0 && pn == an && pn <= MAX_TYPE_PARAMS &&
            !strcmp(last_segment(pbase), last_segment(abase))) {
            for (int i = 0; i < pn; i++)
                unify(u, pargs[i], aargs[i]);
        }
    }
}

static const char *infer_generic_lit(CG *cg, Expr *e, StructTmpl *tm) {
    Unify u;
    memset(&u, 0, sizeof(u));
    u.tm = tm;
    u.line = e->line;
    for (int j = 0; j < e->as.structlit.nfields; j++) {
        int fi = -1;
        for (int i = 0; i < tm->nfields; i++) {
            if (!strcmp(tm->fields[i], e->as.structlit.fields[j]))
                fi = i;
        }
        if (fi < 0)
            cg_error(e->line, "struct '%s' has no field '%s'", tm->name,
                     e->as.structlit.fields[j]);
        /* No expectation flows in: the value alone has to say what the
         * parameter is. */
        const char *saved = cg->expect;
        cg->expect = NULL;
        const char *vt = infer_type(cg, e->as.structlit.vals[j]);
        cg->expect = saved;
        unify(&u, tm->ftypes[fi], vt);
    }
    for (int k = 0; k < tm->ntparams; k++) {
        if (!u.bound[k])
            cg_error(e->line,
                     "cannot infer type parameter '%s' of '%s' from this "
                     "literal; write %s[...] { ... } to give it",
                     tm->tparams[k], tm->name, tm->name);
    }
    char *args[MAX_TYPE_PARAMS];
    for (int k = 0; k < tm->ntparams; k++)
        args[k] = (char *)u.bound[k];
    return instantiate(cg, tm, args, tm->ntparams, e->line);
}

/* The canonical struct type a literal builds. `Box[int] { v: 1 }` names it;
 * `Box { v: 1 }` leaves the arguments to be inferred from the fields, and
 * the answer is kept on the node so every later pass reads the same one. */
const char *structlit_type(CG *cg, Expr *e) {
    if (e->as.structlit.inst)
        return e->as.structlit.inst;
    const char *name = e->as.structlit.tyname;
    if (!strchr(name, '[')) {
        StructTmpl *tm = tmpl_resolve(cg, name, e->line);
        if (tm) {
            e->as.structlit.inst = infer_generic_lit(cg, e, tm);
            return e->as.structlit.inst;
        }
    }
    return canon_type(cg, name, e->line);
}
