// A top-level let is a local of the program body, invisible in functions;
// the error now says so instead of only "undefined variable".
let LIMIT = 5;

fn allowed(n: int) -> bool {
    return n < LIMIT;
}

println(to_str(allowed(3)));
