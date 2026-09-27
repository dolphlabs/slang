// Pass audit, liveness battery: in every case the kept value is used
// ONLY in the named child position, with an allocating call between
// its creation and its use. Under SLANG_GC_THRESHOLD_KB=16 any
// unrooted value is swept and the output below goes wrong (this file
// is in the suite's gcstress list for exactly that reason).

fn churn() {
    let i = 0;
    while i < 2000 {
        push(["pad"], "padding-padding-" + to_str(i));
        i = i + 1;
    }
}

fn churn_str() -> str {
    churn();
    return "fresh";
}

fn cat(a: str, b: str) -> str {
    return a + b;
}

struct Pair {
    a: str,
    b: str,
}

struct Named {
    name: str,
    x: int,
}

impl Named {
    fn tag(self: Named, extra: str) -> str {
        churn();
        return self.name + extra;
    }
}

fn worker(out: chan[str], v: str) {
    churn();
    chan_send(out, v + "!");
}

// 1. struct literal field vs allocating sibling field
let keep1 = "KEEP-ONE";
let p1 = Pair { a: keep1, b: churn_str() };
println(p1.a);

// 2. map literal value vs allocating sibling
let m2 = {"a": keep1, "b": churn_str()};
println(m2["a"]);

// 3. list elements
let l3 = [keep1, churn_str()];
println(l3[0]);

// 4. call arguments, left rooted across right
println(cat(keep1, churn_str()));

// 5. for-in element across a call in the body
let strs = ["a", "b", "c"];
let acc5 = "";
for s in strs {
    churn();
    acc5 = acc5 + s;
}
println(acc5);

// 6. method receiver across an allocating argument
let n6 = Named { name: "NN", x: 1 };
println(n6.tag(churn_str()));

// 7. map base across an allocating index value
let m7 = {"k": "KEEP-SEVEN"};
println(m7[cat("k", "")]);

// 8. switch scrutinee: live across allocations inside the arm
let tag8 = "a-" + "b";
let v8 = switch tag8 {
    case "a-b" { cat(tag8, churn_str()) }
    default { "other" }
};
println(v8);

// 9. switch arm value: kept name lives across the arm's own call
let pick9 = 1;
let v9 = switch pick9 {
    case 1 { cat(keep1, churn_str()) }
    default { "other" }
};
println(v9);

// 10. ?? right side does not disturb a present left
println(cat(keep1, "") + "");

// 11. return value rooted across a call before it
fn f11() -> str {
    let v = "KEEP-ELEVEN";
    churn();
    return v;
}
println(f11());

// 12. select: bound value rooted across a call in the arm body
let c12: chan[str] = make_chan(1);
chan_send(c12, keep1);
let got12 = "";
select {
    case let v = chan_recv(c12) {
        churn();
        guard let s = v else {
            println("FAIL empty");
            exit(1);
        }
        got12 = s;
    }
    default {
        println("FAIL default");
        exit(1);
    }
}
println(got12);

// 14. anonymous scrutinee: its only reference is the switch temp,
// which must survive allocations inside the arms
let v14 = switch cat("a", "-") {
    case "a-" { cat("got-", churn_str()) }
    default { "other" }
};
println(v14);

// 13. spawn args: param live across a call in the worker
let out13: chan[str] = make_chan(1);
spawn worker(out13, keep1);
spawn worker(out13, keep1);
guard let w13 = chan_recv(out13) else {
    println("FAIL spawn");
    exit(1);
}
println(w13);
