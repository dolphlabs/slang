// An opt is held by value ({ has, v }), never boxed: its pointer is rooted
// and traced through it. Each place an opt can live is exercised with a
// payload that holds GC pointers -- locals across calls, list/map slots,
// gc struct fields (a linked list through opt[Self]), value struct fields,
// opt[opt[T]], opt[result[...]] and result[opt[...]], spawn arguments,
// channel receives and select -- written, collected over, then read back.
// Runs under the GC stress lists and the minor verifier.

gc struct Item {
    name: str,
    parts: [str],
}

gc struct Chain {
    item: Item,
    next: opt[Chain],
}

struct Cell {
    label: str,
    item: opt[Item],
}

fn mk(i: int) -> opt[Item] {
    if i % 3 == 0 {
        return none;
    }
    return some(Item { name: "i" + to_str(i), parts: ["p" + to_str(i), "q" + to_str(i)] });
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

fn show(o: opt[Item]) -> str {
    guard let it = o else { return "none"; }
    return it.name + ":" + it.parts[1];
}

fn want(got: str, expected: str, what: str) {
    if got != expected {
        println("FAIL " + what + ": got " + got + ", want " + expected);
        exit(1);
    }
}

fn spawned(o: opt[Item], tag: opt[str]) -> str {
    churn();
    return show(o) + "/" + (tag ?? "-");
}

fn sender(ch: chan[opt[Item]]) {
    for i in 0..5 {
        churn();
        chan_send(ch, mk(i));
    }
    chan_close(ch);
}

let a = mk(1);
let b = mk(3);
churn();
want(show(a), "i1:q1", "local some");
want(show(b), "none", "local none");

let list: [opt[Item]] = [];
for i in 0..30 { push(list, mk(i)); }
churn();
for i in 0..30 {
    let expect = "i" + to_str(i) + ":q" + to_str(i);
    if i % 3 == 0 { expect = "none"; }
    want(show(list[i]), expect, "list slot " + to_str(i));
}
let m: map[int]opt[Item] = {};
for i in 0..20 { m[i] = mk(i); }
churn();
want(show(m[7]), "i7:q7", "map value");
want(show(m[9]), "none", "map none");

// a linked list through gc struct fields
let head = Chain { item: Item { name: "h", parts: [] }, next: none };
let tail = head;
for i in 1..40 {
    let next = Chain { item: Item { name: "n" + to_str(i), parts: [to_str(i)] }, next: none };
    tail.next = some(next);
    tail = next;
    churn();
}
let count = 0;
let cur: opt[Chain] = some(head);
while true {
    guard let c = cur else { break; }
    count = count + 1;
    cur = c.next;
}
want(to_str(count), "40", "linked list through opt[Self]");

let cell = Cell { label: "c", item: mk(4) };
churn();
want(show(cell.item), "i4:q4", "opt in a value struct");

let deep: opt[opt[Item]] = some(mk(5));
churn();
guard let lvl = deep else { want("none", "some", "nested opt"); exit(1); }
want(show(lvl), "i5:q5", "nested opt");
let or: opt[result[str, str]] = some(ok("r" + to_str(churn())));
churn();
guard let inner = or else { want("none", "some", "opt of result"); exit(1); }
want(inner ?? "x", "r1600", "opt of result");
let ro: result[opt[Item], str] = ok(mk(7));
churn();
guard let ri = ro else { want("err", "ok", "result of opt"); exit(1); }
want(show(ri), "i7:q7", "result of opt");
want(show(some(mk(9) ?? Item { name: "fb" + to_str(churn()), parts: ["a", "b"] })), "fb1600:b", "?? fallback");

let h = spawn spawned(mk(8), some("tag"));
let jr = join_wait(h);
guard let joined = jr else let je = err_of(jr) { want(je, "ok", "join"); exit(1); }
want(joined, "i8:q8/tag", "spawned with opt arguments");

let ch: chan[opt[Item]] = make_chan(2);
spawn sender(ch);
let seen = "";
while true {
    let got = chan_recv(ch);
    churn();
    guard let o = got else { break; }
    seen = seen + show(o) + ";";
}
want(seen, "none;i1:q1;i2:q2;none;i4:q4;", "channel of opts");
let sch: chan[Item] = make_chan(1);
chan_send(sch, Item { name: "s", parts: ["x", "y"] });
select {
    case let v = chan_recv(sch) {
        churn();
        want(show(v), "s:y", "select receive");
    }
}
println("value opts ok");
