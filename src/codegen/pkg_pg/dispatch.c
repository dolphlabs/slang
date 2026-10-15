/* pg.rows_as is exposed by the slang pg package; its private intrinsic
 * binds row columns once and emits typed field assignments, like JSON codecs. */
#include "../internal.h"
#include "../../rtpath.h"

#include <stdlib.h>
#include <string.h>

static const char *pg_cell_fn(CG *cg, const char *t, int line) {
    for (int i = 0; i < cg->pg_cells.count; i++)
        if (!strcmp(cg->pg_cells.items[i].type, t)) return cg->pg_cells.items[i].name;
    if (cg->pg_cells.count == cg->pg_cells.cap) {
        cg->pg_cells.cap = cg->pg_cells.cap ? cg->pg_cells.cap * 2 : 8;
        cg->pg_cells.items = xrealloc(cg->pg_cells.items, sizeof(PgCellInst) * (size_t)cg->pg_cells.cap);
    }
    PgCellInst *it = &cg->pg_cells.items[cg->pg_cells.count++];
    it->type = xstrdup(t);
    const char *name = it->name = xasprintf("sl_pgd_%s", sanitize_pkg(t));
    /* Reserve before recursing; JSON owns recursive composite codecs. */
    if (is_opt(t)) pg_cell_fn(cg, opt_inner(t), line);
    json_dec_fn(cg, t, line);
    return name;
}

static PgRowsInst *pg_find(CG *cg, const char *t, const char *rows) {
    for (int i = 0; i < cg->pg_rows.count; i++) {
        PgRowsInst *it = &cg->pg_rows.items[i];
        if (!strcmp(it->type, t) && !strcmp(it->rows_type, rows)) return it;
    }
    return NULL;
}

const char *pg_rows_infer(CG *cg, Expr *e) {
    if (e->as.call.nargs != 1) cg_error(e->line, "pg.rows_as() takes one Rows argument");
    const char *rows = infer_type(cg, e->as.call.args[0]);
    StructDef *rd = struct_find_canon(cg, rows);
    char *pgpath = slang_stdlib_pkg("pg");
    if (!rd || strcmp(rd->name, "Rows") || !rd->file || !pgpath ||
        strncmp(rd->file, pgpath, strlen(pgpath)) || rd->file[strlen(pgpath)] != '/' ||
        strcmp(cg->cur_pkg, rd->pkg))
        cg_error(e->line, "__pg_rows_as is private to the standard pg package; call pg.rows_as(rows)");
    if (!cg->expect || !is_result(cg->expect))
        cg_error(e->line, "cannot infer pg.rows_as()'s target; annotate it, e.g. let users: result[[User], str] = pg.rows_as(rows)");
    char *list, *error;
    result_te(cg->expect, &list, &error);
    if (!is_arr(list) || !is_str(error))
        cg_error(e->line, "pg.rows_as() returns result[[T], str]; use a list of row structs or maps");
    const char *t = arr_elem(list);
    const char *base = t;
    while (is_opt(base)) base = opt_inner(base);
    StructDef *sd = struct_find_canon(cg, base);
    if ((!sd || !strcmp(base, "timez.Time")) && !is_map(base))
        cg_error(e->line, "pg.rows_as() needs a row struct or map[str]V, got %s; declare a struct for the selected columns", t);
    if (is_map(base)) {
        char *k, *v;
        map_kv(base, &k, &v);
        if (!is_str(k)) cg_error(e->line, "pg.rows_as() map keys must be str; use map[str]%s", v);
        pg_cell_fn(cg, v, e->line);
    } else {
        for (int i = 0; i < sd->nfields; i++) pg_cell_fn(cg, sd->ftypes[i], e->line);
    }
    cg->want_json = 1;
    if (!pg_find(cg, t, rows)) {
        if (cg->pg_rows.count == cg->pg_rows.cap) {
            cg->pg_rows.cap = cg->pg_rows.cap ? cg->pg_rows.cap * 2 : 4;
            cg->pg_rows.items = xrealloc(cg->pg_rows.items, sizeof(PgRowsInst) * (size_t)cg->pg_rows.cap);
        }
        PgRowsInst *it = &cg->pg_rows.items[cg->pg_rows.count++];
        it->type = xstrdup(t); it->rows_type = xstrdup(rows);
        it->name = xasprintf("sl_pgr_%s_%s", sanitize_pkg(rows), sanitize_pkg(t));
    }
    return cg->expect;
}

