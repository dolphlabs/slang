// strings.copy_into must stop on a range outside a buffer, never clamp.
import "strings";
let d = strings.bytes_zero(8);
strings.copy_into(d, 0, b"abc", 1, 4);
println("unreachable");
