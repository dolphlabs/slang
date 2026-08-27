/* json.decode / json.encode: monomorphized (de)serialization codegen.
 *
 * Every JSON-representable slang type maps to a C function with one
 * of two fixed signatures:
 *   decode: bool NAME(sl_json_val *v, <ctype_of T> *out, char **err);
 *   encode: void NAME(<ctype_of T> v, sl_json_sb *out);
 * Scalars (bool/str/int-like/float-like) are fixed functions already
 * defined in JSON_RUNTIME (runtime.c). Composite types
 * (opt[T]/[T]/map[str,V]/struct) are monomorphized here, one C
 * function per distinct slang type reached from a json.decode or
 * json.encode call site -- registered (and, for structs/opt/list/map,
 * recursively discovered through their element/field types) by
 * json_dec_fn/json_enc_fn, then emitted by emit_json_codecs. */

#include "../internal.h"

#include <string.h>

static const char *json_scalar_dec_name(const char *t) {
    if (!strcmp(t, "bool")) return "sl_json_dec_bool";
    if (is_str(t)) return "sl_json_dec_str";
    if (!strcmp(t, "i8")) return "sl_json_dec_i8";
    if (!strcmp(t, "i16")) return "sl_json_dec_i16";
    if (!strcmp(t, "i32")) return "sl_json_dec_i32";
    if (!strcmp(t, "u8")) return "sl_json_dec_u8";
    if (!strcmp(t, "u16")) return "sl_json_dec_u16";
    if (!strcmp(t, "u32")) return "sl_json_dec_u32";
    if (!strcmp(t, "u64")) return "sl_json_dec_u64";
    if (!strcmp(t, "f32")) return "sl_json_dec_f32";
    if (!strcmp(t, "float")) return "sl_json_dec_f64";
    /* int/i64/duration all share the 64-bit signed C representation */
    if (!strcmp(t, "i64") || !strcmp(t, "int") || !strcmp(t, "duration"))
        return "sl_json_dec_i64";
    return NULL;
}

static const char *json_scalar_enc_name(const char *t) {
    if (!strcmp(t, "bool")) return "sl_json_enc_bool";
    if (is_str(t)) return "sl_json_enc_str";
    if (is_int(t)) return is_signed_int(t) ? "sl_json_enc_i64" : "sl_json_enc_u64";
    if (is_flt(t)) return "sl_json_enc_f64";
    return NULL;
}

/* Fixed encode helpers take a widened C type (long long / unsigned
 * long long / double); narrower slang scalar types need an explicit
 * cast at the call site. Composite/bool/str values pass through
 * unchanged -- their encode function takes the exact ctype_of(t). */
static char *json_enc_arg(const char *t, const char *val) {
    if (is_int(t))
        return xasprintf(is_signed_int(t) ? "(long long)(%s)"
                                          : "(unsigned long long)(%s)",
                         val);
    if (is_flt(t))
        return xasprintf("(double)(%s)", val);
    return xstrdup(val);
}

static JsonInst *json_find(CG *cg, const char *t) {
    for (int i = 0; i < cg->json.count; i++)
        if (!strcmp(cg->json.items[i].slang_type, t))
            return &cg->json.items[i];
    return NULL;
}

static JsonInst *json_reserve(CG *cg, const char *t) {
    JsonInst *existing = json_find(cg, t);
    if (existing)
        return existing;
    if (cg->json.count == cg->json.cap) {
        cg->json.cap = cg->json.cap ? cg->json.cap * 2 : 8;
        cg->json.items = (JsonInst *)xrealloc(
            cg->json.items, cg->json.cap * sizeof(JsonInst));
    }
    JsonInst *it = &cg->json.items[cg->json.count++];
    it->slang_type = xstrdup(t);
    it->dec_name = NULL;
    it->enc_name = NULL;
    return it;
}

