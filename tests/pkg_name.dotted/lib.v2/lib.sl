pub struct Box {
    v: int,
}

impl Box {
    pub fn twice(self: Box) -> int {
        return self.v * 2;
    }
}

pub struct Wrap[T] {
    v: T,
}

pub fn make(n: int) -> Box {
    return Box { v: n };
}

pub fn wrap(n: int) -> Wrap[int] {
    return Wrap[int] { v: n };
}
