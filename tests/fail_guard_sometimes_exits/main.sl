// A helper counts as never returning only when EVERY path exits.
// warn() returns when quiet is true, so ending the else with it falls through.
fn warn(msg: str, quiet: bool) {
    if quiet {
        return;
    }
    println(msg);
    exit(1);
}

fn get(o: opt[int]) -> int {
    guard let v = o else {
        warn("missing", true);
    }
    return v;
}

println(get(some(2)));
