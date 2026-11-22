import "encoding";
import "strings";

fn hexof(b: bytes) -> str { return encoding.hex_encode(b); }

fn enc_int(v: int) -> str {
    let w = writer();
    write_int(w, v);
    return hexof(finish(w));
}

fn test_should_encode_ints_in_the_shortest_form() {
    let cases = [[0, 0], [127, 1], [128, 2], [255, 3], [256, 4], [65535, 5], [65536, 6],
                 [4294967295, 7], [4294967296, 8], [-1, 9], [-32, 10], [-33, 11], [-128, 12],
                 [-129, 13], [-32768, 14], [-32769, 15], [-2147483648, 16], [-2147483649, 17]];
    let want = ["00", "7f", "cc80", "ccff", "cd0100", "cdffff", "ce00010000", "ceffffffff",
                "cf0000000100000000", "ff", "e0", "d0df", "d080", "d1ff7f", "d18000",
                "d2ffff7fff", "d280000000", "d3ffffffff7fffffff"];
    for c in cases {
        let got = enc_int(c[0]);
        assert(got == want[c[1]], to_str(c[0]) + " -> " + got + ", want " + want[c[1]]);
        let back = read_int(reader(encoding.hex_decode(got) ?? b"")) ?? 12345;
        assert(back == c[0], "read back " + to_str(back) + " for " + to_str(c[0]));
    }
}

fn test_should_read_and_write_the_full_unsigned_range() {
    let w = writer();
    write_uint(w, 18446744073709551615 as u64);
    let b = finish(w);
    assert(hexof(b) == "cfffffffffffffffff", "u64 max " + hexof(b));
    let r = reader(b);
    assert(peek(r) == K_UINT, "kind");
    if let _i = read_int(r) { panic("u64 max read as int"); }
    assert((read_uint(r) ?? (0 as u64)) == 18446744073709551615 as u64, "u64 max back");
}

fn test_should_encode_strings_bins_and_containers_at_their_boundaries() {
    let w = writer();
    write_str(w, strings.repeat("a", 31));
    write_str(w, strings.repeat("b", 32));
    write_str(w, strings.repeat("c", 256));
    let b = finish(w);
    assert(hexof(b[0..1]) == "bf" && hexof(b[32..34]) == "d920" && hexof(b[66..69]) == "da0100", "str headers");
    let r = reader(b);
    assert(len(read_str(r) ?? "") == 31 && len(read_str(r) ?? "") == 32 && len(read_str(r) ?? "") == 256, "str back");
    let w2 = writer();
    write_array(w2, 15);
    write_array(w2, 16);
    write_map(w2, 15);
    write_map(w2, 16);
    write_bin(w2, b"xy");
    assert(hexof(finish(w2)) == "9fdc00108fde0010c4027879", "container headers");
}

fn test_should_encode_floats_exactly() {
    let w = writer();
    write_float(w, 1.5);
    write_float32(w, 1.5);
    let b = finish(w);
    assert(hexof(b) == "cb3ff8000000000000ca3fc00000", "floats " + hexof(b));
    let r = reader(b);
    assert((read_float(r) ?? 0.0) == 1.5 && (read_float(r) ?? 0.0) == 1.5, "floats back");
}

fn test_should_round_trip_timestamps_in_all_three_forms() {
    let cases = [[1700000000, 0], [1700000000, 123456789], [-5, 7]];
    let lens = [6, 10, 15];
    for i in 0..3 {
        let w = writer();
        write_timestamp(w, cases[i][0], cases[i][1]);
        let b = finish(w);
        assert(len(b) == lens[i], "timestamp form " + to_str(i) + " length " + to_str(len(b)));
        let tr = read_timestamp(reader(b));
        guard let t = tr else let e = err_of(tr) { panic(e); }
        assert(t.secs == cases[i][0] && t.nanos == cases[i][1], "timestamp " + to_str(i));
    }
}

fn test_should_round_trip_a_value_tree() {
    let inner = map_value([str_value("k"), int_value(-7)], [array_value([nil_value(), bool_value(true)]), bin_value(b"\x00\x01")]);
    let v = array_value([inner, float_value(2.25), str_value("héllo"), int_value(300)]);
    let b = encode(v);
    let back = decode(b);
    guard let t = back else let e = err_of(back) { panic(e); }
    assert(encode(t) == b, "re-encoding differs");
    let got = get(t.items[0], "k");
    guard let g = got else { panic("key lost"); }
    assert(g.kind == K_ARRAY && g.items[1].b, "nested value");
    assert(t.items[2].s == "héllo", "utf-8 string");
}

fn test_should_skip_nested_values() {
    let w = writer();
    write_map(w, 2);
    write_str(w, "skip");
    write_value(w, array_value([map_value([int_value(1)], [str_value("x")]), bin_value(b"abc")]));
    write_str(w, "keep");
    write_int(w, 99);
    let r = reader(finish(w));
    assert((read_map(r) ?? 0) == 2, "map");
    assert((read_str(r) ?? "") == "skip", "first key");
    if let _s = skip(r) { } else { panic("skip failed"); }
    assert((read_str(r) ?? "") == "keep" && (read_int(r) ?? 0) == 99, "after skip");
    assert(remaining(r) == 0 && peek(r) == K_END, "end");
}

fn test_should_refuse_hostile_and_broken_input() {
    // an array of 4 billion elements in 5 bytes
    let huge = decode(b"\xdd\xff\xff\xff\xff");
    assert(strings.contains(err_of(huge), "longer than the input"), "huge count: " + err_of(huge));
    let deep = builder_repeat(b"\x91", 600) + b"\xc0";
    assert(strings.contains(err_of(decode(deep)), "nested too deeply"), "depth");
    assert(strings.contains(err_of(decode(b"\xa5ab")), "longer than the input"), "short str");
    assert(strings.contains(err_of(decode(b"\xcd\x01")), "truncated"), "short int");
    assert(strings.contains(err_of(decode(b"\x01\x02")), "after the value"), "trailing");
    assert(strings.contains(err_of(decode(b"\xc1")), "0xc1"), "never used byte");
    assert(strings.contains(err_of(decode(b"")), "end of input"), "empty");
}

fn builder_repeat(b: bytes, n: int) -> bytes {
    let out = b"";
    for _ in 0..n { out = out + b; }
    return out;
}
