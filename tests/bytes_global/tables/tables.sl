// Package-level bytes: a constant pointer to one static value whose data is
// writable, shared by every use.
pub let MAGIC = b"PK\x03\x04";
pub let EMPTY = b"";
pub let BIN = b"a\x00\xffz";
let HIDDEN = b"hid";

pub fn magic_ok(data: bytes) -> bool {
    return len(data) >= len(MAGIC) && data[..len(MAGIC)] == MAGIC;
}

pub fn hidden_len() -> int { return len(HIDDEN); }

pub fn stamp(v: int) { MAGIC[0] = v; }
