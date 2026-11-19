// strings.copy_into must stop on a range outside a buffer, never clamp.
import "strings";
let d = strings.bytes_zero(8);
strings.copy_into(d, -1, b"abc", 0, 1);
println("unreachable");
