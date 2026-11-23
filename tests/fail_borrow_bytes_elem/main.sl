// A byte of a bytes value is read out as an int; it cannot be borrowed.
fn peek(p: &mut int) -> int { return *p; }
let b = b"\x01\x02";
println(peek(&mut b[0]));
