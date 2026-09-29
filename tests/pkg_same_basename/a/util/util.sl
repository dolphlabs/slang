pub struct Box { v: int }
pub fn make(n: int) -> Box { return Box { v: n }; }
impl Box { pub fn get(self: Box) -> int { return self.v; } }
