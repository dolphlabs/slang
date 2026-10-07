// A value struct that holds a str, carried inside an opt or a result, must
// keep that str alive: the opt or result is the only thing holding it. Each
// shape below is built, then enough garbage is made to run collections
// before it is read back.
import "strings";

struct Rec { name: str, n: int }
struct Outer { inner: Rec, tag: str }

fn mk(i: int) -> Rec { return Rec{name: strings.repeat("r", 20) + to_str(i), n: i}; }
fn rfault(i: int) -> result[Rec, fault] { return ok(mk(i)); }
fn router(i: int) -> result[Outer, str] {
    return ok(Outer{inner: mk(i), tag: strings.repeat("t", 12) + to_str(i)});
}
fn oouter(i: int) -> opt[Outer] {
    return some(Outer{inner: mk(i), tag: strings.repeat("t", 12) + to_str(i)});
}
fn rerr(i: int) -> result[int, str] { return err(strings.repeat("e", 16) + to_str(i)); }
fn churn(k: int) -> int {
    let t = 0;
    let i = 0;
    while i < k {
        let s = strings.repeat("x", 48) + to_str(i);
        t = t + len(s);
        i = i + 1;
    }
    return t;
}

let os: [opt[Rec]] = [];
let bad = 0;
let round = 0;
let w = strings.repeat("r", 20);
let wt = strings.repeat("t", 12);
while round < 50 {
    let a = rfault(round);
    let b = router(round + 100);
    let c = oouter(round + 200);
    let d = rerr(round + 300);
    let lst: [result[Rec, fault]] = [rfault(round + 400)];
    push(os, some(mk(round + 500)));
    let x = churn(4000);
    if let v = a { if v.name != w + to_str(round) { bad = bad + 1; } } else { bad = bad + 1; }
    if let v = b {
        if v.inner.name != w + to_str(round + 100) || v.tag != wt + to_str(round + 100) { bad = bad + 1; }
    } else { bad = bad + 1; }
    if let v = c {
        if v.inner.name != w + to_str(round + 200) || v.tag != wt + to_str(round + 200) { bad = bad + 1; }
    } else { bad = bad + 1; }
    if let v = d { bad = bad + 1; } else let e = err_of(d) {
        if e != strings.repeat("e", 16) + to_str(round + 300) { bad = bad + 1; }
    }
    if let v = lst[0] { if v.name != w + to_str(round + 400) { bad = bad + 1; } } else { bad = bad + 1; }
    round = round + 1;
}
let k = 0;
for o in os {
    if let v = o { if v.name != w + to_str(k + 500) { bad = bad + 1; } } else { bad = bad + 1; }
    k = k + 1;
}
println("bad: " + to_str(bad));
