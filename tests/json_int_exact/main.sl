// json.decode into an integer type decodes the number's text exactly.
// It used to go through a double, which is exact only up to 2^53:
// 9007199254740993 -- an ordinary 64-bit id -- came back as
// 9007199254740992, and 1.0000000000000000001 was accepted as 1.
import "json";

gc struct IntV { v: int }
gc struct I64V { v: i64 }
gc struct U64V { v: u64 }
gc struct I8V { v: i8 }
gc struct U8V { v: u8 }
gc struct F64V { v: float }
gc struct Ids { id: int, parent: int }

fn int_case(text: str) {
    let r: result[IntV, str] = json.decode("{\"v\":" + text + "}");
    guard let x = r else let e = err_of(r) {
        println("int " + text + " -> err: " + e);
        return;
    }
    println("int " + text + " -> " + to_str(x.v));
}

fn i64_case(text: str) {
    let r: result[I64V, str] = json.decode("{\"v\":" + text + "}");
    guard let x = r else let e = err_of(r) {
        println("i64 " + text + " -> err: " + e);
        return;
    }
    println("i64 " + text + " -> " + to_str(x.v));
}

fn u64_case(text: str) {
    let r: result[U64V, str] = json.decode("{\"v\":" + text + "}");
    guard let x = r else let e = err_of(r) {
        println("u64 " + text + " -> err: " + e);
        return;
    }
    println("u64 " + text + " -> " + to_str(x.v));
}

fn i8_case(text: str) {
    let r: result[I8V, str] = json.decode("{\"v\":" + text + "}");
    guard let x = r else let e = err_of(r) {
        println("i8 " + text + " -> err: " + e);
        return;
    }
    println("i8 " + text + " -> " + to_str(x.v));
}

fn u8_case(text: str) {
    let r: result[U8V, str] = json.decode("{\"v\":" + text + "}");
    guard let x = r else let e = err_of(r) {
        println("u8 " + text + " -> err: " + e);
        return;
    }
    println("u8 " + text + " -> " + to_str(x.v));
}

// the case that started this: a 64-bit id one past 2^53
int_case("9007199254740993");
i64_case("9007199254740993");
u64_case("9007199254740993");
int_case("-9007199254740993");

// exact boundaries, and one past each
int_case("9223372036854775807");
int_case("-9223372036854775808");
int_case("9223372036854775808");
int_case("-9223372036854775809");
u64_case("18446744073709551615");
u64_case("18446744073709551616");
i8_case("127");
i8_case("128");
i8_case("-128");
i8_case("-129");
u8_case("255");
u8_case("256");

// exponent and fraction forms that ARE whole numbers
int_case("1e3");
int_case("5.0");
int_case("1.5e1");
int_case("12345678900000000000e-10");
int_case("-0");
int_case("-0.0");
int_case("0e999999999");
u64_case("-0");

// ...and ones that are not, including one a double rounds to a whole
int_case("1.5");
int_case("1e-1");
int_case("12345678901234567890e-10");
int_case("1.0000000000000000001");

// magnitudes no integer holds
int_case("1e19");
int_case("1e999999999");
u64_case("-1");

// the edges of the one-pass integer path (at most 18 digits, no '.',
// 'e' or 'E' after them): each must decode exactly as the two-pass path
// that handles everything else does
int_case("999999999999999999");
int_case("-999999999999999999");
int_case("1000000000000000000");
int_case("-1000000000000000000");
u64_case("999999999999999999");
u64_case("9999999999999999999");
int_case("0");
int_case("7");
int_case(" \t\n 42");
int_case("00");
int_case("01");
int_case("-01");
int_case("-");
int_case("--1");
int_case("+1");
int_case("1E2");
int_case("0e0");
int_case("0.");
int_case("1x");
i8_case("-0");
u8_case("-0");

// floats are unchanged: they still go through the double
let fr: result[F64V, str] = json.decode("{\"v\":1.5}");
guard let f = fr else { println("BUG: float decode"); exit(1); }
println("f64 1.5 -> " + to_str(f.v));

// and a round trip keeps a large id intact
let enc = json.encode(Ids { id: 9007199254740993, parent: -9223372036854775807 });
println(enc);
let back: result[Ids, str] = json.decode(enc);
guard let ids = back else { println("BUG: round trip"); exit(1); }
println(to_str(ids.id) + " " + to_str(ids.parent));
