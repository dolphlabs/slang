// CBOR (RFC 8949): the binary data format of COSE, WebAuthn, CWT and many
// IoT protocols.
//
//     import "cbor";
//
//     let w = cbor.writer();
//     cbor.write_map(w, 1);
//     cbor.write_text(w, "temp");
//     cbor.write_float(w, 21.5);       // the shortest exact float: f16 here
//     let data = cbor.finish(w);
//
//     let v = cbor.decode(data);       // a Value tree, or read with a Reader
//
// Writing follows the preferred serialization: shortest heads, and a
// float in the smallest of half, single or double precision that holds
// it exactly. Reading accepts every well-formed form, indefinite lengths
// included, checks text is UTF-8, checks every length against the bytes
// left before allocating, and limits nesting to MAX_DEPTH.

import "builder";
import "math";

pub let MAX_DEPTH = 512;

pub let M_UINT = 0;
pub let M_NEG = 1;
pub let M_BYTES = 2;
pub let M_TEXT = 3;
pub let M_ARRAY = 4;
pub let M_MAP = 5;
pub let M_TAG = 6;
pub let M_SIMPLE = 7;   // false, true, null, undefined, floats, break

// ---- writing ---------------------------------------------------------------

pub gc struct Writer {
    b: builder.Bytes,
}

pub fn writer() -> Writer {
    return Writer { b: builder.new_bytes() };
}

pub fn finish(w: Writer) -> bytes {
    return w.b.take();
}

// The head of a data item: a major type and an argument, shortest form.
fn head(w: Writer, major: int, arg: u64) {
    let m = major << 5;
    if arg < (24 as u64) {
        w.b.write_byte(m | (arg as int));
    } else if arg < (256 as u64) {
        w.b.write_byte(m | 24);
        w.b.write_byte(arg as int);
    } else if arg < (65536 as u64) {
        w.b.write_byte(m | 25);
        be(w, arg, 2);
    } else if arg < (4294967296 as u64) {
        w.b.write_byte(m | 26);
        be(w, arg, 4);
    } else {
        w.b.write_byte(m | 27);
        be(w, arg, 8);
    }
}

fn be(w: Writer, v: u64, n: int) {
    let shift = (n - 1) * 8;
    while shift >= 0 {
        w.b.write_byte(((v >> shift) & (255 as u64)) as int);
        shift = shift - 8;
    }
}

pub fn write_uint(w: Writer, v: u64) { head(w, M_UINT, v); }

pub fn write_int(w: Writer, v: int) {
    if v >= 0 {
        head(w, M_UINT, v as u64);
    } else {
        // -1 - v, computed without overflow at the int minimum
        head(w, M_NEG, (-(v + 1)) as u64);
    }
}

pub fn write_bytes(w: Writer, b: bytes) {
    head(w, M_BYTES, len(b) as u64);
    w.b.write(b);
}

pub fn write_text(w: Writer, s: str) {
    let b = to_bytes(s);
    head(w, M_TEXT, len(b) as u64);
    w.b.write(b);
}

pub fn write_array(w: Writer, n: int) { head(w, M_ARRAY, n as u64); }
pub fn write_map(w: Writer, n: int) { head(w, M_MAP, n as u64); }

// A tag on the next item (1: epoch time, 2/3: bignums, 32: URI, ...).
pub fn write_tag(w: Writer, tag: u64) { head(w, M_TAG, tag); }

pub fn write_bool(w: Writer, v: bool) {
    if v { w.b.write_byte(0xf5); } else { w.b.write_byte(0xf4); }
}

pub fn write_null(w: Writer) { w.b.write_byte(0xf6); }
pub fn write_undefined(w: Writer) { w.b.write_byte(0xf7); }

// The smallest of half, single and double precision that holds v exactly.
pub fn write_float(w: Writer, v: float) {
    let h = to_half(v);
    if h >= 0 {
        w.b.write_byte(0xf9);
        be(w, h as u64, 2);
        return;
    }
    let f = v as f32;
    if (f as float) == v || v != v {
        w.b.write_byte(0xfa);
        be(w, math.f32_bits(f) as u64, 4);
        return;
    }
    w.b.write_byte(0xfb);
    be(w, math.float_bits(v), 8);
}

