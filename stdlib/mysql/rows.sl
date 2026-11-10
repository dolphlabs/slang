// Parameters, results, query/exec/stream, and reading cells.

import "builder";
import "decimal";
import "encoding";
import "math";
import "strings";
import "timez";

// ---- parameters ---------------------------------------------------------------------------

// MySQL column and parameter types (the protocol's MYSQL_TYPE_*).
let T_DECIMAL = 0;
let T_TINY = 1;
let T_SHORT = 2;
let T_LONG = 3;
let T_FLOAT = 4;
let T_DOUBLE = 5;
let T_NULL = 6;
let T_TIMESTAMP = 7;
let T_LONGLONG = 8;
let T_INT24 = 9;
let T_DATE = 10;
let T_TIME = 11;
let T_DATETIME = 12;
let T_YEAR = 13;
let T_VARCHAR = 15;
let T_BIT = 16;
let T_JSON = 245;
let T_NEWDECIMAL = 246;
let T_ENUM = 247;
let T_SET = 248;
let T_TINY_BLOB = 249;
let T_MEDIUM_BLOB = 250;
let T_LONG_BLOB = 251;
let T_BLOB = 252;
let T_VAR_STRING = 253;
let T_STRING = 254;
let T_GEOMETRY = 255;

let FLAG_UNSIGNED = 32;
let CHARSET_BINARY = 63;

// A query parameter: a MySQL type and its binary-protocol bytes.
pub gc struct Arg {
    typ: int,
    is_null: bool,
    data: bytes,
}

pub fn arg_text(s: str) -> Arg {
    return Arg { typ: T_VAR_STRING, is_null: false, data: to_bytes(s) };
}

pub fn arg_int(n: int) -> Arg {
    return Arg { typ: T_LONGLONG, is_null: false, data: put_le(n, 8) };
}

// Sent as an 8-byte double: exactly the value, no decimal text between.
pub fn arg_float(x: float) -> Arg {
    return Arg { typ: T_DOUBLE, is_null: false, data: encoding.float64_to_le(x) };
}

pub fn arg_bool(b: bool) -> Arg {
    let v = 0;
    if b {
        v = 1;
    }
    return Arg { typ: T_TINY, is_null: false, data: put_le(v, 1) };
}

// Any bytes, NULs included, for a BLOB or BINARY column.
pub fn arg_bytes(b: bytes) -> Arg {
    return Arg { typ: T_BLOB, is_null: false, data: b };
}

pub fn arg_null() -> Arg {
    return Arg { typ: T_NULL, is_null: true, data: strings.bytes_zero(0) };
}

// An instant, as UTC "YYYY-MM-DD HH:MM:SS.ffffff": DATETIME has no time
// zone, so the convention (UTC) is the program's to keep -- see the
// time_zone url parameter for TIMESTAMP columns.
pub fn arg_time(t: timez.Time) -> Arg {
    let s = t.rfc3339_nano();
    // 2024-01-02T03:04:05.123456789Z -> 2024-01-02 03:04:05.123456
    let date = strings.slice(s, 0, 10);
    let clock = strings.slice(s, 11, 19);
    let frac = "";
    let dot = strings.find(s, ".");
    if dot >= 0 {
        let z = strings.find(s, "Z");
        frac = strings.slice(s, dot, z);
        if len(frac) > 7 {
            frac = strings.slice(frac, 0, 7);
        }
    }
    return Arg { typ: T_VAR_STRING, is_null: false, data: to_bytes(date + " " + clock + frac) };
}

// A decimal for a DECIMAL column, as its exact text.
pub fn arg_decimal(d: decimal.Decimal) -> Arg {
    return Arg { typ: T_NEWDECIMAL, is_null: false, data: to_bytes(decimal.format(d)) };
}

// ---- results ------------------------------------------------------------------------

// A buffered result. Cells live in a few chunks -- the connection's own
// receive buffers, plus one for values the binary protocol sends as
// numbers -- rather than one object per cell, so a large result costs the
// collector a handful of objects. types are Postgres-style codes (see
// mysql_code), which is what lets rows_as share pg's compiled decoder.
pub gc struct Rows {
    columns: [str],
    types: [int],
    // MySQL's own column types (MYSQL_TYPE_*), with the column flags
    // (bits 8-23) and decimals (bits 24-31) packed above them
    mysql_types: [int],
    binary_results: bool,
    count: int,
    affected: int,
    last_insert_id: int,
    tag: str,
    chunks: [bytes],
    locs: [int],
    lens: [int],
    chunk_gen: int,
    // text written for binary-protocol numbers and dates, and its chunk
    scratch: builder.Bytes,
    scratch_at: int,
    stream: int,
    done: bool,
}

