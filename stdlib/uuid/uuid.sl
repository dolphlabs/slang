// UUIDs (RFC 9562): make v4 and v7, check, parse and convert them.
//
//     import "uuid";
//
//     let r = uuid.v7();                    // result[str, str]
//     guard let id = r else let e = err_of(r) { panic(e); }
//     uuid.v4()                             // result[str, str]: random
//     uuid.is_valid(id)                     // true: canonical form only
//     uuid.parse("{0190F4E2-...}")          // result[str, str]: canonical, or why not
//     uuid.version(id) ?? 0                 // 7
//     uuid.time_ms(id) ?? 0                 // when a v7 id was made, unix ms
//     uuid.to_binary(id)                    // result[bytes, str]: 16 bytes
//
// A UUID is a str in canonical form: 36 characters, lowercase hex, hyphens
// at 8, 13, 18 and 23. That is the form JSON, logs and Postgres's `uuid`
// text use, so ids cross those boundaries unconverted, and one value has
// exactly one spelling, so ids can be compared and used as map keys
// directly. `parse` is the door for every other spelling.
//
// Which version: v7 for anything stored, especially a primary key. Its
// first 48 bits are the creation time in milliseconds, so ids sort by when
// they were made and new rows land at the end of a B-tree index instead of
// at random pages. Within one millisecond the order is random: v7 here
// keeps no state, so any task may call it without a lock. v4 is fully
// random (122 bits) and reveals nothing, not even when it was made; use it
// for ids that are shown to people who should not learn timing from them.
//
// Both draw their randomness from crypto.rand, the operating system's
// CSPRNG, so ids are not guessable. They return an error rather than an id
// when it fails: an id from a weak source is worse than none.

import "crypto";
import "time";

// The nil and max UUIDs (RFC 9562 sections 5.9 and 5.10).
pub let NIL = "00000000-0000-0000-0000-000000000000";
pub let MAX = "ffffffff-ffff-ffff-ffff-ffffffffffff";

// The largest timestamp a v7 id holds: 48 bits of milliseconds, which
// lasts until the year 10889.
let V7_MAX_MS = 281474976710655;

// A random UUID, version 4: 122 random bits.
pub fn v4() -> result[str, str] {
    let r = crypto.rand(16);
    guard let b = r else let e = err_of(r) {
        return err("uuid: no randomness from the OS: " + e);
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return ok(encode(b));
}

// A time-ordered UUID, version 7, stamped with the current wall-clock
// time: 48 bits of unix milliseconds, then 74 random bits.
pub fn v7() -> result[str, str] {
    return v7_at(time.wall() / 1000000);
}

// A version 7 UUID stamped with `unix_ms` instead of the clock: for tests,
// and for ids that must carry an event's own time. Errors if `unix_ms` is
// negative or does not fit in 48 bits.
pub fn v7_at(unix_ms: int) -> result[str, str] {
    if unix_ms < 0 || unix_ms > V7_MAX_MS {
        return err("uuid: v7 time must be 0.." + to_str(V7_MAX_MS) +
                   " unix ms, got " + to_str(unix_ms));
    }
    let r = crypto.rand(16);
    guard let b = r else let e = err_of(r) {
        return err("uuid: no randomness from the OS: " + e);
    }
    b[0] = (unix_ms >> 40) & 0xff;
    b[1] = (unix_ms >> 32) & 0xff;
    b[2] = (unix_ms >> 24) & 0xff;
    b[3] = (unix_ms >> 16) & 0xff;
    b[4] = (unix_ms >> 8) & 0xff;
    b[5] = unix_ms & 0xff;
    b[6] = (b[6] & 0x0f) | 0x70;
    b[8] = (b[8] & 0x3f) | 0x80;
    return ok(encode(b));
}

// Is `s` a UUID in canonical form: 36 characters, lowercase hex digits,
// hyphens at 8, 13, 18 and 23? Any version and variant passes, so ids made
// elsewhere (Postgres's gen_random_uuid, another service) are accepted.
// Upper case, braces and urn:uuid: are not: run those through `parse`.
pub fn is_valid(s: str) -> bool {
    if len(s) != 36 {
        return false;
    }
    let b = to_bytes(s);
    for i in 0..36 {
        let c = b[i];
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if c != 45 {
                return false;
            }
        } else if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) {
            return false;
        }
    }
    return true;
}

// The canonical form of a UUID written any common way: canonical, upper
// or mixed case, in braces ({...}), as a urn:uuid: URN, or as 32 hex
// digits without hyphens. The error names the position and what was
// expected there.
pub fn parse(s: str) -> result[str, str] {
    let r = decode(s);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    return ok(encode(b));
}

// The version number of a canonical UUID (4 for v4, 7 for v7, 0 for NIL),
// or none if `s` is not canonical.
pub fn version(s: str) -> opt[int] {
    if !is_valid(s) {
        return none;
    }
    return some(hex_value(to_bytes(s)[14]));
}