char *pg_rows_gen(CG *cg, Expr *e) {
    pg_rows_infer(cg, e);
    const char *rows = infer_type(cg, e->as.call.args[0]);
    char *list, *error;
    result_te(cg->expect, &list, &error);
    const char *t = arr_elem(list);
    PgRowsInst *it = pg_find(cg, t, rows);
    StrBuf pre;
    sb_init(&pre);
    int mark = cg->ambient_count;
    int id = cg->tmp_id++;
    char *value = gen_expr(cg, e->as.call.args[0]);
    char *arg = sequence_one(cg, id, 0, ctype_of(cg, rows), rows, value, e->as.call.args[0], &pre);
    const char *res = res_cname(cg, list, error);
    const char *base = t;
    while (is_opt(base)) base = opt_inner(base);
    StructDef *sd = struct_find_canon(cg, base);
    const char *frame = sd ? xasprintf("sizeof(%s) * 2 + 2048", mangle_struct(base)) : "2048";
    int depth_bytes = json_decode_stack_bytes(cg, t);
    char *inner = xasprintf(
        "({ sl_pgr_view _sl_pgv = { %s->columns, %s->types, %s->chunks, %s->locs, %s->lens, %s->count, %s->binary_results }; "
        "size_t _sl_pgs = sl_pgr_stack_bytes(&_sl_pgv, %d); "
        "sl_rt_stack_reserve(_sl_pgs > (%s) ? _sl_pgs : (%s)); %s(%s); })",
        arg, arg, arg, arg, arg, arg, arg, depth_bytes, frame, frame, it->name, arg);
    char *out = wrap_safepoint(cg, e, xasprintf("%s *", res), pre.data, inner);
    cg->ambient_count = mark;
    return out;
}

static const char *zero(CG *cg, const char *t) {
    StructDef *sd = struct_find_canon(cg, t);
    return sd && !sd->is_gc ? "{}" : "0";
}

static void emit_cell(CG *cg, PgCellInst *it) {
    const char *t = it->type;
    emit_line(cg, "static bool %s(sl_pgr_cell *cell, %s *out, char **err) {", it->name, ctype_of(cg, t));
    cg->indent++;
    emit_line(cg, "if (cell->kind == SL_PGR_JSON) {"); cg->indent++;
    emit_line(cg, "sl_jparser p = { cell->data, cell->len, 0, 0, NULL };");
    emit_line(cg, "if (%s(&p, out) && sl_jd_end(&p)) return true;", json_fast_dec_fn(cg, t));
    emit_line(cg, "sl_json_val *v = sl_json_parse(cell->data, cell->len, err);");
    emit_line(cg, "return v && %s(v, out, err);", json_dec_fn(cg, t, 0));
    cg->indent--; emit_line(cg, "}");
    if (is_opt(t)) {
        const char *inner = opt_inner(t);
        const char *oname = opt_cname(cg, inner);
        const char *trace = type_has_gc_roots(cg, inner) ? xasprintf("sl_gc_trace_%s", oname) : "NULL";
        emit_line(cg, "%s value = %s;", ctype_of(cg, inner), zero(cg, inner));
        emit_line(cg, "if (cell->kind != SL_PGR_NULL && !%s(cell, &value, err)) return false;", pg_cell_fn(cg, inner, 0));
        emit_line(cg, "%s *o = (%s *)sl_gc_alloc(sizeof(%s), %s);", oname, oname, oname, trace);
        emit_line(cg, "o->has = cell->kind != SL_PGR_NULL; o->v = value; *out = o; return true;");
    } else {
        if (is_int(t)) {
            const char *lo = "INT64_MIN", *hi = "INT64_MAX";
            if (!strcmp(t, "i8")) { lo = "INT8_MIN"; hi = "INT8_MAX"; }
            else if (!strcmp(t, "i16")) { lo = "INT16_MIN"; hi = "INT16_MAX"; }
            else if (!strcmp(t, "i32")) { lo = "INT32_MIN"; hi = "INT32_MAX"; }
            else if (!strcmp(t, "u8")) { lo = "0"; hi = "UINT8_MAX"; }
            else if (!strcmp(t, "u16")) { lo = "0"; hi = "UINT16_MAX"; }
            else if (!strcmp(t, "u32")) { lo = "0"; hi = "UINT32_MAX"; }
            else if (!strcmp(t, "u64")) { lo = "0"; hi = "INT64_MAX"; }
            emit_line(cg, "if (cell->kind == SL_PGR_INT) {"); cg->indent++;
            if (!strcmp(t, "u64"))
                emit_line(cg, "if (cell->integer < 0) { *err = sl_json_errf(\"expected a non-negative integer\"); return false; }");
            else if (strcmp(t, "int") && strcmp(t, "i64") && strcmp(t, "duration"))
                emit_line(cg, "if (cell->integer < %s || cell->integer > %s) { *err = sl_json_errf(\"integer out of range for %s\"); return false; }", lo, hi, t);
            emit_line(cg, "*out = (%s)cell->integer; return true;", ctype_of(cg, t));
            cg->indent--; emit_line(cg, "}");
        } else if (is_flt(t)) {
            emit_line(cg, "if (cell->kind == SL_PGR_INT) { *out = (%s)cell->integer; return true; }", ctype_of(cg, t));
        } else if (is_str(t)) {
            emit_line(cg, "if (cell->kind == SL_PGR_STR) { *out = sl_pgr_text(cell); return true; }");
        } else if (!strcmp(t, "bool")) {
            emit_line(cg, "if (cell->kind == SL_PGR_BOOL) { *out = cell->boolean; return true; }");
        } else if (is_bytes(t)) {
            emit_line(cg, "if (cell->kind == SL_PGR_BYTES) return sl_pgr_bytes(cell, out, err);");
        }
        if (is_int(t) || is_flt(t)) {
            emit_line(cg, "if (cell->kind == SL_PGR_NUM) {"); cg->indent++;
            emit_line(cg, "sl_jparser p = { cell->data, cell->len, 0, 0, NULL };");
            emit_line(cg, "if (%s(&p, out) && sl_jd_end(&p)) return true;", json_fast_dec_fn(cg, t));
            cg->indent--; emit_line(cg, "}");
        }
        emit_line(cg, "sl_json_val scratch = {0}; sl_json_val *value = sl_pgr_value(cell, &scratch, err);");
        emit_line(cg, "if (!value) return false;");
        emit_line(cg, "return %s(value, out, err);", json_dec_fn(cg, t, 0));
    }
    cg->indent--; emit_line(cg, "}"); emit_line(cg, "");
}

