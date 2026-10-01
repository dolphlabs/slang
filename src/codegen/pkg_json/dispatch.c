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
    if (is_bytes(t)) return "sl_json_dec_bytes";
    if (!strcmp(t, "i8")) return "sl_json_dec_i8";
    if (!strcmp(t, "i16")) return "sl_json_dec_i16";
    if (!strcmp(t, "i32")) return "sl_json_dec_i32";
    if (!strcmp(t, "u8")) return "sl_json_dec_u8";
    if (!strcmp(t, "u16")) return "sl_json_dec_u16";
    if (!strcmp(t, "u32")) return "sl_json_dec_u32";
    if (!strcmp(t, "u64")) return "sl_json_dec_u64";
    if (!strcmp(t, "f32")) return "sl_json_dec_f32";
    if (!strcmp(t, "float")) return "sl_json_dec_f64";
    /* Same 64-bit width, but not the same C type everywhere: int is
       long long, i64 and duration are int64_t (see sl_json_dec_int). */
    if (!strcmp(t, "int")) return "sl_json_dec_int";
    if (!strcmp(t, "i64") || !strcmp(t, "duration"))
        return "sl_json_dec_i64";
    return NULL;
}

/* The direct decoders (sl_jd_*, runtime/sl_json.c) for the same scalars. */
static const char *json_scalar_fast_name(const char *t) {
    const char *dec = json_scalar_dec_name(t);
    if (!dec)
        return NULL;
    /* sl_json_dec_<x> -> sl_jd_<x>; f64 keeps its name on both sides */
    return xasprintf("sl_jd_%s", dec + strlen("sl_json_dec_"));
}

/* Every type json_dec_fn registers has a direct decoder too:
 *   bool NAME(sl_jparser *p, <ctype_of T> *out);
 * which reads the input straight into T and returns false, with no error
 * built, on anything it does not accept; the call site then decodes again
 * through the tree decoder for the error. */
static const char *json_fast_fn(CG *cg, const char *t) {
    const char *scalar = json_scalar_fast_name(t);
    if (scalar)
        return scalar;
    (void)cg;
    return xasprintf("sl_jdf_%s", sanitize_pkg(t));
}

