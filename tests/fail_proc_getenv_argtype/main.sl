// proc.getenv expects a str, exercising the same NatSig-driven
// argument validation every other native package's functions go
// through (see native.c's native_check).
import "proc";
let r: opt[str] = proc.getenv(5);