// Every row as a struct or map, bound by exact column name: SQL NULL
// becomes none, an incompatible cell a named error. Compiler-backed (pg's
// decoder), with no JSON in between.
pub fn rows_as[T](rows: Rows) -> result[[T], str] {
    return __pg_rows_as(rows);
}

fn empty_rows() -> Rows {
    return Rows { columns: [], types: [], mysql_types: [], binary_results: false, count: 0, affected: 0,
                  last_insert_id: 0, tag: "", chunks: [], locs: [], lens: [], chunk_gen: -1,
                  scratch: builder.new_bytes(), scratch_at: -1, stream: 0, done: true };
}

// The Postgres-style code for a MySQL column: what rows_as and the
// getters read it as.
fn mysql_code(t: int, flags: int, charset: int, length: int) -> int {
    if t == T_TINY && length == 1 {
        return -16;     // tinyint(1): a bool
    }
    if t == T_TINY || t == T_SHORT || t == T_YEAR {
        return 21;
    }
    if t == T_INT24 || t == T_LONG {
        if (flags & FLAG_UNSIGNED) != 0 {
            return 20;
        }
        return 23;
    }
    if t == T_LONGLONG {
        return 20;
    }
    if t == T_FLOAT {
        return 700;
    }
    if t == T_DOUBLE {
        return 701;
    }
    if t == T_DECIMAL || t == T_NEWDECIMAL {
        return 1700;
    }
    if t == T_DATE {
        return 1082;
    }
    if t == T_DATETIME || t == T_TIMESTAMP {
        return 1114;
    }
    if t == T_JSON {
        return 114;
    }
    if t == T_BIT || t == T_GEOMETRY {
        return -17;
    }
    if charset == CHARSET_BINARY && (t == T_TINY_BLOB || t == T_MEDIUM_BLOB || t == T_LONG_BLOB || t == T_BLOB ||
                                     t == T_VAR_STRING || t == T_STRING || t == T_VARCHAR) {
        return -17;
    }
    return 25;
}

gc struct Column {
    name: str,
    typ: int,
    flags: int,
    decimals: int,
    code: int,
}

// A column definition packet.
fn read_column(c: Conn, deadline: until) -> result[Column, str] {
    let e = next_packet(c, deadline);
    if e != "" {
        return err(e);
    }
    if first_byte(c) == 255 {
        return err(error_text(c));
    }
    let p = cur_payload(c);
    get_lenenc_str(p);  // catalog
    get_lenenc_str(p);  // schema
    get_lenenc_str(p);  // table
    get_lenenc_str(p);  // org_table
    let name = get_lenenc_str(p);
    get_lenenc_str(p);  // org_name
    get_lenenc(p);      // length of the fixed fields
    let charset = get_fixed(p, 2);
    let length = get_fixed(p, 4);
    let t = get_u8(p);
    let flags = get_fixed(p, 2);
    let decimals = get_u8(p);
    if p.bad {
        return err("mysql: protocol error: malformed column definition");
    }
    return ok(Column { name: name, typ: t, flags: flags, decimals: decimals, code: mysql_code(t, flags, charset, length) });
}

// The column definitions of a result (and its EOF, when there is one).
fn read_columns(c: Conn, n: int, rows: Rows, deadline: until) -> result[bool, str] {
    if n > 4096 {
        return err("mysql: protocol error: " + to_str(n) + " columns");
    }
    for k in 0..n {
        let cr = read_column(c, deadline);
        guard let col = cr else let e = err_of(cr) { return err(e); }
        push(rows.columns, col.name);
        push(rows.types, col.code);
        // type, flags and fractional-second digits, packed
        push(rows.mysql_types, col.typ | (col.flags << 8) | (col.decimals << 24));
    }
    if (c.caps & CLIENT_DEPRECATE_EOF) == 0 {
        let e = next_packet(c, deadline);
        if e != "" {
            return err(e);
        }
        if !is_eof(c) {
            return err("mysql: protocol error: no EOF after the column definitions");
        }
    }
    return ok(true);
}

