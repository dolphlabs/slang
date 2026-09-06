pub fn find(b: bytes, from: int, target: int) -> int {
    let i = from;
    while i < len(b) {
        if b[i] == target {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

pub fn has_prefix(b: bytes, prefix: bytes) -> bool {
    if len(prefix) > len(b) {
        return false;
    }
    let i = 0;
    while i < len(prefix) {
        if b[i] != prefix[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

pub fn has_suffix(b: bytes, suffix: bytes) -> bool {
    if len(suffix) > len(b) {
        return false;
    }
    let off = len(b) - len(suffix);
    let i = 0;
    while i < len(suffix) {
        if b[off + i] != suffix[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn is_space(b: int) -> bool {
    return b == 9 || b == 10 || b == 13 || b == 32;
}

pub fn trim(b: bytes) -> bytes {
    let lo = 0;
    let hi = len(b);
    while lo < hi && is_space(b[lo]) {
        lo = lo + 1;
    }
    while hi > lo && is_space(b[hi - 1]) {
        hi = hi - 1;
    }
    return b[lo..hi];
}

pub fn split(b: bytes, sep: int) -> [bytes] {
    let parts: [bytes] = [];
    let start = 0;
    let i = 0;
    while i < len(b) {
        if b[i] == sep {
            push(parts, b[start..i]);
            start = i + 1;
        }
        i = i + 1;
    }
    push(parts, b[start..]);
    return parts;
}