const char *json_dec_fn(CG *cg, const char *t, int line) {
    const char *scalar = json_scalar_dec_name(t);
    if (scalar)
        return scalar;

    /* Reserve (or fetch) this type's slot BEFORE recursing into its
     * element/field types, so a self-referential struct reached
     * through opt[Self] finds its own in-progress entry instead of
     * recursing forever. */
    JsonInst *it = json_reserve(cg, t);
    if (it->dec_name)
        return it->dec_name;
    it->dec_name = xasprintf("sl_json_dec_%s", sanitize_pkg(t));

    if (is_opt(t)) {
        char *inner = opt_inner(t);
        json_dec_fn(cg, inner, line); /* registers the inner codec */
    } else if (is_arr(t)) {
        json_dec_fn(cg, arr_elem(t), line);
    } else if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        if (!is_str(k))
            cg_error(line,
                     "cannot json.decode into map[%s]%s: JSON object keys "
                     "must be str (got map[%s]...)",
                     k, v, k);
        json_dec_fn(cg, v, line);
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        if (!sd)
            cg_error(line,
                     "cannot json.decode into type '%s': not representable "
                     "in JSON (rawptr, chan, result, and bytes fields "
                     "aren't supported)",
                     t);
        for (int i = 0; i < sd->nfields; i++)
            json_dec_fn(cg, sd->ftypes[i], line);
    }
    return it->dec_name;
}

const char *json_enc_fn(CG *cg, const char *t, int line) {
    const char *scalar = json_scalar_enc_name(t);
    if (scalar)
        return scalar;

    JsonInst *it = json_reserve(cg, t);
    if (it->enc_name)
        return it->enc_name;
    it->enc_name = xasprintf("sl_json_enc_%s", sanitize_pkg(t));

    if (is_opt(t)) {
        char *inner = opt_inner(t);
        json_enc_fn(cg, inner, line);
    } else if (is_arr(t)) {
        json_enc_fn(cg, arr_elem(t), line);
    } else if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        if (!is_str(k))
            cg_error(line,
                     "cannot json.encode map[%s]%s: JSON object keys must "
                     "be str (got map[%s]...)",
                     k, v, k);
        json_enc_fn(cg, v, line);
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        if (!sd)
            cg_error(line,
                     "cannot json.encode type '%s': not representable in "
                     "JSON (rawptr, chan, result, and bytes fields aren't "
                     "supported)",
                     t);
        for (int i = 0; i < sd->nfields; i++)
            json_enc_fn(cg, sd->ftypes[i], line);
    }
    return it->enc_name;
}

/* ------------------------------------------------------------------ */
/* Emission                                                             */
/* ------------------------------------------------------------------ */

