// arity is still checked when spawning through a function value
fn work(id: int) { println(id); }
let w: fn(int) = work;
spawn w(1, 2);