fn note_chunk(rows: Rows, c: Conn) -> int {
    if rows.chunk_gen != c.gen {
        push(rows.chunks, c.buf);
        rows.chunk_gen = c.gen;
    }
    return (len(rows.chunks) - 1) * 4294967296;
}

// A text-protocol row (COM_QUERY): each cell a length-encoded string or
// NULL, recorded where it lies.
fn add_text_row(rows: Rows, c: Conn) -> str {
    let base = note_chunk(rows, c);
    let p = cur_payload(c);
    let n = len(rows.columns);
    for k in 0..n {
        let l = get_lenenc(p);
        if p.bad {
            return "mysql: protocol error: malformed row";
        }
        if l < 0 {
            push(rows.locs, 0);
            push(rows.lens, -1);
            continue;
        }
        if p.i + l > p.end {
            return "mysql: protocol error: malformed row";
        }
        push(rows.locs, base + p.i);
        push(rows.lens, l);
        p.i += l;
    }
    if p.i != p.end {
        return "mysql: protocol error: malformed row";
    }
    rows.count += 1;
    return "";
}

// Text written into the scratch chunk as a cell.
fn scratch_cell(rows: Rows, s: str) {
    if rows.scratch_at < 0 {
        // placed now, filled when the result is complete (finish_rows)
        push(rows.chunks, strings.bytes_zero(0));
        rows.scratch_at = len(rows.chunks) - 1;
        // the next buffer chunk must be pushed anew
        rows.chunk_gen = -1;
    }
    let off = rows.scratch.size();
    rows.scratch.write_str(s);
    push(rows.locs, rows.scratch_at * 4294967296 + off);
    push(rows.lens, len(s));
}

fn finish_rows(rows: Rows) {
    if rows.scratch_at >= 0 {
        rows.chunks[rows.scratch_at] = rows.scratch.finish();
    }
}

// The fractional seconds as the text protocol writes them: exactly the
// column's digits (fsp 1-6), zeros included; none for fsp 0.
fn fraction(us: int, fsp: int) -> str {
    if fsp < 1 || fsp > 6 {
        return "";
    }
    let six = pad_to(us, 6);
    return "." + strings.slice(six, 0, fsp);
}

fn pad2(n: int) -> str {
    if n < 10 {
        return "0" + to_str(n);
    }
    return to_str(n);
}

fn pad_to(n: int, w: int) -> str {
    let s = to_str(n);
    while len(s) < w {
        s = "0" + s;
    }
    return s;
}

// IEEE single precision bits to a float, exactly.
fn float32_of(bits: int) -> float {
    let sign = 1.0;
    if ((bits >> 31) & 1) == 1 {
        sign = -1.0;
    }
    let ex = (bits >> 23) & 255;
    let man = bits & 8388607;
    if ex == 255 {
        if man != 0 {
            return 0.0 / 0.0;
        }
        return sign / 0.0;
    }
    let m = man as float;
    let e = ex - 150;
    if ex == 0 {
        e = -149;
    } else {
        m = m + 8388608.0;
    }
    let v = m;
    while e > 0 {
        v = v * 2.0;
        e -= 1;
    }
    while e < 0 {
        v = v / 2.0;
        e += 1;
    }
    return sign * v;
}

