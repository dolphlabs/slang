// HPACK header block decode/encode (RFC 7541 §6).
//
// A block is a sequence of representations distinguished by the high
// bits of their first octet. Indices are 1-based over a virtual table:
// 1..61 index the static table, 62+ index the dynamic table with the
// most recently added entry first.

pub gc struct Decoder {
    huff: Huff,
    table: Table,
    // A peer may shrink the table below what it told us at SETTINGS
    // time, but never above it; keeping the ceiling lets us reject an
    // oversized Dynamic Table Size Update instead of honouring it.
    max_cap: int,
}

pub fn decoder_new(cap: int) -> Decoder {
    return Decoder {
        huff: huff_new(),
        table: table_new(cap),
        max_cap: cap
    };
}

fn resolve_name(d: Decoder, idx: int) -> result[str, str] {
    if idx >= 1 && idx <= STATIC_LEN {
        return ok(static_name(idx));
    }
    let dyn = idx - STATIC_LEN - 1;
    if dyn < 0 || dyn >= len(d.table.names) {
        return err("header index out of range");
    }
    return ok(d.table.names[dyn]);
}

fn resolve_value(d: Decoder, idx: int) -> result[str, str] {
    if idx >= 1 && idx <= STATIC_LEN {
        return ok(static_value(idx));
    }
    let dyn = idx - STATIC_LEN - 1;
    if dyn < 0 || dyn >= len(d.table.values) {
        return err("header index out of range");
    }
    return ok(d.table.values[dyn]);
}

// Decode one complete header block. `max_headers` caps how many fields
// a peer may send: without it a small compressed block can expand into
// an unbounded list, which is the HPACK bomb.
pub fn decode_block(d: Decoder, b: bytes, max_headers: int)
        -> result[[Header], str] {
    let out: [Header] = [];
    let i = 0;
    while i < len(b) {
        if len(out) >= max_headers {
            return err("too many header fields");
        }
        let c = b[i];

        // 1xxxxxxx -- Indexed Header Field
        if (c & 0x80) != 0 {
            let ir = read_int(b, i, 7);
            guard let r = ir else let e = err_of(ir) {
                return err("indexed field: " + e);
            }
            if r.value == 0 {
                return err("index 0 is not a valid header index");
            }
            let nr = resolve_name(d, r.value);
            guard let nm = nr else let e = err_of(nr) {
                return err(e);
            }
            let vr = resolve_value(d, r.value);
            guard let vl = vr else let e = err_of(vr) {
                return err(e);
            }
            out = out + [Header { name: nm, value: vl }];
            i = r.next;
            continue;
        }

        // 001xxxxx -- Dynamic Table Size Update
        if (c & 0xe0) == 0x20 {
            let sr = read_int(b, i, 5);
            guard let r = sr else let e = err_of(sr) {
                return err("table size update: " + e);
            }
            if r.value > d.max_cap {
                return err("table size update above the agreed maximum");
            }
            table_resize(d.table, r.value);
            i = r.next;
            continue;
        }

        // 01xxxxxx incremental indexing (6-bit), otherwise 4-bit:
        // 0000xxxx without indexing, 0001xxxx never indexed.
        let indexing = (c & 0x40) != 0;
        let prefix = 4;
        if indexing {
            prefix = 6;
        }
        let ir2 = read_int(b, i, prefix);
        guard let r2 = ir2 else let e = err_of(ir2) {
            return err("literal field: " + e);
        }
        let name = "";
        let pos = r2.next;
        if r2.value == 0 {
            // name is a literal string following the prefix
            let nsr = read_string(d.huff, b, pos);
            guard let ns = nsr else let e = err_of(nsr) {
                return err("field name: " + e);
            }
            name = ns.value;
            pos = ns.next;
        } else {
            let nr2 = resolve_name(d, r2.value);
            guard let nm2 = nr2 else let e = err_of(nr2) {
                return err(e);
            }
            name = nm2;
        }
        let vsr = read_string(d.huff, b, pos);
        guard let vs = vsr else let e = err_of(vsr) {
            return err("field value: " + e);
        }
        if len(name) == 0 {
            return err("empty header field name");
        }
        out = out + [Header { name: name, value: vs.value }];
        if indexing {
            table_add(d.table, name, vs.value);
        }
        i = vs.next;
    }
    return ok(out);
}

// ---- encoding -------------------------------------------------------
//
// Deliberately stateless: every field is emitted either as an indexed
// reference to the STATIC table or as a literal "without indexing", and
// nothing is ever added to a dynamic table on the encode side.
//
// That is fully conformant, and it removes a whole class of bug: an
// encoder's dynamic table must stay exactly in step with the peer's
// decoder table, and any drift corrupts every later block on the
// connection. The cost is a few bytes per response; the benefit is that
// a response can never desynchronise the connection.

pub fn encode_header(name: str, value: str) -> bytes {
    let both = static_find(name, value);
    if both > 0 {
        // 1xxxxxxx indexed field, 7-bit prefix
        return write_int(both, 7, 0x80);
    }
    let only_name = static_find_name(name);
    if only_name > 0 {
        // 0000xxxx literal without indexing, name by index
        return write_int(only_name, 4, 0x00) + write_string(value);
    }
    // 0000 0000 literal without indexing, both as strings
    return write_int(0, 4, 0x00) + write_string(name) + write_string(value);
}

pub fn encode_block(hs: [Header]) -> bytes {
    let out = b"";
    for i in 0..len(hs) {
        out = out + encode_header(hs[i].name, hs[i].value);
    }
    return out;
}
