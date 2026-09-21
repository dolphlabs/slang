pub enum Status {
    Pending,
    Paid,
    Shipped,
}

pub fn label(s: Status) -> str {
    return "status:" + to_str(s);
}