// v as IEEE half-precision bits if that is exact (NaN as the canonical
// 0x7e00), else -1.
fn to_half(v: float) -> int {
    if v != v { return 0x7e00; }
    let bits = math.float_bits(v);
    let sign = ((bits >> 63) as int) << 15;
    if v == 0.0 { return sign; }
    let inf = 1.0 / 0.0;
    if v == inf || v == -inf { return sign | 0x7c00; }
    let a = v;
    if a < 0.0 { a = -a; }
    // normal halves: 2^-14 .. 65504, 11 significant bits
    if a >= 0.00006103515625 && a <= 65504.0 {
        let e = math.frexp_exponent(a) - 1;           // a = m * 2^e, 1 <= m < 2
        let m = math.ldexp(a, -e) - 1.0;               // fraction in [0, 1)
        let frac = math.ldexp(m, 10);
        if frac != math.floor(frac) { return -1; }
        return sign | ((e + 15) << 10) | (frac as int);
    }
    // subnormal halves: multiples of 2^-24 below 2^-14
    if a < 0.00006103515625 {
        let q = math.ldexp(a, 24);
        if q != math.floor(q) || q < 1.0 { return -1; }
        return sign | (q as int);
    }
    return -1;
}

fn from_half(h: int) -> float {
    let sign = 1.0;
    if (h & 0x8000) != 0 { sign = -1.0; }
    let e = (h >> 10) & 0x1f;
    let f = h & 0x3ff;
    if e == 0 { return sign * math.ldexp(f as float, -24); }
    if e == 31 {
        if f == 0 { return sign / 0.0; }
        return 0.0 / 0.0;
    }
    return sign * math.ldexp((f + 1024) as float, e - 25);
}

// ---- reading ---------------------------------------------------------------

pub gc struct Reader {
    b: bytes,
    at: int,
}

pub fn reader(b: bytes) -> Reader {
    return Reader { b: b, at: 0 };
}

pub fn remaining(r: Reader) -> int { return len(r.b) - r.at; }

// The major type of the next item, -1 at the end of the input.
pub fn peek_major(r: Reader) -> int {
    if r.at >= len(r.b) { return -1; }
    return (r.b[r.at] as int) >> 5;
}

// Whether the next byte is the break that ends an indefinite-length item.
pub fn at_break(r: Reader) -> bool {
    return r.at < len(r.b) && (r.b[r.at] as int) == 0xff;
}

pub fn read_break(r: Reader) -> result[bool, str] {
    if !at_break(r) { return err(want(r, "break")); }
    r.at = r.at + 1;
    return ok(true);
}

// A head of the given major type: its argument, or -1 for an indefinite
// length (ai 31) where allowed.
struct Head {
    arg: u64,
    indefinite: bool,
}

fn read_head(r: Reader, major: int, what: str) -> result[Head, str] {
    if r.at >= len(r.b) { return err(want(r, what)); }
    let c = r.b[r.at] as int;
    if (c >> 5) != major { return err(want(r, what)); }
    let ai = c & 0x1f;
    if ai < 24 {
        r.at = r.at + 1;
        return ok(Head { arg: ai as u64, indefinite: false });
    }
    if ai == 31 {
        if major == M_UINT || major == M_NEG || major == M_TAG {
            return err("cbor: indefinite length on a " + what);
        }
        r.at = r.at + 1;
        return ok(Head { arg: 0 as u64, indefinite: true });
    }
    if ai > 27 { return err("cbor: reserved additional information " + to_str(ai)); }
    let n = 1 << (ai - 24);
    if r.at + 1 + n > len(r.b) { return err("cbor: truncated " + what); }
    let v: u64 = 0;
    for i in 0..n {
        v = (v << 8) | ((r.b[r.at + 1 + i] as int) as u64);
    }
    r.at = r.at + 1 + n;
    return ok(Head { arg: v, indefinite: false });
}

pub fn read_uint(r: Reader) -> result[u64, str] {
    let hr = read_head(r, M_UINT, "unsigned int");
    guard let h = hr else let e = err_of(hr) { return err(e); }
    return ok(h.arg);
}

// An unsigned or negative integer that fits int.
pub fn read_int(r: Reader) -> result[int, str] {
    let m = peek_major(r);
    if m != M_UINT && m != M_NEG { return err(want(r, "int")); }
    let save = r.at;
    let hr = read_head(r, m, "int");
    guard let h = hr else let e = err_of(hr) { return err(e); }
    if h.arg > (9223372036854775807 as u64) {
        r.at = save;
        return err("cbor: integer beyond int's range");
    }
    if m == M_UINT { return ok(h.arg as int); }
    return ok(-1 - (h.arg as int));
}

pub fn read_bytes(r: Reader) -> result[bytes, str] {
    return read_string(r, M_BYTES, "byte string");
}

