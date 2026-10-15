/* Typed pg.Rows views. Emitted only for pg.rows_as, after JSON and encoding.
 * No calls back into slang: partially decoded values live in native locals. */
typedef struct {
    sl_arr *columns, *types, *chunks, *locs, *lens;
    long long count;
    bool binary;
} sl_pgr_view;
typedef enum {
    SL_PGR_NULL, SL_PGR_STR, SL_PGR_NUM, SL_PGR_INT,
    SL_PGR_BOOL, SL_PGR_BYTES, SL_PGR_JSON, SL_PGR_TIME
} sl_pgr_kind;
typedef struct {
    sl_pgr_kind kind;
    const char *data;
    long long len, integer, oid;
    bool boolean, binary;
    char *owned;
} sl_pgr_cell;

static bool sl_pgr_valid(sl_pgr_view *v, char **err) {
    if (!v->columns || !v->types || !v->chunks || !v->locs || !v->lens ||
        v->count < 0 || v->columns->len < 0 || v->chunks->len < 0 || v->locs->len < 0 || v->lens->len < 0 ||
        v->types->len != v->columns->len ||
        (v->columns->len && v->count > LLONG_MAX / v->columns->len)) {
        *err = sl_strdup("invalid Rows metadata"); return false;
    }
    long long n = v->count * v->columns->len;
    if (v->locs->len < n || v->lens->len < n) {
        *err = sl_strdup("Rows cell storage is shorter than count * columns"); return false;
    }
    return true;
}

static bool sl_pgr_read(sl_pgr_view *v, long long row, long long col,
                        sl_pgr_cell *out, char **err) {
    *out = (sl_pgr_cell){0};
    if (col < 0 || col >= v->columns->len || row < 0 || row >= v->count) {
        *err = sl_strdup("Rows cell index is out of range"); return false;
    }
    long long index = row * v->columns->len + col;
    long long n = ((long long *)v->lens->data)[index];
    if (n == -1) { out->kind = SL_PGR_NULL; return true; }
    uint64_t loc = (uint64_t)((long long *)v->locs->data)[index];
    uint64_t chunk_index = loc >> 32;
    long long offset = (long long)(loc & UINT32_MAX);
    if (n < 0 || chunk_index >= (uint64_t)v->chunks->len) {
        *err = sl_strdup("invalid Rows cell location"); return false;
    }
    sl_bytes *chunk = ((sl_bytes **)v->chunks->data)[chunk_index];
    if (!chunk || offset > chunk->len || n > chunk->len - offset) {
        *err = sl_strdup("invalid Rows cell bounds"); return false;
    }
    const unsigned char *data = chunk->ptr + offset;
    long long oid = ((long long *)v->types->data)[col];
    out->data = (const char *)data; out->len = n; out->oid = oid; out->binary = v->binary;
    if (v->binary && (oid == 20 || oid == 21 || oid == 23)) {
        int width = oid == 20 ? 8 : oid == 21 ? 2 : 4;
        if (n != width) { *err = sl_strdup("invalid binary integer width"); return false; }
        uint64_t bits = 0;
        for (int i = 0; i < width; i++) bits = (bits << 8) | data[i];
        if (width < 8 && (data[0] & 128)) bits |= UINT64_MAX << (width * 8);
        int64_t signed_value;
        memcpy(&signed_value, &bits, sizeof(signed_value));
        out->kind = SL_PGR_INT; out->integer = (long long)signed_value; return true;
    }
    if (oid == 16) {
        if (n != 1 || (v->binary ? data[0] > 1 : (data[0] != 't' && data[0] != 'f'))) {
            *err = sl_strdup("invalid boolean cell"); return false;
        }
        out->kind = SL_PGR_BOOL; out->boolean = v->binary ? data[0] == 1 : data[0] == 't'; return true;
    }
    if (oid == 17) { out->kind = SL_PGR_BYTES; return true; }
    if (memchr(data, 0, (size_t)n)) { *err = sl_strdup("NUL in text cell"); return false; }
    out->kind = SL_PGR_STR;
    if (oid == 20 || oid == 21 || oid == 23 || oid == 26 || oid == 700 || oid == 701 || oid == 1700) {
        if (!((n == 3 && !memcmp(data, "NaN", 3)) || (n == 8 && !memcmp(data, "Infinity", 8)) ||
              (n == 9 && !memcmp(data, "-Infinity", 9)))) out->kind = SL_PGR_NUM;
    } else if (oid == 114 || oid == 3802) out->kind = SL_PGR_JSON;
    else if (oid == 1114 || oid == 1184) out->kind = SL_PGR_TIME;
    return true;
}

static char *sl_pgr_text(sl_pgr_cell *cell) {
    if (!cell->owned) {
        char *s = (char *)sl_gc_alloc_leaf_uninit((size_t)cell->len + 1, NULL);
        memcpy(s, cell->data, (size_t)cell->len); s[cell->len] = 0;
        cell->owned = s;
    }
    return cell->owned;
}

