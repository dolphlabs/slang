// MessagePack (msgpack.org): a compact binary form of JSON's data model,
// plus binary strings and extension types.
//
//     import "msgpack";
//
//     let w = msgpack.writer();
//     msgpack.write_map(w, 2);
//     msgpack.write_str(w, "id");   msgpack.write_int(w, 42);
//     msgpack.write_str(w, "tags"); msgpack.write_array(w, 1); msgpack.write_str(w, "new");
//     let data = msgpack.finish(w);
//
//     let r = msgpack.reader(data);
//     let n = msgpack.read_map(r) ?? 0;          // 2
//     let k = msgpack.read_str(r) ?? "";         // "id"
//     let id = msgpack.read_int(r) ?? 0;         // 42
//     msgpack.skip(r);                           // "tags" ...
//
//     let v = msgpack.decode(data) ?? msgpack.nil_value();   // a Value tree
//
// The Writer and Reader stream: no tree, nothing allocated but the output
// and the strings read. Values always take the shortest encoding. The
// Reader checks every length against the bytes left before allocating,
// so a hostile "array of 4 billion" header fails at once instead of
// reserving memory, and nesting is limited to MAX_DEPTH.

import "builder";
import "math";

pub let MAX_DEPTH = 512;

// ---- writing ---------------------------------------------------------------

pub gc struct Writer {
    b: builder.Bytes,
}

pub fn writer() -> Writer {
    return Writer { b: builder.new_bytes() };
}

// The bytes written so far; the writer is empty again afterwards.
pub fn finish(w: Writer) -> bytes {
    return w.b.take();
}

pub fn write_nil(w: Writer) {
    w.b.write_byte(0xc0);
}

pub fn write_bool(w: Writer, v: bool) {
    if v { w.b.write_byte(0xc3); } else { w.b.write_byte(0xc2); }
}

pub fn write_int(w: Writer, v: int) {
    if v >= 0 {
        if v < 128 { w.b.write_byte(v); }
        else if v < 256 { w.b.write_byte(0xcc); w.b.write_byte(v); }
        else if v < 65536 { w.b.write_byte(0xcd); be(w, v, 2); }
        else if v < 4294967296 { w.b.write_byte(0xce); be(w, v, 4); }
        else { w.b.write_byte(0xcf); be(w, v, 8); }
        return;
    }
    if v >= -32 { w.b.write_byte(v & 0xff); }
    else if v >= -128 { w.b.write_byte(0xd0); w.b.write_byte(v & 0xff); }
    else if v >= -32768 { w.b.write_byte(0xd1); be(w, v, 2); }
    else if v >= -2147483648 { w.b.write_byte(0xd2); be(w, v, 4); }
    else { w.b.write_byte(0xd3); be(w, v, 8); }
}

// An unsigned value beyond int's range (up to 2^64 - 1).
pub fn write_uint(w: Writer, v: u64) {
    if v < (9223372036854775807 as u64) {
        write_int(w, v as int);
        return;
    }
    w.b.write_byte(0xcf);
    be(w, v as int, 8);
}

pub fn write_float(w: Writer, v: float) {
    w.b.write_byte(0xcb);
    be(w, math.float_bits(v) as int, 8);
}

// A float32: half the size, for values that fit one.
pub fn write_float32(w: Writer, v: float) {
    w.b.write_byte(0xca);
    be(w, math.f32_bits(v as f32) as int, 4);
}

pub fn write_str(w: Writer, s: str) {
    let b = to_bytes(s);
    let n = len(b);
    if n < 32 { w.b.write_byte(0xa0 | n); }
    else if n < 256 { w.b.write_byte(0xd9); w.b.write_byte(n); }
    else if n < 65536 { w.b.write_byte(0xda); be(w, n, 2); }
    else { w.b.write_byte(0xdb); be(w, n, 4); }
    w.b.write(b);
}

pub fn write_bin(w: Writer, b: bytes) {
    let n = len(b);
    if n < 256 { w.b.write_byte(0xc4); w.b.write_byte(n); }
    else if n < 65536 { w.b.write_byte(0xc5); be(w, n, 2); }
    else { w.b.write_byte(0xc6); be(w, n, 4); }
    w.b.write(b);
}

