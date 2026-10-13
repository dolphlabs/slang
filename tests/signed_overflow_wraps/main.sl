// Signed arithmetic wraps two's-complement, so an overflow check written
// in slang works: the C compiler must not assume overflow cannot happen
// and delete it. The operands come from the environment so nothing is
// folded at compile time.
import "proc";

fn grows(x: int) -> bool {
    return x + 1 > x;
}

fn safe_add(a: int, b: int) -> int {
    let s = a + b;
    if b > 0 && s < a {
        return -1;
    }
    return s;
}

fn safe_mul(a: int, b: int) -> int {
    if a == 0 {
        return 0;
    }
    let p = a * b;
    if p / a != b {
        return -1;
    }
    return p;
}

fn count_down_to_wrap(start: i32) -> int {
    // stops when the value wraps negative: a loop the optimiser may not
    // turn into "forever"
    let x = start;
    let steps = 0;
    while x > 0 && steps < 100 {
        x = x + (1 as i32) * (1000000000 as i32);
        steps = steps + 1;
    }
    return steps;
}

let max = to_int(proc.getenv("SLANG_TEST_MAX") ?? "9223372036854775807") ?? 0;
let big = to_int(proc.getenv("SLANG_TEST_BIG") ?? "4294967296") ?? 0;
println(grows(max));
println(grows(max - 1));
println(safe_add(max, 1));
println(safe_add(max - 1, 1));
println(safe_mul(big, big));
println(safe_mul(big, 2));
println(max + 1);
println(count_down_to_wrap(1500000000 as i32));