pub fn read_text(r: Reader) -> result[str, str] {
    let br = read_string(r, M_TEXT, "text string");
    guard let b = br else let e = err_of(br) { return err(e); }
    if !utf8_ok(b) { return err("cbor: text string is not UTF-8"); }
    return ok(to_str(b));
}

// A definite string, or an indefinite one's chunks joined.
fn read_string(r: Reader, major: int, what: str) -> result[bytes, str] {
    let hr = read_head(r, major, what);
    guard let h = hr else let e = err_of(hr) { return err(e); }
    if !h.indefinite {
        if h.arg > ((len(r.b) - r.at) as u64) { return err("cbor: " + what + " longer than the input"); }
        let n = h.arg as int;
        let out = r.b[r.at..r.at + n];
        r.at = r.at + n;
        return ok(out);
    }
    let acc = builder.new_bytes();
    while !at_break(r) {
        if peek_major(r) != major { return err("cbor: bad chunk in an indefinite " + what); }
        let cr = read_head(r, major, what);
        guard let c = cr else let ce = err_of(cr) { return err(ce); }
        if c.indefinite { return err("cbor: nested indefinite " + what); }
        if c.arg > ((len(r.b) - r.at) as u64) { return err("cbor: " + what + " longer than the input"); }
        let n = c.arg as int;
        acc.write(r.b[r.at..r.at + n]);
        r.at = r.at + n;
    }
    r.at = r.at + 1;
    return ok(acc.finish());
}

// An array header: its count, or -1 for an indefinite array (read items
// until at_break, then read_break).
pub fn read_array(r: Reader) -> result[int, str] {
    return read_count(r, M_ARRAY, "array", 1);
}

// A map header: its pair count, or -1 for an indefinite map.
pub fn read_map(r: Reader) -> result[int, str] {
    return read_count(r, M_MAP, "map", 2);
}

fn read_count(r: Reader, major: int, what: str, min_each: int) -> result[int, str] {
    let hr = read_head(r, major, what);
    guard let h = hr else let e = err_of(hr) { return err(e); }
    if h.indefinite { return ok(-1); }
    let left = (len(r.b) - r.at) as u64;
    if h.arg > left || h.arg * (min_each as u64) > left {
        return err("cbor: " + what + " of " + to_str(h.arg) + " is longer than the input");
    }
    return ok(h.arg as int);
}

pub fn read_tag(r: Reader) -> result[u64, str] {
    let hr = read_head(r, M_TAG, "tag");
    guard let h = hr else let e = err_of(hr) { return err(e); }
    return ok(h.arg);
}

pub fn read_bool(r: Reader) -> result[bool, str] {
    if r.at < len(r.b) {
        let c = r.b[r.at] as int;
        if c == 0xf4 || c == 0xf5 { r.at = r.at + 1; return ok(c == 0xf5); }
    }
    return err(want(r, "bool"));
}

// null or undefined.
pub fn read_null(r: Reader) -> result[bool, str] {
    if r.at < len(r.b) {
        let c = r.b[r.at] as int;
        if c == 0xf6 || c == 0xf7 { r.at = r.at + 1; return ok(true); }
    }
    return err(want(r, "null"));
}

// A half, single or double float; an integer is read as its float too.
pub fn read_float(r: Reader) -> result[float, str] {
    if r.at >= len(r.b) { return err(want(r, "float")); }
    let c = r.b[r.at] as int;
    let n = 0;
    if c == 0xf9 { n = 2; } else if c == 0xfa { n = 4; } else if c == 0xfb { n = 8; }
    else {
        let ir = read_int(r);
        guard let v = ir else { return err(want(r, "float")); }
        return ok(v as float);
    }
    if r.at + 1 + n > len(r.b) { return err("cbor: truncated float"); }
    let v: u64 = 0;
    for i in 0..n { v = (v << 8) | ((r.b[r.at + 1 + i] as int) as u64); }
    r.at = r.at + 1 + n;
    if n == 2 { return ok(from_half(v as int)); }
    if n == 4 { return ok(math.f32_from_bits(v as u32) as float); }
    return ok(math.float_from_bits(v));
}

pub fn skip(r: Reader) -> result[bool, str] {
    let vr = read_value(r, 0);
    guard let _v = vr else let e = err_of(vr) { return err(e); }
    return ok(true);
}

fn want(r: Reader, what: str) -> str {
    if r.at >= len(r.b) { return "cbor: expected " + what + ", found the end of the input"; }
    return "cbor: expected " + what + " at byte " + to_str(r.at);
}

