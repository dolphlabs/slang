// The callee expression is a use: naming a value that was already moved is
// an error, exactly as it is anywhere else.
struct Holder {
    cbs: [fn(int) -> int],
}

fn double(n: int) -> int { return n * 2; }

fn take(h: own Holder) -> int {
    return len(h.cbs);
}

let h: own Holder = Holder { cbs: [double] };
println(take(h));
println(h.cbs[0](4));
