pub struct Sq {
    side: int,
}

pub fn make(side: int) -> Sq {
    return Sq { side: side };
}

impl Sq {
    pub fn area(self: Sq) -> int {
        return self.side * self.side;
    }

    pub fn grown(self: Sq, by: int) -> Sq {
        return Sq { side: self.side + by };
    }

    // not exported, though a pub method may use it
    fn perimeter(self: Sq) -> int {
        return self.side * 4;
    }

    pub fn fence(self: Sq) -> int {
        return self.perimeter();
    }
}
