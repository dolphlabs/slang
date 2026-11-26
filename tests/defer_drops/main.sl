struct Boxed {
    n: int,
}

fn take_own(b: own Boxed) {
    println("own_n=" + to_str(b.n));
}

fn inspect_val(v: &Boxed) {
    println("val_n=" + to_str(v.n));
}

fn drop_owned_res(v: int) -> own Boxed {
    println("drop_owned_res=" + to_str(v));
    return Boxed { n: v };
}

fn test_arena_and_own_guard_fallthrough(r: result[int, str]) {
    let a = arena_new(256);
    let p = a.alloc(77);
    let v = *p;
    defer a.reset();

    guard let g = r else |e| {
        println("guard_err=" + e);
        return;
    }
    let a2 = arena_new(256);
    defer a2.reset();
    let q = a2.alloc(g + v);
    println("q=" + to_str(*q));

    let b: own Boxed = Boxed { n: g + 1 };
    defer take_own(b);

    let bv = Boxed { n: g + 2 };
    defer inspect_val(&bv);
}

fn test_nonvoid_own_return() {
    defer drop_owned_res(33);
    println("before_own_drop");
}

test_arena_and_own_guard_fallthrough(ok(23));
test_arena_and_own_guard_fallthrough(err("skip"));
test_nonvoid_own_return();