static void emit_json_dec_body(CG *cg, JsonInst *it) {
    const char *t = it->slang_type;
    const char *ct = ctype_of(cg, t);
    emit_line(cg, "static bool %s(sl_json_val *v, %s *out, char **err) {",
              it->dec_name, ct);
    cg->indent++;

    if (is_opt(t)) {
        char *inner = opt_inner(t);
        const char *oname = opt_cname(cg, inner);
        const char *innerfn = json_dec_fn(cg, inner, 0);
        const char *otrace = type_is_gc_ptr(cg, inner)
                                  ? xasprintf("sl_gc_trace_%s", oname)
                                  : "NULL";
        emit_line(cg, "%s *o = (%s *)sl_gc_alloc(sizeof(%s), %s);", oname,
                  oname, oname, otrace);
        emit_line(cg, "if (v->kind == SL_JV_NULL) {");
        cg->indent++;
        emit_line(cg, "o->has = false;");
        emit_line(cg, "*out = o;");
        emit_line(cg, "return true;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "if (!%s(v, &o->v, err)) return false;", innerfn);
        emit_line(cg, "o->has = true;");
        emit_line(cg, "*out = o;");
        emit_line(cg, "return true;");
    } else if (is_arr(t)) {
        char *elem = arr_elem(t);
        const char *ect = ctype_of(cg, elem);
        const char *elemfn = json_dec_fn(cg, elem, 0);
        emit_line(cg, "if (v->kind != SL_JV_ARR) {");
        cg->indent++;
        emit_line(
            cg,
            "*err = sl_json_errf(\"expected an array, got %%s\", "
            "sl_json_kind_name(v));");
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_arr *a = sl_arr_new(sizeof(%s), %d);", ect,
                  type_is_gc_ptr(cg, elem));
        emit_line(cg, "for (long long i = 0; i < v->as.arr.len; i++) {");
        cg->indent++;
        emit_line(cg, "%s tmp;", ect);
        emit_line(cg, "if (!%s(v->as.arr.items[i], &tmp, err)) {", elemfn);
        cg->indent++;
        emit_line(cg, "char ctx[32];");
        emit_line(cg, "snprintf(ctx, sizeof(ctx), \"index %%lld\", i);");
        emit_line(cg, "*err = sl_json_wrap_err(ctx, *err);");
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_arr_push(a, &tmp, sizeof(%s));", ect);
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "*out = a;");
        emit_line(cg, "return true;");
    } else if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        (void)k; /* validated to be str in json_dec_fn */
        const char *vct = ctype_of(cg, v);
        const char *valfn = json_dec_fn(cg, v, 0);
        emit_line(cg, "if (v->kind != SL_JV_OBJ) {");
        cg->indent++;
        emit_line(
            cg,
            "*err = sl_json_errf(\"expected an object, got %%s\", "
            "sl_json_kind_name(v));");
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_map *m = sl_map_new(sizeof(const char *), "
                       "sizeof(%s), 1, 1, %d);",
                  vct, type_is_gc_ptr(cg, v));
        emit_line(cg, "for (long long i = 0; i < v->as.obj.len; i++) {");
        cg->indent++;
        emit_line(cg, "%s tmp;", vct);
        emit_line(cg, "if (!%s(v->as.obj.vals[i], &tmp, err)) {", valfn);
        cg->indent++;
        emit_line(cg, "*err = sl_json_wrap_err(v->as.obj.keys[i], *err);");
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "const char *k = v->as.obj.keys[i];");
        emit_line(cg, "sl_map_put(m, &k, &tmp);");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "*out = m;");
        emit_line(cg, "return true;");
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        const char *sname = mangle_struct(t);
        const char *strace = struct_has_gc_fields(cg, sd)
                                  ? xasprintf("sl_gc_trace_%s", sname)
                                  : "NULL";
        emit_line(cg, "if (v->kind != SL_JV_OBJ) {");
        cg->indent++;
        emit_line(
            cg,
            "*err = sl_json_errf(\"expected an object, got %%s\", "
            "sl_json_kind_name(v));");
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "%s *tmp = (%s *)sl_gc_alloc(sizeof(%s), %s);", sname,
                  sname, sname, strace);
        emit_line(cg, "sl_json_val *fv;");
        for (int i = 0; i < sd->nfields; i++) {
            const char *ft = sd->ftypes[i];
            const char *fname = sanitize_ident(sd->fields[i]);
            emit_line(cg, "fv = sl_json_obj_get(v, \"%s\");", sd->fields[i]);
            emit_line(cg, "if (!fv) {");
            cg->indent++;
            if (is_opt(ft)) {
                const char *inner_t = opt_inner(ft);
                const char *oname = opt_cname(cg, inner_t);
                const char *otrace = type_is_gc_ptr(cg, inner_t)
                                          ? xasprintf("sl_gc_trace_%s", oname)
                                          : "NULL";
                emit_line(cg,
                          "%s *o%d = (%s *)sl_gc_alloc(sizeof(%s), %s); o%d->has "
                          "= false; tmp->%s = o%d;",
                          oname, i, oname, oname, otrace, i, fname, i);
            } else {
                emit_line(cg,
                          "*err = sl_json_errf(\"missing required field "
                          "'%s'\");",
                          sd->fields[i]);
                emit_line(cg, "return false;");
            }
            cg->indent--;
            emit_line(cg, "} else {");
            cg->indent++;
            const char *fct = ctype_of(cg, ft);
            const char *ffn = json_dec_fn(cg, ft, 0);
            emit_line(cg, "%s ftmp;", fct);
            emit_line(cg, "if (!%s(fv, &ftmp, err)) {", ffn);
            cg->indent++;
            emit_line(cg, "*err = sl_json_wrap_err(\"field '%s'\", *err);",
                      sd->fields[i]);
            emit_line(cg, "return false;");
            cg->indent--;
            emit_line(cg, "}");
            emit_line(cg, "tmp->%s = ftmp;", fname);
            cg->indent--;
            emit_line(cg, "}");
        }
        emit_line(cg, "*out = tmp;");
        emit_line(cg, "return true;");
    }

    cg->indent--;
    emit_line(cg, "}");
    emit_line(cg, "");
}

