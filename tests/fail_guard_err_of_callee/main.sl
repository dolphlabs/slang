// `err_of` must name the SAME expression the guard tested. Two calls through
// different function values are not the same expression, though both are
// called "<function value>" -- this used to be accepted.
fn parse_a(s: str) -> result[int, str] { return err("a"); }
fn parse_b(s: str) -> result[int, str] { return err("b"); }

fn run() {
    let ps: [fn(str) -> result[int, str]] = [parse_a, parse_b];
    guard let v = ps[0]("x") else let e = err_of(ps[1]("x")) {
        return;
    }
}
run();
