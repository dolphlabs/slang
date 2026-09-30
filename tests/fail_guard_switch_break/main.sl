// A break inside a switch leaves only the switch, so it does not leave
// the guard's scope: this else falls through when k == 1.
fn pick(o: opt[int], k: int) -> int {
    guard let v = o else {
        switch k {
            case 1 { break; }
            default { return 0; }
        }
    }
    return v;
}

println(pick(some(1), 1));
