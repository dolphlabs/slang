/* inspect(x): monomorphized value printers.
 *
 * Mirrors pkg_json/dispatch.c's own shape on purpose: every
 * inspectable composite slang type maps to one C function with the
 * fixed signature
 *   static void NAME(<ctype_of T> v, sl_inspect_sb *out, int depth);
 * scalar leaf types go through fixed runtime helpers in
 * runtime/sl_inspect.c instead, so they never need an entry here.
 * Registered (and, for wrappers/opt/list/map/result/struct/enum,
 * recursively discovered through their element/field types) by
 * inspect_fn, then emitted by emit_inspect_codecs.
 *
 * Output reads like a JavaScript console: strings double-quoted,
 * lists [a, b], maps and structs {k: v}, opt as none/some(v),
 * result as ok(v)/err(e), enums as bare variant names.
 *
 * Depth caps nesting (SL_INSPECT_MAX_DEPTH, runtime/sl_inspect.c):
 * a composite entered too deep appends "..." instead of recursing,
 * so cyclic GC values terminate instead of looping forever. */

#include "internal.h"

#include <string.h>

/* Fixed-helper scalar types: rendered by one runtime call, no table
 * entry. Wrappers, enums and composites are NOT scalar even when
 * their C representation is small. */
int inspect_is_scalar(const char *t) {
    char *inner;
    if (type_wrap(t, &inner) != TW_NONE)
        return 0;
    return is_int(t) || is_flt(t) || !strcmp(t, "bool") || is_str(t) ||
           is_bytes(t) || is_fault(t) || is_peer(t) || is_until(t) ||
           is_wire(t);
}

static const char *inspect_scalar_name(const char *t) {
    if (!strcmp(t, "bool"))
        return "sl_inspect_bool";
    if (is_str(t))
        return "sl_inspect_str";
    if (is_bytes(t))
        return "sl_inspect_bytes";
    if (is_fault(t))
        return "sl_inspect_fault";
    if (is_peer(t))
        return "sl_inspect_peer";
    if (is_until(t))
        return "sl_inspect_until";
    if (is_wire(t))
        return "sl_inspect_wire";
    if (is_int(t))
        return is_signed_int(t) ? "sl_inspect_i64" : "sl_inspect_u64";
    if (is_flt(t))
        return "sl_inspect_f64";
    return NULL;
}

/* Fixed helpers take widened C types (long long / unsigned long long
 * / double); narrower slang scalars need a cast at the call site.
 * Same convention as json_enc_call_arg. Composite values and
 * bool/str-likes pass through unchanged. */
char *inspect_call_arg(const char *t, const char *val) {
    if (is_int(t))
        return xasprintf(is_signed_int(t) ? "(long long)(%s)"
                                          : "(unsigned long long)(%s)",
                         val);
    if (is_flt(t))
        return xasprintf("(double)(%s)", val);
    return xstrdup(val);
}

static InspectInst *inspect_find(CG *cg, const char *t) {
    for (int i = 0; i < cg->inspect.count; i++)
        if (!strcmp(cg->inspect.items[i].slang_type, t))
            return &cg->inspect.items[i];
    return NULL;
}

static InspectInst *inspect_reserve(CG *cg, const char *t) {
    InspectInst *existing = inspect_find(cg, t);
    if (existing)
        return existing;
    if (cg->inspect.count == cg->inspect.cap) {
        cg->inspect.cap = cg->inspect.cap ? cg->inspect.cap * 2 : 8;
        cg->inspect.items = (InspectInst *)xrealloc(
            cg->inspect.items, cg->inspect.cap * sizeof(InspectInst));
    }
    InspectInst *it = &cg->inspect.items[cg->inspect.count++];
    it->slang_type = xstrdup(t);
    it->fn_name = NULL;
    return it;
}

