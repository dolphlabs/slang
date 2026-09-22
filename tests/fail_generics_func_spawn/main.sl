// `spawn` resolves a generic function from its arguments, like any other
// call. What it still cannot do is spawn one whose type parameter only
// the return type mentions: a spawn has no annotated `let` to infer from.
fn make_empty[T]() -> [T] {
    return [];
}

spawn make_empty();
