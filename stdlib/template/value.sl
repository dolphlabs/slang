// The data a template sees: the caller's value, through json.encode, read
// once into a structural tape (encoding.json_tape, in C). JSON is slang's
// one generic view of a typed value; reading it back here keeps templates
// free of reflection and of any untyped data in the caller's own code.
//
// The tape is five ints per value -- kind, the entry after its subtree,
// its child count, its byte span -- so reading the data allocates per
// document, not per value, and a string is materialised only when a
// template reads it. A Val is a small value struct: a scalar carries its
// text inline, a list or object points into the tape. Printing a list or
// object whole copies its span of the JSON text instead of encoding it
// again.

import "builder";
import "encoding";
import "sort";
import "strings";

let V_NULL = 0;
let V_BOOL = 1;
let V_NUM = 2;
let V_STR = 3;
let V_LIST = 4;
let V_OBJ = 5;
// a string marked as already-safe HTML (the raw function)
let V_SAFE = 6;

// the tape's kinds beyond the value kinds above
let T_KEY = 7;
let T_ESCAPED = 8;   // added to a string's or key's kind when it holds an escape
let STRIDE = 5;

// containers with more children than this get a lookup index, built the
// first time it is needed
let INDEX_AT = 8;

gc struct Doc {
    src: bytes,
    tape: [int],
    // lazy indexes for large containers: entry -> key -> value entry,
    // and entry -> the entries of its items
    obj_index: map[int]map[str]int,
    list_index: map[int][int],
}

struct Val {
    kind: int,
    b: bool,
    text: str,
    // V_LIST and V_OBJ: the tape and the entry
    doc: opt[Doc],
    at: int,
}

fn v_null() -> Val {
    return Val { kind: V_NULL, b: false, text: "", doc: none, at: -1 };
}

fn v_str(s: str) -> Val {
    return Val { kind: V_STR, b: false, text: s, doc: none, at: -1 };
}

fn v_safe(s: str) -> Val {
    return Val { kind: V_SAFE, b: false, text: s, doc: none, at: -1 };
}

fn v_bool(b: bool) -> Val {
    return Val { kind: V_BOOL, b: b, text: "", doc: none, at: -1 };
}

fn v_num(t: str) -> Val {
    return Val { kind: V_NUM, b: false, text: t, doc: none, at: -1 };
}

fn v_int(n: int) -> Val {
    return v_num(to_str(n));
}

// The document json.encode wrote, as a tape; its root value.
fn parse_value_text(s: str) -> result[Val, str] {
    let tr = encoding.json_tape(s);
    guard let tape = tr else let e = err_of(tr) { return err("template: data: " + e); }
    let d = Doc { src: to_bytes(s), tape: tape, obj_index: {}, list_index: {} };
    return ok(val_at(d, 0));
}

// The text of a string or key entry.
fn span_text(d: Doc, e: int) -> str {
    let base = e * STRIDE;
    let from = d.tape[base + 3];
    let to = d.tape[base + 4];
    if d.tape[base] < T_ESCAPED {
        return strings.from_bytes(d.src, from, to);
    }
    // json_tape validated the escapes, so this cannot fail
    let r = read_string(d.src, from - 1);
    guard let st = r else let e2 = err_of(r) { panic("template: " + e2); }
    return st.text;
}

// The value at tape entry e.
fn val_at(d: Doc, e: int) -> Val {
    let base = e * STRIDE;
    let k = d.tape[base];
    if k == V_LIST || k == V_OBJ {
        return Val { kind: k, b: false, text: "", doc: some(d), at: e };
    }
    if k == V_STR || k == V_STR + T_ESCAPED {
        return Val { kind: V_STR, b: false, text: span_text(d, e), doc: none, at: -1 };
    }
    if k == V_NUM {
        return Val { kind: V_NUM, b: false, text: strings.from_bytes(d.src, d.tape[base + 3], d.tape[base + 4]),
                     doc: none, at: -1 };
    }
    if k == V_BOOL {
        return v_bool(d.tape[base + 4] - d.tape[base + 3] == 4);
    }
    return v_null();
}

fn doc_of(v: Val) -> Doc {
    guard let d = v.doc else { panic("template: a list or object without its data"); }
    return d;
}

// The entry after entry e's subtree.
fn next_of(d: Doc, e: int) -> int {
    return d.tape[e * STRIDE + 1];
}

