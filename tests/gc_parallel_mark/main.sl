import "strings";

gc struct Node {
    val: int,
    tag: str,
}

fn churn(k: int) -> int {
    let total = 0;
    let i = 0;
    while i < k {
        let s = strings.repeat("x", 96) + to_str(i);
        total = total + len(s);
        i = i + 1;
    }
    return total;
}

let kept: [Node] = [];
let expected = 0;
let i = 0;
while i < 90000 {
    let t = "n" + to_str(i % 100);
    expected = expected + i + len(t);
    push(kept, Node { val: i, tag: t });
    i = i + 1;
}

let ws: [join[int]] = [];
let w = 0;
while w < 4 {
    push(ws, spawn churn(60000));
    w = w + 1;
}
for h in ws {
    let _r = join_wait(h);
}

let got = 0;
let idx = 0;
let bad = 0;
for n in kept {
    if n.val != idx || len(n.tag) < 2 {
        bad = bad + 1;
    }
    got = got + n.val + len(n.tag);
    idx = idx + 1;
}
if bad != 0 || got != expected {
    println("bad");
    exit(1);
}
println("ok");
