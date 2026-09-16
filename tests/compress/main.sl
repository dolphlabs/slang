// compress: gzip, zlib and raw DEFLATE over zlib.
//
// Three containers around the same compressed bits. HTTP needs all
// three: `gzip` is what servers send, `zlib` is what the "deflate"
// content-coding is supposed to mean, and raw is what the servers that
// get it wrong send instead.
//
// Every decompressing call takes a MANDATORY max_out. The expansion
// ratio is unbounded: 65 KB of gzip can hold 64 MB of output, so a
// program decompressing anything it did not produce is one hostile
// input away from the OOM killer. The bomb case is at the bottom.

import "compress";
import "strings";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(got: str, want: str, what: str) {
    if got != want {
        die(what + ": got [" + got + "] want [" + want + "]");
    }
}

// Compressible on purpose: the round trips below assert on exact
// equality, and the ratio assertions need something that actually
// compresses.
let text = strings.repeat("the quick brown fox jumps over the lazy dog. ", 80);
let src = to_bytes(text);

// ---- gzip ------------------------------------------------------------

let gr = compress.gzip(src);
guard let gz = gr else let e = err_of(gr) { die("gzip: " + e); }
if len(gz) >= len(src) {
    die("gzip did not compress: " + to_str(len(gz)) + " vs " + to_str(len(src)));
}
println("gzip compresses");

let ur = compress.gunzip(gz, 1000000);
guard let back = ur else let e = err_of(ur) { die("gunzip: " + e); }
expect(to_str(back), text, "gzip round trip");

// Level 0 stores without compressing; level 9 is the smallest. Both are
// valid gzip and both must round-trip.
let l0 = compress.gzip_level(src, 0);
guard let g0 = l0 else let e = err_of(l0) { die("level 0: " + e); }
let l9 = compress.gzip_level(src, 9);
guard let g9 = l9 else let e = err_of(l9) { die("level 9: " + e); }
if len(g0) <= len(g9) {
    die("level 0 should be larger than level 9");
}
let r0 = compress.gunzip(g0, 1000000);
guard let b0 = r0 else let e = err_of(r0) { die("level 0 round trip: " + e); }
expect(to_str(b0), text, "level 0 round trip");
println("levels 0 and 9 both round-trip");

let bad_level = compress.gzip_level(src, 10);
guard let _bl = bad_level else let e = err_of(bad_level) { println(e); }

// ---- zlib and raw ----------------------------------------------------

let dr = compress.deflate(src);
guard let zl = dr else let e = err_of(dr) { die("deflate: " + e); }
let ir = compress.inflate(zl, 1000000);
guard let zb = ir else let e = err_of(ir) { die("inflate: " + e); }
expect(to_str(zb), text, "zlib round trip");

let rr = compress.deflate_raw(src);
guard let raw = rr else let e = err_of(rr) { die("deflate_raw: " + e); }
let rir = compress.inflate_raw(raw, 1000000);
guard let rb = rir else let e = err_of(rir) { die("inflate_raw: " + e); }
expect(to_str(rb), text, "raw round trip");

// Raw is the same bits with no header, so it is the smallest of the
// three, and gzip's header is larger than zlib's.
if len(raw) >= len(zl) || len(zl) >= len(gz) {
    die("expected raw < zlib < gzip: " + to_str(len(raw)) + " " +
        to_str(len(zl)) + " " + to_str(len(gz)));
}
println("raw < zlib < gzip, as their headers imply");

// The containers are NOT interchangeable, and each decoder says so
// rather than producing garbage.
let wrong1 = compress.gunzip(zl, 1000000);
guard let _w1 = wrong1 else { println("gunzip rejects zlib data"); }
let wrong2 = compress.inflate(gz, 1000000);
guard let _w2 = wrong2 else { println("inflate rejects gzip data"); }
let wrong3 = compress.inflate(raw, 1000000);
guard let _w3 = wrong3 else { println("inflate rejects raw data"); }

// ---- edges -----------------------------------------------------------

// Empty input compresses to a valid (header-only) stream that
// round-trips to empty.
let er = compress.gzip(b"");
guard let egz = er else let e = err_of(er) { die("gzip empty: " + e); }
let eur = compress.gunzip(egz, 1000);
guard let eb = eur else let e = err_of(eur) { die("gunzip empty: " + e); }
expect(to_str(len(eb)), "0", "empty round trip");

// Decompressing nothing is an error, not an empty result: a zero-byte
// body where a gzip stream was expected means the transfer failed.
let zr = compress.gunzip(b"", 1000);
guard let _z = zr else let e = err_of(zr) { println(e); }

// Corrupt and truncated input are refused.
let corrupt = compress.gunzip(b"not a gzip stream at all", 1000);
guard let _c = corrupt else { println("corrupt input rejected"); }
let trunc = compress.gunzip(gz[0..12], 1000000);
guard let _t = trunc else { println("truncated input rejected"); }

// The boundary: max_out exactly equal to the output size must SUCCEED.
// Off by one here would reject every response whose length the caller
// knew exactly.
let exact = compress.gunzip(gz, len(src));
guard let ex = exact else let e = err_of(exact) { die("exact limit: " + e); }
expect(to_str(len(ex)), to_str(len(src)), "max_out exactly equal to output");

// One byte under, and it is refused.
let tight = compress.gunzip(gz, len(src) - 1);
guard let _tt = tight else { println("max_out one byte short is refused"); }

// ---- the bomb --------------------------------------------------------
//
// 64 KiB of one repeated byte, which gzip squeezes to under 100. The
// limit is enforced before the allocation that would cross it, so the
// process never grows toward the expanded size. Measured separately at
// a larger scale to be sure that is real rather than merely stated: a
// 65,250-byte gzip of 64 MiB was refused at 3.9 MB peak RSS against a
// 0.86 MB baseline for the same program without the call.

let filler = to_bytes(strings.repeat("a", 65536));
let big = compress.gzip(filler);
guard let bgz = big else let e = err_of(big) { die("bomb build: " + e); }
if len(bgz) > 1000 {
    die("expected a repeated byte to compress hard, got " + to_str(len(bgz)));
}
let bomb = compress.gunzip(bgz, 1024);
guard let _b = bomb else let e = err_of(bomb) {
    if !strings.contains(e, "bomb") {
        die("the limit error should name the hazard: " + e);
    }
    println("expansion past max_out refused");
}

println("done");