static void emit_json_enc_body(CG *cg, JsonInst *it) {
    const char *t = it->slang_type;
    const char *ct = ctype_of(cg, t);
    emit_line(cg, "static void %s(%s v, sl_json_sb *out) {", it->enc_name,
              ct);
    cg->indent++;

    if (is_opt(t)) {
        char *inner = opt_inner(t);
        const char *innerfn = json_enc_fn(cg, inner, 0);
        char *arg = json_enc_arg(inner, "v->v");
        emit_line(cg, "if (!v->has) { sl_json_enc_null(out); return; }");
        emit_line(cg, "%s(%s, out);", innerfn, arg);
    } else if (is_arr(t)) {
        char *elem = arr_elem(t);
        const char *ect = ctype_of(cg, elem);
        const char *elemfn = json_enc_fn(cg, elem, 0);
        emit_line(cg, "sl_json_sb_append(out, \"[\");");
        emit_line(cg, "for (long long i = 0; i < v->len; i++) {");
        cg->indent++;
        emit_line(cg, "if (i) sl_json_sb_append(out, \",\");");
        emit_line(cg, "%s *ep = (%s *)sl_arr_get(v, i, sizeof(%s));", ect,
                  ect, ect);
        char *arg = json_enc_arg(elem, "*ep");
        emit_line(cg, "%s(%s, out);", elemfn, arg);
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_json_sb_append(out, \"]\");");
    } else if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        (void)k;
        const char *vct = ctype_of(cg, v);
        const char *valfn = json_enc_fn(cg, v, 0);
        emit_line(cg, "sl_json_sb_append(out, \"{\");");
        emit_line(cg, "for (long long i = 0; i < v->count; i++) {");
        cg->indent++;
        emit_line(cg, "if (i) sl_json_sb_append(out, \",\");");
        emit_line(cg, "sl_json_enc_str(sl_json_map_key_at(v, i), out);");
        emit_line(cg, "sl_json_sb_append(out, \":\");");
        emit_line(cg, "%s *vp = (%s *)sl_json_map_val_at(v, i);", vct, vct);
        char *arg = json_enc_arg(v, "*vp");
        emit_line(cg, "%s(%s, out);", valfn, arg);
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "sl_json_sb_append(out, \"}\");");
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        emit_line(cg, "sl_json_sb_append(out, \"{\");");
        for (int i = 0; i < sd->nfields; i++) {
            if (i)
                emit_line(cg, "sl_json_sb_append(out, \",\");");
            const char *ft = sd->ftypes[i];
            const char *fname = sanitize_ident(sd->fields[i]);
            const char *ffn = json_enc_fn(cg, ft, 0);
            char *val = xasprintf("v->%s", fname);
            char *arg = json_enc_arg(ft, val);
            emit_line(cg, "sl_json_enc_str(\"%s\", out);", sd->fields[i]);
            emit_line(cg, "sl_json_sb_append(out, \":\");");
            emit_line(cg, "%s(%s, out);", ffn, arg);
        }
        emit_line(cg, "sl_json_sb_append(out, \"}\");");
    }

    cg->indent--;
    emit_line(cg, "}");
    emit_line(cg, "");
}

void emit_json_runtime(CG *cg) {
    if (!cg->want_json)
        return;
    for (int i = 0; i < JSON_RUNTIME_LEN; i++)
        emit_line(cg, "%s", JSON_RUNTIME[i]);
}

void emit_json_codecs(CG *cg) {
    if (!cg->want_json || !cg->json.count)
        return;
    for (int i = 0; i < cg->json.count; i++) {
        JsonInst *it = &cg->json.items[i];
        const char *ct = ctype_of(cg, it->slang_type);
        if (it->dec_name)
            emit_line(cg, "static bool %s(sl_json_val *v, %s *out, char **err);",
                      it->dec_name, ct);
        if (it->enc_name)
            emit_line(cg, "static void %s(%s v, sl_json_sb *out);",
                      it->enc_name, ct);
    }
    emit_line(cg, "");
    for (int i = 0; i < cg->json.count; i++) {
        JsonInst *it = &cg->json.items[i];
        if (it->dec_name)
            emit_json_dec_body(cg, it);
        if (it->enc_name)
            emit_json_enc_body(cg, it);
    }
}

/* Exposed for expr.c/infer.c's json.decode/json.encode call handling. */
char *json_enc_call_arg(const char *t, const char *val) {
    return json_enc_arg(t, val);
}

/* ------------------------------------------------------------------ */
/* json.decode / json.encode call sites                                */
/* ------------------------------------------------------------------ */

