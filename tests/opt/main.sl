// Option and Result: construction, guard-let unwrapping, and the
// null-coalescing operator.

fn div10(n: int) -> opt[int] {
    if n % 10 == 0 {
        return some(n / 10);
    }
    return none;
}

fn parse_small(s: str) -> result[i32, str] {
    if s == "big" {
        return err("value too large");
    }
    if s == "seven" {
        return ok(7);
    }
    return err("unknown: " + s);
}

fn deep(n: int) -> opt[opt[int]] {
    if n == 0 {
        return none;
    }
    return some(some(n));
}

// guard let takes the else branch when the option is none
fn else_path_taken() -> bool {
    let b = div10(41);
    guard let bv = b else {
        return true;
    }
    return bv == 0;
}
println(else_path_taken());

// guard let binds the unwrapped value on the happy path
let a = div10(40);
guard let av = a else {
    println("unreachable");
    exit(1);
}
println(av);

// guard let over a Result: err takes the else branch
fn err_path() -> str {
    let r = parse_small("weird");
    guard let v = r else {
        return "rejected";
    }
    return to_str(v);
}
println(err_path());

fn ok_path() -> i32 {
    let r = parse_small("seven");
    guard let v = r else {
        return -1;
    }
    return v;
}
println(ok_path());

// ?? recovers from none / err with a fallback value
println(div10(40) ?? -1);
println(div10(41) ?? -1);
println(parse_small("seven") ?? -1);
println(parse_small("big") ?? -1);

// ?? chains (parenthesized) peel nested options
println((deep(5) ?? none) ?? -1);
println((deep(0) ?? none) ?? -1);

// annotated bindings let bare none / err infer their type
let nothing: opt[str] = none;
println(nothing ?? "fallback");

let bad: result[str, str] = err("boom");
println(bad ?? "recovered");