// The header of an array of n values; write the n values next.
pub fn write_array(w: Writer, n: int) {
    if n < 16 { w.b.write_byte(0x90 | n); }
    else if n < 65536 { w.b.write_byte(0xdc); be(w, n, 2); }
    else { w.b.write_byte(0xdd); be(w, n, 4); }
}

// The header of a map of n pairs; write key, value, key, value, ... next.
pub fn write_map(w: Writer, n: int) {
    if n < 16 { w.b.write_byte(0x80 | n); }
    else if n < 65536 { w.b.write_byte(0xde); be(w, n, 2); }
    else { w.b.write_byte(0xdf); be(w, n, 4); }
}

// An extension value: an application type -128..127 and its bytes.
pub fn write_ext(w: Writer, kind: int, data: bytes) {
    let n = len(data);
    if n == 1 { w.b.write_byte(0xd4); }
    else if n == 2 { w.b.write_byte(0xd5); }
    else if n == 4 { w.b.write_byte(0xd6); }
    else if n == 8 { w.b.write_byte(0xd7); }
    else if n == 16 { w.b.write_byte(0xd8); }
    else if n < 256 { w.b.write_byte(0xc7); w.b.write_byte(n); }
    else if n < 65536 { w.b.write_byte(0xc8); be(w, n, 2); }
    else { w.b.write_byte(0xc9); be(w, n, 4); }
    w.b.write_byte(kind & 0xff);
    w.b.write(data);
}

// A timestamp (extension type -1) for unix seconds and nanoseconds, in
// the shortest of its three forms.
pub fn write_timestamp(w: Writer, secs: int, nanos: int) {
    let t = builder.new_bytes();
    if nanos == 0 && secs >= 0 && secs < 4294967296 {
        be_into(t, secs, 4);
    } else if secs >= 0 && secs < 17179869184 {
        be_into(t, (nanos << 34) | secs, 8);
    } else {
        be_into(t, nanos, 4);
        be_into(t, secs, 8);
    }
    write_ext(w, -1, t.finish());
}

fn be(w: Writer, v: int, n: int) {
    be_into(w.b, v, n);
}

fn be_into(b: builder.Bytes, v: int, n: int) {
    let shift = (n - 1) * 8;
    while shift >= 0 {
        b.write_byte((v >> shift) & 0xff);
        shift = shift - 8;
    }
}

// ---- reading ---------------------------------------------------------------

pub let K_NIL = 0;
pub let K_BOOL = 1;
pub let K_INT = 2;      // fits int
pub let K_UINT = 3;     // above int's range: read_uint
pub let K_FLOAT = 4;
pub let K_STR = 5;
pub let K_BIN = 6;
pub let K_ARRAY = 7;
pub let K_MAP = 8;
pub let K_EXT = 9;
pub let K_END = 10;     // no bytes left
pub let K_BAD = 11;     // 0xc1, never used

pub gc struct Reader {
    b: bytes,
    at: int,
}

pub fn reader(b: bytes) -> Reader {
    return Reader { b: b, at: 0 };
}

// Bytes not yet read.
pub fn remaining(r: Reader) -> int {
    return len(r.b) - r.at;
}

// The kind of the next value, without reading it.
pub fn peek(r: Reader) -> int {
    if r.at >= len(r.b) { return K_END; }
    let c = r.b[r.at] as int;
    if c <= 0x7f || c >= 0xe0 { return K_INT; }
    if c >= 0x80 && c <= 0x8f { return K_MAP; }
    if c >= 0x90 && c <= 0x9f { return K_ARRAY; }
    if c >= 0xa0 && c <= 0xbf { return K_STR; }
    if c == 0xc0 { return K_NIL; }
    if c == 0xc2 || c == 0xc3 { return K_BOOL; }
    if c >= 0xc4 && c <= 0xc6 { return K_BIN; }
    if (c >= 0xc7 && c <= 0xc9) || (c >= 0xd4 && c <= 0xd8) { return K_EXT; }
    if c == 0xca || c == 0xcb { return K_FLOAT; }
    if c == 0xcf {
        if r.at + 1 < len(r.b) && (r.b[r.at + 1] as int) >= 0x80 { return K_UINT; }
        return K_INT;
    }
    if (c >= 0xcc && c <= 0xce) || (c >= 0xd0 && c <= 0xd3) { return K_INT; }
    if c == 0xd9 || c == 0xda || c == 0xdb { return K_STR; }
    if c == 0xdc || c == 0xdd { return K_ARRAY; }
    if c == 0xde || c == 0xdf { return K_MAP; }
    return K_BAD;
}