const char *inspect_fn(CG *cg, const char *t, int line) {
    const char *scalar = inspect_scalar_name(t);
    if (scalar)
        return scalar;
    /* Reserve (and name) this type's slot BEFORE recursing into its
     * element/field types, so a self-referential struct reached
     * through opt[Self] finds its own in-progress entry instead of
     * recursing forever -- the same ordering json's own dispatch
     * uses for the same reason. */
    InspectInst *it = inspect_find(cg, t);
    if (it && it->fn_name)
        return it->fn_name;
    it = inspect_reserve(cg, t);
    if (!it->fn_name)
        it->fn_name = xasprintf("sl_inspect_%s", sanitize_pkg(t));
    char *wrapped = NULL;
    if (type_wrap(t, &wrapped) != TW_NONE) {
        inspect_fn(cg, wrapped, line);
    } else if (is_opt(t)) {
        char *inner = opt_inner(t);
        inspect_fn(cg, inner, line);
        free(inner);
    } else if (is_arr(t)) {
        char *elem = arr_elem(t);
        inspect_fn(cg, elem, line);
        free(elem);
    } else if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        if (!is_map_key(cg, k))
            cg_error(line,
                     "cannot inspect map[%s]%s: keys must be int, str, "
                     "bool, or enum (got map[%s]...)",
                     k, v, k);
        inspect_fn(cg, k, line);
        inspect_fn(cg, v, line);
        free(k);
        free(v);
    } else if (is_result(t)) {
        char *tv, *te;
        result_te(t, &tv, &te);
        inspect_fn(cg, tv, line);
        inspect_fn(cg, te, line);
        free(tv);
        free(te);
    } else if (is_enum(cg, t)) {
        /* leaf: needs its tables, but no further types */
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        if (!sd)
            cg_error(line,
                     "cannot inspect type '%s': channels, mutexes, "
                     "functions, and raw pointers have no readable form",
                     t);
        for (int i = 0; i < sd->nfields; i++)
            inspect_fn(cg, sd->ftypes[i], line);
    }
    return it->fn_name;
}

/* One C statement appending the rendering of `val` (a C expression of
 * slang type `t`) to `sb` at nesting `depth` (a C expression). Used
 * both for composite bodies (via emit_line) and for inspect's own
 * call site (embedded in a GNU statement expression). */
char *inspect_append_stmt(CG *cg, const char *t, const char *val,
                          const char *sb, const char *depth) {
    const char *scalar = inspect_scalar_name(t);
    if (scalar) {
        char *arg = inspect_call_arg(t, val);
        char *s = xasprintf("%s(%s, %s);", scalar, sb, arg);
        free(arg);
        return s;
    }
    const char *fn = inspect_fn(cg, t, 0);
    return xasprintf("%s(%s, %s, %s);", fn, val, sb, depth);
}

/* ------------------------------------------------------------------ */
/* Emission                                                             */
/* ------------------------------------------------------------------ */