// When a v7 UUID was made, in unix milliseconds. none if `s` is not a
// canonical version 7 UUID with the RFC 9562 variant: other versions keep
// no time, or keep it in another layout.
pub fn time_ms(s: str) -> opt[int] {
    if !is_valid(s) {
        return none;
    }
    let b = to_bytes(s);
    if b[14] != 55 {
        return none;
    }
    let variant = hex_value(b[19]);
    if variant < 8 || variant > 11 {
        return none;
    }
    let ms = 0;
    for i in [0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12] {
        ms = (ms << 4) | hex_value(b[i]);
    }
    return some(ms);
}

// The 16 bytes of a UUID, most significant first: the binary form
// databases store (Postgres `uuid` on the wire, a BINARY(16) column).
// Accepts every spelling `parse` does.
pub fn to_binary(s: str) -> result[bytes, str] {
    return decode(s);
}

// The canonical form of 16 bytes, the reverse of `to_binary`.
pub fn from_binary(b: bytes) -> result[str, str] {
    if len(b) != 16 {
        return err("uuid: want 16 bytes, got " + to_str(len(b)));
    }
    return ok(encode(b));
}

// ---- encoding ---------------------------------------------------------

// 16 bytes to the canonical 36 characters, in one allocation: a template
// with the hyphens already in place, filled with digits.
fn encode(b: bytes) -> str {
    let out = b"00000000-0000-0000-0000-000000000000";
    let j = 0;
    for i in 0..16 {
        if j == 8 || j == 13 || j == 18 || j == 23 {
            j = j + 1;
        }
        out[j] = hex_digit((b[i] >> 4) & 0x0f);
        out[j + 1] = hex_digit(b[i] & 0x0f);
        j = j + 2;
    }
    return to_str(out);
}

// The lowercase hex digit for a value 0..15.
fn hex_digit(v: int) -> int {
    if v < 10 {
        return 48 + v;
    }
    return 87 + v;
}

// The value of one hex digit, either case, or -1.
fn hex_value(c: int) -> int {
    if c >= 48 && c <= 57 {
        return c - 48;
    }
    if c >= 97 && c <= 102 {
        return c - 87;
    }
    if c >= 65 && c <= 70 {
        return c - 55;
    }
    return -1;
}

// A character for an error message: the character itself when it is
// printable ASCII, its byte value otherwise, so a hostile input cannot put
// control characters into a log line.
fn shown(c: int) -> str {
    if c >= 33 && c <= 126 {
        let one = b"\x00";
        one[0] = c;
        return "'" + to_str(one) + "'";
    }
    return "byte " + to_str(c);
}

fn lower_ascii(b: bytes) -> bytes {
    let out = b[0..len(b)];
    for i in 0..len(out) {
        if out[i] >= 65 && out[i] <= 90 {
            out[i] = out[i] + 32;
        }
    }
    return out;
}

// Any accepted spelling to 16 bytes. Every length is checked before any
// byte is read, so input of any size costs at most one pass over 45 bytes.
fn decode(s: str) -> result[bytes, str] {
    let raw = to_bytes(s);
    let n = len(raw);
    let lo = 0;
    let hi = n;
    if n == 38 {
        if raw[0] != 123 || raw[37] != 125 {
            return err("uuid: 38 characters must be {8-4-4-4-12} in braces");
        }
        lo = 1;
        hi = 37;
    } else if n == 45 {
        if to_str(lower_ascii(raw[0..9])) != "urn:uuid:" {
            return err("uuid: 45 characters must be urn:uuid: and 8-4-4-4-12 hex");
        }
        lo = 9;
    } else if n != 36 && n != 32 {
        return err("uuid: want 36 characters (8-4-4-4-12 hex digits), got " + to_str(n));
    }

    let hyphens = hi - lo == 36;
    let out = b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    let k = 0;
    let i = lo;
    while i < hi {
        let at = i - lo;
        if hyphens && (at == 8 || at == 13 || at == 18 || at == 23) {
            if raw[i] != 45 {
                return err("uuid: want '-' at character " + to_str(i + 1) +
                           ", got " + shown(raw[i]));
            }
            i = i + 1;
        } else {
            let a = hex_value(raw[i]);
            if a < 0 {
                return err("uuid: character " + to_str(i + 1) + " is " +
                           shown(raw[i]) + ", not a hex digit");
            }
            let b = hex_value(raw[i + 1]);
            if b < 0 {
                return err("uuid: character " + to_str(i + 2) + " is " +
                           shown(raw[i + 1]) + ", not a hex digit");
            }
            out[k] = (a << 4) | b;
            k = k + 1;
            i = i + 2;
        }
    }
    return ok(out);
}