pub fn read_nil(r: Reader) -> result[bool, str] {
    if r.at < len(r.b) && (r.b[r.at] as int) == 0xc0 {
        r.at = r.at + 1;
        return ok(true);
    }
    return err(want(r, "nil"));
}

pub fn read_bool(r: Reader) -> result[bool, str] {
    if r.at < len(r.b) {
        let c = r.b[r.at] as int;
        if c == 0xc2 || c == 0xc3 {
            r.at = r.at + 1;
            return ok(c == 0xc3);
        }
    }
    return err(want(r, "bool"));
}

// Any integer encoding that fits int.
pub fn read_int(r: Reader) -> result[int, str] {
    if r.at >= len(r.b) { return err(want(r, "int")); }
    let c = r.b[r.at] as int;
    if c <= 0x7f { r.at = r.at + 1; return ok(c); }
    if c >= 0xe0 { r.at = r.at + 1; return ok(c - 256); }
    let n = 0;
    let signed = false;
    if c == 0xcc { n = 1; } else if c == 0xcd { n = 2; } else if c == 0xce { n = 4; }
    else if c == 0xcf { n = 8; }
    else if c == 0xd0 { n = 1; signed = true; } else if c == 0xd1 { n = 2; signed = true; }
    else if c == 0xd2 { n = 4; signed = true; } else if c == 0xd3 { n = 8; signed = true; }
    else { return err(want(r, "int")); }
    if r.at + 1 + n > len(r.b) { return err("msgpack: truncated int"); }
    let v = uint_at(r.b, r.at + 1, n);
    if c == 0xcf && v < 0 { return err("msgpack: unsigned value beyond int; use read_uint"); }
    if signed && n < 8 {
        let top = 1 << (n * 8 - 1);
        if v >= top { v = v - (top << 1); }
    }
    r.at = r.at + 1 + n;
    return ok(v);
}

// An unsigned integer, the full u64 range.
pub fn read_uint(r: Reader) -> result[u64, str] {
    if r.at < len(r.b) && (r.b[r.at] as int) == 0xcf {
        if r.at + 9 > len(r.b) { return err("msgpack: truncated int"); }
        let v = uint_at(r.b, r.at + 1, 8) as u64;
        r.at = r.at + 9;
        return ok(v);
    }
    let save = r.at;
    let ir = read_int(r);
    guard let v = ir else let e = err_of(ir) { return err(e); }
    if v < 0 {
        r.at = save;
        return err("msgpack: negative value read as unsigned");
    }
    return ok(v as u64);
}

// A float32 or float64; an integer is read as its float too.
pub fn read_float(r: Reader) -> result[float, str] {
    if r.at >= len(r.b) { return err(want(r, "float")); }
    let c = r.b[r.at] as int;
    if c == 0xcb {
        if r.at + 9 > len(r.b) { return err("msgpack: truncated float"); }
        let bits = uint_at(r.b, r.at + 1, 8) as u64;
        r.at = r.at + 9;
        return ok(math.float_from_bits(bits));
    }
    if c == 0xca {
        if r.at + 5 > len(r.b) { return err("msgpack: truncated float"); }
        let bits = uint_at(r.b, r.at + 1, 4) as u32;
        r.at = r.at + 5;
        return ok(math.f32_from_bits(bits) as float);
    }
    let ir = read_int(r);
    guard let v = ir else { return err(want(r, "float")); }
    return ok(v as float);
}

