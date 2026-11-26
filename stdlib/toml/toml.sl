// TOML v1.0.0 (https://toml.io/en/v1.0.0): decode a config file into
// your own types, or convert it to JSON.
//
//     import "toml";
//
//     struct Db { host: str, port: int, replicas: [str], timeout_ms: opt[int] }
//     struct Config { name: str, db: Db }
//
//     let r: result[Config, str] = toml.decode(text);
//     guard let cfg = r else |e| { panic(e); }   // "toml: line 4: ..."
//
//     toml.to_json(text);          // result[str, str]: the same document as JSON
//
// decode goes through to_json and json.decode, so a TOML document decodes
// into whatever JSON does: structs, gc structs, lists, maps, opt (a
// missing key is none), enums. Tables keep their keys in document order.
//
// Values become JSON as follows:
//
//     string, integer, boolean    the same JSON value
//     float                       a JSON number; inf and nan have no JSON
//                                 form and become null, as json.encode
//                                 writes them
//     offset date-time            "1979-05-27T07:32:00Z", "...-07:00": RFC
//                                 3339, so json.decode reads it into a time
//                                 field; a space or lowercase t/z is
//                                 written as T/Z
//     local date-time, date, time "1979-05-27T07:32:00", "1979-05-27",
//                                 "07:32:00.5": strings, as written
//
// The whole of TOML 1.0 is read, and everything it forbids is an error
// that names the line: a key or table defined twice, a table extended
// after it was closed, an integer outside 64 bits, an invalid date, a
// control character in a string, a bare CR, invalid UTF-8. Nesting
// (tables in tables, arrays in arrays) is limited to MAX_DEPTH levels.

import "builder";
import "json";
import "strings";
import "unicode";

// Nesting deeper than this is an error: each level is a frame when the
// document is written out.
let MAX_DEPTH = 256;

// Node kinds.
let K_TABLE = 1;
let K_ARRAY = 2;          // an array value: [1, 2]
let K_TABLES = 3;         // an array of tables: [[name]]
let K_VALUE = 4;          // a string, number, boolean or date-time

// Node flags. A table is EXPLICIT once a [header] has defined it, or once
// the section whose dotted keys made it is over: neither may be defined
// or extended again. FROZEN is an inline table or an array value, and
// everything inside one: complete as written.
let F_EXPLICIT = 1;
let F_FROZEN = 2;

gc struct Parser {
    b: bytes,
    n: int,
    pos: int,
    // nodes, by id; 0 is the document's root table
    kind: [int],
    flag: [int],
    depth: [int],
    // a value's JSON text
    text: [str],
    // where a table's or an array's contents are: an index into
    // tkeys/tindex or into aitems. Only tables and arrays have contents,
    // so a value -- most nodes -- allocates nothing of its own.
    slot: [int],
    // a table's keys in document order, each as its JSON string's
    // content: escaped, without the quotes (the same key always has the
    // same text)
    tkeys: [[str]],
    tindex: [map[str]int],
    // an array's or an array of tables' elements
    aitems: [[int]],
    // tables made by dotted keys since the last header
    pending: [int],
}

// The document as JSON.
pub fn to_json(text: str) -> result[str, str] {
    if !unicode.valid(text) {
        return err("toml: the document is not valid UTF-8");
    }
    let b = to_bytes(text);
    let p = Parser { b: b, n: len(b), pos: 0, kind: [], flag: [], depth: [], text: [], slot: [], tkeys: [],
                     tindex: [], aitems: [], pending: [] };
    new_node(p, K_TABLE, 0);
    let dr = document(p);
    guard let _d = dr else let e = err_of(dr) { return err(e); }
    let out = builder.new_str();
    write_node(p, 0, out);
    return ok(out.finish());
}

// The document decoded into T, as json.decode would decode its JSON.
pub fn decode[T](text: str) -> result[T, str] {
    let jr = to_json(text);
    guard let j = jr else let e = err_of(jr) { return err(e); }
    let r: result[T, str] = json.decode(j);
    guard let v = r else let e = err_of(r) { return err("toml: " + e); }
    return ok(v);
}

// ---------------------------------------------------------------- //
// Nodes                                                              //
// ---------------------------------------------------------------- //

fn new_node(p: Parser, kind: int, depth: int) -> int {
    let id = len(p.kind);
    let slot = -1;
    if kind == K_TABLE {
        slot = len(p.tkeys);
        let ks: [str] = [];
        push(p.tkeys, ks);
        let ix: map[str]int = {};
        push(p.tindex, ix);
    } else if kind == K_ARRAY || kind == K_TABLES {
        slot = len(p.aitems);
        let its: [int] = [];
        push(p.aitems, its);
    }
    push(p.kind, kind);
    push(p.flag, 0);
    push(p.depth, depth);
    push(p.text, "");
    push(p.slot, slot);
    return id;
}

// A new node of `kind` under table t at key k (JSON text).
fn add_child(p: Parser, t: int, k: str, kind: int) -> result[int, str] {
    let d = p.depth[t] + 1;
    if d > MAX_DEPTH {
        return err(fail(p, "nested more than " + to_str(MAX_DEPTH) + " levels deep"));
    }
    let id = new_node(p, kind, d);
    push(p.tkeys[p.slot[t]], k);
    p.tindex[p.slot[t]][k] = id;
    return ok(id);
}

