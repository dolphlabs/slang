// A move on a path that cannot reach a later use does not make that use
// an error: the branch returns, exits, continues, or calls a function
// that never returns. These used to be "use of moved value".
struct P { x: int }

fn take(p: own P) -> int {
    return p.x;
}

fn mk(x: int) -> own P {
    return P { x: x };
}

fn die(msg: str) {
    println(msg);
    exit(0);
}

fn early(ok: bool) -> int {
    let c = mk(1);
    if !ok {
        take(c);
        return 0;
    }
    return take(c) + 10;
}

fn either(n: int) -> int {
    let c = mk(2);
    if n == 0 {
        return take(c);
    } else if n == 1 {
        take(c);
        return -1;
    }
    return take(c) * 100;
}

fn per_iteration(n: int) -> int {
    let sum = 0;
    for i in 0..n {
        let c = mk(i);
        if i % 2 == 0 {
            sum += take(c);
            continue;
        }
        sum += take(c) * 10;
    }
    return sum;
}

fn in_while(n: int) -> int {
    let c = mk(3);
    let i = 0;
    while i < n {
        if i == 5 {
            return take(c);
        }
        i += 1;
    }
    return take(c) + 1000;
}

fn switched(k: int) -> int {
    let c = mk(4);
    switch k {
        case 1 {
            take(c);
            return 1;
        }
        default {
        }
    }
    return take(c);
}

fn guarded(o: opt[int]) -> int {
    let c = mk(5);
    guard let v = o else {
        take(c);
        return -5;
    }
    return v + take(c);
}

fn fatal_path(bad: bool) -> int {
    let c = mk(6);
    if bad {
        take(c);
        die("unreachable");
    }
    return take(c);
}

fn if_let(o: opt[int]) -> int {
    let c = mk(7);
    if let v = o {
        take(c);
        return v;
    }
    return take(c);
}

println(early(true));
println(early(false));
println(either(0));
println(either(1));
println(either(2));
println(per_iteration(4));
println(in_while(10));
println(in_while(2));
println(switched(1));
println(switched(2));
println(guarded(some(1)));
println(guarded(none));
println(fatal_path(false));
println(if_let(some(9)));
println(if_let(none));
