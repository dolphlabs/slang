// A package function's result is a receiver like any other: `shapes.make(3)`
// is parsed as a dotted call, and `.area()` after it is the method call on
// what it returned. A pub method is reachable this way, and a pub method
// may use a private one.
import "shapes";

println(shapes.make(3).area());
println(shapes.make(3).grown(2).area());
println(shapes.make(2).grown(1).fence());
