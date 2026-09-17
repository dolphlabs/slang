// A PROGRAM package. Under `slangc test` these top-level statements must
// not run: the test runner is main. If they did, the run would exit 7.
fn greet(name: str) -> str {
    return "hello " + name;
}

println(greet("program"));
exit(7);
