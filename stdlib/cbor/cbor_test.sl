import "encoding";
import "strings";

fn hx(b: bytes) -> str { return encoding.hex_encode(b); }
fn unhex(s: str) -> bytes { return encoding.hex_decode(s) ?? b""; }

fn enc_float(f: float) -> str {
    let w = writer();
    write_float(w, f);
    return hx(finish(w));
}

// RFC 8949 Appendix A, the integers.
fn test_should_encode_the_rfc_integer_vectors() {
    let ints = [0, 1, 10, 23, 24, 25, 100, 1000, 1000000, 1000000000000, -1, -10, -100, -1000];
    let want = ["00", "01", "0a", "17", "1818", "1819", "1864", "1903e8", "1a000f4240",
                "1b000000e8d4a51000", "20", "29", "3863", "3903e7"];
    for i in 0..len(ints) {
        let w = writer();
        write_int(w, ints[i]);
        let got = hx(finish(w));
        assert(got == want[i], to_str(ints[i]) + " -> " + got);
        assert((read_int(reader(unhex(got))) ?? 7777) == ints[i], "back " + to_str(ints[i]));
    }
    let w = writer();
    write_uint(w, 18446744073709551615 as u64);
    assert(hx(finish(w)) == "1bffffffffffffffff", "u64 max");
    if let _x = read_int(reader(unhex("3bffffffffffffffff"))) { panic("-2^64 read as int"); }
}

// RFC 8949 Appendix A, the floats, in preferred (shortest exact) form.
fn test_should_encode_floats_in_the_shortest_exact_form() {
    let fs = [0.0, -0.0, 1.0, 1.1, 1.5, 65504.0, 100000.0, 3.4028234663852886e+38,
              1.0e+300, 5.960464477539063e-8, 0.00006103515625, -4.0, -4.1,
              1.0 / 0.0, -1.0 / 0.0, 0.0 / 0.0];
    let want = ["f90000", "f98000", "f93c00", "fb3ff199999999999a", "f93e00", "f97bff",
                "fa47c35000", "fa7f7fffff", "fb7e37e43c8800759c", "f90001", "f90400",
                "f9c400", "fbc010666666666666", "f97c00", "f9fc00", "f97e00"];
    for i in 0..len(fs) {
        let got = enc_float(fs[i]);
        assert(got == want[i], to_str(fs[i]) + " -> " + got + ", want " + want[i]);
        let back = read_float(reader(unhex(got))) ?? 12345.0;
        assert(back == fs[i] || (fs[i] != fs[i] && back != back), "back " + want[i]);
    }
}

fn reencode(h: str) -> str {
    let vr = decode(unhex(h));
    guard let v = vr else let e = err_of(vr) { panic(h + ": " + e); }
    return hx(encode(v));
}

// RFC 8949 Appendix A, the rest of the definite-length examples: decoding
// and re-encoding gives the same bytes.
fn test_should_round_trip_the_rfc_vectors() {
    for h in ["f4", "f5", "f6", "f7", "f0", "f8ff",
              "c074323031332d30332d32315432303a30343a30305a", "c11a514b67b0",
              "c249010000000000000000", "40", "4401020304", "60", "6161", "6449455446",
              "62225c", "62c3bc", "63e6b0b4", "64f0908591", "80", "83010203",
              "8301820203820405", "a0", "a201020304", "a26161016162820203",
              "826161a161626163", "a56161614161626142616361436164614461656145"] {
        assert(reencode(h) == h, h + " re-encoded as " + reencode(h));
    }
}

// The indefinite-length examples decode to the same values as definite ones.
fn test_should_read_indefinite_lengths() {
    let pairs = [["5f42010243030405ff", "450102030405"],
                 ["7f657374726561646d696e67ff", "6973747265616d696e67"],
                 ["9fff", "80"],
                 ["9f018202039f0405ffff", "8301820203820405"],
                 ["83018202039f0405ff", "8301820203820405"],
                 ["bf61610161629f0203ffff", "a26161016162820203"],
                 ["826161bf61626163ff", "826161a161626163"]];
    for p in pairs {
        assert(reencode(p[0]) == p[1], p[0] + " -> " + reencode(p[0]));
    }
}

fn test_should_build_and_query_values() {
    let v = map_value([text_value("name"), text_value("n")],
                      [text_value("sensor"), int_value(-42)]);
    let back = decode(encode(v)) ?? null_value();
    let n = get(back, "n");
    guard let nv = n else { panic("key lost"); }
    assert((as_int(nv) ?? 0) == -42, "int back");
    let t = tag_value(1 as u64, int_value(1363896240));
    assert(hx(encode(t)) == "c11a514b67b0", "tag");
}

fn test_should_refuse_hostile_and_broken_input() {
    assert(strings.contains(err_of(decode(unhex("9bffffffffffffffff"))), "longer than the input"), "huge array");
    assert(strings.contains(err_of(decode(unhex("5affffffff"))), "longer than the input"), "huge string");
    let deep = "";
    for _ in 0..600 { deep = deep + "81"; }
    assert(strings.contains(err_of(decode(unhex(deep + "00"))), "nested too deeply"), "depth");
    assert(strings.contains(err_of(decode(unhex("62c328"))), "not UTF-8"), "bad utf-8");
    assert(strings.contains(err_of(decode(unhex("1c"))), "reserved"), "reserved ai");
    assert(strings.contains(err_of(decode(unhex("ff"))), "break"), "stray break");
    assert(strings.contains(err_of(decode(unhex("5f6161ff"))), "bad chunk"), "text chunk in bytes");
    assert(strings.contains(err_of(decode(unhex("0101"))), "after the item"), "trailing");
    assert(strings.contains(err_of(decode(unhex("f81f"))), "two bytes"), "short simple in two bytes");
}
