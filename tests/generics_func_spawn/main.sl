// `spawn` of a generic function. The call resolves from its arguments
// exactly as it would without the spawn -- by then it is one concrete
// instance with its own C symbol, which is all a trampoline ever needed.
//
// What this has to prove beyond "it runs": two instances of ONE generic
// function must not share a trampoline or an args struct, because the
// args struct IS their differing parameter types.
import "stash";
import "time";

fn twice[T](v: T) -> str {
    return to_str(v) + to_str(v);
}

struct Box[T] {
    v: T,
}

fn unbox[T](b: Box[T]) -> str {
    return to_str(b.v);
}

fn wait(h: join[str]) -> str {
    let r = join_wait(h);
    guard let v = r else {
        panic("spawned task failed");
    }
    return v;
}

// two different instantiations, both spawned, alive at the same time
let a = spawn twice(21);
let b = spawn twice("ab");
println(wait(a));
println(wait(b));

// a third, through a generic struct
let c = spawn unbox(Box[int] { v: 7 });
println(wait(c));

// cross-package, the qualified `pkg.func(...)` form
let d = spawn stash.labelled(1.5, "num");
println(wait(d));

// the same instance spawned twice DOES share one trampoline: this is
// here so that sharing keeps working, not only that separating does
let e = spawn twice(21);
let f = spawn twice(9);
println(wait(e));
println(wait(f));

// statement form, with a handle-free fire-and-forget target
let done: chan[int] = make_chan(1);
fn ping[T](v: T, ch: chan[int]) {
    chan_send(ch, 1);
}
spawn ping("x", done);
let got = chan_recv(done);
println(to_str(got ?? 0));

// A spawn inside ANOTHER generic function's body. The instance holding
// it is made from a top-level call, which happens after the body loop
// has finished -- so the shape it needs is discovered by the dry run's
// own second pass over late instances, not by the first.
fn relay[T](v: T, ch: chan[int]) {
    spawn ping(v, ch);
}

let relayed: chan[int] = make_chan(1);
relay(7, relayed);
let r2 = chan_recv(relayed);
println(to_str(r2 ?? 0));
