// Functions for main.sl. The leaf rules beyond same-typed arithmetic: a shift by an int count, an
// untyped literal beside a fixed-width int, a scalar cast, a switch over
// constants, a scalar field of a gc struct (read or written), a
// package-level scalar constant, and a call to another leaf, up to four
// deep. run_tests.sh counts the brackets in the generated C: calls to the
// first group have none; the second group (recursion, a fifth level of
// leaf calls, a pointer stored in a gc struct (attach), a loop) keeps theirs. The
// loop at the end sums leaf calls with `+=`, which takes the leaf poll
// rather than a bracket per iteration.
import "strings";

gc struct State {
    a: u64,
    b: u64,
    next: opt[State],
}

let MASK = 255;
let SCALE = 0.5;
let SEED: u64 = 0x9e3779b97f4a7c15;

fn rotl(x: u64, k: int) -> u64 {
    return (x << k) | (x >> (64 - k));
}

fn mixed(x: u64) -> u64 {
    return x * 5 + 1;
}

fn half(n: u64) -> float {
    return (n >> 11) as float * SCALE;
}

fn table(i: int) -> float {
    return switch i & MASK {
        case 0 { 1.5 }
        case 1, 2 { 2.5 }
        default { 0.0 }
    };
}

fn step(s: State) -> u64 {
    let out = rotl(s.a * 5, 7) * 9;
    s.b = s.b ^ s.a;
    s.a = rotl(s.b, 45);
    return out;
}

// A method, list reads and writes, a u64 package constant beside a u64,
// and a leaf native (strings.hash): all leaves.
impl State {
    fn bump(self: State, k: u64) -> u64 {
        self.a = (self.a + k) ^ SEED;
        return self.a;
    }
}

fn peek(xs: [u8], i: int) -> int {
    return (xs[i] as int) + 1;
}

fn poke(xs: [u8], i: int, v: u8) {
    xs[i] = v;
    xs[i + 1] = 7;
}

fn keyed(s: str) -> int {
    return strings.hash(s) & 1023;
}

// Not leaves: a map index (its miss path reports the key) and a pointer
// stored into a list (a write barrier).
fn lookup(m: map[str]int, k: str) -> int {
    return m[k];
}

fn put_ptr(xs: [State], s: State) {
    xs[0] = s;
}

fn d1(x: int) -> int { return x + 1; }
fn d2(x: int) -> int { return d1(x) + 1; }
fn d3(x: int) -> int { return d2(x) + 1; }
fn d4(x: int) -> int { return d3(x) + 1; }
fn d5(x: int) -> int { return d4(x) + 1; }

fn fact(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * fact(n - 1);
}

fn attach(s: State, t: State) -> int {
    s.next = some(t);
    return 1;
}

fn spins(n: int) -> int {
    let i = 0;
    while i < n { i += 1; }
    return i;
}

fn sum_steps(s: State, n: int) -> u64 {
    let acc: u64 = 0;
    for i in 0..n {
        acc += step(s);
    }
    return acc;
}

// `tag` stays live across every call, so a call that is not a leaf needs a
// bracket to root it.
pub fn run(tag: str) -> str {
    let s = State { a: 0x9e3779b97f4a7c15, b: 7, next: none };
    let t = State { a: 1, b: 2, next: none };
    let r1 = rotl(3, 62);
    let r2 = mixed(10);
    let r3 = half((1 << 20) as u64);
    let r4 = table(2) + table(256) + table(9);
    let r5 = step(s);
    let r6 = d4(0);
    let r7 = d5(0);
    let r8 = fact(5);
    let r9 = attach(s, t);
    let r10 = spins(3);
    let r11 = sum_steps(s, 1000);
    let bytes8: [u8] = [1, 2, 3];
    poke(bytes8, 0, 9);
    let r12 = s.bump(3) % 1000 + (peek(bytes8, 1) as u64) + (keyed(tag) as u64 & 0);
    let m: map[str]int = {"k": 5};
    let ss: [State] = [t];
    put_ptr(ss, s);
    let r13 = lookup(m, "k") + (ss[0].b as int & 0);
    return tag + " " + to_str(r1) + " " + to_str(r2) + " " + to_str(r3) + " " +
           to_str(r4) + " " + to_str(r5) + " " + to_str(r6) + " " + to_str(r7) +
           " " + to_str(r8) + " " + to_str(r9) + " " + to_str(r10) + " " +
           to_str(r11 % 1000) + " " + to_str(r12) + " " + to_str(r13);
}

