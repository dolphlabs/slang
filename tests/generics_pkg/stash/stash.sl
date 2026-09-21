pub struct Slot[T] {
    v: T,
    set: bool,
}

// names another generic struct of THIS package, bare: each instance has to
// resolve `Slot` in stash even when the argument is a type from main
pub struct Wrapped[T] {
    inner: Slot[T],
    note: str,
}

pub struct Stack[T] {
    items: [T],
}

struct Hidden[T] {
    v: T,
}

pub fn size(s: Stack[int]) -> int {
    return len(s.items);
}

pub fn empty_slot(n: int) -> Slot[int] {
    return Slot[int] { v: n, set: false };
}
