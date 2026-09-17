pub gc struct Shape { pts: [int] }
pub fn total(xs: [int]) -> int { return len(xs); }
impl Shape {
    pub fn add_all(self: Shape, xs: [int]) -> int { for x in xs { push(self.pts, x); } return len(self.pts); }
}
