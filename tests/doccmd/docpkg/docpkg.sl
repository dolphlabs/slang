// Fixture for run_tests.sh (slangc doc): which comment belongs to which
// item, and searching a package instead of paging it.

pub fn plain(x: int) -> int {
    return x;
}

// Sets one header. Mentions Retry-After only in its doc.
pub fn set_header(name: str, value: str) -> str {
    return name + value;
}

// A private helper's comment must not reach the item after it.
fn helper() -> int {
    return 1;
}
pub fn after_helper() -> int {
    return helper();
}

pub gc struct Req {
    path: str,
}

impl Req {
    // The value of one request header.
    pub fn header(self: Req, name: str) -> str {
        return self.path + name;
    }
}
