import "strings";
import "time";

fn must(r: result[str, str]) -> str {
    guard let v = r else let e = err_of(r) {
        panic("unexpected error: " + e);
    }
    return v;
}

fn must_fail(r: result[str, str]) -> str {
    if let v = r {
        panic("expected an error, got " + v);
    }
    return err_of(r);
}

fn has_variant_rfc(id: str) -> bool {
    let c = strings.slice(id, 19, 20);
    return c == "8" || c == "9" || c == "a" || c == "b";
}

// ---- v4 ---------------------------------------------------------------

fn test_should_make_canonical_v4_with_version_and_variant() {
    for _ in 0..200 {
        let id = must(v4());
        assert(is_valid(id), "not canonical: " + id);
        assert(strings.slice(id, 14, 15) == "4", "version digit: " + id);
        assert(has_variant_rfc(id), "variant digit: " + id);
    }
}

fn test_should_make_distinct_v4() {
    let seen: map[str]bool = {};
    for _ in 0..2000 {
        let id = must(v4());
        assert(!has(seen, id), "repeated id " + id);
        seen[id] = true;
    }
}

// The variant digit carries two random bits. A generator that pins it
// (say's hand-rolled one always wrote 'a') loses them; across 200 ids all
// four values 8, 9, a and b appear with near certainty.
fn test_should_keep_random_bits_in_v4_variant_digit() {
    let digits: map[str]bool = {};
    for _ in 0..200 {
        digits[strings.slice(must(v4()), 19, 20)] = true;
    }
    assert(len(digits) == 4, "variant digits seen: " + to_str(len(digits)));
}

// ---- v7 ---------------------------------------------------------------

// RFC 9562 appendix A.6: unix ms 0x017F22E279B0 (2022-02-22 19:22:22 UTC).
fn test_should_stamp_v7_with_the_rfc_example_time() {
    let id = must(v7_at(1645557742000));
    assert(strings.slice(id, 0, 15) == "017f22e2-79b0-7", "got " + id);
    assert(has_variant_rfc(id), "variant digit: " + id);
    assert((time_ms(id) ?? -1) == 1645557742000, "time_ms of " + id);
    assert((version(id) ?? -1) == 7, "version of " + id);
}

fn test_should_sort_v7_by_time_as_strings() {
    let prev = must(v7_at(0));
    for ms in [1, 2, 999, 1000, 1645557742000, 281474976710655] {
        let id = must(v7_at(ms));
        assert(prev < id, prev + " should sort before " + id);
        prev = id;
    }
}

fn test_should_stamp_v7_with_the_wall_clock() {
    let before = time.wall() / 1000000;
    let id = must(v7());
    let after = time.wall() / 1000000;
    let ms = time_ms(id) ?? -1;
    assert(ms >= before && ms <= after,
           to_str(ms) + " not in " + to_str(before) + ".." + to_str(after));
}

fn test_should_accept_the_v7_time_range_ends() {
    assert(strings.slice(must(v7_at(0)), 0, 15) == "00000000-0000-7");
    assert(strings.slice(must(v7_at(281474976710655)), 0, 15) == "ffffffff-ffff-7");
}

fn test_should_reject_v7_time_outside_48_bits() {
    let e = must_fail(v7_at(-1));
    assert(strings.contains(e, "got -1"), e);
    e = must_fail(v7_at(281474976710656));
    assert(strings.contains(e, "0..281474976710655"), e);
}

// ---- is_valid ---------------------------------------------------------

fn test_should_accept_canonical_ids_of_any_version() {
    assert(is_valid(NIL));
    assert(is_valid(MAX));
    assert(is_valid("017f22e2-79b0-7cc3-98c4-dc0c0c07398f"));
    assert(is_valid("6ba7b810-9dad-11d1-80b4-00c04fd430c8"));   // v1
    assert(is_valid("123e4567-e89b-02d3-0456-426614174000"));   // no version
}

fn test_should_reject_non_canonical_spellings() {
    assert(!is_valid(""));
    assert(!is_valid("017F22E2-79B0-7CC3-98C4-DC0C0C07398F"), "upper case");
    assert(!is_valid("{017f22e2-79b0-7cc3-98c4-dc0c0c07398f}"), "braces");
    assert(!is_valid("017f22e279b07cc398c4dc0c0c07398f"), "no hyphens");
    assert(!is_valid("017f22e2-79b0-7cc3-98c4-dc0c0c07398"), "35 characters");
    assert(!is_valid("017f22e2-79b0-7cc3-98c4-dc0c0c07398f0"), "37 characters");
    assert(!is_valid("017f22e279-b0-7cc3-98c4-dc0c0c07398f"), "hyphen moved");
    assert(!is_valid("017f22e2-79b0-7cc3-98c4-dc0c0c07398g"), "g");
    assert(!is_valid("017f22e2-79b0-7cc3-98c4-dc0c0c0739é"), "non-ASCII");
}