fn utf8_ok(b: bytes) -> bool {
    let i = 0;
    let n = len(b);
    while i < n {
        let c = b[i] as int;
        if c < 0x80 { i = i + 1; continue; }
        let need = 0;
        let min = 0;
        if c >= 0xc2 && c <= 0xdf { need = 1; min = 0x80; }
        else if c >= 0xe0 && c <= 0xef { need = 2; min = 0x800; }
        else if c >= 0xf0 && c <= 0xf4 { need = 3; min = 0x10000; }
        else { return false; }
        if i + need >= n { return false; }
        let cp = c & (0x7f >> (need + 1));
        for k in 1..need + 1 {
            if i + k >= n { return false; }
            let d = b[i + k] as int;
            if (d & 0xc0) != 0x80 { return false; }
            cp = (cp << 6) | (d & 0x3f);
        }
        if cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) { return false; }
        i = i + need + 1;
    }
    return true;
}

// ---- dynamic values --------------------------------------------------------

pub let K_UINT = 0;
pub let K_NEG = 1;      // n is -1 - u (beyond int's range: read u)
pub let K_BYTES = 2;
pub let K_TEXT = 3;
pub let K_ARRAY = 4;
pub let K_MAP = 5;
pub let K_TAG = 6;      // tag, with the tagged item as items[0]
pub let K_BOOL = 7;
pub let K_NULL = 8;
pub let K_UNDEFINED = 9;
pub let K_FLOAT = 10;
pub let K_SIMPLE = 11;  // another simple value, in u

pub gc struct Value {
    kind: int,
    u: u64,          // K_UINT, K_NEG (the argument), K_TAG, K_SIMPLE
    b: bool,
    f: float,
    s: str,
    bin: bytes,
    items: [Value],
    keys: [Value],
    vals: [Value],
}

pub fn int_value(v: int) -> Value {
    if v >= 0 { let x = blank(K_UINT); x.u = v as u64; return x; }
    let x = blank(K_NEG);
    x.u = (-(v + 1)) as u64;
    return x;
}
pub fn text_value(s: str) -> Value { let x = blank(K_TEXT); x.s = s; return x; }
pub fn bytes_value(b: bytes) -> Value { let x = blank(K_BYTES); x.bin = b; return x; }
pub fn float_value(f: float) -> Value { let x = blank(K_FLOAT); x.f = f; return x; }
pub fn bool_value(b: bool) -> Value { let x = blank(K_BOOL); x.b = b; return x; }
pub fn null_value() -> Value { return blank(K_NULL); }
pub fn array_value(items: [Value]) -> Value { let x = blank(K_ARRAY); x.items = items; return x; }
pub fn map_value(keys: [Value], vals: [Value]) -> Value {
    let x = blank(K_MAP);
    x.keys = keys;
    x.vals = vals;
    return x;
}
pub fn tag_value(tag: u64, item: Value) -> Value {
    let x = blank(K_TAG);
    x.u = tag;
    x.items = [item];
    return x;
}

// An integer value as int, if it fits.
pub fn as_int(v: Value) -> opt[int] {
    if (v.kind == K_UINT || v.kind == K_NEG) && v.u <= (9223372036854775807 as u64) {
        if v.kind == K_UINT { return some(v.u as int); }
        return some(-1 - (v.u as int));
    }
    return none;
}

// The value of a map entry whose key is the text key.
pub fn get(v: Value, key: str) -> opt[Value] {
    if v.kind != K_MAP { return none; }
    for i in 0..len(v.keys) {
        if v.keys[i].kind == K_TEXT && v.keys[i].s == key { return some(v.vals[i]); }
    }
    return none;
}

pub fn decode(b: bytes) -> result[Value, str] {
    let r = reader(b);
    let vr = read_value(r, 0);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    if r.at != len(b) { return err("cbor: " + to_str(len(b) - r.at) + " bytes after the item"); }
    return ok(v);
}