// A new element of `kind` at the end of array a.
fn add_item(p: Parser, a: int, kind: int) -> result[int, str] {
    let d = p.depth[a] + 1;
    if d > MAX_DEPTH {
        return err(fail(p, "nested more than " + to_str(MAX_DEPTH) + " levels deep"));
    }
    let id = new_node(p, kind, d);
    push(p.aitems[p.slot[a]], id);
    return ok(id);
}

// Freeze an inline table or array value and everything in it.
fn freeze(p: Parser, id: int) {
    p.flag[id] = p.flag[id] | F_FROZEN;
    let k = p.kind[id];
    if k == K_TABLE {
        for key in p.tkeys[p.slot[id]] {
            freeze(p, p.tindex[p.slot[id]][key]);
        }
    } else if k == K_ARRAY || k == K_TABLES {
        for it in p.aitems[p.slot[id]] {
            freeze(p, it);
        }
    }
}

// The section is over: tables its dotted keys made are now defined.
fn close_section(p: Parser) {
    for t in p.pending {
        p.flag[t] = p.flag[t] | F_EXPLICIT;
    }
    let none_left: [int] = [];
    p.pending = none_left;
}

fn kind_name(k: int) -> str {
    if k == K_TABLE {
        return "a table";
    }
    if k == K_ARRAY {
        return "an array";
    }
    if k == K_TABLES {
        return "an array of tables";
    }
    return "a value";
}

// ---------------------------------------------------------------- //
// Document                                                           //
// ---------------------------------------------------------------- //

fn document(p: Parser) -> result[bool, str] {
    let cur = 0;
    while true {
        skip_ws(p);
        if p.pos >= p.n {
            break;
        }
        let c = p.b[p.pos];
        if c == 91 {
            let hr = header(p);
            guard let t = hr else let e = err_of(hr) { return err(e); }
            cur = t;
        } else if c != 35 && c != 10 && c != 13 {
            let kr = key_value(p, cur);
            guard let _k = kr else let e = err_of(kr) { return err(e); }
        }
        let er = line_end(p);
        guard let _e = er else let e = err_of(er) { return err(e); }
    }
    return ok(true);
}

// After a header or a key/value pair: spaces, an optional comment, and a
// newline or the end of the document.
fn line_end(p: Parser) -> result[bool, str] {
    skip_ws(p);
    if p.pos < p.n && p.b[p.pos] == 35 {
        let cr = comment(p);
        guard let _c = cr else let e = err_of(cr) { return err(e); }
    }
    if p.pos >= p.n {
        return ok(true);
    }
    let nr = newline(p);
    guard let got = nr else let e = err_of(nr) { return err(e); }
    if !got {
        return err(fail(p, "expected the end of the line, found " + describe(p)));
    }
    return ok(true);
}

// [a.b] or [[a.b]]: the table that later key/value pairs go into.
fn header(p: Parser) -> result[int, str] {
    p.pos += 1;
    let many = p.pos < p.n && p.b[p.pos] == 91;
    if many {
        p.pos += 1;
    }
    let kr = key(p);
    guard let ks = kr else let e = err_of(kr) { return err(e); }
    skip_ws(p);
    if p.pos >= p.n || p.b[p.pos] != 93 {
        return err(fail(p, "expected ] to close the table header"));
    }
    p.pos += 1;
    if many {
        if p.pos >= p.n || p.b[p.pos] != 93 {
            return err(fail(p, "expected ]] to close the array of tables header"));
        }
        p.pos += 1;
    }
    close_section(p);
    let t = 0;
    let last = len(ks) - 1;
    for i in 0..last {
        let k = ks[i];
        if !has(p.tindex[p.slot[t]], k) {
            let cr = add_child(p, t, k, K_TABLE);
            guard let c = cr else let e = err_of(cr) { return err(e); }
            t = c;
            continue;
        }
        let c = p.tindex[p.slot[t]][k];
        let kind = p.kind[c];
        if kind == K_TABLES {
            let its = p.aitems[p.slot[c]];
            t = its[len(its) - 1];
        } else if kind == K_TABLE {
            t = c;
        } else {
            return err(fail(p, "key \"" + k + "\" is already " + kind_name(kind)));
        }
        if (p.flag[t] & F_FROZEN) != 0 {
            return err(fail(p, "table \"" + k + "\" was written inline and cannot be extended"));
        }
    }
    let k = ks[last];
    if many {
        if !has(p.tindex[p.slot[t]], k) {
            let ar = add_child(p, t, k, K_TABLES);
            guard let a = ar else let e = err_of(ar) { return err(e); }
            return add_item(p, a, K_TABLE);
        }
        let a = p.tindex[p.slot[t]][k];
        if p.kind[a] != K_TABLES || (p.flag[a] & F_FROZEN) != 0 {
            return err(fail(p, "key \"" + k + "\" is already " + kind_name(p.kind[a]) + ", not an array of tables"));
        }
        return add_item(p, a, K_TABLE);
    }
    if !has(p.tindex[p.slot[t]], k) {
        let nr = add_child(p, t, k, K_TABLE);
        guard let nt = nr else let e = err_of(nr) { return err(e); }
        p.flag[nt] = p.flag[nt] | F_EXPLICIT;
        return ok(nt);
    }
    let c = p.tindex[p.slot[t]][k];
    if p.kind[c] != K_TABLE {
        return err(fail(p, "key \"" + k + "\" is already " + kind_name(p.kind[c])));
    }
    if (p.flag[c] & (F_EXPLICIT | F_FROZEN)) != 0 {
        return err(fail(p, "table \"" + k + "\" is defined more than once"));
    }
    p.flag[c] = p.flag[c] | F_EXPLICIT;
    return ok(c);
}

