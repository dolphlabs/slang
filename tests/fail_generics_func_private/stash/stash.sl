pub fn map_len[T](xs: [T]) -> int {
    return len(xs);
}

pub struct Pair[A, B] {
    first: A,
    second: B,
}

pub fn make_pair[A, B](a: A, b: B) -> Pair[A, B] {
    return Pair[A, B] { first: a, second: b };
}

// private: not exported, but still checked against a call from outside
fn hidden_id[T](x: T) -> T {
    return x;
}
