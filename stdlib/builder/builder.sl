// Building a string or a byte sequence out of many pieces.
//
// In slang `a + b` allocates a new value and copies BOTH sides, so
// building a result one piece at a time costs the sum of every
// intermediate length:
//
//     let out = "";
//     while i < n { out = out + piece; }      // O(n^2)
//
// Measured on this runtime, building 80 KB one byte at a time takes two
// seconds, and a 1 MB body would take minutes. That is not a slow
// constant; it is a different growth rate, and it is the difference
// between a parser and a way to take a server down.
//
// A builder collects the pieces and copies each exactly once, at the
// end:
//
//     let b = builder.new_str();
//     b.write("hello").write(", ").write(name);
//     let s = b.finish();                     // O(total)
//
// `Str` is for text and `Bytes` for binary data. `Bytes` also takes
// single bytes cheaply, which is what a tokenizer or an escaper does:
// they land in a 512-byte chunk that is filled in place, so a million
// `write_byte` calls make about two thousand allocations, not a million.

import "strings";

// ---------------------------------------------------------------- //
// Text                                                               //
// ---------------------------------------------------------------- //

pub gc struct Str {
    parts: [str],
    size: int,
}

pub fn new_str() -> Str {
    let parts: [str] = [];
    return Str { parts: parts, size: 0 };
}

impl Str {
    // Appends, and returns the builder so writes chain. A str is
    // immutable, so the builder holds the caller's value, not a copy.
    pub fn write(self: Str, s: str) -> Str {
        if len(s) > 0 {
            push(self.parts, s);
            self.size = self.size + len(s);
        }
        return self;
    }

    pub fn write_int(self: Str, n: int) -> Str {
        return self.write(to_str(n));
    }

    pub fn write_line(self: Str, s: str) -> Str {
        return self.write(s).write("\n");
    }

    // The bytes written so far, without assembling anything.
    pub fn size(self: Str) -> int {
        return self.size;
    }

    pub fn is_empty(self: Str) -> bool {
        return self.size == 0;
    }

    // The whole result, in one allocation. Can be called again after
    // more writes; each call assembles what is there, so ask once when
    // you are done rather than after every write.
    pub fn finish(self: Str) -> str {
        return strings.join(self.parts, "");
    }

    // finish() and start over.
    pub fn take(self: Str) -> str {
        let out = self.finish();
        self.reset();
        return out;
    }

    pub fn reset(self: Str) -> int {
        let parts: [str] = [];
        self.parts = parts;
        self.size = 0;
        return 0;
    }
}

// ---------------------------------------------------------------- //
// Bytes                                                              //
// ---------------------------------------------------------------- //

// Single bytes and short slices are copied into a chunk of this many
// bytes; a full chunk becomes one piece. Big enough that the piece list
// stays short, small enough that an unused builder costs little.
fn chunk_len() -> int {
    return 512;
}

// A write at least this long is kept as its own piece rather than
// copied into the chunk: past this point the chunk copy is more work
// than the piece it would save.
fn inline_max() -> int {
    return 64;
}

pub gc struct Bytes {
    parts: [bytes],
    chunk: bytes,
    fill: int,
    size: int,
}

pub fn new_bytes() -> Bytes {
    let parts: [bytes] = [];
    return Bytes {
        parts: parts,
        chunk: to_bytes(strings.repeat(" ", chunk_len())),
        fill: 0,
        size: 0
    };
}

impl Bytes {
    // Moves the partly filled chunk into the piece list, as a copy, so
    // the chunk itself is free to be filled again.
    fn flush(self: Bytes) -> int {
        if self.fill > 0 {
            push(self.parts, self.chunk[0..self.fill]);
            self.fill = 0;
        }
        return 0;
    }

    pub fn write_byte(self: Bytes, b: int) -> Bytes {
        if self.fill == chunk_len() {
            self.flush();
        }
        self.chunk[self.fill] = b;
        self.fill = self.fill + 1;
        self.size = self.size + 1;
        return self;
    }

    // Appends a copy. Bytes are mutable in slang, so keeping the
    // caller's own value would let a later change of theirs rewrite
    // what was already written.
    pub fn write(self: Bytes, b: bytes) -> Bytes {
        let n = len(b);
        if n == 0 {
            return self;
        }
        if n <= inline_max() {
            if self.fill + n > chunk_len() {
                self.flush();
            }
            let i = 0;
            while i < n {
                self.chunk[self.fill + i] = b[i];
                i = i + 1;
            }
            self.fill = self.fill + n;
        } else {
            self.flush();
            push(self.parts, b[0..n]);
        }
        self.size = self.size + n;
        return self;
    }

    // Text goes in as its UTF-8 bytes. `to_bytes` already makes a fresh
    // value, so a long string is kept as-is rather than copied twice.
    pub fn write_str(self: Bytes, s: str) -> Bytes {
        let n = len(s);
        if n == 0 {
            return self;
        }
        if n <= inline_max() {
            return self.write(to_bytes(s));
        }
        self.flush();
        push(self.parts, to_bytes(s));
        self.size = self.size + n;
        return self;
    }

    pub fn size(self: Bytes) -> int {
        return self.size;
    }

    pub fn is_empty(self: Bytes) -> bool {
        return self.size == 0;
    }

    // The whole result, in one allocation. Leaves the builder as it
    // was, so it can be written to and finished again; call it once
    // when you are done rather than after every write.
    pub fn finish(self: Bytes) -> bytes {
        self.flush();
        return strings.join_bytes(self.parts, b"");
    }

    pub fn take(self: Bytes) -> bytes {
        let out = self.finish();
        self.reset();
        return out;
    }

    pub fn reset(self: Bytes) -> int {
        let parts: [bytes] = [];
        self.parts = parts;
        self.fill = 0;
        self.size = 0;
        return 0;
    }
}
