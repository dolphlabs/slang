// Tier 1: bytes type — literals, builtins, conversions, iteration

let a = b"hello";
println(len(a));                    // 5
println(a[1]);                      // 101 ('e')

// binary safety: embedded NULs survive
let z = b"a\0b\x00!";
println(len(z));                    // 5

// concatenation
let s = b"foo" + b"bar";
println(len(s));                    // 6
println(s == b"foobar");            // true
println(s != b"foobaz");            // true

// slicing (start inclusive, end exclusive; either end optional)
println(a[0..2] == b"he");          // true
println(a[..2] == b"he");           // true
println(a[3..] == b"lo");           // true
println(a[..] == a);                // true

// str <-> bytes
println(to_str(a));                 // hello
println(to_bytes("abc") == b"abc"); // true
println(len(to_bytes("")));         // 0

// int -> bytes LE/BE helpers and back
let le = to_le(258);                // 0x0102 little-endian
println(le[0]);                     // 2
println(le[1]);                     // 1
println(from_le(to_le(123456789))); // 123456789
println(from_be(to_be(305419896))); // 305419896

// mutation through index assignment
let m = b"cat";
m[0] = 98;                          // 'b'
println(to_str(m));                 // bat

// iteration yields integer byte values
for byte in b"AB" {
    println(byte);                  // 65, 66
}

// raw printing of binary data (no escaping)
print(b"xy");
println(b"");