const char *json_call_infer(CG *cg, const char *fname, Expr *e) {
    cg->want_json = 1;
    int n = e->as.call.nargs;
    if (!strcmp(fname, "decode")) {
        if (n != 1)
            cg_error(e->line, "json.decode() takes exactly one argument");
        const char *at = infer_type(cg, e->as.call.args[0]);
        if (!is_str(at) && !is_bytes(at))
            cg_error(e->line,
                     "json.decode() expects a str or bytes argument (got "
                     "%s)",
                     at);
        if (!cg->expect || !is_result(cg->expect))
            cg_error(e->line,
                     "cannot infer the type of 'json.decode()'; annotate "
                     "the binding, e.g. let x: result[Person, str] = "
                     "json.decode(body)");
        char *tv, *tev;
        result_te(cg->expect, &tv, &tev);
        if (!is_str(tev))
            cg_error(e->line,
                     "json.decode()'s error type must be str (got "
                     "result[%s, %s])",
                     tv, tev);
        json_dec_fn(cg, tv, e->line);
        return cg->expect;
    }
    if (!strcmp(fname, "encode")) {
        if (n != 1)
            cg_error(e->line, "json.encode() takes exactly one argument");
        const char *at = infer_type(cg, e->as.call.args[0]);
        json_enc_fn(cg, at, e->line);
        return "str";
    }
    cg_error(e->line, "package 'json' has no function '%s'", fname);
    return NULL; /* unreachable */
}

char *json_call_gen(CG *cg, const char *fname, Expr *e) {
    if (!strcmp(fname, "decode")) {
        char *tv, *tev;
        result_te(cg->expect, &tv, &tev);
        const char *resname = res_cname(cg, tv, tev);
        const char *restrace =
            (type_is_gc_ptr(cg, tv) || type_is_gc_ptr(cg, tev))
                ? xasprintf("sl_gc_trace_%s", resname)
                : "NULL";
        const char *decfn = json_dec_fn(cg, tv, e->line);
        const char *fct = ctype_of(cg, tv);
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *argexpr = gen_expr(cg, e->as.call.args[0]);
        char *data, *len;
        if (is_bytes(at)) {
            data = xasprintf("(const char *)(%s)->ptr", argexpr);
            len = xasprintf("(%s)->len", argexpr);
        } else {
            data = xasprintf("(%s)", argexpr);
            len = xasprintf("(long long)strlen(%s)", argexpr);
        }
        char *inner = xasprintf(
            "({ char *_sl_jerr = NULL; sl_json_val *_sl_jv = "
            "sl_json_parse(%s, %s, &_sl_jerr); %s *_sl_jr = (%s "
            "*)sl_gc_alloc(sizeof(%s), %s); if (!_sl_jv) { _sl_jr->ok = false; "
            "_sl_jr->e = _sl_jerr; } else { %s _sl_jout; char *_sl_jderr = "
            "NULL; if (%s(_sl_jv, &_sl_jout, &_sl_jderr)) { _sl_jr->ok = "
            "true; _sl_jr->v = _sl_jout; } else { _sl_jr->ok = false; "
            "_sl_jr->e = _sl_jderr; } } _sl_jr; })",
            data, len, resname, resname, resname, restrace, fct, decfn);
        /* Tier 10: json.decode allocates (the result[T,E] wrapper,
         * plus whatever the monomorphized decoder itself
         * allocates) -- a real safepoint, same as any other call
         * liveness.c computes e->live_set for. Single argument, no
         * sibling to protect against. */
        return wrap_safepoint(cg, e, xasprintf("%s *", resname), NULL, inner);
    }
    /* encode */
    const char *at = infer_type(cg, e->as.call.args[0]);
    const char *encfn = json_enc_fn(cg, at, e->line);
    char *argexpr = gen_expr(cg, e->as.call.args[0]);
    char *arg = json_enc_arg(at, argexpr);
    char *inner = xasprintf(
        "({ sl_json_sb _sl_jsb; sl_json_sb_init(&_sl_jsb); %s(%s, "
        "&_sl_jsb); (const char *)(_sl_jsb.data ? _sl_jsb.data : \"\"); })",
        encfn, arg);
    return wrap_safepoint(cg, e, ctype_of(cg, "str"), NULL, inner);
}
