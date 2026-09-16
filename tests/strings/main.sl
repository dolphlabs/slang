// strings: search, trim, case, split and join on `str`.
//
// Native rather than a slang source package because `str` supports len,
// + and == and nothing else -- it cannot be indexed or sliced -- so
// none of this could be written in slang without a bytes round trip on
// every call. byteutil covers the bytes side; this covers str directly.
//
// Indices are BYTE offsets and the case operations are ASCII-only. That
// is a deliberate limit, not an oversight: doing better means a Unicode
// table and a normalisation policy.

import "strings";

// ---- search ----------------------------------------------------------
println(strings.find("hello world", "world"));   // 6
println(strings.find("hello", "zzz"));           // -1
println(strings.find("hello", ""));              // 0 -- empty is at 0
println(strings.rfind("a/b/c", "/"));            // 3, not 1
println(strings.rfind("a/b/c", "z"));            // -1
println(strings.contains("hello", "ell"));
println(strings.has_prefix("hello", "he"));
println(strings.has_prefix("he", "hello"));      // longer prefix: false
println(strings.has_suffix("hello", "lo"));
println(strings.count("a,b,c", ","));            // 2
println(strings.count("aaa", "aa"));             // 1 -- non-overlapping

// ---- trim ------------------------------------------------------------
println("[" + strings.trim("  hi \r\n") + "]");
println("[" + strings.trim_start("  hi  ") + "]");
println("[" + strings.trim_end("  hi  ") + "]");
println("[" + strings.trim("      ") + "]");

// ---- case ------------------------------------------------------------
println(strings.to_upper("hello, World 42!"));
println(strings.to_lower("HELLO, World 42!"));

// ---- shaping ---------------------------------------------------------
println(strings.slice("hello", 1, 3));           // el
println(strings.slice("hello", -3, 5));          // llo -- negative counts back
println(strings.slice("hello", 99, 200));        // "" -- clamps, never panics
println(strings.slice("hello", 3, 1));           // "" -- end before start
println(strings.repeat("ab", 3));
println("[" + strings.repeat("ab", 0) + "]");
println(strings.replace("a,b,c", ",", " | "));
println(strings.replace("aaa", "a", ""));        // ""
println(strings.replace("abc", "zz", "!"));      // unchanged

// ---- split / join ----------------------------------------------------
// Inverses: adjacent separators produce empty elements, so the count is
// always count(s, sep) + 1 and a round trip is lossless.
let parts = strings.split("a,b,,c", ",");
println(len(parts));                             // 4
println(strings.join(parts, ","));               // a,b,,c -- round trip
println(strings.join(parts, "-"));
println(len(strings.split("nosep", ",")));       // 1
println(len(strings.split("", ",")));            // 1 -- one empty element
println(strings.join(strings.split("x/y/z", "/"), "."));
println(len(strings.split("abc", "")));          // 3 -- single bytes
let empty: [str] = [];
println("[" + strings.join(empty, ",") + "]");

// the shape a config parser actually wants
let cfg = "  host = example.com  ";
let kv = strings.split(strings.trim(cfg), "=");
println(strings.trim(kv[0]) + "/" + strings.trim(kv[1]));
println("done");