// Items of a list, or fields of an object.
fn count_of(v: Val) -> int {
    if v.kind != V_LIST && v.kind != V_OBJ {
        return 0;
    }
    let d = doc_of(v);
    return d.tape[v.at * STRIDE + 2];
}

// The tape entries of a list's items, in order.
fn list_entries(v: Val) -> [int] {
    let d = doc_of(v);
    if has(d.list_index, v.at) {
        return d.list_index[v.at];
    }
    let n = d.tape[v.at * STRIDE + 2];
    let out: [int] = [];
    let c = v.at + 1;
    for k in 0..n {
        push(out, c);
        c = next_of(d, c);
    }
    if n > INDEX_AT {
        d.list_index[v.at] = out;
    }
    return out;
}

// Item i of a list (0 <= i < count_of(v)).
fn list_at(v: Val, i: int) -> Val {
    let d = doc_of(v);
    if i > INDEX_AT || has(d.list_index, v.at) {
        let es = list_entries(v);
        return val_at(d, es[i]);
    }
    let c = v.at + 1;
    for k in 0..i {
        c = next_of(d, c);
    }
    return val_at(d, c);
}

// Whether key entry e is the key kb, compared in place.
fn key_is(d: Doc, e: int, k: str, kb: bytes) -> bool {
    let base = e * STRIDE;
    if d.tape[base] != T_KEY {
        return span_text(d, e) == k;
    }
    let from = d.tape[base + 3];
    let n = len(kb);
    if d.tape[base + 4] - from != n {
        return false;
    }
    let src = d.src;
    for j in 0..n {
        if src[from + j] != kb[j] {
            return false;
        }
    }
    return true;
}

// Field k of an object; kb is to_bytes(k), which a caller looking the same
// name up again and again (a template's .name) makes once.
fn obj_get(v: Val, k: str, kb: bytes) -> opt[Val] {
    let d = doc_of(v);
    let n = d.tape[v.at * STRIDE + 2];
    if n > INDEX_AT {
        if !has(d.obj_index, v.at) {
            let ix: map[str]int = {};
            let c = v.at + 1;
            for j in 0..n {
                ix[span_text(d, c)] = c + 1;
                c = next_of(d, c + 1);
            }
            d.obj_index[v.at] = ix;
        }
        let ix = d.obj_index[v.at];
        if !has(ix, k) {
            return none;
        }
        return some(val_at(d, ix[k]));
    }
    let c = v.at + 1;
    for j in 0..n {
        if key_is(d, c, k, kb) {
            return some(val_at(d, c + 1));
        }
        c = next_of(d, c + 1);
    }
    return none;
}

// An object's keys, sorted bytewise (range over an object goes in this
// order, so output does not depend on how the data was built).
fn obj_keys(v: Val) -> [str] {
    let d = doc_of(v);
    let n = d.tape[v.at * STRIDE + 2];
    let keys: [str] = [];
    let c = v.at + 1;
    for j in 0..n {
        push(keys, span_text(d, c));
        c = next_of(d, c + 1);
    }
    return sort.strings(keys);
}

fn truthy(v: Val) -> bool {
    if v.kind == V_NULL {
        return false;
    }
    if v.kind == V_BOOL {
        return v.b;
    }
    if v.kind == V_NUM {
        let fr = to_float(v.text);
        guard let f = fr else { return true; }
        return f != 0.0;
    }
    if v.kind == V_STR || v.kind == V_SAFE {
        return v.text != "";
    }
    return count_of(v) > 0;
}

fn hexv(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 87; }
    if c >= 65 && c <= 70 { return c - 55; }
    return -1;
}

struct StrAt {
    text: str,
    next: int,
}