// ---- parse ------------------------------------------------------------

fn test_should_parse_every_common_spelling_to_canonical() {
    let want = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f";
    assert(must(parse(want)) == want);
    assert(must(parse("017F22E2-79B0-7CC3-98C4-DC0C0C07398F")) == want);
    assert(must(parse("{017f22e2-79b0-7cc3-98c4-dc0c0c07398f}")) == want);
    assert(must(parse("urn:uuid:017f22e2-79b0-7cc3-98c4-dc0c0c07398f")) == want);
    assert(must(parse("URN:UUID:017F22E2-79B0-7CC3-98C4-DC0C0C07398F")) == want);
    assert(must(parse("017f22e279b07cc398c4dc0c0c07398f")) == want);
}

fn test_should_say_what_is_wrong_when_parse_fails() {
    let e = must_fail(parse("017f22e2-79b0-7cc3-98c4"));
    assert(strings.contains(e, "want 36 characters") && strings.contains(e, "got 23"), e);
    e = must_fail(parse("017f22e2-79b0-7cc3-98c4-dc0c0c07398g"));
    assert(strings.contains(e, "character 36 is 'g', not a hex digit"), e);
    e = must_fail(parse("017f22e2x79b0-7cc3-98c4-dc0c0c07398f"));
    assert(strings.contains(e, "want '-' at character 9, got 'x'"), e);
    e = must_fail(parse("(017f22e2-79b0-7cc3-98c4-dc0c0c07398f)"));
    assert(strings.contains(e, "in braces"), e);
    e = must_fail(parse("urn:uid::017f22e2-79b0-7cc3-98c4-dc0c0c07398f"));
    assert(strings.contains(e, "urn:uuid:"), e);
}

// Input is hostile: a control character is reported by value, so it never
// reaches a log line raw.
fn test_should_not_echo_control_characters_in_errors() {
    let e = must_fail(parse("017f22e2-79b0-7cc3-98c4-dc0c0c07398\n"));
    assert(strings.contains(e, "byte 10"), e);
    assert(!strings.contains(e, "\n"), e);
}

fn test_should_report_length_without_reading_long_input() {
    let long = strings.repeat("a", 1000000);
    let e = must_fail(parse(long));
    assert(strings.contains(e, "got 1000000"), e);
}

// ---- version, time_ms -------------------------------------------------

fn test_should_read_the_version_digit() {
    assert((version(must(v4())) ?? -1) == 4);
    assert((version(NIL) ?? -1) == 0);
    assert((version("6ba7b810-9dad-11d1-80b4-00c04fd430c8") ?? -1) == 1);
    assert((version("not a uuid") ?? -1) == -1);
}

fn test_should_give_no_time_for_ids_that_keep_none() {
    assert((time_ms(must(v4())) ?? -1) == -1, "v4");
    assert((time_ms("6ba7b810-9dad-11d1-80b4-00c04fd430c8") ?? -1) == -1, "v1");
    assert((time_ms("017f22e2-79b0-7cc3-08c4-dc0c0c07398f") ?? -1) == -1, "v7 digit, NCS variant");
    assert((time_ms("017F22E2-79B0-7CC3-98C4-DC0C0C07398F") ?? -1) == -1, "not canonical");
}

// ---- binary -----------------------------------------------------------

fn test_should_round_trip_the_16_byte_form() {
    let id = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f";
    let rb = to_binary(id);
    guard let b = rb else let e = err_of(rb) {
        panic(e);
    }
    assert(len(b) == 16);
    assert(b[0] == 0x01 && b[1] == 0x7f && b[6] == 0x7c && b[15] == 0x8f, inspect(b));
    assert(must(from_binary(b)) == id);
    for _ in 0..100 {
        let r = must(v4());
        let rr = to_binary(r);
        guard let raw = rr else {
            panic("to_binary failed");
        }
        assert(must(from_binary(raw)) == r);
    }
}

fn test_should_reject_binary_that_is_not_16_bytes() {
    let e = must_fail(from_binary(b"\x01\x02\x03"));
    assert(strings.contains(e, "want 16 bytes, got 3"), e);
}
