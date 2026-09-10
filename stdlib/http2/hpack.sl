// HPACK header compression (RFC 7541).
//
// Four representations share the first byte's high bits:
//
//   1xxxxxxx  Indexed Header Field          -- index into the tables
//   01xxxxxx  Literal, Incremental Indexing -- adds to the dynamic table
//   0000xxxx  Literal, no indexing
//   0001xxxx  Literal, never indexed        -- must stay unindexed on
//                                              forwarding (auth tokens)
//   001xxxxx  Dynamic Table Size Update
//
// Indices are 1-based over a virtual table: 1..61 are the static table
// below, and 62+ are the dynamic table with the MOST RECENT entry first.

pub gc struct Header {
    name: str,
    value: str,
}

// A decoder's dynamic table. Bounded by `cap` octets, where each entry
// costs len(name) + len(value) + 32 (RFC 7541 §4.1); the constant
// accounts for per-entry overhead so a peer cannot exhaust memory with
// many tiny headers.
pub gc struct Table {
    names: [str],
    values: [str],
    size: int,
    cap: int,
}

pub fn table_new(cap: int) -> Table {
    let n: [str] = [];
    let v: [str] = [];
    return Table { names: n, values: v, size: 0, cap: cap };
}

fn entry_cost(name: str, value: str) -> int {
    return len(name) + len(value) + 32;
}

// Evict from the end (oldest) until the new entry fits.
fn table_evict_to(t: Table, target: int) {
    while t.size > target && len(t.names) > 0 {
        let last = len(t.names) - 1;
        t.size = t.size - entry_cost(t.names[last], t.values[last]);
        t.names = t.names[0..last];
        t.values = t.values[0..last];
    }
}

pub fn table_add(t: Table, name: str, value: str) {
    let cost = entry_cost(name, value);
    // An entry larger than the whole table empties it and is not stored
    // (RFC 7541 §4.4) -- this is legal, not an error.
    if cost > t.cap {
        table_evict_to(t, 0);
        return;
    }
    table_evict_to(t, t.cap - cost);
    // newest first
    t.names = [name] + t.names;
    t.values = [value] + t.values;
    t.size = t.size + cost;
}

pub fn table_resize(t: Table, cap: int) {
    t.cap = cap;
    table_evict_to(t, cap);
}

// ---- integers (RFC 7541 §5.1) ---------------------------------------
//
// A value smaller than the N-bit prefix's maximum is stored inline. At
// the maximum, the prefix is all ones and the remainder follows as
// continuation octets, 7 bits each, high bit set to continue.

pub gc struct IntRead {
    value: int,
    next: int,
}

pub fn read_int(b: bytes, off: int, prefix_bits: int) -> result[IntRead, str] {
    if off >= len(b) {
        return err("truncated integer");
    }
    let maxv = (1 << prefix_bits) - 1;
    let v = b[off] & maxv;
    let i = off + 1;
    if v < maxv {
        return ok(IntRead { value: v, next: i });
    }
    let shift = 0;
    while true {
        if i >= len(b) {
            return err("truncated integer continuation");
        }
        let byte = b[i];
        i = i + 1;
        v = v + ((byte & 0x7f) << shift);
        // 5 continuation octets already exceed any sane header value and
        // keep a hostile peer from shifting past the int width.
        if shift > 28 {
            return err("integer overflow in HPACK");
        }
        if (byte & 0x80) == 0 {
            break;
        }
        shift = shift + 7;
    }
    return ok(IntRead { value: v, next: i });
}

// `first` supplies the bits ABOVE the prefix (the representation tag).
pub fn write_int(v: int, prefix_bits: int, first: int) -> bytes {
    let maxv = (1 << prefix_bits) - 1;
    let out = b"\x00";
    if v < maxv {
        out[0] = (first & ~maxv) | v;
        return out;
    }
    out[0] = (first & ~maxv) | maxv;
    let rest = v - maxv;
    while rest >= 0x80 {
        let cont = b"\x00";
        cont[0] = (rest & 0x7f) | 0x80;
        out = out + cont;
        rest = rest >> 7;
    }
    let last = b"\x00";
    last[0] = rest;
    return out + last;
}

// ---- strings (RFC 7541 §5.2) ----------------------------------------

pub gc struct StrRead {
    value: str,
    next: int,
}

pub fn read_string(h: Huff, b: bytes, off: int) -> result[StrRead, str] {
    if off >= len(b) {
        return err("truncated string");
    }
    let huff = (b[off] & 0x80) != 0;
    let lr = read_int(b, off, 7);
    guard let l = lr else let e = err_of(lr) {
        return err("string length: " + e);
    }
    let start = l.next;
    let end = start + l.value;
    if end > len(b) {
        return err("string runs past end of block");
    }
    let raw = b[start..end];
    if huff {
        let hr = huff_decode(h, raw);
        guard let dec = hr else let e = err_of(hr) {
            return err("huffman: " + e);
        }
        raw = dec;
    }
    // A NUL in a field name or value is a protocol error (RFC 9113
    // §8.2.1). Rejecting it here is also what makes the str below safe:
    // to_str stops at a NUL, so accepting one would silently truncate.
    for i in 0..len(raw) {
        if raw[i] == 0 {
            return err("NUL in header field");
        }
    }
    return ok(StrRead { value: to_str(raw), next: end });
}

// Always emitted as a raw literal, never Huffman-coded. That is fully
// legal (the H bit says which), costs a few bytes per response, and
// avoids shipping an encoder table for a saving the transport layer
// mostly recovers anyway.
pub fn write_string(s: str) -> bytes {
    return write_int(len(s), 7, 0x00) + to_bytes(s);
}