static bool sl_pgr_bytes(sl_pgr_cell *cell, sl_bytes **out, char **err) {
    if (cell->binary) { *out = sl_bytes_new((const unsigned char *)cell->data, cell->len); return true; }
    if (cell->len < 2 || cell->data[0] != '\\' || cell->data[1] != 'x' || (cell->len - 2) % 2) {
        *err = sl_strdup("bytea must use the hex format; set bytea_output = 'hex'"); return false;
    }
    long long n = (cell->len - 2) / 2;
    sl_bytes *value = sl_bytes_alloc_uninit(n);
    for (long long i = 0; i < n; i++) {
        int hi = sl_enc_hex_digit((unsigned char)cell->data[2 + 2 * i]);
        int lo = sl_enc_hex_digit((unsigned char)cell->data[3 + 2 * i]);
        if (hi < 0 || lo < 0) { *err = sl_strdup("invalid bytea hex digit"); return false; }
        value->ptr[i] = (unsigned char)((hi << 4) | lo);
    }
    *out = value; return true;
}

/* Match pg.timestamp_rfc3339, including its fallback for infinity/BC and
 * seconds-level offsets. Calendar validity belongs to the Time decoder. */
static char *sl_pgr_timestamp(sl_pgr_cell *cell) {
    long long n = cell->len;
    const char *s = cell->data;
    if (n < 19 || (s[10] != ' ' && s[10] != 'T') || (n >= 3 && !memcmp(s + n - 3, " BC", 3)))
        return sl_pgr_text(cell);
    long long i = 19;
    if (i < n && s[i] == '.') { i++; while (i < n && s[i] >= '0' && s[i] <= '9') i++; }
    int add = 0;
    if (cell->oid == 1114) { if (i != n) return sl_pgr_text(cell); add = 1; }
    else {
        if (i >= n || (s[i] != '+' && s[i] != '-') || (n - i != 3 && n - i != 6)) return sl_pgr_text(cell);
        if (n - i == 3) add = 3;
    }
    char *value = (char *)sl_gc_alloc_leaf_uninit((size_t)n + (size_t)add + 1, NULL);
    memcpy(value, s, (size_t)n); value[10] = 'T';
    if (add == 1) value[n] = 'Z';
    else if (add == 3) memcpy(value + n, ":00", 3);
    value[n + add] = 0;
    cell->owned = value; return value;
}

/* A view for the existing typed JSON codecs, never an encoded row. */
static sl_json_val *sl_pgr_value(sl_pgr_cell *cell, sl_json_val *scratch, char **err) {
    switch (cell->kind) {
    case SL_PGR_NULL: scratch->kind = SL_JV_NULL; return scratch;
    case SL_PGR_BOOL: scratch->kind = SL_JV_BOOL; scratch->as.b = cell->boolean; return scratch;
    case SL_PGR_STR: scratch->kind = SL_JV_STR; scratch->as.str = sl_pgr_text(cell); return scratch;
    case SL_PGR_TIME: scratch->kind = SL_JV_STR; scratch->as.str = sl_pgr_timestamp(cell); return scratch;
    case SL_PGR_NUM: case SL_PGR_JSON: return sl_json_parse(cell->data, cell->len, err);
    case SL_PGR_INT: {
        char text[32];
        sl_rt_preempt_disable();
        int n = snprintf(text, sizeof(text), "%lld", cell->integer);
        sl_rt_preempt_enable();
        return sl_json_parse(text, n, err);
    }
    case SL_PGR_BYTES: {
        sl_bytes *value = NULL;
        if (!sl_pgr_bytes(cell, &value, err)) return NULL;
        scratch->kind = SL_JV_STR; scratch->as.str = sl_encoding_base64_encode(value); return scratch;
    }
    }
    *err = sl_strdup("unknown cell kind"); return NULL;
}

/* Runs at the call site, before native decoding holds any partial output.
 * A recursive JSON column uses the same input-depth stack reservation as
 * json.decode. Ordinary scalar rows do not scan their data for depth. */
static size_t sl_pgr_stack_bytes(sl_pgr_view *view, size_t per_level) {
    char *ignored = NULL;
    if (!per_level || !sl_pgr_valid(view, &ignored)) return 0;
    long long depth = 0;
    for (long long r = 0; r < view->count; r++) {
        for (long long c = 0; c < view->columns->len; c++) {
            long long oid = ((long long *)view->types->data)[c];
            if (oid != 114 && oid != 3802) continue;
            sl_pgr_cell cell;
            if (sl_pgr_read(view, r, c, &cell, &ignored) && cell.kind == SL_PGR_JSON) {
                long long d = sl_json_depth(cell.data, cell.len);
                if (d > SL_JSON_MAX_DEPTH) d = SL_JSON_MAX_DEPTH;
                if (d > depth) depth = d;
            }
        }
    }
    return (size_t)depth * per_level;
}
