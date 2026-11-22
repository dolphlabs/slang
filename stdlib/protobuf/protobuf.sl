// The Protocol Buffers wire format: write and read messages field by
// field, without generated code.
//
//     import "protobuf";
//
//     // message User { int64 id = 1; string name = 2; repeated sint32 deltas = 3; }
//     let w = protobuf.writer();
//     protobuf.write_int64(w, 1, 42);
//     protobuf.write_string(w, 2, "ada");
//     protobuf.write_packed_sint(w, 3, [-1, 5, -9]);
//     let data = protobuf.finish(w);
//
//     let r = protobuf.reader(data);
//     while protobuf.more(r) {
//         let fr = protobuf.next(r);                // field number and wire type
//         guard let f = fr else { break; }
//         if f.num == 1 { id = protobuf.read_varint(r) ?? 0; }
//         else if f.num == 2 { name = protobuf.read_string(r) ?? ""; }
//         else { protobuf.skip(r, f.wire); }       // unknown: skip it
//     }
//
// A nested message is its own Writer, finished and written with
// write_bytes; read one with reader(read_bytes(r)). Default values
// (0, "", false) are written when asked: proto3 leaves them out, so a
// caller following proto3 skips them.
//
// Reading checks every length against the bytes left and varints
// against their ten-byte limit, so hostile input fails without
// allocating.

import "builder";
import "math";

pub let WIRE_VARINT = 0;
pub let WIRE_I64 = 1;
pub let WIRE_LEN = 2;
pub let WIRE_I32 = 5;

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

// The bytes written so far, without emptying the writer.
pub fn size(w: Writer) -> int {
    return w.b.size();
}

fn tag(w: Writer, field: int, wire: int) {
    varint(w, ((field << 3) | wire) as u64);
}

fn varint(w: Writer, v: u64) {
    let x = v;
    while x >= (128 as u64) {
        w.b.write_byte(((x & (127 as u64)) | (128 as u64)) as int);
        x = x >> 7;
    }
    w.b.write_byte(x as int);
}

fn fixed(w: Writer, v: u64, n: int) {
    for i in 0..n {
        w.b.write_byte(((v >> (8 * i)) & (255 as u64)) as int);
    }
}

fn zigzag(v: int) -> u64 {
    return ((v << 1) ^ (v >> 63)) as u64;
}

// int32, int64, uint32, uint64 and enum fields. A negative int32 or
// int64 takes ten bytes, as the format says; use write_sint for fields
// declared sint32/sint64.
pub fn write_int64(w: Writer, field: int, v: int) {
    tag(w, field, WIRE_VARINT);
    varint(w, v as u64);
}

pub fn write_uint64(w: Writer, field: int, v: u64) {
    tag(w, field, WIRE_VARINT);
    varint(w, v);
}

// sint32 and sint64 fields: zigzag, so small negatives stay small.
pub fn write_sint(w: Writer, field: int, v: int) {
    tag(w, field, WIRE_VARINT);
    varint(w, zigzag(v));
}

pub fn write_bool(w: Writer, field: int, v: bool) {
    tag(w, field, WIRE_VARINT);
    if v { w.b.write_byte(1); } else { w.b.write_byte(0); }
}

// fixed64, sfixed64.
pub fn write_fixed64(w: Writer, field: int, v: u64) {
    tag(w, field, WIRE_I64);
    fixed(w, v, 8);
}

// fixed32, sfixed32 (the low 32 bits of v).
pub fn write_fixed32(w: Writer, field: int, v: int) {
    tag(w, field, WIRE_I32);
    fixed(w, (v & 0xffffffff) as u64, 4);
}

pub fn write_double(w: Writer, field: int, v: float) {
    tag(w, field, WIRE_I64);
    fixed(w, math.float_bits(v), 8);
}

pub fn write_float(w: Writer, field: int, v: float) {
    tag(w, field, WIRE_I32);
    fixed(w, math.f32_bits(v as f32) as u64, 4);
}

// bytes fields and nested messages (a finished Writer's bytes).
pub fn write_bytes(w: Writer, field: int, b: bytes) {
    tag(w, field, WIRE_LEN);
    varint(w, len(b) as u64);
    w.b.write(b);
}

pub fn write_string(w: Writer, field: int, s: str) {
    write_bytes(w, field, to_bytes(s));
}

// repeated int32/int64/uint32/uint64/enum/bool, packed.
pub fn write_packed_int(w: Writer, field: int, vs: [int]) {
    let inner = writer();
    for v in vs { varint(inner, v as u64); }
    write_bytes(w, field, finish(inner));
}

// repeated sint32/sint64, packed.
pub fn write_packed_sint(w: Writer, field: int, vs: [int]) {
    let inner = writer();
    for v in vs { varint(inner, zigzag(v)); }
    write_bytes(w, field, finish(inner));
}

// repeated double, packed.
pub fn write_packed_double(w: Writer, field: int, vs: [float]) {
    let inner = writer();
    for v in vs { fixed(inner, math.float_bits(v), 8); }
    write_bytes(w, field, finish(inner));
}

// ---- reading ---------------------------------------------------------------

pub gc struct Reader {
    b: bytes,
    at: int,
}

pub fn reader(b: bytes) -> Reader {
    return Reader { b: b, at: 0 };
}

pub fn more(r: Reader) -> bool {
    return r.at < len(r.b);
}

pub struct Field {
    num: int,
    wire: int,
}