// key = value, into table t: the document's current table, or an inline
// table's own.
fn key_value(p: Parser, t: int) -> result[bool, str] {
    let kr = key(p);
    guard let ks = kr else let e = err_of(kr) { return err(e); }
    skip_ws(p);
    if p.pos >= p.n || p.b[p.pos] != 61 {
        return err(fail(p, "expected = after the key, found " + describe(p)));
    }
    p.pos += 1;
    skip_ws(p);
    let last = len(ks) - 1;
    for i in 0..last {
        let k = ks[i];
        if !has(p.tindex[p.slot[t]], k) {
            let cr = add_child(p, t, k, K_TABLE);
            guard let c = cr else let e = err_of(cr) { return err(e); }
            push(p.pending, c);
            t = c;
            continue;
        }
        let c = p.tindex[p.slot[t]][k];
        if p.kind[c] != K_TABLE {
            return err(fail(p, "key \"" + k + "\" is already " + kind_name(p.kind[c])));
        }
        if (p.flag[c] & F_FROZEN) != 0 {
            return err(fail(p, "table \"" + k + "\" was written inline and cannot be extended"));
        }
        if (p.flag[c] & F_EXPLICIT) != 0 {
            return err(fail(p, "table \"" + k + "\" is defined elsewhere and cannot be extended with dotted keys"));
        }
        t = c;
    }
    let k = ks[last];
    if has(p.tindex[p.slot[t]], k) {
        return err(fail(p, "key \"" + k + "\" is defined more than once"));
    }
    if (p.flag[t] & F_FROZEN) != 0 {
        return err(fail(p, "an inline table cannot be extended"));
    }
    return value_at(p, t, k);
}

// ---------------------------------------------------------------- //
// Keys                                                               //
// ---------------------------------------------------------------- //

// A dotted key: each part as its JSON string's content (no quotes).
fn key(p: Parser) -> result[[str], str] {
    let out: [str] = [];
    while true {
        skip_ws(p);
        if p.pos >= p.n {
            return err(fail(p, "expected a key"));
        }
        let c = p.b[p.pos];
        if c == 34 {
            if p.pos + 2 < p.n && p.b[p.pos + 1] == 34 && p.b[p.pos + 2] == 34 {
                return err(fail(p, "a key cannot be a multi-line string"));
            }
            let sr = basic_string(p);
            guard let s = sr else let e = err_of(sr) { return err(e); }
            push(out, strings.slice(s, 1, len(s) - 1));
        } else if c == 39 {
            if p.pos + 2 < p.n && p.b[p.pos + 1] == 39 && p.b[p.pos + 2] == 39 {
                return err(fail(p, "a key cannot be a multi-line string"));
            }
            let sr = literal_string(p);
            guard let s = sr else let e = err_of(sr) { return err(e); }
            push(out, strings.slice(s, 1, len(s) - 1));
        } else {
            let start = p.pos;
            while p.pos < p.n && is_bare(p.b[p.pos]) {
                p.pos += 1;
            }
            if p.pos == start {
                return err(fail(p, "expected a key, found " + describe(p)));
            }
            push(out, strings.from_bytes(p.b, start, p.pos));
        }
        skip_ws(p);
        if p.pos < p.n && p.b[p.pos] == 46 {
            p.pos += 1;
            continue;
        }
        break;
    }
    return ok(out);
}

fn is_bare(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45;
}

// ---------------------------------------------------------------- //
// Values                                                             //
// ---------------------------------------------------------------- //

// The value at p.pos, as table t's key k.
fn value_at(p: Parser, t: int, k: str) -> result[bool, str] {
    if p.pos >= p.n {
        return err(fail(p, "expected a value"));
    }
    let c = p.b[p.pos];
    if c == 91 {
        let ar = add_child(p, t, k, K_ARRAY);
        guard let a = ar else let e = err_of(ar) { return err(e); }
        return array(p, a);
    }
    if c == 123 {
        let tr = add_child(p, t, k, K_TABLE);
        guard let it = tr else let e = err_of(tr) { return err(e); }
        return inline_table(p, it);
    }
    let sr = scalar(p);
    guard let s = sr else let e = err_of(sr) { return err(e); }
    let vr = add_child(p, t, k, K_VALUE);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    p.text[v] = s;
    return ok(true);
}

// The value at p.pos, appended to array a.
fn value_in(p: Parser, a: int) -> result[bool, str] {
    if p.pos >= p.n {
        return err(fail(p, "expected a value"));
    }
    let c = p.b[p.pos];
    if c == 91 {
        let ar = add_item(p, a, K_ARRAY);
        guard let na = ar else let e = err_of(ar) { return err(e); }
        return array(p, na);
    }
    if c == 123 {
        let tr = add_item(p, a, K_TABLE);
        guard let it = tr else let e = err_of(tr) { return err(e); }
        return inline_table(p, it);
    }
    let sr = scalar(p);
    guard let s = sr else let e = err_of(sr) { return err(e); }
    let vr = add_item(p, a, K_VALUE);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    p.text[v] = s;
    return ok(true);
}

