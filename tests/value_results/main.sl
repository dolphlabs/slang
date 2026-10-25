// A result is held by value (a C struct), never boxed: its pointers are
// rooted and traced through it. Every place a result can live is
// exercised here with payloads that hold GC pointers -- a local across
// calls, list/map slots, gc struct fields, opt payloads, nested results,
// spawn arguments, channel slots and select -- each written, then
// collected over, then read back. Runs under the GC stress lists and the
// minor verifier, where a pointer reached only through an untraced or
// unrooted result shows up as missed or as a wrong value.

gc struct Node {
    name: str,
    tags: [str],
}

struct Pair {
    left: str,
    right: result[Node, str],
}

gc struct Box {
    r: result[[str], str],
    o: opt[result[str, int]],
    p: Pair,
}

fn mk(i: int) -> result[Node, str] {
    if i % 3 == 0 {
        return err("bad " + to_str(i));
    }
    return ok(Node { name: "n" + to_str(i), tags: ["t" + to_str(i), "u" + to_str(i)] });
}

fn churn() -> int {
    let n = 0;
    for i in 0..200 {
        let xs: [str] = [];
        for j in 0..8 {
            push(xs, "c" + to_str(i) + "." + to_str(j));
        }
        n = n + len(xs);
    }
    return n;
}

fn name_of(r: result[Node, str]) -> str {
    if let n = r {
        return n.name + ":" + n.tags[1];
    } else let e = err_of(r) {
        return "E(" + e + ")";
    }
    return "";
}

fn want(got: str, expected: str, what: str) {
    if got != expected {
        println("FAIL " + what + ": got " + got + ", want " + expected);
        exit(1);
    }
}

fn spawned(r: result[Node, str], extra: result[str, str]) -> str {
    churn();
    return name_of(r) + "/" + (extra ?? "none");
}

fn sender(ch: chan[result[Node, str]]) {
    for i in 0..6 {
        churn();
        chan_send(ch, mk(i));
    }
    chan_close(ch);
}

// locals across collections
let a = mk(1);
let b = mk(3);
churn();
want(name_of(a), "n1:u1", "local ok");
want(name_of(b), "E(bad 3)", "local err");

// list and map slots
let list: [result[Node, str]] = [];
for i in 0..30 { push(list, mk(i)); }
churn();
for i in 0..30 {
    let expect = "n" + to_str(i) + ":u" + to_str(i);
    if i % 3 == 0 { expect = "E(bad " + to_str(i) + ")"; }
    want(name_of(list[i]), expect, "list slot " + to_str(i));
}
let m: map[str]result[Node, str] = {};
for i in 0..20 { m["k" + to_str(i)] = mk(i); }
churn();
want(name_of(m["k7"]), "n7:u7", "map value");
want(name_of(m["k9"]), "E(bad 9)", "map err value");

// gc struct fields, opt payloads, a result inside a value struct
let box = Box { r: ok(["x", "y"]), o: some(ok("inner")), p: Pair { left: "L", right: mk(4) } };
churn();
box.r = ok(["p" + to_str(churn()), "q"]);
churn();
guard let rs = box.r else { want("err", "ok", "struct field result"); exit(1); }
want(rs[1], "q", "struct field result");
guard let inner = box.o else { want("none", "some", "opt payload"); exit(1); }
want(inner ?? "x", "inner", "opt of result");
want(name_of(box.p.right), "n4:u4", "result in a value struct");

// nested results and ?? with an allocating fallback
let nested: result[result[str, str], str] = ok(ok("deep"));
churn();
guard let level = nested else { want("err", "ok", "nested"); exit(1); }
want(level ?? ("fallback " + to_str(churn())), "deep", "nested result");
let missing = mk(6);
want((missing ?? Node { name: "fb" + to_str(churn()), tags: ["a", "b"] }).name, "fb1600", "?? fallback");

// spawn arguments and join_wait
let h = spawn spawned(mk(5), ok("extra"));
let jr = join_wait(h);
guard let joined = jr else let je = err_of(jr) { want(je, "ok", "join"); exit(1); }
want(joined, "n5:u5/extra", "spawned with result arguments");

// channel slots and select
let ch: chan[result[Node, str]] = make_chan(2);
spawn sender(ch);
let seen = "";
while true {
    let got = chan_recv(ch);
    churn();
    guard let r = got else { break; }
    seen = seen + name_of(r) + ";";
}
want(seen, "E(bad 0);n1:u1;n2:u2;E(bad 3);n4:u4;n5:u5;", "channel of results");
let sch: chan[result[Node, str]] = make_chan(1);
chan_send(sch, mk(8));
select {
    case let v = chan_recv(sch) {
        churn();
        guard let r = v else { want("closed", "value", "select"); exit(1); }
        want(name_of(r), "n8:u8", "select on results");
    }
}
println("value results ok");
