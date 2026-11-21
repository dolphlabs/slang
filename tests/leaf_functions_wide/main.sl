// See lw/lw.sl: the functions live in a package so they can use
// package-level constants, which a program's own functions cannot see.
import "lw";

let held: [str] = [];
for i in 0..2000 {
    push(held, lw.run("t" + to_str(i)));
}
println(held[0]);
println(held[1999]);