// A binary-protocol row (COM_STMT_EXECUTE): a NULL bitmap, then each
// value in its type's binary form. Strings, decimals and blobs stay in
// the buffer; numbers and dates are written out as the text the text
// protocol would have sent.
fn add_binary_row(rows: Rows, c: Conn) -> str {
    let base = note_chunk(rows, c);
    let p = cur_payload(c);
    let n = len(rows.columns);
    get_u8(p);
    let bm = p.i;
    let nb = (n + 9) / 8;
    if p.i + nb > p.end {
        return "mysql: protocol error: malformed row";
    }
    p.i += nb;
    for k in 0..n {
        let bit = k + 2;
        if (p.b[bm + bit / 8] & (1 << (bit % 8))) != 0 {
            push(rows.locs, 0);
            push(rows.lens, -1);
            continue;
        }
        let mt = rows.mysql_types[k];
        let t = mt & 255;
        let unsigned = ((mt >> 8) & FLAG_UNSIGNED) != 0;
        let fsp = (mt >> 24) & 255;
        if t == T_TINY || t == T_SHORT || t == T_YEAR || t == T_INT24 || t == T_LONG || t == T_LONGLONG {
            let w = 1;
            if t == T_SHORT || t == T_YEAR {
                w = 2;
            } else if t == T_INT24 || t == T_LONG {
                w = 4;
            } else if t == T_LONGLONG {
                w = 8;
            }
            let v = get_fixed(p, w);
            if p.bad {
                return "mysql: protocol error: malformed row";
            }
            if !unsigned && w < 8 && ((v >> (8 * w - 1)) & 1) == 1 {
                v = v - (1 << (8 * w));
            }
            if unsigned && w == 8 && v < 0 {
                // past 2^63: as text, exactly
                let d = decimal.add(decimal.from_int(v & 9223372036854775807),
                                    decimal.parse("9223372036854775808") ?? decimal.zero()) ?? decimal.zero();
                scratch_cell(rows, decimal.format(d));
            } else {
                scratch_cell(rows, to_str(v));
            }
            continue;
        }
        if t == T_DOUBLE {
            let fb = take_bytes(p, 8);
            if p.bad {
                return "mysql: protocol error: malformed row";
            }
            scratch_cell(rows, strings.from_float(encoding.float64_from_le(fb) ?? 0.0));
            continue;
        }
        if t == T_FLOAT {
            let bits = get_fixed(p, 4);
            if p.bad {
                return "mysql: protocol error: malformed row";
            }
            scratch_cell(rows, float32_text(float32_of(bits)));
            continue;
        }
        if t == T_DATE || t == T_DATETIME || t == T_TIMESTAMP {
            let l = get_u8(p);
            let y = 0;
            let mo = 0;
            let d = 0;
            let h = 0;
            let mi = 0;
            let s = 0;
            let us = 0;
            if l >= 4 {
                y = get_fixed(p, 2);
                mo = get_u8(p);
                d = get_u8(p);
            }
            if l >= 7 {
                h = get_u8(p);
                mi = get_u8(p);
                s = get_u8(p);
            }
            if l >= 11 {
                us = get_fixed(p, 4);
            }
            if p.bad || !(l == 0 || l == 4 || l == 7 || l == 11) {
                return "mysql: protocol error: malformed date";
            }
            let text = pad_to(y, 4) + "-" + pad2(mo) + "-" + pad2(d);
            if t != T_DATE {
                text = text + " " + pad2(h) + ":" + pad2(mi) + ":" + pad2(s) + fraction(us, fsp);
            }
            scratch_cell(rows, text);
            continue;
        }
        if t == T_TIME {
            let l = get_u8(p);
            let neg = 0;
            let days = 0;
            let h = 0;
            let mi = 0;
            let s = 0;
            let us = 0;
            if l >= 8 {
                neg = get_u8(p);
                days = get_fixed(p, 4);
                h = get_u8(p);
                mi = get_u8(p);
                s = get_u8(p);
            }
            if l >= 12 {
                us = get_fixed(p, 4);
            }
            if p.bad || !(l == 0 || l == 8 || l == 12) {
                return "mysql: protocol error: malformed time";
            }
            let text = pad2(days * 24 + h) + ":" + pad2(mi) + ":" + pad2(s) + fraction(us, fsp);
            if neg == 1 {
                text = "-" + text;
            }
            scratch_cell(rows, text);
            continue;
        }
        // everything else is a length-encoded string, kept in place
        let l = get_lenenc(p);
        if p.bad || l < 0 || p.i + l > p.end {
            return "mysql: protocol error: malformed row";
        }
        if rows.chunk_gen != c.gen {
            base = note_chunk(rows, c);
        }
        push(rows.locs, base + p.i);
        push(rows.lens, l);
        p.i += l;
    }
    if p.i != p.end {
        return "mysql: protocol error: malformed row";
    }
    rows.count += 1;
    return "";
}

// A FLOAT column read back as text: the shortest %g that is the same
// single-precision value, as MySQL's text protocol writes it.
fn float32_text(x: float) -> str {
    if x != x {
        return "NaN";
    }
    for digits in 1..10 {
        let s = math.format(x, digits);
        if float32_round(to_float(s) ?? 0.0) == x {
            return s;
        }
    }
    return math.format(x, 9);
}

