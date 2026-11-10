// NKeys: the Ed25519 identities NATS uses for authentication. A seed is
// "S" + the key type + base32 of (two prefix bytes, the 32-byte Ed25519
// seed, a CRC-16) -- "SU..." for a user. The server sends a nonce in INFO;
// the client signs it with the seed and sends the signature and its public
// key ("U...") in CONNECT. A .creds file carries a user JWT and a seed.

import "crypto";
import "encoding";
import "strings";

// Key-type prefix bytes (nkeys' PrefixByte values).
let PREFIX_SEED = 144;   // 18 << 3: "S"
let PREFIX_USER = 160;   // 20 << 3: "U"

let B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

// RFC 4648 base32 without padding.
fn b32_encode(b: bytes) -> str {
    let alpha = to_bytes(B32);
    let n = (len(b) * 8 + 4) / 5;
    let out = strings.bytes_zero(n);
    let acc = 0;
    let bits = 0;
    let o = 0;
    for i in 0..len(b) {
        acc = (acc << 8) | b[i];
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out[o] = alpha[(acc >> bits) & 31];
            o += 1;
        }
        acc = acc & 255;
    }
    if bits > 0 {
        out[o] = alpha[(acc << (5 - bits)) & 31];
        o += 1;
    }
    return strings.from_bytes(out, 0, o);
}

fn b32_value(c: int) -> int {
    if c >= 65 && c <= 90 {
        return c - 65;
    }
    if c >= 50 && c <= 55 {
        return c - 24;
    }
    return -1;
}

fn b32_decode(s: str) -> result[bytes, str] {
    let src = to_bytes(s);
    let out = strings.bytes_zero(len(src) * 5 / 8);
    let acc = 0;
    let bits = 0;
    let o = 0;
    for i in 0..len(src) {
        let v = b32_value(src[i]);
        if v < 0 {
            return err("nkey: not base32");
        }
        acc = (acc << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            if o < len(out) {
                out[o] = (acc >> bits) & 255;
                o += 1;
            }
        }
        acc = acc & 255;
    }
    return ok(out[..o]);
}

// CRC-16/XMODEM (polynomial 0x1021, initial 0), as nkeys uses.
fn crc16(b: bytes) -> int {
    let crc = 0;
    for i in 0..len(b) {
        crc = crc ^ (b[i] << 8);
        for _ in 0..8 {
            if (crc & 32768) != 0 {
                crc = ((crc << 1) ^ 4129) & 65535;
            } else {
                crc = (crc << 1) & 65535;
            }
        }
    }
    return crc;
}

fn with_crc(b: bytes) -> bytes {
    let c = crc16(b);
    let tail = strings.bytes_zero(2);
    tail[0] = c & 255;
    tail[1] = (c >> 8) & 255;
    return b + tail;
}

fn check_crc(raw: bytes) -> result[bytes, str] {
    if len(raw) < 3 {
        return err("nkey: too short");
    }
    let body = raw[..len(raw) - 2];
    let want = raw[len(raw) - 2] | (raw[len(raw) - 1] << 8);
    if crc16(body) != want {
        return err("nkey: checksum mismatch");
    }
    return ok(body);
}

// The 32-byte Ed25519 seed inside a user seed ("SU...").
pub fn nkey_seed_raw(seed: str) -> result[bytes, str] {
    let dr = b32_decode(strings.trim(seed));
    guard let raw = dr else let e = err_of(dr) { return err(e); }
    let cr = check_crc(raw);
    guard let body = cr else let e = err_of(cr) { return err(e); }
    // first byte: seed prefix plus the top bits of the type; second: the
    // rest of the type
    if (body[0] & 248) != PREFIX_SEED {
        return err("nkey: not a seed");
    }
    if len(body) != 34 {
        return err("nkey: a seed holds 32 bytes");
    }
    let kind = ((body[0] & 7) << 5) | (body[1] >> 3);
    if kind != PREFIX_USER {
        return err("nkey: not a user seed");
    }
    return ok(body[2..34]);
}

// The public key ("U...") for a user seed.
pub fn nkey_public(seed: str) -> result[str, str] {
    let sr = nkey_seed_raw(seed);
    guard let raw = sr else let e = err_of(sr) { return err(e); }
    let pr = crypto.ed25519_public_key(raw);
    guard let pub_key = pr else let e = err_of(pr) { return err(e); }
    let body = strings.bytes_zero(1) + pub_key;
    body[0] = PREFIX_USER;
    return ok(b32_encode(with_crc(body)));
}

// A user seed ("SU...") for a 32-byte Ed25519 seed: for tests and tools.
pub fn nkey_encode_seed(raw: bytes) -> result[str, str] {
    if len(raw) != 32 {
        return err("nkey: a seed holds 32 bytes");
    }
    let head = strings.bytes_zero(2);
    head[0] = PREFIX_SEED | (PREFIX_USER >> 5);
    head[1] = (PREFIX_USER & 31) << 3;
    return ok(b32_encode(with_crc(head + raw)));
}

// The base64url signature of a server nonce, for CONNECT's "sig".
pub fn nkey_sign_nonce(seed: str, nonce: str) -> result[str, str] {
    let sr = nkey_seed_raw(seed);
    guard let raw = sr else let e = err_of(sr) { return err(e); }
    let sig = crypto.ed25519_sign(raw, to_bytes(nonce));
    guard let s = sig else let e = err_of(sig) { return err(e); }
    return ok(encoding.base64url_encode(s));
}

// The user JWT and the seed from a .creds file (two armoured blocks).
pub fn parse_creds(text: str) -> result[[str], str] {
    let jwt = creds_block(text, "-----BEGIN NATS USER JWT-----");
    let seed = creds_block(text, "-----BEGIN USER NKEY SEED-----");
    if jwt == "" || seed == "" {
        return err("creds: expected a NATS USER JWT and a USER NKEY SEED block");
    }
    return ok([jwt, seed]);
}

fn creds_block(text: str, begin: str) -> str {
    let at = strings.find(text, begin);
    if at < 0 {
        return "";
    }
    let rest = strings.slice(text, at + len(begin), len(text));
    let end = strings.find(rest, "------");
    if end < 0 {
        return "";
    }
    return strings.trim(strings.slice(rest, 0, end));
}
