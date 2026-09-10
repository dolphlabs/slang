// Canonical Huffman decoding over the tables in huffman_table.sl.
//
// The classic canonical walk: consume one bit at a time, and at each
// length ask whether the accumulated code falls inside that length's
// consecutive run. `first` is the smallest code of the current length
// and `index` the offset of its symbol, so the symbol is found by
// subtraction with no tree and no per-symbol comparison.

pub gc struct Huff {
    counts: [int],
    symbols: [int],
}

pub fn huff_new() -> Huff {
    return Huff { counts: huff_counts(), symbols: huff_symbols() };
}

// Decode a Huffman-coded byte string to BYTES, not str.
//
// Returning str here would be a silent data-loss bug: symbol 0 is NUL,
// and to_str truncates there, so a value containing \x00 came back
// empty. Header field values are byte sequences on the wire; the caller
// decides whether to reject NUL (read_string does) rather than having
// the codec quietly drop everything after it.
//
// Padding rules (RFC 7541 §5.2) are enforced rather than ignored: the
// tail must be fewer than 8 bits, must be all ones, and must not encode
// a symbol. A decoder that skips these accepts streams a conforming one
// rejects, which is how HPACK implementations end up disagreeing.
pub fn huff_decode(h: Huff, src: bytes) -> result[bytes, str] {
    let out = b"";
    let code = 0;
    let clen = 0;
    let first = 0;
    let index = 0;
    let counts = h.counts;
    let symbols = h.symbols;

    let nbits = len(src) * 8;
    let i = 0;
    while i < nbits {
        let byte = src[i >> 3];
        let bit = (byte >> (7 - (i & 7))) & 1;
        i = i + 1;

        code = (code << 1) | bit;
        clen = clen + 1;
        if clen > HUFF_MAX_BITS {
            return err("code longer than 30 bits");
        }
        let cnt = counts[clen];
        if cnt > 0 && code - first < cnt {
            let sym = symbols[index + (code - first)];
            if sym == HUFF_EOS {
                return err("EOS symbol in header string");
            }
            let one = b"\x00";
            one[0] = sym;
            out = out + one;
            code = 0;
            clen = 0;
            first = 0;
            index = 0;
            continue;
        }
        index = index + cnt;
        first = (first + cnt) << 1;
    }

    // whatever is left must be valid padding
    if clen > 0 {
        if clen >= 8 {
            return err("padding longer than 7 bits");
        }
        let allones = (1 << clen) - 1;
        if code != allones {
            return err("padding is not all ones");
        }
    }
    return ok(out);
}
