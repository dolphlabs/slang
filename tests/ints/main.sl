// Tier 1: fixed-width integers & f32 — widths, widening, casts, printing

// literal fitting: an integer literal may initialize any width it fits
let w: i8 = 127;
let n: i8 = -128;
let u: u8 = 255;
let s16: i16 = -32768;
let big32: i32 = 2147483647;
let big64: i64 = 9007199254740993;
println(w);        // 127
println(n);        // -128
println(u);        // 255
println(s16);      // -32768
println(big32);    // 2147483647
println(big64);    // 9007199254740993

// implicit widening within the int family (function signatures)
fn widen(a: i32, b: i64) -> i64 {
    a + b          // i32 widens to i64 implicitly
}
println(widen(2000000000, 1));   // 2000000001

fn mix(a: u8, b: i64) -> i64 {
    a + b          // unsigned widens into signed wider type
}
println(mix(200, 1000));         // 1200

// explicit-only narrowing via 'as'
let over: i8 = 300 as i8;        // wraps: 300 - 256 = 44
println(over);                   // 44

// wrap semantics on cast (unsigned)
println((0 as u8) - (1 as u8));  // 255

// truncation toward zero on float -> int cast
println(3.9 as i32);             // 3
println((-3.9) as i32);          // -3

// f32 and float arithmetic
let f: f32 = 1.5;
println(f * 2.0);                // 3 (f32 promotes to double with float)

// mixed-width comparison
let a: i32 = 1000;
let b: i64 = 999;
println(a > b);                  // true

// string interpolation across all widths
let ui: u64 = 9223372036854775807;   // i64 max fits u64 too
let ff: f32 = 2.5;
println("w=${w} u=${u} ff=${ff} ui=${ui}");