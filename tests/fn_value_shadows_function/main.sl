// A parameter holding a function value, named like a top-level function:
// the call goes through the parameter. The liveness pass used to look the
// name up as the top-level function, and with more arguments than that
// function has it read past its parameter list (slangc crashed).

gc struct Box { items: [str] }

fn h(x: str) -> str {
    return "top-level h: " + x;
}

fn add4(a: int, b: int, c: int, d: int) -> int {
    return a + b + c + d;
}

fn tag(b: Box, s: str, n: int, more: [str]) -> int {
    push(b.items, s + to_str(n));
    for m in more {
        push(b.items, m);
    }
    return len(b.items);
}

fn run(h: fn(int, int, int, int) -> int, a: int) -> int {
    return h(a, 2, 3, 4);
}

// GC-holding arguments through the shadowing value, each made by a call
// that can collect, so their roots matter.
fn fill(h: fn(Box, str, int, [str]) -> int, b: Box) -> int {
    let n = 0;
    let i = 0;
    while i < 200 {
        n = h(b, "item " + to_str(i), i * 2, ["x" + to_str(i), "y" + to_str(i)]);
        i = i + 1;
    }
    return n;
}

println(run(add4, 1));
println(h("still callable"));
let b = Box { items: [] };
println(fill(tag, b));
println(b.items[0] + " " + b.items[599]);
