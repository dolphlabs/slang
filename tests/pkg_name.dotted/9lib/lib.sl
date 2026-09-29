pub struct Box {
    v: int,
}

pub fn make(n: int) -> Box {
    return Box { v: n + 100 };
}
