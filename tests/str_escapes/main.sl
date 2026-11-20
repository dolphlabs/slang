// \xHH and \u escapes in str and bytes literals. \x is one raw byte; \uXXXX
// (JSON's four digits) and \u{H..H} are a code point written as UTF-8.

fn hex(s: str) -> str {
    let digits = "0123456789abcdef";
    let b = to_bytes(s);
    let d = to_bytes(digits);
    let out = "";
    for i in 0..len(b) {
        let v = b[i];
        out = out + to_str(d[v / 16..v / 16 + 1]) + to_str(d[v % 16..v % 16 + 1]);
    }
    return out;
}

println(hex("\x1b[32m"));
println(hex("\u001b[0m"));
println(hex("\x41\x7a"));
println(hex("\u00e9 \u{e9}"));
println(hex("\u20ac\u{1F600}"));
println(hex("\u{10FFFF}"));
// a hex digit right after \x1b stays its own character in the C output
println(hex("\x1b1"));
println(hex("\xff\xfe"));
println("caf\u{e9} \u2713");
println(len(to_bytes("\u{1F600}")));
println("\x41\u0042\u{43} == ABC: " + to_str("\x41\u0042\u{43}" == "ABC"));
println(len(b"\x1b\u{1F600}"));
println(to_str(b"\u00e9") == "\u00e9");