pub fn read_str(r: Reader) -> result[str, str] {
    if r.at >= len(r.b) { return err(want(r, "str")); }
    let c = r.b[r.at] as int;
    let hdr = 1;
    let n = 0;
    if c >= 0xa0 && c <= 0xbf { n = c & 0x1f; }
    else if c == 0xd9 { hdr = 2; } else if c == 0xda { hdr = 3; } else if c == 0xdb { hdr = 5; }
    else { return err(want(r, "str")); }
    if r.at + hdr > len(r.b) { return err("msgpack: truncated str"); }
    if hdr > 1 { n = uint_at(r.b, r.at + 1, hdr - 1); }
    let start = r.at + hdr;
    if n > len(r.b) - start { return err("msgpack: str longer than the input"); }
    r.at = start + n;
    return ok(to_str(r.b[start..start + n]));
}

pub fn read_bin(r: Reader) -> result[bytes, str] {
    if r.at >= len(r.b) { return err(want(r, "bin")); }
    let c = r.b[r.at] as int;
    let hdr = 0;
    if c == 0xc4 { hdr = 2; } else if c == 0xc5 { hdr = 3; } else if c == 0xc6 { hdr = 5; }
    else { return err(want(r, "bin")); }
    if r.at + hdr > len(r.b) { return err("msgpack: truncated bin"); }
    let n = uint_at(r.b, r.at + 1, hdr - 1);
    let start = r.at + hdr;
    if n > len(r.b) - start { return err("msgpack: bin longer than the input"); }
    r.at = start + n;
    return ok(r.b[start..start + n]);
}

// An array header: how many values follow.
pub fn read_array(r: Reader) -> result[int, str] {
    return read_container(r, 0x90, 0xdc, 0xdd, 1, "array");
}

// A map header: how many key-value pairs follow.
pub fn read_map(r: Reader) -> result[int, str] {
    return read_container(r, 0x80, 0xde, 0xdf, 2, "map");
}

pub struct Ext {
    kind: int,
    data: bytes,
}

pub fn read_ext(r: Reader) -> result[Ext, str] {
    if r.at >= len(r.b) { return err(want(r, "ext")); }
    let c = r.b[r.at] as int;
    let n = 0;
    let hdr = 1;
    if c == 0xd4 { n = 1; } else if c == 0xd5 { n = 2; } else if c == 0xd6 { n = 4; }
    else if c == 0xd7 { n = 8; } else if c == 0xd8 { n = 16; }
    else if c == 0xc7 { hdr = 2; } else if c == 0xc8 { hdr = 3; } else if c == 0xc9 { hdr = 5; }
    else { return err(want(r, "ext")); }
    if r.at + hdr + 1 > len(r.b) { return err("msgpack: truncated ext"); }
    if hdr > 1 { n = uint_at(r.b, r.at + 1, hdr - 1); }
    let kind = r.b[r.at + hdr] as int;
    if kind >= 128 { kind = kind - 256; }
    let start = r.at + hdr + 1;
    if n > len(r.b) - start { return err("msgpack: ext longer than the input"); }
    r.at = start + n;
    return ok(Ext { kind: kind, data: r.b[start..start + n] });
}

pub struct Timestamp {
    secs: int,
    nanos: int,
}

// Reads extension type -1 in any of its three forms.
pub fn read_timestamp(r: Reader) -> result[Timestamp, str] {
    let save = r.at;
    let er = read_ext(r);
    guard let e = er else let m = err_of(er) { return err(m); }
    if e.kind != -1 { r.at = save; return err("msgpack: not a timestamp"); }
    let d = e.data;
    if len(d) == 4 { return ok(Timestamp { secs: uint_at(d, 0, 4), nanos: 0 }); }
    if len(d) == 8 {
        let v = uint_at(d, 0, 8) as u64;
        return ok(Timestamp { secs: (v & (0x3ffffffff as u64)) as int, nanos: (v >> 34) as int });
    }
    if len(d) == 12 {
        return ok(Timestamp { secs: uint_at(d, 4, 8), nanos: uint_at(d, 0, 4) });
    }
    r.at = save;
    return err("msgpack: bad timestamp length");
}

// Skips the next value, containers and all.
pub fn skip(r: Reader) -> result[bool, str] {
    return skip_depth(r, 0);
}

