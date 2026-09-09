fn ck(name: str, got: int, want: int) -> int {
    if got != want {
        println("FAIL " + name + ": got " + to_str(got) + " want " + to_str(want));
        return 1;
    }
    return 0;
}

let fails = 0;

// ---- the operators themselves ----------------------------------
fails = fails + ck("and", 12 & 10, 8);
fails = fails + ck("or", 12 | 10, 14);
fails = fails + ck("xor", 12 ^ 10, 6);
fails = fails + ck("shl", 1 << 10, 1024);
fails = fails + ck("shr", 1024 >> 3, 128);
fails = fails + ck("not", ~0, -1);
fails = fails + ck("not5", ~5, -6);
fails = fails + ck("and-zero", 255 & 0, 0);
fails = fails + ck("xor-self", 12345 ^ 12345, 0);
fails = fails + ck("shl-zero", 7 << 0, 7);
fails = fails + ck("shr-zero", 7 >> 0, 7);

// ---- precedence, matching C exactly ----------------------------
// | looser than ^ looser than & looser than == looser than shifts
fails = fails + ck("prec-or-xor-and", 1 | 2 ^ 3 & 4, 3);
fails = fails + ck("prec-shift-add", 1 << 2 + 1, 8);      // 1 << 3
fails = fails + ck("prec-paren", (1 << 4) - 1, 15);
// C's precedence puts == tighter than &, so `1 & 3 == 3` means
// `1 & (3 == 3)`. C accepts that silently because bool is an int; slang
// makes it a type error instead ("'&' requires integer operands"), which
// turns one of C's best-known footguns into a compile failure. Write the
// parens you meant:
if (1 & 3) != 1 {
    println("FAIL prec-and-eq-parens");
    fails = fails + 1;
}
fails = fails + ck("prec-mixed", 2 + 3 << 1, 10);          // (2+3) << 1
fails = fails + ck("prec-unary-not", ~0 & 255, 255);

// ---- hex, binary and digit separators --------------------------
fails = fails + ck("hex", 0xff, 255);
fails = fails + ck("hex-upper", 0xFF, 255);
fails = fails + ck("hex-wide", 0x7fffffff, 2147483647);
fails = fails + ck("binary", 0b1010, 10);
fails = fails + ck("sep-dec", 1_000_000, 1000000);
fails = fails + ck("sep-hex", 0xff_ff, 65535);
fails = fails + ck("sep-bin", 0b1010_1010, 170);

// ---- signed vs unsigned right shift ----------------------------
// int is signed, so >> keeps the sign (arithmetic shift), same as C.
fails = fails + ck("shr-signed", -8 >> 1, -4);
fails = fails + ck("shr-signed-neg1", -1 >> 20, -1);
// on an unsigned type the same bits shift in as zeroes (logical shift).
// Written in hex deliberately: a DECIMAL literal above i64's range is
// clamped by the lexer's strtoll, so 0xffff_ffff_ffff_ffff is the only
// way to say "all ones" today.
let u: u64 = 0xffff_ffff_ffff_ffff as u64;
if (u >> 60) as int != 15 {
    println("FAIL shr-unsigned");
    fails = fails + 1;
}

// ---- widths: shift count does not widen the value --------------
let small = 0xff as u8;
fails = fails + ck("u8-and", (small & 0x0f) as int, 15);
// u8 << 4 wraps within u8 rather than promoting to int
fails = fails + ck("u8-shl-wraps", ((small << 4) as u8) as int, 240);

// ---- the case this was built for: an HTTP/2 frame header -------
let f = b"\x00\x40\x10\x01\x05\x80\x00\x00\x07";
let flen = (f[0] << 16) | (f[1] << 8) | f[2];
let ftype = f[3];
let fflags = f[4];
let sid = ((f[5] & 0x7f) << 24) | (f[6] << 16) | (f[7] << 8) | f[8];
fails = fails + ck("h2-length", flen, 16400);
fails = fails + ck("h2-type", ftype, 1);
fails = fails + ck("h2-flags", fflags, 5);
fails = fails + ck("h2-stream-id", sid, 7);   // reserved high bit masked off
fails = fails + ck("h2-end-stream", fflags & 0x01, 1);
fails = fails + ck("h2-end-headers", fflags & 0x04, 4);
fails = fails + ck("h2-padded", fflags & 0x08, 0);

// ---- round-tripping a value through shifts ---------------------
let v = 0xdeadbeef;
let b0 = (v >> 24) & 0xff;
let b1 = (v >> 16) & 0xff;
let b2 = (v >> 8) & 0xff;
let b3 = v & 0xff;
fails = fails + ck("split-b0", b0, 222);
fails = fails + ck("split-b3", b3, 239);
fails = fails + ck("rejoin", (b0 << 24) | (b1 << 16) | (b2 << 8) | b3, 0xdeadbeef);

// ---- variable shift counts still work in range -----------------
let acc = 0;
for i in 0..8 {
    acc = acc | (1 << i);
}
fails = fails + ck("loop-mask", acc, 255);

if fails == 0 {
    println("all bitwise checks passed");
} else {
    println("FAILURES: " + to_str(fails));
    exit(1);
}
