# crypto

> Package crypto.

Hashes, MACs, key derivation, authenticated encryption and signatures
over OpenSSL: SHA-256/384/512 and their HMACs, HKDF, PBKDF2, Argon2id,
AES-256-GCM and ChaCha20-Poly1305, Ed25519, ECDSA P-256, RSA, and a
CSPRNG. Hashes and HMACs are infallible on valid inputs and return
`bytes` directly; anything that can fail returns a `result`.

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

**Hashes, MACs, key derivation.** `sha384`/`sha512` and
`hmac_sha384`/`hmac_sha512` (JWS HS384/HS512) sit beside the SHA-256 ones.
`hkdf_sha256(ikm, salt, info, length)` and `hkdf_sha512` are RFC 5869 HKDF:
use them to derive several keys from one secret, never a bare hash. The
length is 1 to 255 hash lengths. `constant_time_eq(a, b)` compares in
time that depends only on the length: use it for MACs, tokens and anything
else an attacker could probe a byte at a time.

```slang
let enc = crypto.hkdf_sha256(master, salt, b"cookie-encryption", 32);
let mac_ok = crypto.constant_time_eq(crypto.hmac_sha256(k, body), sent_mac);
```

**Authenticated encryption.** `seal(key, plaintext, aad)` encrypts with
AES-256-GCM under a fresh random nonce and returns nonce, ciphertext and
tag in one `bytes`. `open(key, box, aad)` checks and decrypts it. The aad
(associated data, which may be empty) is authenticated but not encrypted:
bind a cookie to its name, a record to its id. Because the caller never
chooses a nonce, it cannot reuse one, the mistake that breaks GCM
outright. A key should seal fewer than 2^32 messages this way, so rotate
it, for example via HKDF with a date in `info`. When a protocol fixes the
nonce, `aes256gcm_seal`/`aes256gcm_open` and
`chacha20poly1305_seal`/`chacha20poly1305_open` take (key, nonce, data,
aad) with a 32-byte key and a 12-byte nonce, and carry ciphertext then a
16-byte tag. Every opener returns an error, never partial plaintext, when
anything was altered.

```slang
let box = crypto.seal(key, to_bytes(session_json), b"session");
let back = crypto.open(key, box ?? b"", b"session");   // err if tampered
```

**Signatures.** Keys use the raw forms JWK and JWS use. Ed25519 has a
32-byte private seed, a 32-byte public key and a 64-byte signature.
ECDSA P-256 with SHA-256 (JWS ES256) has a 32-byte private scalar, a
65-byte uncompressed public point (`0x04 || x || y`) and a 64-byte
`r || s` signature. RSA keys are PEM text.

| | Ed25519 | ECDSA P-256 | RSA (SHA-256) |
|---|---|---|---|
| new key | `ed25519_generate()` | `ecdsa_p256_generate()` | `rsa_generate(bits)` (PEM) |
| public key | `ed25519_public_key(priv)` | `ecdsa_p256_public_key(priv)` | `rsa_public_n(pem)`, `rsa_public_e(pem)` |
| sign | `ed25519_sign(priv, msg)` | `ecdsa_p256_sign_sha256(priv, msg)` | `rsa_sign_sha256(pem, msg)` (RS256), `rsa_sign_pss_sha256` (PS256) |
| verify | `ed25519_verify(pub, msg, sig)` | `ecdsa_p256_verify_sha256(pub, msg, sig)` | `rsa_verify_sha256(n, e, msg, sig)`, `rsa_verify_pss_sha256` |
| from PEM | `ed25519_private_from_pem`, `ed25519_public_from_pem` | `ecdsa_p256_private_from_pem`, `ecdsa_p256_public_from_pem` | (sign takes PEM) |
| encrypt | | | `rsa_encrypt_oaep_sha256(pem, data)`, `rsa_encrypt_oaep_sha1` |
| decrypt | | | `rsa_decrypt_oaep_sha256(pem, data)`, `rsa_decrypt_oaep_sha1` |