// [ v, v, ... ]: newlines and comments allowed between, a trailing comma
// allowed.
fn array(p: Parser, a: int) -> result[bool, str] {
    p.pos += 1;
    while true {
        let wr = skip_blank(p);
        guard let _w = wr else let e = err_of(wr) { return err(e); }
        if p.pos >= p.n {
            return err(fail(p, "an array that is never closed"));
        }
        if p.b[p.pos] == 93 {
            break;
        }
        let vr = value_in(p, a);
        guard let _v = vr else let e = err_of(vr) { return err(e); }
        let wr2 = skip_blank(p);
        guard let _w2 = wr2 else let e = err_of(wr2) { return err(e); }
        if p.pos < p.n && p.b[p.pos] == 44 {
            p.pos += 1;
            continue;
        }
        if p.pos < p.n && p.b[p.pos] == 93 {
            break;
        }
        return err(fail(p, "expected , or ] in an array, found " + describe(p)));
    }
    p.pos += 1;
    freeze(p, a);
    return ok(true);
}

// { k = v, k = v }: one line, no trailing comma.
fn inline_table(p: Parser, t: int) -> result[bool, str] {
    p.pos += 1;
    skip_ws(p);
    if p.pos < p.n && p.b[p.pos] == 125 {
        p.pos += 1;
        freeze(p, t);
        return ok(true);
    }
    while true {
        let kr = key_value(p, t);
        guard let _k = kr else let e = err_of(kr) { return err(e); }
        skip_ws(p);
        if p.pos >= p.n {
            return err(fail(p, "an inline table that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 44 {
            p.pos += 1;
            skip_ws(p);
            if p.pos < p.n && p.b[p.pos] == 125 {
                return err(fail(p, "a trailing comma in an inline table"));
            }
            continue;
        }
        if c == 125 {
            break;
        }
        return err(fail(p, "expected , or } in an inline table, found " + describe(p)));
    }
    p.pos += 1;
    freeze(p, t);
    return ok(true);
}

// A string, number, boolean or date-time at p.pos, as JSON text.
fn scalar(p: Parser) -> result[str, str] {
    let c = p.b[p.pos];
    if c == 34 {
        if p.pos + 2 < p.n && p.b[p.pos + 1] == 34 && p.b[p.pos + 2] == 34 {
            return ml_basic_string(p);
        }
        return basic_string(p);
    }
    if c == 39 {
        if p.pos + 2 < p.n && p.b[p.pos + 1] == 39 && p.b[p.pos + 2] == 39 {
            return ml_literal_string(p);
        }
        return literal_string(p);
    }
    if c == 116 && word(p, "true") {
        return ok("true");
    }
    if c == 102 && word(p, "false") {
        return ok("false");
    }
    if is_digit(c) && p.pos + 4 < p.n && all_digits(p.b, p.pos, p.pos + 4) && p.b[p.pos + 4] == 45 {
        return date_time(p);
    }
    if is_digit(c) && p.pos + 2 < p.n && is_digit(p.b[p.pos + 1]) && p.b[p.pos + 2] == 58 {
        return local_time(p);
    }
    if is_digit(c) || c == 43 || c == 45 || c == 105 || c == 110 {
        return number(p);
    }
    return err(fail(p, "expected a value, found " + describe(p)));
}

// The keyword w at p.pos, ending there; consumed if so.
fn word(p: Parser, w: str) -> bool {
    let wb = to_bytes(w);
    let m = len(wb);
    if p.pos + m > p.n {
        return false;
    }
    for i in 0..m {
        if p.b[p.pos + i] != wb[i] {
            return false;
        }
    }
    if p.pos + m < p.n && is_bare(p.b[p.pos + m]) {
        return false;
    }
    p.pos += m;
    return true;
}

// ---------------------------------------------------------------- //
// Strings: each read straight into JSON text                         //
// ---------------------------------------------------------------- //

// "...": escapes, no newlines.
fn basic_string(p: Parser) -> result[str, str] {
    // Most strings have nothing to escape: then the source, quotes and
    // all, is already the JSON, and one slice is the whole cost.
    let q = p.pos + 1;
    while q < p.n {
        let c = p.b[q];
        if c == 34 || c == 92 || c < 32 || c == 127 {
            break;
        }
        q += 1;
    }
    if q < p.n && p.b[q] == 34 {
        let s = strings.from_bytes(p.b, p.pos, q + 1);
        p.pos = q + 1;
        return ok(s);
    }
    p.pos += 1;
    let out = builder.new_str();
    out.write("\"");
    let run = p.pos;
    while true {
        if p.pos >= p.n {
            return err(fail(p, "a string that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 34 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            p.pos += 1;
            break;
        }
        if c == 92 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            let er = escape(p, out);
            guard let _e = er else let e = err_of(er) { return err(e); }
            run = p.pos;
            continue;
        }
        if c == 10 || c == 13 {
            return err(fail(p, "a newline in a single-line string"));
        }
        if c < 32 && c != 9 || c == 127 {
            return err(fail(p, "a control character in a string (escape it)"));
        }
        if c == 9 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            out.write("\\t");
            p.pos += 1;
            run = p.pos;
            continue;
        }
        p.pos += 1;
    }
    out.write("\"");
    return ok(out.finish());
}

// """...""": escapes and newlines; a newline right after the opening
// quotes is dropped, and a backslash at the end of a line drops the
// newline and the whitespace after it.
fn ml_basic_string(p: Parser) -> result[str, str] {
    p.pos += 3;
    let nr = newline(p);
    guard let _n = nr else let e = err_of(nr) { return err(e); }
    let out = builder.new_str();
    out.write("\"");
    let run = p.pos;
    while true {
        if p.pos >= p.n {
            return err(fail(p, "a multi-line string that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 34 && p.pos + 2 < p.n && p.b[p.pos + 1] == 34 && p.b[p.pos + 2] == 34 {
            let q = quote_run(p.b, p.pos, 34);
            if q > 5 {
                return err(fail(p, "too many quotes closing a multi-line string"));
            }
            out.write(strings.from_bytes(p.b, run, p.pos));
            for _i in 0..(q - 3) {
                out.write("\\\"");
            }
            p.pos += q;
            break;
        }
        if c == 34 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            out.write("\\\"");
            p.pos += 1;
            run = p.pos;
            continue;
        }
        if c == 92 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            let lr = line_ending_backslash(p);
            guard let skipped = lr else let e = err_of(lr) { return err(e); }
            if !skipped {
                let er = escape(p, out);
                guard let _e = er else let e = err_of(er) { return err(e); }
            }
            run = p.pos;
            continue;
        }
        if c == 10 || c == 13 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            let nlr = newline(p);
            guard let _nl = nlr else let e = err_of(nlr) { return err(e); }
            out.write("\\n");
            run = p.pos;
            continue;
        }
        if c < 32 && c != 9 || c == 127 {
            return err(fail(p, "a control character in a string (escape it)"));
        }
        if c == 9 {
            out.write(strings.from_bytes(p.b, run, p.pos));
            out.write("\\t");
            p.pos += 1;
            run = p.pos;
            continue;
        }
        p.pos += 1;
    }
    out.write("\"");
    return ok(out.finish());
}

// A backslash followed by whitespace to the end of the line: skip it,
// the newline, and all whitespace and newlines after. False (nothing
// consumed) if the backslash is an escape instead.
fn line_ending_backslash(p: Parser) -> result[bool, str] {
    let i = p.pos + 1;
    while i < p.n && (p.b[i] == 32 || p.b[i] == 9) {
        i += 1;
    }
    if i >= p.n || (p.b[i] != 10 && p.b[i] != 13) {
        return ok(false);
    }
    p.pos = i;
    while p.pos < p.n {
        let c = p.b[p.pos];
        if c == 32 || c == 9 {
            p.pos += 1;
        } else if c == 10 || c == 13 {
            let nr = newline(p);
            guard let _n = nr else let e = err_of(nr) { return err(e); }
        } else {
            break;
        }
    }
    return ok(true);
}

// One escape sequence at p.pos (the backslash), written to out as JSON.
fn escape(p: Parser, out: builder.Str) -> result[bool, str] {
    if p.pos + 1 >= p.n {
        return err(fail(p, "a string that is never closed"));
    }
    let c = p.b[p.pos + 1];
    p.pos += 2;
    if c == 98 {
        out.write("\\b");
    } else if c == 116 {
        out.write("\\t");
    } else if c == 110 {
        out.write("\\n");
    } else if c == 102 {
        out.write("\\f");
    } else if c == 114 {
        out.write("\\r");
    } else if c == 34 {
        out.write("\\\"");
    } else if c == 92 {
        out.write("\\\\");
    } else if c == 117 || c == 85 {
        let digits = 4;
        if c == 85 {
            digits = 8;
        }
        if p.pos + digits > p.n {
            return err(fail(p, "a \\u escape needs " + to_str(digits) + " hex digits"));
        }
        let cp = 0;
        for i in 0..digits {
            let h = hex_val(p.b[p.pos + i]);
            if h < 0 {
                return err(fail(p, "a \\u escape needs " + to_str(digits) + " hex digits"));
            }
            cp = cp * 16 + h;
        }
        p.pos += digits;
        if cp > 1114111 || (cp >= 55296 && cp <= 57343) {
            return err(fail(p, "\\u escape of " + to_str(cp) + ", which is not a Unicode scalar value"));
        }
        write_code_point(out, cp);
    } else {
        p.pos -= 1;
        return err(fail(p, "an unknown escape in a string"));
    }
    return ok(true);
}

// A code point as JSON: escaped if JSON needs it, UTF-8 otherwise.
fn write_code_point(out: builder.Str, cp: int) {
    if cp == 34 {
        out.write("\\\"");
    } else if cp == 92 {
        out.write("\\\\");
    } else if cp == 8 {
        out.write("\\b");
    } else if cp == 9 {
        out.write("\\t");
    } else if cp == 10 {
        out.write("\\n");
    } else if cp == 12 {
        out.write("\\f");
    } else if cp == 13 {
        out.write("\\r");
    } else if cp < 32 {
        out.write("\\u00");
        out.write(hex_digit(cp / 16));
        out.write(hex_digit(cp % 16));
    } else {
        out.write(unicode.encode(cp) ?? "");
    }
}

fn hex_digit(d: int) -> str {
    let digits = "0123456789abcdef";
    return strings.slice(digits, d, d + 1);
}

// '...': no escapes, no newlines.
fn literal_string(p: Parser) -> result[str, str] {
    p.pos += 1;
    let start = p.pos;
    while true {
        if p.pos >= p.n {
            return err(fail(p, "a string that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 39 {
            break;
        }
        if c == 10 || c == 13 {
            return err(fail(p, "a newline in a single-line string"));
        }
        if c < 32 && c != 9 || c == 127 {
            return err(fail(p, "a control character in a literal string"));
        }
        p.pos += 1;
    }
    let s = raw_json(p.b, start, p.pos);
    p.pos += 1;
    return ok(s);
}

// '''...''': no escapes; newlines kept (a newline right after the opening
// quotes is dropped).
fn ml_literal_string(p: Parser) -> result[str, str] {
    p.pos += 3;
    let nr = newline(p);
    guard let _n = nr else let e = err_of(nr) { return err(e); }
    let out = builder.new_str();
    out.write("\"");
    while true {
        if p.pos >= p.n {
            return err(fail(p, "a multi-line string that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 39 && p.pos + 2 < p.n && p.b[p.pos + 1] == 39 && p.b[p.pos + 2] == 39 {
            let q = quote_run(p.b, p.pos, 39);
            if q > 5 {
                return err(fail(p, "too many quotes closing a multi-line string"));
            }
            for _i in 0..(q - 3) {
                out.write("'");
            }
            p.pos += q;
            break;
        }
        if c == 39 {
            out.write("'");
            p.pos += 1;
            continue;
        }
        if c == 10 || c == 13 {
            let nlr = newline(p);
            guard let _nl = nlr else let e = err_of(nlr) { return err(e); }
            out.write("\\n");
            continue;
        }
        if c < 32 && c != 9 || c == 127 {
            return err(fail(p, "a control character in a literal string"));
        }
        let start = p.pos;
        while p.pos < p.n {
            let d = p.b[p.pos];
            if d == 39 || d == 10 || d == 13 || (d < 32 && d != 9) || d == 127 {
                break;
            }
            p.pos += 1;
        }
        let piece = raw_json(p.b, start, p.pos);
        out.write(strings.slice(piece, 1, len(piece) - 1));
    }
    out.write("\"");
    return ok(out.finish());
}

// b[from..to] (no control characters but tab) as a JSON string.
fn raw_json(b: bytes, from: int, to: int) -> str {
    let out = builder.new_str();
    out.write("\"");
    let run = from;
    for i in from..to {
        let c = b[i];
        if c == 34 || c == 92 || c == 9 {
            out.write(strings.from_bytes(b, run, i));
            if c == 34 {
                out.write("\\\"");
            } else if c == 92 {
                out.write("\\\\");
            } else {
                out.write("\\t");
            }
            run = i + 1;
        }
    }
    out.write(strings.from_bytes(b, run, to));
    out.write("\"");
    return out.finish();
}

// How many of byte q in a row from b[at].
fn quote_run(b: bytes, at: int, q: int) -> int {
    let i = at;
    while i < len(b) && b[i] == q {
        i += 1;
    }
    return i - at;
}

// ---------------------------------------------------------------- //
// Numbers                                                            //
// ---------------------------------------------------------------- //

fn number(p: Parser) -> result[str, str] {
    let start = p.pos;
    while p.pos < p.n && is_number_byte(p.b[p.pos]) {
        p.pos += 1;
    }
    // The common case, a plain decimal integer (digits, maybe a minus,
    // no leading zero, short enough to fit 64 bits): its text is the JSON.
    let plain_end = start;
    if plain_end < p.pos && p.b[plain_end] == 45 {
        plain_end += 1;
    }
    let first_digit = plain_end;
    while plain_end < p.pos && is_digit(p.b[plain_end]) {
        plain_end += 1;
    }
    let nd = plain_end - first_digit;
    if plain_end == p.pos && nd > 0 && nd <= 18 && (p.b[first_digit] != 48 || (nd == 1 && first_digit == start)) {
        return ok(strings.from_bytes(p.b, start, p.pos));
    }
    let tok = strings.from_bytes(p.b, start, p.pos);
    let tb = to_bytes(tok);
    let m = len(tb);
    let body = 0;
    if m > 0 && (tb[0] == 43 || tb[0] == 45) {
        body = 1;
    }
    let rest = strings.slice(tok, body, m);
    if rest == "inf" || rest == "nan" {
        return ok("null");
    }
    if m - body >= 2 && tb[body] == 48 && (tb[body + 1] == 120 || tb[body + 1] == 111 || tb[body + 1] == 98) {
        if body == 1 {
            p.pos = start;
            return err(fail(p, "a hex, octal or binary integer cannot have a sign"));
        }
        let base = 16;
        if tb[1] == 111 {
            base = 8;
        } else if tb[1] == 98 {
            base = 2;
        }
        return radix_int(p, start, tb, base);
    }
    // decimal: int part, then an optional fraction and exponent
    let i = body;
    let ir = digit_run(tb, i, false);
    if ir < 0 {
        p.pos = start;
        return err(fail(p, "an invalid number " + tok));
    }
    if ir - i > 1 && tb[i] == 48 {
        p.pos = start;
        return err(fail(p, "a number with a leading zero " + tok));
    }
    i = ir;
    let is_float = false;
    if i < m && tb[i] == 46 {
        let fr = digit_run(tb, i + 1, false);
        if fr < 0 {
            p.pos = start;
            return err(fail(p, "a float needs digits after the point " + tok));
        }
        i = fr;
        is_float = true;
    }
    if i < m && (tb[i] == 101 || tb[i] == 69) {
        let j = i + 1;
        if j < m && (tb[j] == 43 || tb[j] == 45) {
            j += 1;
        }
        let er = digit_run(tb, j, true);
        if er < 0 {
            p.pos = start;
            return err(fail(p, "a float needs digits in its exponent " + tok));
        }
        i = er;
        is_float = true;
    }
    if i != m {
        p.pos = start;
        return err(fail(p, "an invalid number " + tok));
    }
    let plain = strings.replace(tok, "_", "");
    if body == 1 && tb[0] == 43 {
        plain = strings.slice(plain, 1, len(plain));
    }
    if is_float {
        let fr2 = to_float(plain);
        guard let f = fr2 else { p.pos = start; return err(fail(p, "an invalid float " + tok)); }
        return ok(to_str(f));
    }
    let nr = to_int(plain);
    guard let v = nr else { p.pos = start; return err(fail(p, "an integer outside 64 bits " + tok)); }
    return ok(to_str(v));
}

// A run of digits from tb[i], underscores only between two digits: the
// index after it, or -1 if there is none or an underscore is misplaced.
fn digit_run(tb: bytes, i: int, any: bool) -> int {
    let m = len(tb);
    let start = i;
    while i < m {
        let c = tb[i];
        if is_digit(c) {
            i += 1;
        } else if c == 95 && i > start && i + 1 < m && is_digit(tb[i - 1]) && is_digit(tb[i + 1]) {
            i += 1;
        } else {
            break;
        }
    }
    if i == start {
        return -1;
    }
    return i;
}

// 0x, 0o or 0b: digits of the base, underscores between them; at most
// 2^63 - 1.
fn radix_int(p: Parser, start: int, tb: bytes, base: int) -> result[str, str] {
    let m = len(tb);
    let v = 0;
    let seen = 0;
    let limit = 9223372036854775807;
    for i in 2..m {
        let c = tb[i];
        if c == 95 {
            if i == 2 || i + 1 >= m || tb[i - 1] == 95 || tb[i + 1] == 95 {
                p.pos = start;
                return err(fail(p, "a misplaced underscore in an integer"));
            }
            continue;
        }
        let d = hex_val(c);
        if d < 0 || d >= base {
            p.pos = start;
            return err(fail(p, "an invalid digit in a base " + to_str(base) + " integer"));
        }
        if v > (limit - d) / base {
            p.pos = start;
            return err(fail(p, "an integer outside 64 bits"));
        }
        v = v * base + d;
        seen += 1;
    }
    if seen == 0 {
        p.pos = start;
        return err(fail(p, "an integer with no digits"));
    }
    return ok(to_str(v));
}

fn is_number_byte(c: int) -> bool {
    return is_digit(c) || (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c == 43 || c == 45 || c == 46;
}

// ---------------------------------------------------------------- //
// Dates and times                                                    //
// ---------------------------------------------------------------- //

// YYYY-MM-DD, and then optionally a time and an offset.
fn date_time(p: Parser) -> result[str, str] {
    let start = p.pos;
    if p.pos + 10 > p.n || !all_digits(p.b, p.pos + 5, p.pos + 7) || p.b[p.pos + 7] != 45 ||
       !all_digits(p.b, p.pos + 8, p.pos + 10) {
        return err(fail(p, "an invalid date"));
    }
    let y = digits_val(p.b, p.pos, p.pos + 4);
    let mo = digits_val(p.b, p.pos + 5, p.pos + 7);
    let d = digits_val(p.b, p.pos + 8, p.pos + 10);
    if mo < 1 || mo > 12 || d < 1 || d > days_in(y, mo) {
        return err(fail(p, "an invalid date " + strings.from_bytes(p.b, start, start + 10)));
    }
    p.pos += 10;
    let out = strings.from_bytes(p.b, start, p.pos);
    // a time follows a T, or a space when a time is there
    let sep = 0;
    if p.pos < p.n {
        sep = p.b[p.pos];
    }
    let has_time = sep == 84 || sep == 116 ||
                   (sep == 32 && p.pos + 3 < p.n && is_digit(p.b[p.pos + 1]) && is_digit(p.b[p.pos + 2]) &&
                    p.b[p.pos + 3] == 58);
    if !has_time {
        return ok("\"" + out + "\"");
    }
    p.pos += 1;
    let tr = time_part(p);
    guard let t = tr else let e = err_of(tr) { return err(e); }
    out = out + "T" + t;
    if p.pos < p.n && (p.b[p.pos] == 90 || p.b[p.pos] == 122) {
        p.pos += 1;
        return ok("\"" + out + "Z\"");
    }
    if p.pos < p.n && (p.b[p.pos] == 43 || p.b[p.pos] == 45) {
        let o = p.pos;
        if o + 6 > p.n || !all_digits(p.b, o + 1, o + 3) || p.b[o + 3] != 58 || !all_digits(p.b, o + 4, o + 6) {
            return err(fail(p, "an invalid time offset"));
        }
        if digits_val(p.b, o + 1, o + 3) > 23 || digits_val(p.b, o + 4, o + 6) > 59 {
            return err(fail(p, "an invalid time offset"));
        }
        p.pos = o + 6;
        return ok("\"" + out + strings.from_bytes(p.b, o, o + 6) + "\"");
    }
    return ok("\"" + out + "\"");
}

fn local_time(p: Parser) -> result[str, str] {
    let tr = time_part(p);
    guard let t = tr else let e = err_of(tr) { return err(e); }
    return ok("\"" + t + "\"");
}

// HH:MM:SS with an optional fraction.
fn time_part(p: Parser) -> result[str, str] {
    let s = p.pos;
    if s + 8 > p.n || !all_digits(p.b, s, s + 2) || p.b[s + 2] != 58 || !all_digits(p.b, s + 3, s + 5) ||
       p.b[s + 5] != 58 || !all_digits(p.b, s + 6, s + 8) {
        return err(fail(p, "an invalid time (HH:MM:SS)"));
    }
    if digits_val(p.b, s, s + 2) > 23 || digits_val(p.b, s + 3, s + 5) > 59 || digits_val(p.b, s + 6, s + 8) > 59 {
        return err(fail(p, "an invalid time " + strings.from_bytes(p.b, s, s + 8)));
    }
    p.pos = s + 8;
    if p.pos < p.n && p.b[p.pos] == 46 {
        let f = p.pos + 1;
        let e = f;
        while e < p.n && is_digit(p.b[e]) {
            e += 1;
        }
        if e == f {
            return err(fail(p, "a time fraction needs digits after the point"));
        }
        p.pos = e;
    }
    return ok(strings.from_bytes(p.b, s, p.pos));
}

fn days_in(y: int, m: int) -> int {
    if m == 2 {
        if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
            return 29;
        }
        return 28;
    }
    if m == 4 || m == 6 || m == 9 || m == 11 {
        return 30;
    }
    return 31;
}

fn all_digits(b: bytes, from: int, to: int) -> bool {
    if to > len(b) {
        return false;
    }
    for i in from..to {
        if !is_digit(b[i]) {
            return false;
        }
    }
    return true;
}

fn digits_val(b: bytes, from: int, to: int) -> int {
    let v = 0;
    for i in from..to {
        v = v * 10 + (b[i] - 48);
    }
    return v;
}

// ---------------------------------------------------------------- //
// Whitespace, comments, newlines                                     //
// ---------------------------------------------------------------- //

fn skip_ws(p: Parser) {
    while p.pos < p.n && (p.b[p.pos] == 32 || p.b[p.pos] == 9) {
        p.pos += 1;
    }
}

// Inside an array: whitespace, newlines and comments.
fn skip_blank(p: Parser) -> result[bool, str] {
    while p.pos < p.n {
        let c = p.b[p.pos];
        if c == 32 || c == 9 {
            p.pos += 1;
        } else if c == 10 || c == 13 {
            let nr = newline(p);
            guard let _n = nr else let e = err_of(nr) { return err(e); }
        } else if c == 35 {
            let cr = comment(p);
            guard let _c = cr else let e = err_of(cr) { return err(e); }
        } else {
            break;
        }
    }
    return ok(true);
}

// # to the end of the line (not the newline itself).
fn comment(p: Parser) -> result[bool, str] {
    p.pos += 1;
    while p.pos < p.n {
        let c = p.b[p.pos];
        if c == 10 || (c == 13 && p.pos + 1 < p.n && p.b[p.pos + 1] == 10) {
            break;
        }
        if c < 32 && c != 9 || c == 127 {
            return err(fail(p, "a control character in a comment"));
        }
        p.pos += 1;
    }
    return ok(true);
}

// LF or CRLF at p.pos: true and consumed; false if neither. A CR without
// an LF is an error.
fn newline(p: Parser) -> result[bool, str] {
    if p.pos >= p.n {
        return ok(false);
    }
    let c = p.b[p.pos];
    if c == 10 {
        p.pos += 1;
        return ok(true);
    }
    if c == 13 {
        if p.pos + 1 < p.n && p.b[p.pos + 1] == 10 {
            p.pos += 2;
            return ok(true);
        }
        return err(fail(p, "a carriage return without a line feed"));
    }
    return ok(false);
}

// ---------------------------------------------------------------- //
// Output and errors                                                  //
// ---------------------------------------------------------------- //

fn write_node(p: Parser, id: int, out: builder.Str) {
    let k = p.kind[id];
    if k == K_VALUE {
        out.write(p.text[id]);
        return;
    }
    if k == K_TABLE {
        out.write("{");
        let first = true;
        for key in p.tkeys[p.slot[id]] {
            if !first {
                out.write(",");
            }
            first = false;
            out.write("\"");
            out.write(key);
            out.write("\":");
            write_node(p, p.tindex[p.slot[id]][key], out);
        }
        out.write("}");
        return;
    }
    out.write("[");
    let first = true;
    for it in p.aitems[p.slot[id]] {
        if !first {
            out.write(",");
        }
        first = false;
        write_node(p, it, out);
    }
    out.write("]");
}

// An error at p.pos, with its line.
fn fail(p: Parser, msg: str) -> str {
    let line = 1;
    let to = p.pos;
    if to > p.n {
        to = p.n;
    }
    for i in 0..to {
        if p.b[i] == 10 {
            line += 1;
        }
    }
    return "toml: line " + to_str(line) + ": " + msg;
}

// The byte at p.pos, for an error message.
fn describe(p: Parser) -> str {
    if p.pos >= p.n {
        return "the end of the document";
    }
    let c = p.b[p.pos];
    if c == 10 || c == 13 {
        return "a newline";
    }
    if c < 32 || c == 127 {
        return "a control character";
    }
    if c >= 128 {
        return "a non-ASCII character";
    }
    return "'" + strings.from_bytes(p.b, p.pos, p.pos + 1) + "'";
}

fn is_digit(c: int) -> bool {
    return c >= 48 && c <= 57;
}

fn hex_val(c: int) -> int {
    if c >= 48 && c <= 57 {
        return c - 48;
    }
    if c >= 97 && c <= 102 {
        return c - 87;
    }
    if c >= 65 && c <= 70 {
        return c - 55;
    }
    return -1;
}
