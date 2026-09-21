// `perimeter` is not pub, so a caller in another package cannot reach it
// through a temporary receiver either.
import "shapes";

println(shapes.make(3).perimeter());
