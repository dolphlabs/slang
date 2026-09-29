pub struct Box { v: int }
pub fn make(n: int) -> Box { return Box { v: n * 10 }; }
impl Box { pub fn get(self: Box) -> int { return self.v + 1; } }
