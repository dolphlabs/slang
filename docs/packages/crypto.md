# crypto

> Package crypto.

SHA-256, HMAC-SHA256, PBKDF2, MD5 and a CSPRNG over OpenSSL. Hashes and
HMAC are infallible on valid inputs and return `bytes` directly; `rand`
and `pbkdf2_sha256` can fail and return `result[bytes, str]`.

```slang
import "crypto";

let h: bytes = crypto.sha256(b"abc");              // 32 bytes
let m: bytes = crypto.hmac_sha256(key, msg);       // 32 bytes
let r = crypto.rand(32);
guard let b = r else let e = err_of(r) {
    log.error("rand failed: " + e);
}
let k = crypto.pbkdf2_sha256(password, salt, 600000, 32);   // RFC 8018
let s1: bytes = crypto.sha1(b"abc");               // 20 bytes
let d: bytes = crypto.md5(b"abc");                 // 16 bytes
```

`pbkdf2_sha256(password, salt, iterations, length)` accepts 1 to
10,000,000 iterations and a length of 1 to 1024 bytes; anything else is
an `err`. The iteration count is capped because it is often chosen by the
other side of a protocol (a SCRAM server sends it) and the whole
derivation runs without yielding the worker thread.

`sha1` and `md5` are broken for collision resistance. They exist for the
protocols that still specify them and cannot be changed -- the WebSocket
handshake (RFC 6455) hashes the client's key with a fixed GUID, Git
object ids, Postgres md5 authentication, `Content-MD5`,
legacy ETags -- and must not protect anything new.

The low-level `argon2id_raw` and `argon2id_verify` primitives support the
standalone [`argon` package](https://github.com/dolphlabs/argon), which emits
standard PHC password hashes. They accept byte passwords and salts and
validated cost parameters; verification returns `ok(false)` for a mismatch
and compares tags in constant time. Calls require OpenSSL 3.2 or newer with
Argon2id support; on older OpenSSL builds they return an error while the
other `crypto` functions remain available. Use the package's bounded PHC
parser rather than parsing stored hashes in application code.

A derivation is tens of milliseconds of work that cannot be preempted. In
a program that links the reactor (anything importing `net` or `io`, so
every server), it runs on a small pool of dedicated kdf threads while the
calling task parks, the way a DNS lookup does: a burst of logins neither
pins the pool's workers nor holds up a collection. `SLANG_KDF_THREADS`
sets the pool size (default: one per worker). Each in-flight derivation
holds its `memory_kib`, so bound how many you start, as you would any
other expensive request. Without the reactor it derives on the calling
worker.

`rsa_verify_sha256(n, e, msg, sig) -> result[bool, str]` checks an
RSASSA-PKCS1-v1_5 SHA-256 signature (JWS `RS256`) against a public key
given as its raw big-endian modulus and exponent, which is what a JWKS
entry's base64url `n` and `e` decode to. `ok(false)` is a signature that
does not verify, including one of the wrong length; `err` is a key out of
bounds (a 2048- to 8192-bit modulus, a 1- to 8-byte exponent) or one
OpenSSL rejects.

```slang
import "crypto";

let r = crypto.rsa_verify_sha256(n, e, to_bytes(header_dot_payload), sig);
let valid = r ?? false;
```

## API

### `crypto.sha256(bytes) -> bytes`

### `crypto.hmac_sha256(bytes, bytes) -> bytes`

### `crypto.rand(int) -> result[bytes,str]`

### `crypto.sha1(bytes) -> bytes`

### `crypto.md5(bytes) -> bytes`

### `crypto.pbkdf2_sha256(bytes, bytes, int, int) -> result[bytes,str]`

### `crypto.argon2id_raw(bytes, bytes, int, int, int, int) -> result[bytes,str]`

### `crypto.argon2id_verify(bytes, bytes, bytes, int, int, int) -> result[bool,str]`

### `crypto.rsa_verify_sha256(bytes, bytes, bytes, bytes) -> result[bool,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
