// spawn through a function VALUE, not just a named function.
//
// The trampoline only ever needed the target's SIGNATURE -- it used the
// name to recover it. A fn type carries the signature in full, so a
// spawn shape can be keyed on the type instead and the target can
// travel in the args struct. One trampoline serves every value of a
// given fn type.

fn work(id: int, out: chan[int]) {
    chan_send(out, id * 10);
}

fn square(x: int) -> int { return x * x; }
fn negate(x: int) -> int { return 0 - x; }

gc struct Job {
    run: fn(int, chan[int]),
}

let out: chan[int] = make_chan(16);

// through a plain variable
let w: fn(int, chan[int]) = work;
spawn w(1, out);

// through a struct field
let j = Job { run: work };
spawn j.run(2, out);

// as an EXPRESSION, yielding join[T]
let f: fn(int) -> int = square;
let h = spawn f(7);
let r = join_wait(h);
guard let v = r else let e = err_of(r) {
    println("FAIL: " + e);
    exit(1);
}
println(v);

// two values of the SAME fn type share one trampoline; two different
// targets must still run the right code
let g: fn(int) -> int = negate;
let h2 = spawn g(7);
let r2 = join_wait(h2);
guard let v2 = r2 else let e2 = err_of(r2) {
    println("FAIL: " + e2);
    exit(1);
}
println(v2);

let a = chan_recv(out) ?? -1;
let b = chan_recv(out) ?? -1;
println(a + b);

// A spawned value's args struct holds GC pointers that the collector
// must still trace -- and a function pointer that it must NOT, because
// that address names code and was never allocated. Enough concurrent
// tasks with live str arguments to force real collections while they
// are in flight.
fn tag(s: str, out: chan[int]) {
    chan_send(out, len(s));
}

let t: fn(str, chan[int]) = tag;
let sink: chan[int] = make_chan(64);
for i in 0..200 {
    spawn t("abcdefghij", sink);
}
let total = 0;
for i in 0..200 {
    total = total + (chan_recv(sink) ?? 0);
}
println(total);
println("done");
