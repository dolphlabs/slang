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
let d: bytes = crypto.md5(b"abc");                 // 16 bytes
```

`pbkdf2_sha256(password, salt, iterations, length)` accepts 1 to
10,000,000 iterations and a length of 1 to 1024 bytes; anything else is
an `err`. The iteration count is capped because it is often chosen by the
other side of a protocol (a SCRAM server sends it) and the whole
derivation runs without yielding the worker thread.

`md5` is broken for collision resistance. It exists for the protocols
that still specify it -- Postgres md5 authentication, `Content-MD5`,
legacy ETags -- and must not protect anything new.

## API

### `crypto.sha256(bytes) -> bytes`

### `crypto.hmac_sha256(bytes, bytes) -> bytes`

### `crypto.rand(int) -> result[bytes,str]`

### `crypto.md5(bytes) -> bytes`

### `crypto.pbkdf2_sha256(bytes, bytes, int, int) -> result[bytes,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
