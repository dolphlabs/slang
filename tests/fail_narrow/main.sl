// Narrowing requires an explicit cast: this must be a compile error.
fn shrink(a: i32) -> i8 {
    a
}
shrink(5);