static void wrap_row(CG *cg, const char *t, const char *base, const char *value,
                     const char *dest, int depth) {
    if (!is_opt(t)) { emit_line(cg, "%s = %s;", dest, value); return; }
    const char *inner = opt_inner(t);
    char *tmp = xasprintf("wrapped%d", depth);
    emit_line(cg, "%s %s = %s;", ctype_of(cg, inner), tmp, zero(cg, inner));
    wrap_row(cg, inner, base, value, tmp, depth + 1);
    const char *name = opt_cname(cg, inner);
    const char *trace = type_has_gc_roots(cg, inner) ? xasprintf("sl_gc_trace_%s", name) : "NULL";
    emit_line(cg, "%s = (%s *)sl_gc_alloc(sizeof(%s), %s);", dest, name, name, trace);
    emit_line(cg, "%s->has = true; %s->v = %s;", dest, dest, tmp);
}

static void emit_rows(CG *cg, PgRowsInst *it) {
    const char *t = it->type;
    const char *base = t;
    while (is_opt(base)) base = opt_inner(base);
    StructDef *sd = struct_find_canon(cg, base);
    const char *list = xasprintf("[%s]", t);
    const char *res = res_cname(cg, list, "str");
    const char *trace = xasprintf("sl_gc_trace_%s", res);
    const char *ct = ctype_of(cg, t);
    emit_line(cg, "static %s *%s(%s input) {", res, it->name, ctype_of(cg, it->rows_type));
    cg->indent++;
    emit_line(cg, "sl_pgr_view view = { input->columns, input->types, input->chunks, input->locs, input->lens, input->count, input->binary_results };");
    emit_line(cg, "char *err = NULL; long long row = -1; sl_arr *out = NULL;");
    emit_line(cg, "if (!sl_pgr_valid(&view, &err)) goto fail;");
    /* sl_arr_reserve rounds up to a power of two, which must fit both
     * signed element counts and the allocation's size_t byte count. */
    emit_line(cg, "if ((unsigned long long)view.count > (unsigned long long)(SIZE_MAX / (sizeof(%s) ? sizeof(%s) : 1) / 2) || view.count > LLONG_MAX / 2) { err = sl_strdup(\"row output is too large\"); goto fail; }", ct, ct);
    if (sd && sd->nfields) {
        emit_line(cg, "sl_arr *bound = sl_arr_new(sizeof(long long), 0);");
        emit_line(cg, "sl_arr_reserve(bound, %d);", sd->nfields);
        for (int i = 0; i < sd->nfields; i++) {
            emit_line(cg, "{ long long col = -1;"); cg->indent++;
            emit_line(cg, "for (long long c = 0; c < view.columns->len; c++) {"); cg->indent++;
            emit_line(cg, "if (!strcmp(((const char **)view.columns->data)[c], \"%s\")) { col = c; break; }", sd->fields[i]);
            cg->indent--; emit_line(cg, "}");
            emit_line(cg, "sl_arr_push(bound, &col, sizeof(col));");
            cg->indent--; emit_line(cg, "}");
        }
    }
    emit_line(cg, "out = sl_arr_new(sizeof(%s), %d);", ct, elem_trace_flag(cg, t));
    emit_line(cg, "sl_arr_reserve(out, view.count);");
    emit_line(cg, "for (row = 0; row < view.count; row++) {"); cg->indent++;
    if (sd) {
        const char *sname = mangle_struct(base);
        emit_line(cg, "%s fields = {};", sname);
        for (int i = 0; i < sd->nfields; i++) {
            const char *ft = sd->ftypes[i];
            const char *field = sanitize_ident(sd->fields[i]);
            emit_line(cg, "{ long long col = ((long long *)bound->data)[%d]; sl_pgr_cell cell = {0};", i);
            cg->indent++;
            emit_line(cg, "if (col < 0) {"); cg->indent++;
            if (is_opt(ft)) emit_line(cg, "cell.kind = SL_PGR_NULL;");
            else emit_line(cg, "err = sl_json_errf(\"missing required field '%s'\"); goto fail;", sd->fields[i]);
            cg->indent--; emit_line(cg, "} else if (!sl_pgr_read(&view, row, col, &cell, &err)) {"); cg->indent++;
            emit_line(cg, "err = sl_json_wrap_err(\"field '%s'\", err); goto fail;", sd->fields[i]);
            cg->indent--; emit_line(cg, "}");
            emit_line(cg, "if (!%s(&cell, &fields.%s, &err)) { err = sl_json_wrap_err(\"field '%s'\", err); goto fail; }", pg_cell_fn(cg, ft, 0), field, sd->fields[i]);
            cg->indent--; emit_line(cg, "}");
        }
        if (sd->is_gc) {
            const char *strace = struct_has_gc_fields(cg, sd) ? xasprintf("sl_gc_trace_%s", sname) : "NULL";
            emit_line(cg, "%s *value = (%s *)sl_gc_alloc(sizeof(%s), %s); *value = fields;", sname, sname, sname, strace);
        } else emit_line(cg, "%s value = fields;", sname);
    } else {
        char *k, *v;
        map_kv(base, &k, &v);
        emit_line(cg, "sl_map *value = sl_map_new(sizeof(const char *), sizeof(%s), 1, 1, %d);", ctype_of(cg, v), elem_trace_flag(cg, v));
        emit_line(cg, "for (long long col = 0; col < view.columns->len; col++) {"); cg->indent++;
        emit_line(cg, "const char *key = ((const char **)view.columns->data)[col]; sl_pgr_cell cell;");
        emit_line(cg, "%s item = %s;", ctype_of(cg, v), zero(cg, v));
        emit_line(cg, "if (!sl_pgr_read(&view, row, col, &cell, &err) || !%s(&cell, &item, &err)) { err = sl_json_wrap_err(key, err); goto fail; }", pg_cell_fn(cg, v, 0));
        emit_line(cg, "sl_map_put(value, &key, &item);");
        cg->indent--; emit_line(cg, "}");
    }
    emit_line(cg, "%s item = %s;", ct, zero(cg, t));
    wrap_row(cg, t, base, "value", "item", 0);
    emit_line(cg, "sl_arr_push(out, &item, sizeof(item));");
    cg->indent--; emit_line(cg, "}");
    emit_line(cg, "goto done;");
    emit_line(cg, "fail:"); cg->indent++;
    emit_line(cg, "if (row >= 0) {"); cg->indent++;
    emit_line(cg, "char context[32]; sl_rt_preempt_disable(); snprintf(context, sizeof(context), \"row %%lld\", row); sl_rt_preempt_enable();");
    emit_line(cg, "err = sl_json_wrap_err(context, err);");
    cg->indent--; emit_line(cg, "}");
    cg->indent--; emit_line(cg, "done:;");
    emit_line(cg, "%s *answer = (%s *)sl_gc_alloc(sizeof(%s), %s);", res, res, res, trace);
    emit_line(cg, "answer->ok = err == NULL; if (err) answer->e = err; else answer->v = out; return answer;");
    cg->indent--; emit_line(cg, "}"); emit_line(cg, "");
}

void emit_pg_rows_codecs(CG *cg) {
    if (!cg->pg_rows.count) return;
    emit_runtime_file(cg, "sl_pg_rows.c");
    for (int i = 0; i < cg->pg_cells.count; i++) {
        PgCellInst *it = &cg->pg_cells.items[i];
        emit_line(cg, "static bool %s(sl_pgr_cell *, %s *, char **);", it->name, ctype_of(cg, it->type));
    }
    emit_line(cg, "");
    for (int i = 0; i < cg->pg_cells.count; i++) emit_cell(cg, &cg->pg_cells.items[i]);
    for (int i = 0; i < cg->pg_rows.count; i++) emit_rows(cg, &cg->pg_rows.items[i]);
}
