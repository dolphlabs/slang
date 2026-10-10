import "encoding";

fn expect_f64(raw: bytes, want: float) {
    let r = encoding.float64_from_le(raw);
    guard let got = r else let e = err_of(r) {
        panic(e);
    }
    assert(got == want, "decoded float differs");
}

fn test_float64_little_endian_vectors() {
    let one = encoding.float64_to_le(1.0);
    assert(len(one) == 8);
    assert(one[0] == 0 && one[1] == 0 && one[2] == 0 && one[3] == 0);
    assert(one[4] == 0 && one[5] == 0 && one[6] == 240 && one[7] == 63);
    expect_f64(one, 1.0);

    let pi = encoding.float64_to_le(3.141592653589793);
    assert(pi[0] == 24 && pi[1] == 45 && pi[2] == 68 && pi[3] == 84);
    assert(pi[4] == 251 && pi[5] == 33 && pi[6] == 9 && pi[7] == 64);
    expect_f64(pi, 3.141592653589793);
}

fn test_float64_preserves_signed_zero() {
    let negative_zero = encoding.float64_to_le(-0.0);
    assert(negative_zero[7] == 128, "negative-zero sign bit was lost");
    let r = encoding.float64_from_le(negative_zero);
    guard let decoded = r else let e = err_of(r) {
        panic(e);
    }
    let round_trip = encoding.float64_to_le(decoded);
    assert(round_trip[7] == 128, "negative zero did not round-trip");
}

fn test_float64_preserves_non_finite_bits() {
    let quiet_nan = b"\x01\x00\x00\x00\x00\x00\xf8\x7f";
    let r = encoding.float64_from_le(quiet_nan);
    guard let decoded = r else let e = err_of(r) {
        panic(e);
    }
    let round_trip = encoding.float64_to_le(decoded);
    let i = 0;
    while i < 8 {
        assert(round_trip[i] == quiet_nan[i], "NaN payload changed");
        i = i + 1;
    }

    let negative_infinity = b"\x00\x00\x00\x00\x00\x00\xf0\xff";
    let ir = encoding.float64_from_le(negative_infinity);
    guard let inf = ir else let e = err_of(ir) {
        panic(e);
    }
    let infinity_round_trip = encoding.float64_to_le(inf);
    let j = 0;
    while j < 8 {
        assert(infinity_round_trip[j] == negative_infinity[j],
               "infinity bits changed");
        j = j + 1;
    }
}

fn expect_bad_float64(raw: bytes) {
    let r = encoding.float64_from_le(raw);
    guard let _value = r else let e = err_of(r) {
        assert(e == "encoding.float64_from_le: expected exactly 8 bytes", e);
        return;
    }
    panic("float64_from_le accepted a byte slice that was not 8 bytes");
}

fn test_float64_rejects_wrong_byte_lengths() {
    expect_bad_float64(b"");
    expect_bad_float64(b"1234567");
    expect_bad_float64(b"123456789");
}

test_float64_little_endian_vectors();
test_float64_preserves_signed_zero();
test_float64_preserves_non_finite_bits();
test_float64_rejects_wrong_byte_lengths();
println("done");