// The nearest single-precision value to x.
fn float32_round(x: float) -> float {
    let b = encoding.float64_to_le(x);
    let bits = le64(b, 0);
    let sign = (bits >> 63) & 1;
    let ex = ((bits >> 52) & 2047) - 1023;
    if x == 0.0 || ex > 127 || ex < -126 {
        return x;
    }
    // keep 24 significant bits, rounding half to even
    let man = (bits & 4503599627370495) | 4503599627370496;
    let drop = 29;
    let keep = man >> drop;
    let rem = man & ((1 << drop) - 1);
    let half = 1 << (drop - 1);
    if rem > half || (rem == half && (keep & 1) == 1) {
        keep += 1;
    }
    let v = keep as float;
    let e = ex - 23;
    while e > 0 {
        v = v * 2.0;
        e -= 1;
    }
    while e < 0 {
        v = v / 2.0;
        e += 1;
    }
    if sign == 1 {
        return -v;
    }
    return v;
}

// ---- prepared statements --------------------------------------------------------------

fn prepare(c: Conn, sql: str, deadline: until) -> result[Stmt, str] {
    if has(c.stmts, sql) {
        let st = c.stmts[sql];
        c.stmt_tick += 1;
        st.used = c.stmt_tick;
        return ok(st);
    }
    c.seq = 0;
    let sr = send_packet(c, cmd_bytes(COM_STMT_PREPARE, to_bytes(sql)), deadline);
    guard let _s = sr else let e = err_of(sr) { return err(fail(c, e)); }
    let e = next_packet(c, deadline);
    if e != "" {
        return err(fail(c, e));
    }
    if first_byte(c) == 255 {
        return err(error_text(c));
    }
    let p = cur_payload(c);
    if get_u8(p) != 0 {
        return err(fail(c, "mysql: protocol error: bad prepare response"));
    }
    let id = get_fixed(p, 4);
    let ncols = get_fixed(p, 2);
    let nparams = get_fixed(p, 2);
    if p.bad {
        return err(fail(c, "mysql: protocol error: bad prepare response"));
    }
    let scratch = empty_rows();
    if nparams > 0 {
        let pr = read_columns(c, nparams, scratch, deadline);
        guard let _p = pr else let e2 = err_of(pr) { return err(fail(c, e2)); }
    }
    let cols = empty_rows();
    if ncols > 0 {
        let cr = read_columns(c, ncols, cols, deadline);
        guard let _c = cr else let e3 = err_of(cr) { return err(fail(c, e3)); }
    }
    c.stmt_tick += 1;
    let st = Stmt { id: id, params: nparams, columns: cols.columns, types: cols.types, raw_types: cols.mysql_types,
                    used: c.stmt_tick };
    if c.cfg.statement_cache > 0 {
        if len(c.stmts) >= c.cfg.statement_cache {
            evict(c, deadline);
        }
        c.stmts[sql] = st;
    }
    return ok(st);
}

// Closes the least recently used statement (COM_STMT_CLOSE has no reply).
fn evict(c: Conn, deadline: until) {
    let oldest = "";
    let at = -1;
    for sql, st in c.stmts {
        if at < 0 || st.used < at {
            at = st.used;
            oldest = sql;
        }
    }
    if at >= 0 {
        close_stmt(c, c.stmts[oldest].id, deadline);
        del(c.stmts, oldest);
    }
}

fn close_stmt(c: Conn, id: int, deadline: until) {
    c.seq = 0;
    send_packet(c, cmd_bytes(COM_STMT_CLOSE, put_le(id, 4)), deadline);
}

fn execute_packet(st: Stmt, args: [Arg]) -> bytes {
    let parts: [bytes] = [b"\x17", put_le(st.id, 4), b"\x00", put_le(1, 4)];
    let n = len(args);
    if n > 0 {
        let bitmap = strings.bytes_zero((n + 7) / 8);
        for k in 0..n {
            if args[k].is_null {
                bitmap[k / 8] = bitmap[k / 8] | (1 << (k % 8));
            }
        }
        push(parts, bitmap);
        push(parts, b"\x01");
        let types = strings.bytes_zero(2 * n);
        for k in 0..n {
            types[2 * k] = args[k].typ;
        }
        push(parts, types);
        for a in args {
            if a.is_null {
                continue;
            }
            if a.typ == T_VAR_STRING || a.typ == T_BLOB || a.typ == T_NEWDECIMAL {
                push(parts, lenenc(len(a.data)));
            }
            push(parts, a.data);
        }
    }
    return cat(parts);
}

// ---- queries ----------------------------------------------------------------------------

