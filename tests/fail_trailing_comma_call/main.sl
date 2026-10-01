// A trailing comma in a call is refused, and the error says so.
fn add(a: int, b: int) -> int {
    return a + b;
}
println(to_str(add(1, 2,)));
