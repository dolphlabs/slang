# crypto

> Package crypto.

SHA-256, HMAC-SHA256, and a CSPRNG over OpenSSL. Hash and HMAC are
infallible on valid inputs and return `bytes` directly; `rand` can fail
and returns `result[bytes, str]`.

```slang
import "crypto";

let h: bytes = crypto.sha256(b"abc");              // 32 bytes
let m: bytes = crypto.hmac_sha256(key, msg);       // 32 bytes
let r = crypto.rand(32);
guard let b = r else let e = err_of(r) {
    log.error("rand failed: " + e);
}
```

## API

### `crypto.sha256(bytes) -> bytes`

### `crypto.hmac_sha256(bytes, bytes) -> bytes`

### `crypto.rand(int) -> result[bytes,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