static void emit_inspect_body(CG *cg, InspectInst *it) {
    const char *t = it->slang_type;
    const char *ct = ctype_of(cg, t);
    emit_line(cg, "static void %s(%s v, sl_inspect_sb *out, int depth) {",
              it->fn_name, ct);
    cg->indent++;

    char *wrapped = NULL;
    TypeWrap w = type_wrap(t, &wrapped);
    if (w != TW_NONE) {
        /* Transparent wrapper (ref/own/gc/ptr): not a nesting level
         * the user sees, so depth passes through unchanged. A null
         * pointer (ptr[T]/nullable shapes) renders as nullptr rather
         * than faulting on the dereference. */
        const char *inner_fn = inspect_fn(cg, wrapped, 0);
        emit_line(cg, "if (!v) { sl_inspect_sb_append(out, \"nullptr\"); return; }");
        if (inspect_is_scalar(wrapped)) {
            char *arg = inspect_call_arg(wrapped, "(*v)");
            emit_line(cg, "%s(out, %s);", inner_fn, arg);
            free(arg);
        } else {
            emit_line(cg, "%s(*v, out, depth);", inner_fn);
        }
    } else if (is_opt(t)) {
        char *inner = opt_inner(t);
        emit_line(cg, "if (!v->has) { sl_inspect_sb_append(out, \"none\"); return; }");
        emit_line(cg, "sl_inspect_sb_append(out, \"some(\");");
        char *s = inspect_append_stmt(cg, inner, "v->v", "out", "depth + 1");
        emit_line(cg, "%s", s);
        free(s);
        emit_line(cg, "sl_inspect_sb_append(out, \")\");");
        free(inner);
    } else if (is_arr(t)) {
        char *elem = arr_elem(t);
        const char *ect = ctype_of(cg, elem);
        emit_line(cg, "if (depth > SL_INSPECT_MAX_DEPTH) { "
                      "sl_inspect_sb_append(out, \"...\"); return; }");
        emit_line(cg, "sl_inspect_sb_append(out, \"[\");");
        emit_line(cg, "for (long long i = 0; i < v->len; i++) {");
        cg->indent++;
        emit_line(cg, "if (i) sl_inspect_sb_append(out, \", \");");
        emit_line(cg, "%s *ep = (%s *)sl_arr_at(v, i, sizeof(%s));", ect,
                  ect, ect);
        char *s = inspect_append_stmt(cg, elem, "*ep", "out", "depth + 1");
        emit_line(cg, "%s", s);
        free(s);
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_inspect_sb_append(out, \"]\");");
        free(elem);
    } else if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        const char *vct = ctype_of(cg, v);
        emit_line(cg, "if (depth > SL_INSPECT_MAX_DEPTH) { "
                      "sl_inspect_sb_append(out, \"...\"); return; }");
        emit_line(cg, "sl_inspect_sb_append(out, \"{\");");
        emit_line(cg, "for (long long i = 0; i < v->count; i++) {");
        cg->indent++;
        emit_line(cg, "if (i) sl_inspect_sb_append(out, \", \");");
        if (is_str(k)) {
            emit_line(cg, "const char *kp = *(const char **)(v->keys + "
                          "(size_t)v->order[i] * v->ksz);");
            char *s = inspect_append_stmt(cg, k, "kp", "out", "depth + 1");
            emit_line(cg, "%s", s);
            free(s);
        } else {
            const char *kct = ctype_of(cg, k);
            emit_line(cg, "%s *kp = (%s *)(v->keys + (size_t)v->order[i] * "
                          "v->ksz);",
                      kct, kct);
            char *s = inspect_append_stmt(cg, k, "*kp", "out", "depth + 1");
            emit_line(cg, "%s", s);
            free(s);
        }
        emit_line(cg, "sl_inspect_sb_append(out, \": \");");
        emit_line(cg, "%s *vp = (%s *)sl_inspect_map_val_at(v, i);", vct,
                  vct);
        char *s = inspect_append_stmt(cg, v, "*vp", "out", "depth + 1");
        emit_line(cg, "%s", s);
        free(s);
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_inspect_sb_append(out, \"}\");");
        free(k);
        free(v);
    } else if (is_result(t)) {
        char *tv, *te;
        result_te(t, &tv, &te);
        const char *acc = res_access(cg, t);
        emit_line(cg, "if (v%sok) {", acc);
        cg->indent++;
        emit_line(cg, "sl_inspect_sb_append(out, \"ok(\");");
        char *vo = xasprintf("v%s%s", acc, "v");
        char *s = inspect_append_stmt(cg, tv, vo, "out", "depth + 1");
        emit_line(cg, "%s", s);
        free(s);
        free(vo);
        emit_line(cg, "sl_inspect_sb_append(out, \")\");");
        cg->indent--;
        emit_line(cg, "} else {");
        cg->indent++;
        emit_line(cg, "sl_inspect_sb_append(out, \"err(\");");
        char *eo = xasprintf("v%s%s", acc, "e");
        s = inspect_append_stmt(cg, te, eo, "out", "depth + 1");
        emit_line(cg, "%s", s);
        free(s);
        free(eo);
        emit_line(cg, "sl_inspect_sb_append(out, \")\");");
        cg->indent--;
        emit_line(cg, "}");
        free(tv);
        free(te);
    } else if (is_enum(cg, t)) {
        char *m = mangle_enum(t);
        EnumDef *ed = enum_find_canon(cg, t);
        emit_line(cg, "sl_inspect_sb_append(out, sl_enum_name((int32_t)v, "
                      "%s_names, %s_values, %d));",
                  m, m, ed->nvariants);
        free(m);
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        const char *acc = sd->is_gc ? "->" : ".";
        emit_line(cg, "if (depth > SL_INSPECT_MAX_DEPTH) { "
                      "sl_inspect_sb_append(out, \"...\"); return; }");
        emit_line(cg, "sl_inspect_sb_append(out, \"{\");");
        for (int i = 0; i < sd->nfields; i++) {
            if (i)
                emit_line(cg, "sl_inspect_sb_append(out, \", \");");
            const char *ft = sd->ftypes[i];
            const char *fname = sanitize_ident(sd->fields[i]);
            emit_line(cg, "sl_inspect_sb_append(out, \"%s: \");",
                      sd->fields[i]);
            char *acc_expr = xasprintf("v%s%s", acc, fname);
            char *s = inspect_append_stmt(cg, ft, acc_expr, "out",
                                          "depth + 1");
            emit_line(cg, "%s", s);
            free(s);
            free(acc_expr);
        }
        emit_line(cg, "sl_inspect_sb_append(out, \"}\");");
    }

    cg->indent--;
    emit_line(cg, "}");
    emit_line(cg, "");
}

void emit_inspect_runtime(CG *cg) {
    if (!cg->want_inspect)
        return;
    emit_runtime_file(cg, "sl_inspect.c");
}

void emit_inspect_codecs(CG *cg) {
    if (!cg->want_inspect || !cg->inspect.count)
        return;
    for (int i = 0; i < cg->inspect.count; i++) {
        InspectInst *it = &cg->inspect.items[i];
        const char *ct = ctype_of(cg, it->slang_type);
        emit_line(cg, "static void %s(%s v, sl_inspect_sb *out, int depth);",
                  it->fn_name, ct);
    }
    emit_line(cg, "");
    for (int i = 0; i < cg->inspect.count; i++)
        emit_inspect_body(cg, &cg->inspect.items[i]);
}
