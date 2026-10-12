// builder.Bytes makes its 512-byte chunk on the first short write, not
// in new_bytes(), and take() hands back a lone piece without a copy.
// This walks every path that has to make the chunk, crosses the chunk
// boundary, and checks that no result aliases what the builder keeps.
//
// ALLOC_BUDGET_N=N is the allocation-budget mode tests/run_tests.sh
// drives under SLANG_GC_STAT: N rounds of new_bytes, one long write and
// take. 8 allocations a round when the chunk was built eagerly and take
// always joined; 5 now.

import "builder";
import "proc";
import "strings";

fn check(name: str, got: bytes, want: bytes) {
    if len(got) != len(want) {
        println("FAIL " + name + ": length " + to_str(len(got)) + ", want " +
                to_str(len(want)));
        exit(1);
    }
    let i = 0;
    while i < len(want) {
        if got[i] != want[i] {
            println("FAIL " + name + " at " + to_str(i));
            exit(1);
        }
        i = i + 1;
    }
}

let budget_n = to_int(proc.getenv("ALLOC_BUDGET_N") ?? "") ?? -1;
if budget_n >= 0 {
    let piece = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    let k = 0;
    let total = 0;
    while k < budget_n {
        let bb = builder.new_bytes();
        bb.write_str(piece);
        total = total + len(bb.take());
        k = k + 1;
    }
    println(to_str(total));
    exit(0);
}

// empty: nothing written, finish and take both empty
let e = builder.new_bytes();
check("empty finish", e.finish(), b"");
check("empty take", e.take(), b"");

// a byte first: write_byte must make the chunk
let a = builder.new_bytes();
a.write_byte(65);
a.write(b"BC");
a.write_str("de");
check("byte first", a.finish(), b"ABCde");
check("finish twice", a.finish(), b"ABCde");

// across the 512-byte chunk: 600 single bytes, then short writes
let big = builder.new_bytes();
let i = 0;
while i < 600 {
    big.write_byte(97 + i % 26);
    i = i + 1;
}
big.write_str("-tail");
let expect = "";
i = 0;
while i < 600 {
    expect = expect + strings.slice("abcdefghijklmnopqrstuvwxyz", i % 26, i % 26 + 1);
    i = i + 1;
}
expect = expect + "-tail";
check("across chunk", big.finish(), to_bytes(expect));

// take() of a single long piece is the piece itself; mutating it must
// not reach the builder, which is reset and reused
let long_s = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
let t = builder.new_bytes();
t.write_str(long_s);
let got = t.take();
check("take one piece", got, to_bytes(long_s));
got[0] = 88;
t.write_str("again");
check("reused after take", t.take(), b"again");

// take() of several pieces joins them
let m = builder.new_bytes();
m.write(b"short");
m.write_str(long_s);
m.write(b"end");
check("take many pieces", m.take(), to_bytes("short" + long_s + "end"));

// finish() of a single piece is a copy: mutating it does not change
// the next finish
let f = builder.new_bytes();
f.write_str(long_s);
let r1 = f.finish();
r1[0] = 88;
check("finish copies", f.finish(), to_bytes(long_s));

println("ok");