Verifiers return `ok(false)` for a signature that does not verify
(including one of the wrong length) and `err` for a malformed key, such
as a P-256 point that is not on the curve. ECDSA signatures are
deterministic (RFC 6979) on OpenSSL 3.2 and newer, so a weak random
number generator cannot leak the key; older 3.x uses random nonces. PSS
fixes the salt at the digest length, as PS256 requires. RSA key
generation takes tens of milliseconds at 2048 bits and seconds at 4096,
without yielding, so do it at startup or in a tool. Prepared keys are
cached (up to 16), so signing or verifying repeatedly with the same keys,
as a server does with its JWT key or a JWKS, skips rebuilding them.
RSA-OAEP encrypts to a public key and decrypts with the private one, the
same hash for the label and MGF1. Use SHA-256 for anything new; SHA-1 is
there for MySQL's password exchange, and OAEP does not depend on the
hash's collision resistance the way a signature does.

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

### `crypto.sha384(bytes) -> bytes`

### `crypto.sha512(bytes) -> bytes`

### `crypto.hmac_sha384(bytes, bytes) -> bytes`

### `crypto.hmac_sha512(bytes, bytes) -> bytes`

### `crypto.hkdf_sha256(bytes, bytes, bytes, int) -> result[bytes,str]`

### `crypto.hkdf_sha512(bytes, bytes, bytes, int) -> result[bytes,str]`

### `crypto.constant_time_eq(bytes, bytes) -> bool`

### `crypto.aes256gcm_seal(bytes, bytes, bytes, bytes) -> result[bytes,str]`

### `crypto.aes256gcm_open(bytes, bytes, bytes, bytes) -> result[bytes,str]`

### `crypto.chacha20poly1305_seal(bytes, bytes, bytes, bytes) -> result[bytes,str]`

### `crypto.chacha20poly1305_open(bytes, bytes, bytes, bytes) -> result[bytes,str]`

### `crypto.seal(bytes, bytes, bytes) -> result[bytes,str]`

### `crypto.open(bytes, bytes, bytes) -> result[bytes,str]`

### `crypto.ed25519_generate() -> result[bytes,str]`

### `crypto.ed25519_public_key(bytes) -> result[bytes,str]`

### `crypto.ed25519_sign(bytes, bytes) -> result[bytes,str]`

### `crypto.ed25519_verify(bytes, bytes, bytes) -> result[bool,str]`

### `crypto.ed25519_private_from_pem(str) -> result[bytes,str]`

### `crypto.ed25519_public_from_pem(str) -> result[bytes,str]`

### `crypto.ecdsa_p256_generate() -> result[bytes,str]`

### `crypto.ecdsa_p256_public_key(bytes) -> result[bytes,str]`

### `crypto.ecdsa_p256_sign_sha256(bytes, bytes) -> result[bytes,str]`

### `crypto.ecdsa_p256_verify_sha256(bytes, bytes, bytes) -> result[bool,str]`

### `crypto.ecdsa_p256_private_from_pem(str) -> result[bytes,str]`

### `crypto.ecdsa_p256_public_from_pem(str) -> result[bytes,str]`

### `crypto.rsa_generate(int) -> result[str,str]`

### `crypto.rsa_public_n(str) -> result[bytes,str]`

### `crypto.rsa_public_e(str) -> result[bytes,str]`

### `crypto.rsa_sign_sha256(str, bytes) -> result[bytes,str]`

### `crypto.rsa_sign_pss_sha256(str, bytes) -> result[bytes,str]`

### `crypto.rsa_encrypt_oaep_sha1(str, bytes) -> result[bytes,str]`

### `crypto.rsa_decrypt_oaep_sha1(str, bytes) -> result[bytes,str]`

### `crypto.rsa_encrypt_oaep_sha256(str, bytes) -> result[bytes,str]`

### `crypto.rsa_decrypt_oaep_sha256(str, bytes) -> result[bytes,str]`

### `crypto.rsa_verify_pss_sha256(bytes, bytes, bytes, bytes) -> result[bool,str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
