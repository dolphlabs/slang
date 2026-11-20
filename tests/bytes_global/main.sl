// A package-level bytes global used to be a C compile error: it was
// emitted as a static value where every use expects a pointer.
import "tables";

fn scrub(b: bytes) {
    b[1] = 75;
}

println(len(tables.MAGIC));
println(tables.MAGIC[0]);
println(to_str(tables.MAGIC[..2]));
println(tables.magic_ok(b"PK\x03\x04rest"));
println(tables.magic_ok(b"PX"));
println(len(tables.EMPTY));
println(tables.EMPTY == b"");
println(len(tables.BIN));
println(tables.BIN[1]);
println(tables.BIN[2]);
println(tables.hidden_len());

// one value: a write through any path is seen by every other
tables.stamp(81);
println(tables.MAGIC[0]);
scrub(tables.MAGIC);
println(to_str(tables.MAGIC[..2]));
tables.MAGIC[0] = 80;
println(tables.magic_ok(b"PK\x03\x04"));

// held from the heap across collections (not a GC object; marking skips it)
let held: [bytes] = [];
for i in 0..20000 {
    push(held, tables.MAGIC);
    let _junk = to_bytes("x" + to_str(i));
}
println(len(held));
println(held[19999] == tables.MAGIC);