// Runs one statement with ? parameters as a prepared statement. A SELECT
// returns its rows; anything else an empty result whose affected and
// last_insert_id say what it did.
pub fn query(c: Conn, sql: str, args: [Arg], deadline: until) -> result[Rows, str] {
    let ur = check_usable(c, deadline);
    guard let _u = ur else let e = err_of(ur) { return err(e); }
    mutex_lock(c.lock);
    let r = query_locked(c, sql, args, deadline, false);
    if is_stale(r) {
        // the table changed under a cached statement: prepare it again
        del(c.stmts, sql);
        r = query_locked(c, sql, args, deadline, false);
    }
    mutex_unlock(c.lock);
    return r;
}

fn is_stale(r: result[Rows, str]) -> bool {
    guard let _rows = r else let e = err_of(r) { return error_code(e) == 1615; }
    return false;
}

fn query_locked(c: Conn, sql: str, args: [Arg], deadline: until, streamed: bool) -> result[Rows, str] {
    let pr = prepare(c, sql, deadline);
    guard let st = pr else let e = err_of(pr) { return err(e); }
    if len(args) != st.params {
        if c.cfg.statement_cache == 0 {
            close_stmt(c, st.id, deadline);
        }
        return err("mysql: the statement takes " + to_str(st.params) + " parameter(s), " + to_str(len(args)) + " given");
    }
    c.seq = 0;
    let sr = send_packet(c, execute_packet(st, args), deadline);
    guard let _s = sr else let e = err_of(sr) { return err(fail(c, e)); }
    let rows = empty_rows();
    rows.binary_results = false;
    let hr = result_head(c, rows, deadline);
    guard let has_rows = hr else let e = err_of(hr) {
        if c.cfg.statement_cache == 0 && !c.broken {
            close_stmt(c, st.id, deadline);
        }
        return err(fail_unless_server(c, e));
    }
    if has_rows && streamed {
        c.mode = 1;
        c.stream_id += 1;
        rows.stream = c.stream_id;
        rows.done = false;
        return ok(rows);
    }
    if has_rows {
        let rr = read_rows(c, rows, true, deadline);
        guard let _r = rr else let e = err_of(rr) { return err(fail_unless_server(c, e)); }
    }
    let dr = drain_more(c, deadline);
    guard let _d = dr else let e = err_of(dr) { return err(fail_unless_server(c, e)); }
    if c.cfg.statement_cache == 0 {
        close_stmt(c, st.id, deadline);
    }
    return ok(rows);
}

// The first packet of a result: OK (no rows: false), an error, or a
// column count and the column definitions (true).
fn result_head(c: Conn, rows: Rows, deadline: until) -> result[bool, str] {
    let e = next_packet(c, deadline);
    if e != "" {
        return err(e);
    }
    let f = first_byte(c);
    if f == 0 {
        take_ok(c);
        rows.affected = c.affected;
        rows.last_insert_id = c.last_insert_id;
        return ok(false);
    }
    if f == 255 {
        return err(error_text(c));
    }
    if f == 251 {
        // LOCAL INFILE: never offered, never served
        return err("mysql: the server asked for a local file (LOAD DATA LOCAL), which this client does not send");
    }
    let p = cur_payload(c);
    let n = get_lenenc(p);
    if p.bad || n <= 0 {
        return err("mysql: protocol error: bad result header");
    }
    let cr = read_columns(c, n, rows, deadline);
    guard let _c = cr else let e2 = err_of(cr) { return err(e2); }
    return ok(true);
}

// Rows up to the end of the result.
fn read_rows(c: Conn, rows: Rows, binary: bool, deadline: until) -> result[bool, str] {
    let size = 0;
    while true {
        let e = next_packet(c, deadline);
        if e != "" {
            return err(e);
        }
        if first_byte(c) == 255 {
            return err(error_text(c));
        }
        if is_end_of_rows(c) {
            take_end_of_rows(c);
            rows.affected = rows.count;
            finish_rows(rows);
            return ok(true);
        }
        size += c.plen;
        if size > MAX_RESULT {
            return err("mysql: a result over " + to_str(MAX_RESULT) + " bytes; use mysql.stream");
        }
        let bad = "";
        if binary {
            bad = add_binary_row(rows, c);
        } else {
            bad = add_text_row(rows, c);
        }
        if bad != "" {
            return err(bad);
        }
    }
    return err("unreachable");
}