static const char *json_scalar_enc_name(const char *t) {
    if (!strcmp(t, "bool")) return "sl_json_enc_bool";
    if (is_str(t)) return "sl_json_enc_str";
    if (is_bytes(t)) return "sl_json_enc_bytes";
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

/* The generated codecs read and build a struct through a pointer (a
 * decoded struct is a heap object; an encoded one is walked with `->`), so
 * they only exist for `gc struct`. Without this a plain struct got as far
 * as the C compiler, which said `member reference type is not a pointer`
 * about generated code. Checked at every struct the walk reaches, so a
 * plain struct nested inside a gc one is named too. */
static void json_require_gc_struct(StructDef *sd, const char *what, int line) {
    if (sd->is_gc)
        return;
    cg_error(line,
             "cannot json.%s '%s': json supports only gc structs (declare "
             "it 'gc struct %s')",
             what, sd->canonical, sd->name);
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
    } else if (is_enum(cg, t)) {
        /* leaf scalar: no element/field types to recurse into */
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        if (!sd)
            cg_error(line,
                     "cannot json.decode into type '%s': not representable "
                     "in JSON (rawptr, chan, and result aren't supported)",
                     t);
        json_require_gc_struct(sd, "decode into", line);
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
    } else if (is_enum(cg, t)) {
        /* leaf scalar: no element/field types to recurse into */
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        if (!sd)
            cg_error(line,
                     "cannot json.encode type '%s': not representable in "
                     "JSON (rawptr, chan, and result aren't supported)",
                     t);
        json_require_gc_struct(sd, "encode", line);
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
                  /* Same elem flag fix as gen_list: interior pointers. */
                  type_has_gc_roots(cg, elem));
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
                  vct, type_has_gc_roots(cg, v));
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
    } else if (is_enum(cg, t)) {
        char *m = mangle_enum(t);
        EnumDef *ed = enum_find_canon(cg, t);
        emit_line(cg, "if (v->kind != SL_JV_STR) {");
        cg->indent++;
        emit_line(cg,
                  "*err = sl_json_errf(\"expected a string, got %%s\", "
                  "sl_json_kind_name(v));");
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "int32_t idx;");
        emit_line(cg, "if (!sl_enum_from_str(v->as.str, %s_names, %d, &idx)) {",
                  m, ed->nvariants);
        cg->indent++;
        emit_line(cg,
                  "*err = sl_json_errf(\"not a valid %s: %%s\", v->as.str);",
                  ed->name);
        emit_line(cg, "return false;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "*out = (int32_t)%s_values[idx];", m);
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

/* The direct decoder for a composite type. Values are decoded before the
 * object that holds them is allocated, and the object is filled at once:
 * a collection in between could otherwise promote the holder and leave it
 * pointing at young values with no barrier. Lists and maps are the
 * exception, filled through sl_arr_push/sl_map_put, which barrier. */
static void emit_json_fast_body(CG *cg, JsonInst *it) {
    const char *t = it->slang_type;
    const char *ct = ctype_of(cg, t);
    emit_line(cg, "static bool %s(sl_jparser *p, %s *out) {",
              json_fast_fn(cg, t), ct);
    cg->indent++;

    if (is_opt(t)) {
        char *inner = opt_inner(t);
        const char *oname = opt_cname(cg, inner);
        const char *ict = ctype_of(cg, inner);
        const char *otrace = type_is_gc_ptr(cg, inner)
                                  ? xasprintf("sl_gc_trace_%s", oname)
                                  : "NULL";
        emit_line(cg, "%s *o;", oname);
        emit_line(cg, "if (sl_jd_peek(p) == 'n') {");
        cg->indent++;
        emit_line(cg, "if (!sl_jd_null(p)) return false;");
        emit_line(cg, "o = (%s *)sl_gc_alloc(sizeof(%s), %s);", oname, oname,
                  otrace);
        emit_line(cg, "o->has = false;");
        cg->indent--;
        emit_line(cg, "} else {");
        cg->indent++;
        emit_line(cg, "%s v;", ict);
        emit_line(cg, "if (!%s(p, &v)) return false;", json_fast_fn(cg, inner));
        emit_line(cg, "o = (%s *)sl_gc_alloc(sizeof(%s), %s);", oname, oname,
                  otrace);
        emit_line(cg, "o->has = true;");
        emit_line(cg, "o->v = v;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "*out = o;");
        emit_line(cg, "return true;");
    } else if (is_arr(t) || is_map(t)) {
        int arr = is_arr(t);
        const char *et;
        if (arr) {
            et = arr_elem(t);
        } else {
            char *k, *v;
            map_kv(t, &k, &v);
            et = v;
        }
        const char *ect = ctype_of(cg, et);
        const char *close = arr ? "']'" : "'}'";
        emit_line(cg, "if (!sl_jd_open(p, %s)) return false;", arr ? "'['" : "'{'");
        if (arr)
            emit_line(cg, "sl_arr *c = sl_arr_new(sizeof(%s), %d);", ect,
                      type_has_gc_roots(cg, et));
        else
            emit_line(cg, "sl_map *c = sl_map_new(sizeof(const char *), "
                           "sizeof(%s), 1, 1, %d);",
                      ect, type_has_gc_roots(cg, et));
        emit_line(cg, "if (!sl_jd_empty(p, %s)) {", close);
        cg->indent++;
        emit_line(cg, "for (;;) {");
        cg->indent++;
        if (!arr) {
            /* a map keeps its keys, so each is its own string */
            emit_line(cg, "if (!sl_jd_eat(p, '\"')) return false;");
            emit_line(cg, "const char *k = sl_jparse_string_raw(p);");
            emit_line(cg, "if (!k || !sl_jd_eat(p, ':')) return false;");
        }
        emit_line(cg, "%s tmp;", ect);
        emit_line(cg, "if (!%s(p, &tmp)) return false;", json_fast_fn(cg, et));
        if (arr)
            emit_line(cg, "sl_arr_push(c, &tmp, sizeof(%s));", ect);
        else
            emit_line(cg, "sl_map_put(c, &k, &tmp);");
        emit_line(cg, "bool done;");
        emit_line(cg, "if (sl_jd_more(p, %s, &done)) continue;", close);
        emit_line(cg, "if (!done) return false;");
        emit_line(cg, "break;");
        cg->indent--;
        emit_line(cg, "}");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "*out = c;");
        emit_line(cg, "return true;");
    } else if (is_enum(cg, t)) {
        char *m = mangle_enum(t);
        EnumDef *ed = enum_find_canon(cg, t);
        emit_line(cg, "const char *s;");
        emit_line(cg, "int32_t idx;");
        emit_line(cg, "if (!sl_jd_str(p, &s) || "
                       "!sl_enum_from_str(s, %s_names, %d, &idx)) return false;",
                  m, ed->nvariants);
        emit_line(cg, "*out = (int32_t)%s_values[idx];", m);
        emit_line(cg, "return true;");
    } else {
        StructDef *sd = struct_find_canon(cg, t);
        const char *sname = mangle_struct(t);
        const char *strace = struct_has_gc_fields(cg, sd)
                                  ? xasprintf("sl_gc_trace_%s", sname)
                                  : "NULL";
        emit_line(cg, "if (!sl_jd_open(p, '{')) return false;");
        for (int i = 0; i < sd->nfields; i++) {
            emit_line(cg, "%s f%d = 0;", ctype_of(cg, sd->ftypes[i]), i);
            emit_line(cg, "bool seen%d = false;", i);
        }
        emit_line(cg, "if (!sl_jd_empty(p, '}')) {");
        cg->indent++;
        emit_line(cg, "for (;;) {");
        cg->indent++;
        emit_line(cg, "const char *k;");
        emit_line(cg, "long long kn;");
        emit_line(cg, "if (!sl_jd_key(p, &k, &kn)) return false;");
        /* The first occurrence of a key counts and a repeat is skipped,
         * as the tree decoder's field lookup finds the first. */
        for (int i = 0; i < sd->nfields; i++) {
            const char *fn = sd->fields[i];
            emit_line(cg,
                      "%sif (!seen%d && kn == %d && !memcmp(k, \"%s\", %d)) {",
                      i ? "} else " : "", i, (int)strlen(fn), fn,
                      (int)strlen(fn));
            cg->indent++;
            emit_line(cg, "if (!%s(p, &f%d)) return false;",
                      json_fast_fn(cg, sd->ftypes[i]), i);
            emit_line(cg, "seen%d = true;", i);
            cg->indent--;
        }
        if (sd->nfields) {
            emit_line(cg, "} else if (!sl_jd_skip(p)) {");
            cg->indent++;
            emit_line(cg, "return false;");
            cg->indent--;
            emit_line(cg, "}");
        } else {
            emit_line(cg, "(void)kn;");
            emit_line(cg, "if (!sl_jd_skip(p)) return false;");
        }
        emit_line(cg, "bool done;");
        emit_line(cg, "if (sl_jd_more(p, '}', &done)) continue;");
        emit_line(cg, "if (!done) return false;");
        emit_line(cg, "break;");
        cg->indent--;
        emit_line(cg, "}");
        cg->indent--;
        emit_line(cg, "}");
        for (int i = 0; i < sd->nfields; i++) {
            const char *ft = sd->ftypes[i];
            if (is_opt(ft)) {
                /* absent: none, like the tree decoder */
                const char *inner_t = opt_inner(ft);
                const char *oname = opt_cname(cg, inner_t);
                const char *otrace = type_is_gc_ptr(cg, inner_t)
                                          ? xasprintf("sl_gc_trace_%s", oname)
                                          : "NULL";
                emit_line(cg, "if (!seen%d) f%d = (%s *)sl_gc_alloc(sizeof(%s), %s);",
                          i, i, oname, oname, otrace);
            } else {
                emit_line(cg, "if (!seen%d) return false;", i);
            }
        }
        emit_line(cg, "%s *s = (%s *)sl_gc_alloc(sizeof(%s), %s);", sname,
                  sname, sname, strace);
        for (int i = 0; i < sd->nfields; i++)
            emit_line(cg, "s->%s = f%d;", sanitize_ident(sd->fields[i]), i);
        emit_line(cg, "*out = s;");
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
        emit_line(cg, "%s *ep = (%s *)sl_arr_at(v, i, sizeof(%s));", ect, ect,
                  ect);
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
    } else if (is_enum(cg, t)) {
        char *m = mangle_enum(t);
        EnumDef *ed = enum_find_canon(cg, t);
        emit_line(cg,
                  "sl_json_enc_str(sl_enum_name((int32_t)v, %s_names, "
                  "%s_values, %d), out);",
                  m, m, ed->nvariants);
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
    emit_runtime_file(cg, "sl_json.c");
}

void emit_json_codecs(CG *cg) {
    if (!cg->want_json || !cg->json.count)
        return;
    for (int i = 0; i < cg->json.count; i++) {
        JsonInst *it = &cg->json.items[i];
        const char *ct = ctype_of(cg, it->slang_type);
        if (it->dec_name) {
            emit_line(cg, "static bool %s(sl_json_val *v, %s *out, char **err);",
                      it->dec_name, ct);
            emit_line(cg, "static bool %s(sl_jparser *p, %s *out);",
                      json_fast_fn(cg, it->slang_type), ct);
        }
        if (it->enc_name)
            emit_line(cg, "static void %s(%s v, sl_json_sb *out);",
                      it->enc_name, ct);
    }
    emit_line(cg, "");
    for (int i = 0; i < cg->json.count; i++) {
        JsonInst *it = &cg->json.items[i];
        if (it->dec_name) {
            emit_json_dec_body(cg, it);
            emit_json_fast_body(cg, it);
        }
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
        /* Bind the argument's VALUE once, via the same sequence_one/
         * ambient-root mechanism gen_call's own arguments use, rather
         * than embedding argexpr's text twice (once as-is, once inside
         * strlen(...) for the str case). A non-trivial argument --
         * json.decode(snake_keys(body)), not a pre-bound local -- is
         * an allocating expression with its OWN nested safepoint
         * bracket; embedding it twice ran that bracket twice, and the
         * FIRST call's result was unrooted (its own bracket had
         * already exited) by the time the SECOND call's bracket did
         * its own safepoint check-in -- a GC landing there could sweep
         * the first result before sl_json_parse below ever read it.
         * Reproduced directly: concurrent load against a route
         * decoding a generic-typed body intermittently answered a
         * validation error, "unexpected character '?' (at byte 0)" --
         * a stale/reused byte where the real first character of a
         * once-valid, already-freed string used to be. */
        StrBuf prelude;
        sb_init(&prelude);
        int ambient_mark = cg->ambient_count;
        int seq_id = cg->tmp_id++;
        char *name = sequence_one(cg, seq_id, 0, ctype_of(cg, at), at,
                                  argexpr, e->as.call.args[0], &prelude);
        char *data, *len;
        if (is_bytes(at)) {
            data = xasprintf("(const char *)(%s)->ptr", name);
            len = xasprintf("(%s)->len", name);
        } else {
            data = xasprintf("(%s)", name);
            len = xasprintf("(long long)strlen(%s)", name);
        }
        /* The direct decoder first. Only when it declines does the input
         * go through the tree, whose decoder then names the error (or, if
         * the direct one was merely stricter, decodes it). The result is
         * allocated last, after the value it holds. */
        char *inner = xasprintf(
            "({ const char *_sl_js = %s; long long _sl_jn = %s; "
            "sl_jparser _sl_jp = { _sl_js, _sl_jn, 0, 0, NULL }; "
            "%s _sl_jout = 0; char *_sl_jerr = NULL; "
            "bool _sl_jok = %s(&_sl_jp, &_sl_jout) && sl_jd_end(&_sl_jp); "
            "if (!_sl_jok) { sl_json_val *_sl_jv = sl_json_parse(_sl_js, "
            "_sl_jn, &_sl_jerr); if (_sl_jv) _sl_jok = %s(_sl_jv, &_sl_jout, "
            "&_sl_jerr); } "
            "%s *_sl_jr = (%s *)sl_gc_alloc(sizeof(%s), %s); "
            "if (_sl_jok) { _sl_jr->ok = true; _sl_jr->v = _sl_jout; } "
            "else { _sl_jr->ok = false; _sl_jr->e = _sl_jerr; } _sl_jr; })",
            data, len, fct, json_fast_fn(cg, tv), decfn, resname, resname,
            resname, restrace);
        /* Tier 10: json.decode allocates (the result[T,E] wrapper,
         * plus whatever the monomorphized decoder itself
         * allocates) -- a real safepoint, same as any other call
         * liveness.c computes e->live_set for. Single argument, no
         * sibling to protect against (the sequence_one binding above
         * is about protecting THIS argument's own value across the
         * call, not about ordering against a second argument). */
        char *result = wrap_safepoint(cg, e, xasprintf("%s *", resname),
                                      prelude.data, inner);
        /* Pop the ambient root sequence_one may have pushed: it must
         * not leak into whatever safepoint-wrapped code gets emitted
         * next, which does not declare (and would not find in scope)
         * this call's own C temp. */
        cg->ambient_count = ambient_mark;
        return result;
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
