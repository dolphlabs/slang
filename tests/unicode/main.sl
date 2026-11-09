// unicode: UTF-8 checks, code points, case folding and normalisation,
// end to end through the native package. The full conformance data
// (NormalizationTest.txt, CaseFolding.txt) runs in
// tests/runtime/test_unicode; this pins the slang-facing behaviour.

import "unicode";

// Combining marks are invisible in source, so strings that hold them are
// spelled as UTF-8 bytes. U+0301 combining acute is CC 81.
fn u(b: bytes) -> str {
    return to_str(b);
}

// ---- validity and counting --------------------------------------------
println(unicode.valid("café 😀"));                 // true
println(unicode.valid(to_str(b"a\xC0\xAF")));       // false: overlong '/'
println(unicode.valid(to_str(b"\xED\xA0\x80")));    // false: a surrogate
println(unicode.valid(to_str(b"\xF4\x90\x80\x80"))); // false: past U+10FFFF
println(unicode.valid(""));                         // true
println(unicode.valid_bytes(b"\xE2\x82\xAC"));      // true: €
println(unicode.valid_bytes(b"\xE2\x82"));          // false: cut short
println(len("café 😀"));                            // 10 bytes
println(unicode.count("café 😀"));                  // 6 characters
println(unicode.count(""));                         // 0
println(unicode.count(to_str(b"a\xF1\x80\x80\xE1\x80\xC2b"))); // 5

// ---- code points ------------------------------------------------------
let rs = unicode.runes("aé😀");
println(len(rs));                                   // 3
println(rs[0]);                                     // 97
println(rs[1]);                                     // 233
println(rs[2]);                                     // 128512
println(unicode.runes(to_str(b"\xFF"))[0]);         // 65533: U+FFFD
println(unicode.encode(233) ?? "none");             // é
println(unicode.encode(0x1F600) ?? "none");         // 😀
println(unicode.encode(0xD800) ?? "none");          // none: surrogate
println(unicode.encode(0x110000) ?? "none");        // none
println(unicode.encode(-1) ?? "none");              // none
println(unicode.encode(0) ?? "none");               // none: str is NUL-terminated

// ---- truncate never splits a character ---------------------------------
println(unicode.truncate("héllo wörld", 7));        // héllo w
println(unicode.truncate("😀😀😀", 2));             // 😀😀
println(unicode.truncate("short", 10));             // short
println(unicode.truncate("abc", 0) == "");          // true
println(unicode.truncate("abc", -3) == "");         // true

// ---- case folding ------------------------------------------------------
println(unicode.fold("HeLLo"));                     // hello
println(unicode.fold("Straße"));                    // strasse: full folding
println(unicode.fold("ΣΊΣΥΦΟΣ"));                   // σίσυφοσ
println(unicode.fold("İ") == u(b"i\xCC\x87"));   // true: i + U+0307
println(unicode.equal_fold("STRASSE", "straße"));   // true
println(unicode.equal_fold("Hello", "hELLO"));      // true
println(unicode.equal_fold("Hello", "Help"));       // false
println(unicode.equal_fold("Hello", "Hello!"));     // false
// Canonical caseless match: composed and decomposed é, any case.
println(unicode.equal_fold("CAFÉ", u(b"cafe\xCC\x81"))); // true
println(unicode.equal_fold("ǅ", u(b"\xC7\x86")));     // true: U+01C5, U+01C6
// The first NFD of D145 matters: U+0345 (class 240) folds to iota, a
// starter, so the marks must be put in order before folding. alpha +
// U+0345 + U+0301 and alpha + U+0301 + U+0345 are the same text.
println(unicode.equal_fold(u(b"\xCE\xB1\xCD\x85\xCC\x81"),
                           u(b"\xCE\xB1\xCC\x81\xCD\x85")));   // true
// Canonical, not compatibility: the ligature and the letters d + ž are
// different text until NFKC, which this package does not do.
println(unicode.equal_fold("ǅ", "dž"));               // false

// ---- normalisation -----------------------------------------------------
let composed = "café";
let decomposed = u(b"cafe\xCC\x81");
println(composed == decomposed);                    // false: different bytes
println(unicode.nfc(decomposed) == composed);       // true
println(unicode.nfd(composed) == decomposed);       // true
println(unicode.is_nfc(composed));                  // true
println(unicode.is_nfc(decomposed));                // false
println(len(unicode.nfc(decomposed)));              // 5
println(len(unicode.nfd(composed)));                // 6
// Marks are reordered by combining class: dot below (220) before dot
// above (230), whatever order they arrived in.
println(unicode.nfd(u(b"q\xCC\x87\xCC\xA3")) == u(b"q\xCC\xA3\xCC\x87")); // true
println(unicode.nfc(u(b"q\xCC\x87\xCC\xA3")) == u(b"q\xCC\xA3\xCC\x87")); // true
// Hangul composes arithmetically.
println(unicode.nfc(u(b"\xE1\x84\x80\xE1\x85\xA1\xE1\x86\xA8"))); // 각
println(len(unicode.nfd("각")));                    // 9: three jamo
// Singletons never come back: Ohm sign becomes Omega.
println(unicode.nfc(u(b"\xE2\x84\xA6")) == u(b"\xCE\xA9")); // true: U+2126 to U+03A9
// Invalid input comes out repaired.
println(unicode.nfc(u(b"a\xFFb")) == "a�b");       // true: U+FFFD
println(unicode.is_nfc(to_str(b"a\xFFb")));         // false

// ---- results kept across many collections ------------------------------
// Every transform's result is a fresh GC str (encode's is an opt holding
// one). Keep thousands alive while the nursery cycles, then check them:
// run under SLANG_GC_VERIFY_MINOR with a 16 KB nursery in run_tests.sh.
let kept: [str] = [];
let codes: [[int]] = [];
for i in 0..3000 {
    push(kept, unicode.nfc(decomposed));
    push(kept, unicode.nfd(composed));
    push(kept, unicode.fold("ÉCOLE Straße"));
    push(kept, unicode.truncate("héllo wörld", 4));
    push(kept, unicode.encode(0x1F600 + i % 16) ?? "");
    push(codes, unicode.runes("añ😀"));
}
let intact = true;
for i in 0..3000 {
    let b = i * 5;
    if kept[b] != composed || kept[b + 1] != decomposed { intact = false; }
    if kept[b + 2] != "école strasse" || kept[b + 3] != "héll" { intact = false; }
    if (unicode.runes(kept[b + 4])[0]) != 0x1F600 + i % 16 { intact = false; }
    let c = codes[i];
    if len(c) != 3 || c[0] != 97 || c[1] != 241 || c[2] != 128512 { intact = false; }
}
println(intact);                                    // true