// The JSON string starting at b[i] (a '"'), decoded.
fn read_string(b: bytes, i0: int) -> result[StrAt, str] {
    let n = len(b);
    let i = i0 + 1;
    let start = i;
    // fast path: no escapes
    while i < n && b[i] != 34 && b[i] != 92 {
        i += 1;
    }
    if i < n && b[i] == 34 {
        return ok(StrAt { text: strings.from_bytes(b, start, i), next: i + 1 });
    }
    let out = builder.new_str();
    out.write(strings.from_bytes(b, start, i));
    while i < n {
        let c = b[i];
        if c == 34 {
            return ok(StrAt { text: out.finish(), next: i + 1 });
        }
        if c != 92 {
            let run = i;
            while i < n && b[i] != 34 && b[i] != 92 {
                i += 1;
            }
            out.write(strings.from_bytes(b, run, i));
            continue;
        }
        if i + 1 >= n {
            break;
        }
        let e = b[i + 1];
        i += 2;
        if e == 110 { out.write("\n"); }
        else if e == 116 { out.write("\t"); }
        else if e == 114 { out.write("\r"); }
        else if e == 98 { out.write(to_str(b"\x08")); }
        else if e == 102 { out.write(to_str(b"\x0c")); }
        else if e == 117 {
            if i + 4 > n {
                return err("template: bad \\u escape in data");
            }
            let cp = 0;
            for k in 0..4 {
                let h = hexv(b[i + k]);
                if h < 0 {
                    return err("template: bad \\u escape in data");
                }
                cp = cp * 16 + h;
            }
            i += 4;
            // a surrogate pair
            if cp >= 55296 && cp <= 56319 && i + 6 <= n && b[i] == 92 && b[i + 1] == 117 {
                let lo = 0;
                let okp = true;
                for k in 0..4 {
                    let h = hexv(b[i + 2 + k]);
                    if h < 0 { okp = false; }
                    lo = lo * 16 + h;
                }
                if okp && lo >= 56320 && lo <= 57343 {
                    cp = 65536 + ((cp - 55296) << 10) + (lo - 56320);
                    i += 6;
                }
            }
            if cp >= 55296 && cp <= 57343 {
                // a lone surrogate is not text
                cp = 65533;
            }
            out.write(to_str(utf8_of(cp)));
        } else {
            let one = strings.bytes_zero(1);
            one[0] = e;
            out.write(to_str(one));
        }
    }
    return err("template: unterminated string in data");
}

fn utf8_of(cp: int) -> bytes {
    if cp < 128 {
        let b = strings.bytes_zero(1);
        b[0] = cp;
        return b;
    }
    if cp < 2048 {
        let b = strings.bytes_zero(2);
        b[0] = 192 | (cp >> 6);
        b[1] = 128 | (cp & 63);
        return b;
    }
    if cp < 65536 {
        let b = strings.bytes_zero(3);
        b[0] = 224 | (cp >> 12);
        b[1] = 128 | ((cp >> 6) & 63);
        b[2] = 128 | (cp & 63);
        return b;
    }
    let b = strings.bytes_zero(4);
    b[0] = 240 | (cp >> 18);
    b[1] = 128 | ((cp >> 12) & 63);
    b[2] = 128 | ((cp >> 6) & 63);
    b[3] = 128 | (cp & 63);
    return b;
}

// The value as JSON again (for an object or list printed whole, and for
// the json function and script contexts). A list or object is its span of
// json.encode's text, as written.
fn to_json(v: Val) -> str {
    if v.kind == V_NULL { return "null"; }
    if v.kind == V_BOOL {
        if v.b { return "true"; }
        return "false";
    }
    if v.kind == V_NUM { return v.text; }
    if v.kind == V_STR || v.kind == V_SAFE { return json_quote(v.text); }
    let d = doc_of(v);
    return strings.from_bytes(d.src, d.tape[v.at * STRIDE + 3], d.tape[v.at * STRIDE + 4]);
}

fn json_quote(s: str) -> str {
    let b = to_bytes(s);
    let out = builder.new_str();
    out.write("\"");
    let run = 0;
    for i in 0..len(b) {
        let c = b[i];
        if c == 34 || c == 92 || c < 32 {
            if i > run { out.write(strings.from_bytes(b, run, i)); }
            if c == 34 { out.write("\\\""); }
            else if c == 92 { out.write("\\\\"); }
            else if c == 10 { out.write("\\n"); }
            else if c == 13 { out.write("\\r"); }
            else if c == 9 { out.write("\\t"); }
            else { out.write("\\u00" + hex2(c)); }
            run = i + 1;
        }
    }
    if run < len(b) { out.write(strings.from_bytes(b, run, len(b))); }
    out.write("\"");
    return out.finish();
}

fn hex2(c: int) -> str {
    let h = to_bytes("0123456789abcdef");
    let b = strings.bytes_zero(2);
    b[0] = h[c >> 4];
    b[1] = h[c & 15];
    return to_str(b);
}

// The value as text: strings as they are, numbers as written, true and
// false, null as nothing, lists and objects as JSON.
fn to_text(v: Val) -> str {
    if v.kind == V_STR || v.kind == V_SAFE || v.kind == V_NUM { return v.text; }
    if v.kind == V_NULL { return ""; }
    if v.kind == V_BOOL {
        if v.b { return "true"; }
        return "false";
    }
    return to_json(v);
}
