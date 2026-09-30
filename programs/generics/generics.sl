struct Box[T] {
    v: T,
}

impl Box[T] {
    fn get(self: Box[T]) -> T { return self.v; }
    fn doubled(self: Box[T]) -> int { return self.v * 2; }
}

println(Box { v: 21 }.doubled());   // checked for Box[int]
println(Box { v: "hi" }.get());     // doubled never checked here
