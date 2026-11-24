gc struct ErrInfo {
    code: int,
    msg: str,
    tags: [str],
}

gc struct Counter {
    calls: int,
}

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn parse_pos(s: str) -> result[int, str] {
    guard let n = to_int(s) else |e| {
        return err("bad int: " + e);
    }
    if n <= 0 {
        return err("non-positive");
    }
    return ok(n);
}

fn sum_two(a: str, b: str) -> result[int, str] {
    // Multi-step chaining reusing `e`
    guard let x = parse_pos(a) else |e| {
        let wrapped = "first(" + e + ")";
        return err(wrapped);
    }
    guard let y = parse_pos(b) else |e| {
        let wrapped = "second(" + e + ")";
        return err(wrapped);
    }
    return ok(x + y);
}

fn shadow_err_name(r: result[int, str]) -> result[int, str] {
    guard let v = r else |v| {
        return err("shadow:" + v);
    }
    return ok(v + 1);
}

fn next_res(c: Counter, fail: bool) -> result[int, str] {
    c.calls += 1;
    if fail {
        return err("boom");
    }
    return ok(42);
}

fn make_gc_err(i: int, fail: bool) -> result[int, ErrInfo] {
    if fail {
        return err(ErrInfo {
            code: 100 + i,
            msg: "gc-" + to_str(i),
            tags: ["t0", "t" + to_str(i)],
        });
    }
    return ok(i);
}

fn test_basic_and_chaining() {
    guard let s1 = sum_two("10", "20") else |e| {
        die("sum_two ok failed: " + e);
    }
    println(s1);

    let r1 = sum_two("bad", "20");
    guard let _u1 = r1 else |e| {
        println(e);
        // Check legacy compatibility right alongside
        let r2 = sum_two("10", "0");
        guard let _u2 = r2 else let e2 = err_of(r2) {
            println(e2);
            return;
        }
        die("expected r2 err");
    }
    die("expected r1 err");
}

fn test_shadow_and_single_eval() {
    let s_ok = shadow_err_name(ok(9));
    guard let v1 = s_ok else |e| {
        die("shadow ok: " + e);
    }
    println(v1);

    let s_err = shadow_err_name(err("oops"));
    guard let _v2 = s_err else |e| {
        println(e);
        let c = Counter { calls: 0 };
        guard let g1 = next_res(c, false) else |e2| {
            die("next_res false: " + e2);
        }
        if g1 != 42 || c.calls != 1 {
            die("single eval ok failed");
        }
        guard let _g2 = next_res(c, true) else |e3| {
            if c.calls != 2 || e3 != "boom" {
                die("single eval err failed");
            }
            println("single_eval=2");
            return;
        }
        die("expected next_res err");
    }
    die("expected shadow err");
}

fn test_plain_opt_compat() {
    let o: opt[int] = some(5);
    guard let x = o else {
        die("opt failed");
    }
    println(x);
}

fn test_gc_struct_pressure() {
    let acc = 0;
    for i in 0..800 {
        guard let _v = make_gc_err(i, true) else |e| {
            let pad = ["p" + to_str(i), "q" + to_str(i), e.msg];
            if e.code != 100 + i || len(e.tags) != 2 || pad[2] != e.msg {
                die("gc struct corrupted");
            }
            acc += e.code;
            continue;
        }
        die("expected gc err");
    }
    println(acc);
}

test_basic_and_chaining();
test_shadow_and_single_eval();
test_plain_opt_compat();
test_gc_struct_pressure();
