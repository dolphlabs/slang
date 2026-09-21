pub struct Slot[T] {
    v: T,
    set: bool,
}

impl Slot[T] {
    pub fn value(self: Slot[T]) -> T {
        return self.v;
    }

    pub fn filled(self: Slot[T]) -> bool {
        return self.set;
    }

    // private: callable from inside this package only
    fn raw(self: Slot[T]) -> T {
        return self.v;
    }

    // a pub method reaching a private one of the same instance
    pub fn through(self: Slot[T]) -> T {
        return self.raw();
    }
}

pub gc struct Bag[T] {
    items: [T],
}

impl Bag[T] {
    pub fn add(self: Bag[T], x: T) -> int {
        push(self.items, x);
        return len(self.items);
    }

    pub fn size(self: Bag[T]) -> int {
        return len(self.items);
    }
}

// used from this package only, over a type this package does not know
pub fn slot_of(n: int) -> Slot[int] {
    return Slot[int] { v: n, set: true };
}
