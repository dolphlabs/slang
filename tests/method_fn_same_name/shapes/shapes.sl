pub gc struct Box { w: int }
pub gc struct Bag { n: int }
// a package function, and a method of the same name on two structs
pub fn size(b: Box) -> int { return b.w * 100; }
impl Box {
    pub fn size(self: Box) -> int { return self.w; }
    pub fn both(self: Box) -> int { return self.size() + size(self); }
}
impl Bag {
    pub fn size(self: Bag) -> int { return self.n + 1000; }
}
