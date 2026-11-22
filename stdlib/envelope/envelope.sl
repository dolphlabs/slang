// Envelope encryption: each value gets its own random data key, and the
// data key is stored wrapped (encrypted) by a key-encryption key named by
// an id. Rotating the key-encryption key is then cheap -- rewrap changes
// a few dozen bytes, not the data -- and old keys can stay for reading.
//
//     import "envelope";
//
//     let kr = envelope.keyring();
//     envelope.add_key(kr, "2026-11", key_from_kms_or_env);   // 32 bytes
//     let box = envelope.seal(kr, to_bytes(ssn), to_bytes("user:42"));
//     let back = envelope.open(kr, box ?? b"", to_bytes("user:42"));
//
//     envelope.add_key(kr, "2027-01", new_key);   // the newest key seals
//     let fresh = envelope.rewrap(kr, box ?? b"");  // moved to 2027-01
//
// Both layers are AES-256-GCM through crypto.seal (random nonces, so none
// is ever reused). The aad binds the value to its context: a box sealed
// for "user:42" will not open as "user:43". The wrapped data key is bound
// to its key id. Layout: version 1 | id length | id | wrapped key length
// (2 bytes) | wrapped key | sealed value.

import "builder";
import "crypto";

pub gc struct Keyring {
    mu: mutex,
    keys: map[str]bytes,
    current: str,
}

pub fn keyring() -> Keyring {
    let m: map[str]bytes = {};
    return Keyring { mu: make_mutex(), keys: m, current: "" };
}

// Adds a 32-byte key-encryption key under id (1 to 255 bytes) and makes
// it the one new values are sealed with.
pub fn add_key(kr: Keyring, id: str, key: bytes) -> result[bool, str] {
    if len(key) != 32 { return err("envelope: a key must be 32 bytes"); }
    let n = len(to_bytes(id));
    if n < 1 || n > 255 { return err("envelope: a key id must be 1 to 255 bytes"); }
    mutex_lock(kr.mu);
    kr.keys[id] = key;
    kr.current = id;
    mutex_unlock(kr.mu);
    return ok(true);
}

// Makes an already added key the one new values are sealed with.
pub fn use_key(kr: Keyring, id: str) -> result[bool, str] {
    mutex_lock(kr.mu);
    if !has(kr.keys, id) {
        mutex_unlock(kr.mu);
        return err("envelope: no key " + id);
    }
    kr.current = id;
    mutex_unlock(kr.mu);
    return ok(true);
}

// Forgets a key: values sealed with it no longer open. Refused for the
// current key.
pub fn remove_key(kr: Keyring, id: str) -> result[bool, str] {
    mutex_lock(kr.mu);
    if id == kr.current {
        mutex_unlock(kr.mu);
        return err("envelope: cannot remove the current key");
    }
    if has(kr.keys, id) { del(kr.keys, id); }
    mutex_unlock(kr.mu);
    return ok(true);
}

pub fn seal(kr: Keyring, plaintext: bytes, aad: bytes) -> result[bytes, str] {
    mutex_lock(kr.mu);
    let id = kr.current;
    let ok_key = has(kr.keys, id);
    let kek = b"";
    if ok_key { kek = kr.keys[id]; }
    mutex_unlock(kr.mu);
    if !ok_key { return err("envelope: no key added"); }
    let dr = crypto.rand(32);
    guard let dek = dr else let e = err_of(dr) { return err("envelope: " + e); }
    let wr = crypto.seal(kek, dek, wrap_aad(id));
    guard let wrapped = wr else let we = err_of(wr) { return err("envelope: " + we); }
    let br = crypto.seal(dek, plaintext, aad);
    guard let body = br else let be = err_of(br) { return err("envelope: " + be); }
    return ok(pack(id, wrapped, body));
}

pub fn open(kr: Keyring, box: bytes, aad: bytes) -> result[bytes, str] {
    let pr = unpack(box);
    guard let p = pr else let e = err_of(pr) { return err(e); }
    let kr2 = unwrap(kr, p);
    guard let dek = kr2 else let ke = err_of(kr2) { return err(ke); }
    let or = crypto.open(dek, p.body, aad);
    guard let pt = or else { return err("envelope: value does not open (altered, or another aad)"); }
    return ok(pt);
}

// The id of the key a box was sealed with.
pub fn key_id(box: bytes) -> result[str, str] {
    let pr = unpack(box);
    guard let p = pr else let e = err_of(pr) { return err(e); }
    return ok(p.id);
}

// The box with its data key wrapped by the current key instead; the
// sealed value itself is unchanged. For rotating keys over stored data.
pub fn rewrap(kr: Keyring, box: bytes) -> result[bytes, str] {
    let pr = unpack(box);
    guard let p = pr else let e = err_of(pr) { return err(e); }
    let dr = unwrap(kr, p);
    guard let dek = dr else let de = err_of(dr) { return err(de); }
    mutex_lock(kr.mu);
    let id = kr.current;
    let kek = kr.keys[id];
    mutex_unlock(kr.mu);
    let wr = crypto.seal(kek, dek, wrap_aad(id));
    guard let wrapped = wr else let we = err_of(wr) { return err("envelope: " + we); }
    return ok(pack(id, wrapped, p.body));
}

// ---- internals -----------------------------------------------------------

struct Parts {
    id: str,
    wrapped: bytes,
    body: bytes,
}

fn wrap_aad(id: str) -> bytes {
    return to_bytes("slang-envelope-v1|" + id);
}

fn pack(id: str, wrapped: bytes, body: bytes) -> bytes {
    let idb = to_bytes(id);
    let b = builder.new_bytes();
    b.write_byte(1);
    b.write_byte(len(idb));
    b.write(idb);
    b.write_byte(len(wrapped) >> 8);
    b.write_byte(len(wrapped) & 255);
    b.write(wrapped);
    b.write(body);
    return b.finish();
}

fn unpack(box: bytes) -> result[Parts, str] {
    if len(box) < 4 || (box[0] as int) != 1 { return err("envelope: not a version 1 envelope"); }
    let n = box[1] as int;
    if n == 0 || len(box) < 2 + n + 2 { return err("envelope: truncated"); }
    let id = to_str(box[2..2 + n]);
    let wl = ((box[2 + n] as int) << 8) | (box[3 + n] as int);
    let at = 4 + n;
    if len(box) < at + wl { return err("envelope: truncated"); }
    return ok(Parts { id: id, wrapped: box[at..at + wl], body: box[at + wl..] });
}

fn unwrap(kr: Keyring, p: Parts) -> result[bytes, str] {
    mutex_lock(kr.mu);
    let have = has(kr.keys, p.id);
    let kek = b"";
    if have { kek = kr.keys[p.id]; }
    mutex_unlock(kr.mu);
    if !have { return err("envelope: no key " + p.id); }
    let dr = crypto.open(kek, p.wrapped, wrap_aad(p.id));
    guard let dek = dr else { return err("envelope: data key does not open under " + p.id); }
    return ok(dek);
}

