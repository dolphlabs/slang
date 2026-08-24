struct P {
    x: int,
}

impl P {
    fn get(self: P) -> int {
        return self.x;
    }
}

let p = P { x: 1 };
println(p.get(1));