pub fn read_value(r: Reader, depth: int) -> result[Value, str] {
    if depth > MAX_DEPTH { return err("cbor: nested too deeply"); }
    let m = peek_major(r);
    if m < 0 { return err("cbor: unexpected end of input"); }
    if m == M_UINT || m == M_NEG {
        let hr = read_head(r, m, "int");
        guard let h = hr else let e = err_of(hr) { return err(e); }
        let x = blank(m);
        x.u = h.arg;
        return ok(x);
    }
    if m == M_BYTES {
        let br = read_bytes(r);
        guard let b = br else let e = err_of(br) { return err(e); }
        return ok(bytes_value(b));
    }
    if m == M_TEXT {
        let tr = read_text(r);
        guard let t = tr else let e = err_of(tr) { return err(e); }
        return ok(text_value(t));
    }
    if m == M_ARRAY {
        let nr = read_array(r);
        guard let n = nr else let e = err_of(nr) { return err(e); }
        let items: [Value] = [];
        let i = 0;
        while (n >= 0 && i < n) || (n < 0 && !at_break(r)) {
            let ir = read_value(r, depth + 1);
            guard let it = ir else let ie = err_of(ir) { return err(ie); }
            push(items, it);
            i = i + 1;
        }
        if n < 0 { let _b = read_break(r); }
        return ok(array_value(items));
    }
    if m == M_MAP {
        let nr = read_map(r);
        guard let n = nr else let e = err_of(nr) { return err(e); }
        let keys: [Value] = [];
        let vals: [Value] = [];
        let i = 0;
        while (n >= 0 && i < n) || (n < 0 && !at_break(r)) {
            let kr = read_value(r, depth + 1);
            guard let k = kr else let ke = err_of(kr) { return err(ke); }
            let vr = read_value(r, depth + 1);
            guard let v = vr else let ve = err_of(vr) { return err(ve); }
            push(keys, k);
            push(vals, v);
            i = i + 1;
        }
        if n < 0 { let _b = read_break(r); }
        return ok(map_value(keys, vals));
    }
    if m == M_TAG {
        let tr = read_tag(r);
        guard let t = tr else let e = err_of(tr) { return err(e); }
        let ir = read_value(r, depth + 1);
        guard let it = ir else let ie = err_of(ir) { return err(ie); }
        return ok(tag_value(t, it));
    }
    // major 7
    let c = r.b[r.at] as int;
    if c == 0xf4 || c == 0xf5 { r.at = r.at + 1; return ok(bool_value(c == 0xf5)); }
    if c == 0xf6 { r.at = r.at + 1; return ok(null_value()); }
    if c == 0xf7 { r.at = r.at + 1; return ok(blank(K_UNDEFINED)); }
    if c == 0xf9 || c == 0xfa || c == 0xfb {
        let fr = read_float(r);
        guard let f = fr else let e = err_of(fr) { return err(e); }
        return ok(float_value(f));
    }
    if c == 0xff { return err("cbor: unexpected break"); }
    let ai = c & 0x1f;
    if ai < 20 { r.at = r.at + 1; let x = blank(K_SIMPLE); x.u = ai as u64; return ok(x); }
    if ai == 24 {
        if r.at + 1 >= len(r.b) { return err("cbor: truncated simple value"); }
        let sv = r.b[r.at + 1] as int;
        if sv < 32 { return err("cbor: simple value " + to_str(sv) + " in two bytes"); }
        r.at = r.at + 2;
        let x = blank(K_SIMPLE);
        x.u = sv as u64;
        return ok(x);
    }
    return err("cbor: reserved additional information " + to_str(ai));
}

pub fn encode(v: Value) -> bytes {
    let w = writer();
    write_value(w, v);
    return finish(w);
}

pub fn write_value(w: Writer, v: Value) {
    let k = v.kind;
    if k == K_UINT { head(w, M_UINT, v.u); }
    else if k == K_NEG { head(w, M_NEG, v.u); }
    else if k == K_BYTES { write_bytes(w, v.bin); }
    else if k == K_TEXT { write_text(w, v.s); }
    else if k == K_BOOL { write_bool(w, v.b); }
    else if k == K_NULL { write_null(w); }
    else if k == K_UNDEFINED { write_undefined(w); }
    else if k == K_FLOAT { write_float(w, v.f); }
    else if k == K_SIMPLE {
        if v.u < (24 as u64) { w.b.write_byte(0xe0 | (v.u as int)); }
        else { w.b.write_byte(0xf8); w.b.write_byte(v.u as int); }
    } else if k == K_TAG {
        head(w, M_TAG, v.u);
        write_value(w, v.items[0]);
    } else if k == K_ARRAY {
        write_array(w, len(v.items));
        for it in v.items { write_value(w, it); }
    } else if k == K_MAP {
        write_map(w, len(v.keys));
        for i in 0..len(v.keys) {
            write_value(w, v.keys[i]);
            write_value(w, v.vals[i]);
        }
    }
}

fn blank(kind: int) -> Value {
    let items: [Value] = [];
    let keys: [Value] = [];
    let vals: [Value] = [];
    return Value { kind: kind, u: 0 as u64, b: false, f: 0.0, s: "", bin: b"",
                   items: items, keys: keys, vals: vals };
}
