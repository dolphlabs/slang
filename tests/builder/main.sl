// builder: assembling text and bytes in linear time.
import "builder";
import "strings";

fn check(name: str, ok: bool) {
    if !ok {
        println("FAIL " + name);
        exit(1);
    }
}

// ---- Str ---------------------------------------------------------

let s = builder.new_str();
check("str empty", s.finish() == "");
check("str empty size", s.size() == 0);
check("str is_empty", s.is_empty());

s.write("hello").write(", ").write("world");
check("str chain", s.finish() == "hello, world");
check("str size", s.size() == 12);
check("str not empty", !s.is_empty());

// finish does not consume: it can be asked again, and more can follow
check("str finish twice", s.finish() == s.finish());
s.write("!");
check("str write after finish", s.finish() == "hello, world!");

s.write("").write("");
check("str empty writes", s.size() == 13);

let n = builder.new_str();
n.write_int(42).write(" ").write_int(-7).write(" ").write_int(0);
check("str ints", n.finish() == "42 -7 0");

let l = builder.new_str();
l.write_line("a").write_line("b");
check("str lines", l.finish() == "a\nb\n");

// size counts BYTES: an accented letter is two
let u = builder.new_str();
u.write("caf").write("é");
check("str utf8 size", u.size() == 5);
check("str utf8 value", u.finish() == "café");

let t = builder.new_str();
t.write("one").write("two");
let taken = t.take();
check("str take value", taken == "onetwo");
check("str take resets", t.finish() == "" && t.size() == 0);
t.write("again");
check("str after take", t.finish() == "again");

let r = builder.new_str();
r.write("x");
r.reset();
check("str reset", r.finish() == "" && r.is_empty());

// many pieces
let m = builder.new_str();
let i = 0;
while i < 5000 {
    m.write("ab");
    i = i + 1;
}
check("str many size", m.size() == 10000);
check("str many len", len(m.finish()) == 10000);
println("str ok");

// ---- Bytes: single bytes ------------------------------------------

fn bytes_of(n: int) -> bytes {
    let b = builder.new_bytes();
    let k = 0;
    while k < n {
        b.write_byte(k % 251);
        k = k + 1;
    }
    return b.finish();
}

fn expect_run(name: str, n: int) {
    let got = bytes_of(n);
    check(name + " length", len(got) == n);
    let k = 0;
    while k < n {
        if got[k] != k % 251 {
            println("FAIL " + name + " byte " + to_str(k));
            exit(1);
        }
        k = k + 1;
    }
}

// on either side of the 512-byte chunk, and past several chunks
expect_run("bytes 0", 0);
expect_run("bytes 1", 1);
expect_run("bytes 511", 511);
expect_run("bytes 512", 512);
expect_run("bytes 513", 513);
expect_run("bytes 1024", 1024);
expect_run("bytes 1500", 1500);
expect_run("bytes 10000", 10000);
println("bytes single ok");

// ---- Bytes: order across every kind of write -----------------------

let mix = builder.new_bytes();
mix.write_byte(65);                       // A       (chunk)
mix.write(b"BC");                         // short   (chunk)
mix.write_str("DE");                      // short   (chunk)
let big = to_bytes(strings_repeat("x", 100));   // longer than the inline limit
mix.write(big);                           // its own piece
mix.write_byte(90);                       // Z       (chunk again)
mix.write_str(strings_repeat("y", 100));  // long str: its own piece
mix.write_byte(33);                       // !
let got = mix.finish();
check("mix size", mix.size() == 1 + 2 + 2 + 100 + 1 + 100 + 1);
check("mix length", len(got) == mix.size());
check("mix head", to_str(got[0..5]) == "ABCDE");
check("mix big", to_str(got[5..105]) == strings_repeat("x", 100));
check("mix Z", got[105] == 90);
check("mix y", to_str(got[106..206]) == strings_repeat("y", 100));
check("mix tail", got[206] == 33);
println("bytes mix ok");

// a short write that does not fit the rest of the chunk must not be
// split, dropped or reordered
let edge = builder.new_bytes();
let z = 0;
while z < 500 {
    edge.write_byte(48);
    z = z + 1;
}
edge.write(to_bytes(strings_repeat("q", 40)));    // 500 + 40 > 512
edge.write_byte(49);
let eg = edge.finish();
check("edge length", len(eg) == 541);
check("edge zeros", eg[499] == 48 && eg[500] == 113 && eg[539] == 113);
check("edge last", eg[540] == 49);
println("bytes edge ok");

// binary safety: NUL and 0xff survive, and so do CR and LF
let bin = builder.new_bytes();
bin.write_byte(0).write_byte(255).write_byte(13).write_byte(10);
let bg = bin.finish();
check("bin len", len(bg) == 4);
check("bin bytes", bg[0] == 0 && bg[1] == 255 && bg[2] == 13 && bg[3] == 10);

// the builder keeps a COPY: changing the caller's bytes afterwards must
// not rewrite what was already written, for a short write and a long one
let src = to_bytes("abcd");
let al = builder.new_bytes();
al.write(src);
src[0] = 90;
let long_src = to_bytes(strings_repeat("m", 200));
al.write(long_src);
long_src[0] = 90;
let ag = al.finish();
check("alias short", ag[0] == 97);
check("alias long", ag[4] == 109);
println("bytes alias ok");

// finish is repeatable and writes continue after it, including a
// finish that lands exactly on a chunk boundary
let rep = builder.new_bytes();
let q = 0;
while q < 512 {
    rep.write_byte(7);
    q = q + 1;
}
let first = rep.finish();
check("rep first", len(first) == 512);
rep.write_byte(8);
let second = rep.finish();
check("rep second", len(second) == 513 && second[512] == 8 && second[0] == 7);
check("rep again", len(rep.finish()) == 513);

let tk = builder.new_bytes();
tk.write_str("take me");
let out = tk.take();
check("take value", to_str(out) == "take me");
check("take reset", tk.size() == 0 && len(tk.finish()) == 0);
tk.write_str("more");
check("after take", to_str(tk.finish()) == "more");

let e = builder.new_bytes();
check("empty finish", len(e.finish()) == 0 && e.is_empty());
e.write(b"").write_str("");
check("empty writes", e.size() == 0);
println("bytes ok");

// ---- scale: this many pieces used to be minutes -------------------

let big_b = builder.new_bytes();
let w = 0;
while w < 200000 {
    big_b.write_byte(97 + (w % 26));
    w = w + 1;
}
let bigger = big_b.finish();
check("scale len", len(bigger) == 200000);
check("scale content", bigger[0] == 97 && bigger[199999] == 97 + (199999 % 26));
println("scale ok");

// bytes_zero: one allocation for zeroed bytes, no throwaway str
let bz = strings.bytes_zero(16);
check("bytes_zero len", len(bz) == 16);
check("bytes_zero zeroed", bz[0] == 0 && bz[15] == 0);
let bzn = strings.bytes_zero(-5);
check("bytes_zero negative", len(bzn) == 0);
println("bytes_zero ok");

// helper used above; the repeat lives in strings, but this file only
// needs the builder to be imported, so it is spelled out here
fn strings_repeat(s: str, n: int) -> str {

    let b = builder.new_str();
    let k = 0;
    while k < n {
        b.write(s);
        k = k + 1;
    }
    return b.finish();
}