// The next field's number and wire type; read its value next with the
// reader for that type, or skip it.
pub fn next(r: Reader) -> result[Field, str] {
    let tr = read_raw_varint(r);
    guard let t = tr else let e = err_of(tr) { return err(e); }
    let num = (t >> 3) as int;
    let wire = (t & (7 as u64)) as int;
    if num < 1 || num > 536870911 { return err("protobuf: bad field number " + to_str(num)); }
    if wire != WIRE_VARINT && wire != WIRE_I64 && wire != WIRE_LEN && wire != WIRE_I32 {
        return err("protobuf: unsupported wire type " + to_str(wire) + " (groups are not read)");
    }
    return ok(Field { num: num, wire: wire });
}

// A varint field: int32/int64/uint*/enum read as int (uint64 values above
// int's range come back negative; read_uvarint keeps them).
pub fn read_varint(r: Reader) -> result[int, str] {
    let vr = read_raw_varint(r);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    return ok(v as int);
}

pub fn read_uvarint(r: Reader) -> result[u64, str] {
    return read_raw_varint(r);
}

// A zigzag (sint32/sint64) field.
pub fn read_sint(r: Reader) -> result[int, str] {
    let vr = read_raw_varint(r);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    return ok(((v >> 1) as int) ^ (-((v & (1 as u64)) as int)));
}

pub fn read_bool(r: Reader) -> result[bool, str] {
    let vr = read_raw_varint(r);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    return ok(v != (0 as u64));
}

pub fn read_fixed64(r: Reader) -> result[u64, str] {
    if r.at + 8 > len(r.b) { return err("protobuf: truncated fixed64"); }
    let v: u64 = 0;
    for i in 0..8 { v = v | (((r.b[r.at + i] as int) as u64) << (8 * i)); }
    r.at = r.at + 8;
    return ok(v);
}

// A fixed32 field as an unsigned value; sfixed32 is read_sfixed32.
pub fn read_fixed32(r: Reader) -> result[int, str] {
    if r.at + 4 > len(r.b) { return err("protobuf: truncated fixed32"); }
    let v = 0;
    for i in 0..4 { v = v | ((r.b[r.at + i] as int) << (8 * i)); }
    r.at = r.at + 4;
    return ok(v);
}

pub fn read_sfixed32(r: Reader) -> result[int, str] {
    let vr = read_fixed32(r);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    if v >= 2147483648 { return ok(v - 4294967296); }
    return ok(v);
}

pub fn read_double(r: Reader) -> result[float, str] {
    let vr = read_fixed64(r);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    return ok(math.float_from_bits(v));
}

pub fn read_float(r: Reader) -> result[float, str] {
    let vr = read_fixed32(r);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    return ok(math.f32_from_bits(v as u32) as float);
}

// A length-delimited field: bytes, a string, a nested message, or packed
// repeated values.
pub fn read_bytes(r: Reader) -> result[bytes, str] {
    let nr = read_raw_varint(r);
    guard let n = nr else let e = err_of(nr) { return err(e); }
    if n > ((len(r.b) - r.at) as u64) { return err("protobuf: length beyond the input"); }
    let k = n as int;
    let out = r.b[r.at..r.at + k];
    r.at = r.at + k;
    return ok(out);
}

pub fn read_string(r: Reader) -> result[str, str] {
    let br = read_bytes(r);
    guard let b = br else let e = err_of(br) { return err(e); }
    return ok(to_str(b));
}

// A packed repeated varint field (or a single unpacked element, which a
// parser must also accept for repeated scalars).
pub fn read_packed_int(r: Reader, wire: int) -> result[[int], str] {
    let out: [int] = [];
    if wire == WIRE_VARINT {
        let vr = read_varint(r);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        push(out, v);
        return ok(out);
    }
    let br = read_bytes(r);
    guard let b = br else let e = err_of(br) { return err(e); }
    let inner = reader(b);
    while more(inner) {
        let vr = read_varint(inner);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        push(out, v);
    }
    return ok(out);
}

pub fn read_packed_sint(r: Reader, wire: int) -> result[[int], str] {
    let out: [int] = [];
    if wire == WIRE_VARINT {
        let vr = read_sint(r);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        push(out, v);
        return ok(out);
    }
    let br = read_bytes(r);
    guard let b = br else let e = err_of(br) { return err(e); }
    let inner = reader(b);
    while more(inner) {
        let vr = read_sint(inner);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        push(out, v);
    }
    return ok(out);
}

// Skips a field's value of the given wire type.
pub fn skip(r: Reader, wire: int) -> result[bool, str] {
    if wire == WIRE_VARINT {
        let vr = read_raw_varint(r);
        guard let _v = vr else let e = err_of(vr) { return err(e); }
        return ok(true);
    }
    if wire == WIRE_I64 {
        if r.at + 8 > len(r.b) { return err("protobuf: truncated field"); }
        r.at = r.at + 8;
        return ok(true);
    }
    if wire == WIRE_I32 {
        if r.at + 4 > len(r.b) { return err("protobuf: truncated field"); }
        r.at = r.at + 4;
        return ok(true);
    }
    if wire == WIRE_LEN {
        let br = read_bytes(r);
        guard let _b = br else let e = err_of(br) { return err(e); }
        return ok(true);
    }
    return err("protobuf: unsupported wire type " + to_str(wire));
}

fn read_raw_varint(r: Reader) -> result[u64, str] {
    let v: u64 = 0;
    let shift = 0;
    for i in 0..10 {
        if r.at >= len(r.b) { return err("protobuf: truncated varint"); }
        let c = r.b[r.at] as int;
        r.at = r.at + 1;
        if i == 9 && c > 1 { return err("protobuf: varint over 64 bits"); }
        v = v | (((c & 127) as u64) << shift);
        if c < 128 { return ok(v); }
        shift = shift + 7;
    }
    return err("protobuf: varint over 10 bytes");
}
