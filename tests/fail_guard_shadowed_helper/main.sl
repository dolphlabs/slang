// die() never returns, but here the name is a parameter holding some
// function value, which may return: the call does not leave the scope.
fn die(msg: str) {
    println(msg);
    exit(1);
}

fn say(msg: str) {
    println(msg);
}

fn get(o: opt[int], die: fn(str)) -> int {
    guard let v = o else {
        die("missing");
    }
    return v;
}

println(get(some(3), say));