fn skip_depth(r: Reader, depth: int) -> result[bool, str] {
    if depth > MAX_DEPTH { return err("msgpack: nested too deeply"); }
    let k = peek(r);
    if k == K_ARRAY || k == K_MAP {
        let n = 0;
        if k == K_MAP {
            let mr = read_map(r);
            guard let m = mr else let me = err_of(mr) { return err(me); }
            n = m * 2;
        } else {
            let ar = read_array(r);
            guard let a = ar else let ae = err_of(ar) { return err(ae); }
            n = a;
        }
        for _ in 0..n {
            let sr = skip_depth(r, depth + 1);
            guard let _s = sr else let se = err_of(sr) { return err(se); }
        }
        return ok(true);
    }
    if k == K_NIL { return read_nil(r); }
    if k == K_BOOL { let x = read_bool(r); guard let _v = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_INT { let x = read_int(r); guard let _i = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_UINT { let x = read_uint(r); guard let _u = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_FLOAT { let x = read_float(r); guard let _f = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_STR { let x = read_str(r); guard let _t = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_BIN { let x = read_bin(r); guard let _b = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_EXT { let x = read_ext(r); guard let _x = x else let e = err_of(x) { return err(e); } return ok(true); }
    if k == K_END { return err("msgpack: unexpected end of input"); }
    return err("msgpack: invalid byte 0xc1");
}

// A container header at r: fix range starting at fix_lo (16 values),
// 16- and 32-bit forms. Each element takes at least `min_each` bytes, so
// a count the remaining input cannot hold is refused before anything is
// allocated for it.
fn read_container(r: Reader, fix_lo: int, c16: int, c32: int, min_each: int,
                  what: str) -> result[int, str] {
    if r.at >= len(r.b) { return err(want(r, what)); }
    let c = r.b[r.at] as int;
    let n = 0;
    let hdr = 1;
    if c >= fix_lo && c <= fix_lo + 15 { n = c - fix_lo; }
    else if c == c16 { hdr = 3; } else if c == c32 { hdr = 5; }
    else { return err(want(r, what)); }
    if r.at + hdr > len(r.b) { return err("msgpack: truncated " + what + " header"); }
    if hdr > 1 { n = uint_at(r.b, r.at + 1, hdr - 1); }
    if n * min_each > len(r.b) - r.at - hdr {
        return err("msgpack: " + what + " of " + to_str(n) + " is longer than the input");
    }
    r.at = r.at + hdr;
    return ok(n);
}

fn uint_at(b: bytes, at: int, n: int) -> int {
    let v = 0;
    for i in 0..n {
        v = (v << 8) | (b[at + i] as int);
    }
    return v;
}

fn want(r: Reader, what: str) -> str {
    if r.at >= len(r.b) { return "msgpack: expected " + what + ", found the end of the input"; }
    return "msgpack: expected " + what + " at byte " + to_str(r.at);
}

// ---- dynamic values --------------------------------------------------------

// Any MessagePack value. kind is one of the K_ constants; the field for
// it holds the value (items for an array, keys and vals for a map).
pub gc struct Value {
    kind: int,
    b: bool,
    i: int,
    u: u64,
    f: float,
    s: str,
    bin: bytes,
    items: [Value],
    keys: [Value],
    vals: [Value],
    ext_kind: int,
}

pub fn nil_value() -> Value { return blank(K_NIL); }
pub fn bool_value(v: bool) -> Value { let x = blank(K_BOOL); x.b = v; return x; }
pub fn int_value(v: int) -> Value { let x = blank(K_INT); x.i = v; return x; }
pub fn float_value(v: float) -> Value { let x = blank(K_FLOAT); x.f = v; return x; }
pub fn str_value(v: str) -> Value { let x = blank(K_STR); x.s = v; return x; }
pub fn bin_value(v: bytes) -> Value { let x = blank(K_BIN); x.bin = v; return x; }
pub fn array_value(items: [Value]) -> Value { let x = blank(K_ARRAY); x.items = items; return x; }
pub fn map_value(keys: [Value], vals: [Value]) -> Value {
    let x = blank(K_MAP);
    x.keys = keys;
    x.vals = vals;
    return x;
}

// The value of a map entry whose key is the string key.
pub fn get(v: Value, key: str) -> opt[Value] {
    if v.kind != K_MAP { return none; }
    for i in 0..len(v.keys) {
        if v.keys[i].kind == K_STR && v.keys[i].s == key { return some(v.vals[i]); }
    }
    return none;
}

// One whole value; trailing bytes are an error.
pub fn decode(b: bytes) -> result[Value, str] {
    let r = reader(b);
    let vr = read_value(r, 0);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    if r.at != len(b) { return err("msgpack: " + to_str(len(b) - r.at) + " bytes after the value"); }
    return ok(v);
}

// The next value from r as a tree.
pub fn read_value(r: Reader, depth: int) -> result[Value, str] {
    if depth > MAX_DEPTH { return err("msgpack: nested too deeply"); }
    let k = peek(r);
    if k == K_ARRAY {
        let nr = read_array(r);
        guard let n = nr else let e = err_of(nr) { return err(e); }
        let items: [Value] = [];
        for _ in 0..n {
            let ir = read_value(r, depth + 1);
            guard let it = ir else let ie = err_of(ir) { return err(ie); }
            push(items, it);
        }
        return ok(array_value(items));
    }
    if k == K_MAP {
        let nr = read_map(r);
        guard let n = nr else let e = err_of(nr) { return err(e); }
        let keys: [Value] = [];
        let vals: [Value] = [];
        for _ in 0..n {
            let kr = read_value(r, depth + 1);
            guard let kv = kr else let ke = err_of(kr) { return err(ke); }
            let vr = read_value(r, depth + 1);
            guard let vv = vr else let ve = err_of(vr) { return err(ve); }
            push(keys, kv);
            push(vals, vv);
        }
        return ok(map_value(keys, vals));
    }
    if k == K_NIL { let x = read_nil(r); guard let _n = x else let e = err_of(x) { return err(e); } return ok(nil_value()); }
    if k == K_BOOL { let x = read_bool(r); guard let v = x else let e = err_of(x) { return err(e); } return ok(bool_value(v)); }
    if k == K_INT { let x = read_int(r); guard let v = x else let e = err_of(x) { return err(e); } return ok(int_value(v)); }
    if k == K_UINT {
        let x = read_uint(r);
        guard let v = x else let e = err_of(x) { return err(e); }
        let out = blank(K_UINT);
        out.u = v;
        return ok(out);
    }
    if k == K_FLOAT { let x = read_float(r); guard let v = x else let e = err_of(x) { return err(e); } return ok(float_value(v)); }
    if k == K_STR { let x = read_str(r); guard let v = x else let e = err_of(x) { return err(e); } return ok(str_value(v)); }
    if k == K_BIN { let x = read_bin(r); guard let v = x else let e = err_of(x) { return err(e); } return ok(bin_value(v)); }
    if k == K_EXT {
        let x = read_ext(r);
        guard let v = x else let e = err_of(x) { return err(e); }
        let out = blank(K_EXT);
        out.ext_kind = v.kind;
        out.bin = v.data;
        return ok(out);
    }
    if k == K_END { return err("msgpack: unexpected end of input"); }
    return err("msgpack: invalid byte 0xc1");
}

pub fn encode(v: Value) -> bytes {
    let w = writer();
    write_value(w, v);
    return finish(w);
}

pub fn write_value(w: Writer, v: Value) {
    let k = v.kind;
    if k == K_NIL { write_nil(w); }
    else if k == K_BOOL { write_bool(w, v.b); }
    else if k == K_INT { write_int(w, v.i); }
    else if k == K_UINT { write_uint(w, v.u); }
    else if k == K_FLOAT { write_float(w, v.f); }
    else if k == K_STR { write_str(w, v.s); }
    else if k == K_BIN { write_bin(w, v.bin); }
    else if k == K_EXT { write_ext(w, v.ext_kind, v.bin); }
    else if k == K_ARRAY {
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
    return Value { kind: kind, b: false, i: 0, u: 0 as u64, f: 0.0, s: "", bin: b"",
                   items: items, keys: keys, vals: vals, ext_kind: 0 };
}
