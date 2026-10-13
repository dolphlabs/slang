// An extern fn may name a C function the runtime's own headers already
// declare, with slang's types: strlen is size_t(const char *) in
// <string.h>, declared here as int(str). It used to be a second,
// conflicting C prototype -- raw C compiler errors; now each extern fn is
// bound to its symbol under a C name of its own.
extern fn strlen(s: str) -> int;
extern fn abs(n: i32) -> i32;
extern fn atoi(s: str) -> i32;
extern fn labs(n: int) -> int;

fn apply(f: fn(str) -> int, s: str) -> int {
    return f(s);
}

println(strlen("hello, world"));
println(abs(-42));
println(atoi("123") + 1);
println(labs(-9000000000));
// an extern fn is a function value like any other
println(apply(strlen, "four"));
