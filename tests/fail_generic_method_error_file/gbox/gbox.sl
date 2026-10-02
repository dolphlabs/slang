pub gc struct Box[T] {
    v: T,
}

impl Box[T] {
    pub fn get(self: Box[T]) -> T {
        let v = self.v;
        return v;
    }
}
