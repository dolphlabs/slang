// A call through a function value whose callee is an EXPRESSION:
//   fns[i](x)        an element         pick(0)(x)     a call's result
//   h.cbs[0](x)      a field's element  (f)(x)         parenthesised
//
// The callee was invisible to every analysis pass, and the worst of it was
// liveness: a list of functions whose only later use is as a callee looked
// dead at its last VISIBLE use, so it was not rooted across the allocations
// in between and a collection freed it before the call read it. That crashed
// at the default GC threshold -- any dispatch table used only as
// `handlers[name](req)` was at risk.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(cond: bool, what: str) {
    if !cond {
        die(what);
    }
}

fn double(n: int) -> int { return n * 2; }
fn triple(n: int) -> int { return n * 3; }
fn plus1(n: int) -> int { return n + 1; }

// Allocates a lot and keeps it: forces collections, and memory freed by one
// is reused by the next allocation.
fn churn() -> int {
    let junk: [[int]] = [];
    let i = 0;
    while i < 300 {
        let row: [int] = [];
        let j = 0;
        while j < 20 {
            push(row, i + j);
            j = j + 1;
        }
        push(junk, row);
        i = i + 1;
    }
    return len(junk);
}

// ---- the crash -----------------------------------------------------------

fn list_only_as_callee() -> int {
    let fns: [fn(int) -> int] = [double, triple, plus1];
    churn();
    churn();
    return fns[1](10);       // fns' only later use is this callee
}

fn map_only_as_callee() -> int {
    let by_name: map[str]fn(int) -> int = {};
    by_name["double"] = double;
    by_name["triple"] = triple;
    churn();
    return by_name["triple"](7);
}

struct Holder {
    cbs: [fn(int) -> int],
    tag: str,
}

fn field_only_as_callee() -> int {
    let h = Holder { cbs: [plus1, double], tag: "h" };
    churn();
    return h.cbs[1](21);
}

fn crash() {
    let bad = 0;
    let n = 0;
    while n < 100 {
        if list_only_as_callee() != 30 { bad = bad + 1; }
        if map_only_as_callee() != 21 { bad = bad + 1; }
        if field_only_as_callee() != 42 { bad = bad + 1; }
        n = n + 1;
    }
    expect(bad == 0, "a container used only as a callee was freed early");
    println("ok callee kept alive");
}

// ---- spawn through a callee expression --------------------------------------
// The README documents `spawn handlers[i](job);`, and it had the same
// blind spot: the spawn carries its own copy of the call, and the callee in
// it was never visited either.

fn send_double(ch: chan[int], n: int) { chan_send(ch, n * 2); }
fn send_triple(ch: chan[int], n: int) { chan_send(ch, n * 3); }

fn spawn_via_callee() {
    let ch: chan[int] = make_chan(64);
    let i = 0;
    while i < 20 {
        // `hs` is used only as the spawn's callee
        let hs: [fn(chan[int], int)] = [send_double, send_triple];
        churn();
        spawn hs[1](ch, 7);
        i = i + 1;
    }
    let total = 0;
    let k = 0;
    while k < 20 {
        total = total + (chan_recv(ch) ?? 0);
        k = k + 1;
    }
    expect(total == 20 * 21, "spawn through a callee expression");
    println("ok spawn");
}

// ---- evaluation order -------------------------------------------------------

fn pick(which: int) -> fn(int) -> int {
    println("callee " + to_str(which));
    if which == 0 {
        return double;
    }
    return triple;
}

fn arg(n: int) -> int {
    println("arg " + to_str(n));
    return n;
}

fn ordering() {
    // the callee expression runs before the arguments, which run left to
    // right -- C leaves this unspecified, so it is made explicit
    println(pick(0)(arg(5)));
    println(pick(1)(arg(6)));

    let fns: [fn(int) -> int] = [double, triple];
    println(fns[1](arg(7)));

    let f = double;
    println((f)(arg(8)));
    println("ok ordering");
}

// ---- other shapes ---------------------------------------------------------

fn add(a: int, b: int) -> int { return a + b; }

fn make_adder() -> fn(int, int) -> int { return add; }

fn choose(flag: bool) -> fn() -> fn(int) -> int {
    if flag {
        return fn_double;
    }
    return fn_triple;
}

fn fn_double() -> fn(int) -> int { return double; }
fn fn_triple() -> fn(int) -> int { return triple; }

fn shapes() {
    expect(make_adder()(3, 4) == 7, "call result, two arguments");
    // a callee that is itself a call through a callee
    expect(choose(true)()(5) == 10, "nested callee");
    expect(choose(false)()(5) == 15, "nested callee 2");

    let fns: [fn(int) -> int] = [double, triple];
    let total = 0;
    for i in 0..2 {
        total = total + fns[i](10);
    }
    expect(total == 50, "index by a loop variable");
    println("ok shapes");
}

// ---- an own value passed through a callee call ------------------------------

struct Point {
    x: int,
    y: int,
}

fn eat(p: own Point) -> fn(int) -> int {
    return double;
}

fn ownership() {
    // `a` is moved into the call INSIDE the callee. If that drop flag were
    // left set, both the callee and this function would free it.
    let total = 0;
    let i = 0;
    while i < 100000 {
        let a: own Point = Point { x: 1, y: 2 };
        total = total + eat(a)(i);
        i = i + 1;
    }
    expect(total == 2 * 4999950000, "own through a callee");
    println("ok ownership");
}

// ---- guard let / err_of: the callee is part of "the same expression" -----------

fn parse_a(s: str) -> result[int, str] { return err("a: " + s); }
fn parse_b(s: str) -> result[int, str] { return err("b: " + s); }

fn guarded() {
    let ps: [fn(str) -> result[int, str]] = [parse_a, parse_b];
    guard let v = ps[1]("x") else let e = err_of(ps[1]("x")) {
        expect(e == "b: x", "err_of names the same callee");
        println("ok guard");
        return;
    }
    die("guard should have failed");
}

crash();
spawn_via_callee();
ordering();
shapes();
ownership();
guarded();
