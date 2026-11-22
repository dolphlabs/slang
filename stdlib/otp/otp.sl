// One-time passwords for two-factor sign-in: HOTP (RFC 4226) and TOTP
// (RFC 6238), the codes authenticator apps show.
//
//     import "otp";
//
//     // enrolment: store the secret, show the URI as a QR code
//     let secret = otp.new_secret() ?? b"";
//     let uri = otp.uri(secret, "Acme", "ada@example.com", otp.totp_options());
//
//     // sign-in: accept the code once
//     let step = otp.verify_totp(secret, code, now_unix, otp.totp_options());
//     if let s = step {
//         if s <= last_used_step { /* a replay: refuse */ }
//         last_used_step = s;   // store it with the user
//     }
//
// Codes are compared in constant time. verify_totp returns the time step
// that matched so a caller can refuse a code used before (RFC 6238 5.2):
// within its 30 seconds a code is otherwise valid for anyone who saw it.

import "builder";
import "crypto";
import "encoding";
import "strings";

pub struct Options {
    digits: int,      // 6 (the default) to 10
    step: int,        // seconds per TOTP code, 30 by default
    skew: int,        // steps before and after now also accepted (clock drift)
    algorithm: str,   // "SHA1" (what apps assume), "SHA256" or "SHA512"
}

pub fn totp_options() -> Options {
    return Options { digits: 6, step: 30, skew: 1, algorithm: "SHA1" };
}

// A random 160-bit secret, the size RFC 4226 recommends for SHA-1.
pub fn new_secret() -> result[bytes, str] {
    return crypto.rand(20);
}

// The HOTP code for a counter value.
pub fn hotp(secret: bytes, counter: int, o: Options) -> str {
    let msg = be64(counter);
    let mac = hmac(o.algorithm, secret, msg);
    let off = (mac[len(mac) - 1] as int) & 15;
    let bin = (((mac[off] as int) & 0x7f) << 24) | ((mac[off + 1] as int) << 16) |
              ((mac[off + 2] as int) << 8) | (mac[off + 3] as int);
    let digits = clamp_digits(o.digits);
    let modulus = 1;
    for _ in 0..digits { modulus = modulus * 10; }
    let code = to_str(bin % modulus);
    while len(code) < digits { code = "0" + code; }
    return code;
}

// The TOTP code for a moment, in unix seconds.
pub fn totp(secret: bytes, unix_secs: int, o: Options) -> str {
    return hotp(secret, step_of(unix_secs, o), o);
}

// The time step (counter) a TOTP code at unix_secs belongs to.
pub fn step_of(unix_secs: int, o: Options) -> int {
    let step = o.step;
    if step <= 0 { step = 30; }
    if unix_secs < 0 { return 0; }
    return unix_secs / step;
}

// The time step code is valid for, within o.skew steps of unix_secs; none
// if it matches none. Compare the step with the last one accepted for the
// user to refuse replays.
pub fn verify_totp(secret: bytes, code: str, unix_secs: int, o: Options) -> opt[int] {
    let c = strings.trim(code);
    if len(c) != clamp_digits(o.digits) { return none; }
    let now = step_of(unix_secs, o);
    let found = -1;
    // every candidate is checked, so the time taken does not tell which
    // step (if any) matched
    for d in 0 - o.skew..o.skew + 1 {
        let s = now + d;
        if s < 0 { continue; }
        if crypto.constant_time_eq(to_bytes(hotp(secret, s, o)), to_bytes(c)) && found < 0 {
            found = s;
        }
    }
    if found < 0 { return none; }
    return some(found);
}

// The counter value code matches, looking ahead up to window counters from
// counter (HOTP resynchronisation); none if none does.
pub fn verify_hotp(secret: bytes, code: str, counter: int, window: int, o: Options) -> opt[int] {
    let c = strings.trim(code);
    if len(c) != clamp_digits(o.digits) { return none; }
    for k in counter..counter + window + 1 {
        if crypto.constant_time_eq(to_bytes(hotp(secret, k, o)), to_bytes(c)) {
            return some(k);
        }
    }
    return none;
}

// The otpauth:// URI authenticator apps read (usually from a QR code).
pub fn uri(secret: bytes, issuer: str, account: str, o: Options) -> str {
    let label = encoding.url_encode(issuer) + ":" + encoding.url_encode(account);
    let s = strings.trim(encoding.base32_encode(secret));
    while strings.has_suffix(s, "=") { s = strings.slice(s, 0, len(s) - 1); }
    return "otpauth://totp/" + label + "?secret=" + s + "&issuer=" +
           encoding.url_encode(issuer) + "&algorithm=" + o.algorithm + "&digits=" +
           to_str(clamp_digits(o.digits)) + "&period=" + to_str(o.step);
}

// A secret typed or pasted as base32 (spaces, lower case and missing
// padding allowed), as apps display it.
pub fn parse_secret(b32: str) -> result[bytes, str] {
    let s = strings.to_upper(strings.replace(strings.replace(b32, " ", ""), "-", ""));
    while len(s) % 8 != 0 { s = s + "="; }
    return encoding.base32_decode(s);
}

// ---- internals -----------------------------------------------------------

fn clamp_digits(d: int) -> int {
    if d < 6 { return 6; }
    if d > 10 { return 10; }
    return d;
}

fn be64(v: int) -> bytes {
    let b = builder.new_bytes();
    let shift = 56;
    while shift >= 0 {
        b.write_byte((v >> shift) & 255);
        shift = shift - 8;
    }
    return b.finish();
}

fn hmac(algorithm: str, key: bytes, msg: bytes) -> bytes {
    if algorithm == "SHA256" { return crypto.hmac_sha256(key, msg); }
    if algorithm == "SHA512" { return crypto.hmac_sha512(key, msg); }
    return hmac_sha1(key, msg);
}

// HMAC-SHA1 (RFC 2104) over crypto.sha1: the crypto package has no
// HMAC-SHA1, and HOTP's default needs it.
fn hmac_sha1(key: bytes, msg: bytes) -> bytes {
    let k = key;
    if len(k) > 64 { k = crypto.sha1(k); }
    let ipad = builder.new_bytes();
    let opad = builder.new_bytes();
    for i in 0..64 {
        let kb = 0;
        if i < len(k) { kb = k[i] as int; }
        ipad.write_byte(kb ^ 0x36);
        opad.write_byte(kb ^ 0x5c);
    }
    let inner = ipad.write(msg).finish();
    return crypto.sha1(opad.write(crypto.sha1(inner)).finish());
}
