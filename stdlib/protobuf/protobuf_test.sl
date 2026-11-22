import "encoding";
import "strings";

fn hx(b: bytes) -> str { return encoding.hex_encode(b); }
fn unhex(s: str) -> bytes { return encoding.hex_decode(s) ?? b""; }

// The protobuf encoding guide's examples.
fn test_should_encode_the_documented_examples() {
    let w = writer();
    write_int64(w, 1, 150);                 // "08 96 01"
    assert(hx(finish(w)) == "089601", "150");
    write_string(w, 2, "testing");          // "12 07 74 65 73 74 69 6e 67"
    assert(hx(finish(w)) == "120774657374696e67", "string");
    write_packed_int(w, 4, [3, 270, 86942]); // "22 06 03 8e 02 9e a7 05"
    assert(hx(finish(w)) == "2206038e029ea705", "packed");
    write_int64(w, 1, -2);                   // ten-byte negative int64
    assert(hx(finish(w)) == "08feffffffffffffffff01", "negative int64");
    write_sint(w, 1, -2);                    // zigzag 3
    assert(hx(finish(w)) == "0803", "sint");
}

fn test_should_round_trip_every_type() {
    let inner = writer();
    write_string(inner, 1, "nested");
    let w = writer();
    write_int64(w, 1, -9223372036854775807 - 1);
    write_uint64(w, 2, 18446744073709551615 as u64);
    write_sint(w, 3, -123456789);
    write_bool(w, 4, true);
    write_fixed64(w, 5, 1234567890123 as u64);
    write_fixed32(w, 6, -5);
    write_double(w, 7, 3.25);
    write_float(w, 8, 1.5);
    write_bytes(w, 9, finish(inner));
    write_packed_sint(w, 10, [-1, 0, 1, -1000]);
    write_packed_double(w, 11, [0.5, -2.0]);
    let r = reader(finish(w));
    let seen = 0;
    while more(r) {
        let fr = next(r);
        guard let f = fr else let e = err_of(fr) { panic(e); }
        seen = seen + 1;
        if f.num == 1 { assert((read_varint(r) ?? 0) == -9223372036854775807 - 1, "int64 min"); }
        else if f.num == 2 { assert((read_uvarint(r) ?? (0 as u64)) == 18446744073709551615 as u64, "uint64 max"); }
        else if f.num == 3 { assert((read_sint(r) ?? 0) == -123456789, "sint"); }
        else if f.num == 4 { assert(read_bool(r) ?? false, "bool"); }
        else if f.num == 5 { assert((read_fixed64(r) ?? (0 as u64)) == 1234567890123 as u64, "fixed64"); }
        else if f.num == 6 { assert((read_sfixed32(r) ?? 0) == -5, "sfixed32"); }
        else if f.num == 7 { assert((read_double(r) ?? 0.0) == 3.25, "double"); }
        else if f.num == 8 { assert((read_float(r) ?? 0.0) == 1.5, "float"); }
        else if f.num == 9 {
            let nr = reader(read_bytes(r) ?? b"");
            let nf = next(nr) ?? Field { num: 0, wire: 0 };
            assert(nf.num == 1 && (read_string(nr) ?? "") == "nested", "nested message");
        } else if f.num == 10 {
            let vs = read_packed_sint(r, f.wire) ?? [];
            assert(len(vs) == 4 && vs[0] == -1 && vs[3] == -1000, "packed sint");
        } else if f.num == 11 {
            let sk = skip(r, f.wire);
            guard let _s = sk else { panic("skip"); }
        }
    }
    assert(seen == 11, "fields seen " + to_str(seen));
}

fn test_should_accept_an_unpacked_repeated_element() {
    let w = writer();
    write_int64(w, 4, 7);
    write_int64(w, 4, 8);
    let r = reader(finish(w));
    let all: [int] = [];
    while more(r) {
        let f = next(r) ?? Field { num: 0, wire: 0 };
        for v in read_packed_int(r, f.wire) ?? [] { push(all, v); }
    }
    assert(len(all) == 2 && all[0] == 7 && all[1] == 8, "unpacked repeated");
}

fn test_should_refuse_broken_input() {
    assert(strings.contains(err_of(read_bytes(reader(unhex("ffffffff0f")))), "beyond the input"), "huge length");
    assert(strings.contains(err_of(read_varint(reader(unhex("8080")))), "truncated"), "short varint");
    assert(strings.contains(err_of(read_varint(reader(unhex("ffffffffffffffffff7f")))), "over 64 bits"), "long varint");
    assert(strings.contains(err_of(next(reader(unhex("0b")))), "wire type"), "group start");
    assert(strings.contains(err_of(next(reader(unhex("00")))), "field number"), "field 0");
    assert(strings.contains(err_of(read_fixed64(reader(unhex("0102")))), "truncated"), "short fixed");
}
