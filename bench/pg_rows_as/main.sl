// Hermetic mapping benchmark: no network or database timing. Run with
// ./slangc bench/pg_rows_as/main.sl -o /tmp/pg-rows && /tmp/pg-rows
// ABBA x4 compares the frozen Zokor JSON adapter at cf958da to pg.rows_as.
// OP=noop|legacy|direct SLANG_GC_STAT=1 /tmp/pg-rows measures allocations
// for 200 decodes of the same 1,000-row fixture; subtract noop totals.
import "builder";
import "encoding";
import "json";
import "pg";
import "proc";
import "time";
struct User { id: int, email: str, name: opt[str], active: bool, created: str }
fn quote(s: str) -> str { return json.encode(s); }
fn quote_into(sb: builder.Str, s: str) { sb.write(json.encode(s)); }

fn json_number_ok(t: str) -> bool {
    return len(t) > 0 && t != "NaN" && t != "Infinity" && t != "-Infinity";
}

fn cell_into(sb: builder.Str, rows: pg.Rows, r: int, c: int) {
    if pg.is_null(rows, r, c) {
        sb.write("null");
        return;
    }
    let oid = rows.types[c];
    // int2, int4, int8, oid
    if oid == 21 || oid == 23 || oid == 20 || oid == 26 {
        sb.write(pg.get_text(rows, r, c));
        return;
    }
    // float4, float8, numeric
    if oid == 700 || oid == 701 || oid == 1700 {
        let t = pg.get_text(rows, r, c);
        if json_number_ok(t) {
            sb.write(t);
        } else {
            quote_into(sb, t);
        }
        return;
    }
    if oid == 16 {
        if pg.get_bool(rows, r, c) {
            sb.write("true");
        } else {
            sb.write("false");
        }
        return;
    }
    // json, jsonb: already JSON
    if oid == 114 || oid == 3802 {
        sb.write(pg.get_text(rows, r, c));
        return;
    }
    if oid == 17 {
        quote_into(sb, encoding.base64_encode(pg.get_bytes(rows, r, c)));
        return;
    }
    // timestamptz, timestamp: RFC 3339, so a timez.Time field reads them
    // (and a str field gets the same text an API would send); infinity
    // and BC dates stay as Postgres wrote them, which a Time refuses
    if oid == 1184 || oid == 1114 {
        let t = pg.get_text(rows, r, c);
        quote_into(sb, pg.timestamp_rfc3339(t, oid == 1184) ?? t);
        return;
    }
    quote_into(sb, pg.get_text(rows, r, c));
}

// Row `r` as a JSON object keyed by column name.
fn row_json(rows: pg.Rows, r: int) -> str {
    let sb = builder.new_str();
    row_into(sb, rows, column_keys(rows), r);
    return sb.finish();
}

// `"name":` per column, quoted once per query, not once per row.
fn column_keys(rows: pg.Rows) -> [str] {
    let keys: [str] = [];
    let c = 0;
    while c < len(rows.columns) {
        let k = quote(rows.columns[c]) + ":";
        if c > 0 {
            k = "," + k;
        }
        push(keys, k);
        c = c + 1;
    }
    return keys;
}

fn row_into(sb: builder.Str, rows: pg.Rows, keys: [str], r: int) {
    sb.write("{");
    let c = 0;
    while c < len(keys) {
        sb.write(keys[c]);
        cell_into(sb, rows, r, c);
        c = c + 1;
    }
    sb.write("}");
}

// Every row as a T, matched by column name.
fn legacy_rows_as[T](rows: pg.Rows) -> result[[T], str] {
    let sb = builder.new_str();
    let keys = column_keys(rows);
    sb.write("[");
    let r = 0;
    while r < rows.count {
        if r > 0 {
            sb.write(",");
        }
        row_into(sb, rows, keys, r);
        r = r + 1;
    }
    sb.write("]");
    let out: result[[T], str] = json.decode(sb.finish());
    guard let list = out else let e = err_of(out) {
        return err("rows do not fit the struct: " + e);
    }
    return ok(list);
}


fn fixture() -> pg.Rows {
    let b = builder.new_bytes();
    let locs: [int] = [];
    let lens: [int] = [];
    let offset = 0;
    let i = 0;
    while i < 1000 {
        let name: opt[str] = none;
        if i % 3 != 0 { name = some("User " + to_str(i)); }
        let fields: [opt[str]] = [some(to_str(i)), some("user" + to_str(i) + "@example.com"),
            name, some("t"), some("2026-10-15 10:20:30+00")];
        for field in fields {
            push(locs, offset);
            if let s = field { let value = to_bytes(s); push(lens, len(value)); b.write(value); offset += len(value); }
            else { push(lens, -1); }
        }
        i += 1;
    }
    return pg.Rows { columns: ["id", "email", "name", "active", "created"],
        types: [23, 25, 25, 16, 1184], binary_results: false,
        count: 1000, affected: 0, tag: "SELECT", chunks: [b.finish()], locs: locs, lens: lens,
        chunk_gen: 0, stream: 0, done: true };
}
fn convert(input: pg.Rows, direct: bool) -> result[[User], str] {
    if direct { return pg.rows_as(input); }
    return legacy_rows_as(input);
}
fn decode(input: pg.Rows, direct: bool) -> [User] {
    let converted = convert(input, direct);
    guard let users = converted else let e = err_of(converted) { panic(e); }
    return users;
}
fn measure(input: pg.Rows, direct: bool) -> int {
    let total = 0;
    let start = time.mono();
    let i = 0;
    while i < 200 {
        let users = decode(input, direct);
        total += users[999].id;
        i += 1;
    }
    assert(total == 199800);
    return ((time.mono() - start) as int) / 200;
}
let input = fixture();
let op = proc.getenv("OP") ?? "abba";
if op == "legacy" || op == "direct" { println(to_str(measure(input, op == "direct"))); }
else if op == "abba" {
    assert(json.encode(decode(input, false)) == json.encode(decode(input, true)));
    for round in [1, 2, 3, 4] {
        println("legacy " + to_str(measure(input, false)));
        println("direct " + to_str(measure(input, true)));
        println("direct " + to_str(measure(input, true)));
        println("legacy " + to_str(measure(input, false)));
    }
}