// Further results (a stored procedure's), read and dropped.
fn drain_more(c: Conn, deadline: until) -> result[bool, str] {
    while (c.status & STATUS_MORE_RESULTS) != 0 {
        let extra = empty_rows();
        let hr = result_head(c, extra, deadline);
        guard let has_rows = hr else let e = err_of(hr) { return err(e); }
        if has_rows {
            let rr = read_rows(c, extra, true, deadline);
            guard let _r = rr else let e = err_of(rr) { return err(e); }
        }
    }
    return ok(true);
}

// Runs SQL as text, any number of statements separated by semicolons (a
// migration, a schema). Returns the rows the statements changed, all
// together; the rows of any SELECT among them are read and dropped.
pub fn exec(c: Conn, sql: str, deadline: until) -> result[int, str] {
    let ur = check_usable(c, deadline);
    guard let _u = ur else let e = err_of(ur) { return err(e); }
    mutex_lock(c.lock);
    let r = exec_locked(c, sql, deadline);
    mutex_unlock(c.lock);
    return r;
}

fn exec_locked(c: Conn, sql: str, deadline: until) -> result[int, str] {
    c.seq = 0;
    let sr = send_packet(c, cmd_bytes(COM_QUERY, to_bytes(sql)), deadline);
    guard let _s = sr else let e = err_of(sr) { return err(fail(c, e)); }
    let total = 0;
    while true {
        let rows = empty_rows();
        let hr = result_head(c, rows, deadline);
        guard let has_rows = hr else let e = err_of(hr) { return err(fail_unless_server(c, e)); }
        if has_rows {
            let rr = read_rows(c, rows, false, deadline);
            guard let _r = rr else let e = err_of(rr) { return err(fail_unless_server(c, e)); }
        } else {
            total += c.affected;
        }
        if (c.status & STATUS_MORE_RESULTS) == 0 {
            break;
        }
    }
    return ok(total);
}

// ---- streamed results ------------------------------------------------------------------

// Starts a query whose rows are read one at a time with next_row, for
// results too large to hold. The connection is busy until the last row
// has been read or stream_close is called.
pub fn stream(c: Conn, sql: str, args: [Arg], deadline: until) -> result[Rows, str] {
    let ur = check_usable(c, deadline);
    guard let _u = ur else let e = err_of(ur) { return err(e); }
    mutex_lock(c.lock);
    let r = query_locked(c, sql, args, deadline, true);
    mutex_unlock(c.lock);
    return r;
}

fn clear_cells(rows: Rows) {
    while len(rows.locs) > 0 {
        pop(rows.locs);
        pop(rows.lens);
    }
    while len(rows.chunks) > 0 {
        pop(rows.chunks);
    }
    rows.count = 0;
    rows.chunk_gen = -1;
    rows.scratch.reset();
    rows.scratch_at = -1;
}

// Reads the next row of a stream into rows (at index 0): true, or false
// at the end (the connection is free again).
pub fn next_row(c: Conn, rows: Rows, deadline: until) -> result[bool, str] {
    if rows.done {
        return ok(false);
    }
    if c.mode != 1 || rows.stream != c.stream_id || c.broken {
        return err("mysql: this stream is no longer open on the connection");
    }
    mutex_lock(c.lock);
    clear_cells(rows);
    let e = next_packet(c, deadline);
    if e != "" {
        mutex_unlock(c.lock);
        return err(fail(c, e));
    }
    if first_byte(c) == 255 {
        let se = error_text(c);
        c.mode = 0;
        rows.done = true;
        mutex_unlock(c.lock);
        return err(se);
    }
    if is_end_of_rows(c) {
        take_end_of_rows(c);
        let dr = drain_more(c, deadline);
        c.mode = 0;
        rows.done = true;
        mutex_unlock(c.lock);
        guard let _d = dr else let e2 = err_of(dr) { return err(fail_unless_server(c, e2)); }
        return ok(false);
    }
    let bad = add_binary_row(rows, c);
    finish_rows(rows);
    mutex_unlock(c.lock);
    if bad != "" {
        return err(fail(c, bad));
    }
    return ok(true);
}

// Ends a stream early: the remaining rows are read and dropped (MySQL has
// no way to stop a result part way).
pub fn stream_close(c: Conn, rows: Rows, deadline: until) -> result[bool, str] {
    while !rows.done {
        let nr = next_row(c, rows, deadline);
        guard let _n = nr else let e = err_of(nr) { return err(e); }
    }
    return ok(true);
}

// ---- reading cells ----------------------------------------------------------------------

