// strings.copy_into must stop on a range outside a buffer, never clamp.
import "strings";
let d = strings.bytes_zero(4);
strings.copy_into(d, 2, b"abc", 0, 3);
println("unreachable");
