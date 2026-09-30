// Compiler diagnostics for agents and editors: every function's first
// error in one compile, each naming its file, with a fix where one is
// likely (tests/run_tests.sh compares the whole of stderr, and --json).
struct Point { x: int, y: int }

fn area(p: Point) -> int {
    return p.x * p.yy;
}

fn greet(name: str) {
    printn("hi " + name);
}

fn total(xs: [int]) -> int {
    let sum = 0;
    for x in xs { sum += x; }
    return summ;
}

let p = Point { x: 1, y: 2 };
println(area(p));