// The index of the column called name; panics if there is none (the
// query and the code reading it disagree).
pub fn col(rows: Rows, name: str) -> int {
    for k in 0..len(rows.columns) {
        if rows.columns[k] == name {
            return k;
        }
    }
    panic("no column named '" + name + "' (columns: " + strings.join(rows.columns, ", ") + ")");
}

fn cell_index(rows: Rows, r: int, c: int) -> int {
    let n = len(rows.columns);
    if r < 0 || r >= rows.count {
        panic("row " + to_str(r) + " out of range (" + to_str(rows.count) + " rows)");
    }
    if c < 0 || c >= n {
        panic("column " + to_str(c) + " out of range (" + to_str(n) + " columns)");
    }
    return r * n + c;
}

pub fn is_null(rows: Rows, r: int, c: int) -> bool {
    return rows.lens[cell_index(rows, r, c)] == -1;
}

fn cell(rows: Rows, r: int, c: int, want: str) -> bytes {
    let ci = cell_index(rows, r, c);
    let n = rows.lens[ci];
    if n == -1 {
        panic("column '" + rows.columns[c] + "' is NULL in row " + to_str(r) + "; check mysql.is_null before mysql.get_" + want);
    }
    let loc = rows.locs[ci];
    let off = loc & 4294967295;
    return rows.chunks[loc >> 32][off..off + n];
}

// Any column as text (a binary column's bytes as they are).
pub fn get_text(rows: Rows, r: int, c: int) -> str {
    let ci = cell_index(rows, r, c);
    let n = rows.lens[ci];
    if n == -1 {
        panic("column '" + rows.columns[c] + "' is NULL in row " + to_str(r) + "; check mysql.is_null before mysql.get_text");
    }
    let loc = rows.locs[ci];
    let off = loc & 4294967295;
    return strings.from_bytes(rows.chunks[loc >> 32], off, off + n);
}

// The integer types, YEAR, BIT up to 64 bits, and a DECIMAL that is a
// whole number.
pub fn get_int(rows: Rows, r: int, c: int) -> int {
    let code = rows.types[c];
    if code == -17 && (rows.mysql_types[c] & 255) == T_BIT {
        let b = cell(rows, r, c, "int");
        let v = 0;
        for k in 0..len(b) {
            v = (v << 8) | b[k];
        }
        return v;
    }
    let t = get_text(rows, r, c);
    let ir = to_int(t);
    guard let v = ir else {
        panic("column '" + rows.columns[c] + "' holds '" + t + "', which mysql.get_int does not read");
    }
    return v;
}

pub fn get_float(rows: Rows, r: int, c: int) -> float {
    let t = get_text(rows, r, c);
    let fr = to_float(t);
    guard let v = fr else {
        panic("column '" + rows.columns[c] + "' holds '" + t + "', which mysql.get_float does not read");
    }
    return v;
}

// BOOL / tinyint(1), and any integer: true when not 0.
pub fn get_bool(rows: Rows, r: int, c: int) -> bool {
    return get_int(rows, r, c) != 0;
}

pub fn get_bytes(rows: Rows, r: int, c: int) -> bytes {
    return cell(rows, r, c, "bytes");
}

// A DATETIME, TIMESTAMP or DATE cell as an instant, read as UTC.
pub fn get_time(rows: Rows, r: int, c: int) -> result[timez.Time, str] {
    let code = rows.types[c];
    if code != 1114 && code != 1082 {
        return err("column " + rows.columns[c] + " is not a date or time");
    }
    let t = get_text(rows, r, c);
    if strings.has_prefix(t, "0000-00-00") {
        return err("column " + rows.columns[c] + ": the zero date is not an instant");
    }
    let iso = t;
    if code == 1082 {
        iso = t + "T00:00:00Z";
    } else {
        iso = strings.replace(t, " ", "T") + "Z";
    }
    return timez.parse_rfc3339(iso);
}

// The exact value of a DECIMAL or integer cell, at the column's scale.
pub fn get_decimal(rows: Rows, r: int, c: int) -> result[decimal.Decimal, str] {
    let code = rows.types[c];
    if code != 1700 && code != 20 && code != 21 && code != 23 {
        return err("column " + rows.columns[c] + " is not numeric");
    }
    let d = decimal.parse(get_text(rows, r, c));
    guard let v = d else let e = err_of(d) { return err("column " + rows.columns[c] + ": " + e); }
    return ok(v);
}
