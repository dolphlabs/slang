pub enum Status {
    Pending,
    Paid = 5,
    Shipped,
    Cancelled,
}

enum Internal {
    A,
    B,
}

pub gc struct Order {
    id: int,
    status: Status,
}

pub fn describe(o: Order) -> str {
    return to_str(o.id) + ":" + to_str(o.status);
}

pub fn is_final(s: Status) -> bool {
    return s == Status.Shipped || s == Status.Cancelled;
}

pub fn first_internal() -> int {
    return Internal.A as i32;
}
