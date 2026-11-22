# acme

> Package acme.

Certificates from Let's Encrypt or any ACME CA (RFC 8555), obtained and
renewed by the program itself with http-01 challenges.

```slang
import "acme";
import "crypto";

let store = acme.challenges();
// in the port-80 handler: answer acme.http01(store, path) when it is some(body)

let key = crypto.ecdsa_p256_generate() ?? b"";      // keep it: it is the account
let ar = acme.account(acme.LETSENCRYPT, key, ["mailto:ops@example.com"], deadline);
guard let acct = ar else { return err("acme account"); }
let cr = acme.obtain(acct, store, ["example.com", "www.example.com"], deadline);
guard let cert = cr else { return err("acme order"); }
// cert.chain_pem and cert.key_pem: serve them with net.tls_ctx_add_sni
if acme.renew_due(cert.chain_pem, 30) { /* obtain again */ }
```

- `account` registers (or finds) the account for a P-256 key and agrees
  to the CA's terms.
- `obtain` orders the names, publishes each http-01 key authorization in
  the store while the CA checks it, finalizes with a CSR for a fresh
  P-256 key, and downloads the chain.
- Requests are JWS-signed (ES256) with the replay-nonce protocol, and
  retried once on `badNonce`.
- `LETSENCRYPT_STAGING` is for trying it out without production rate
  limits.

## API

### `let LETSENCRYPT = "https://acme-v02.api.letsencrypt.org/directory";`

### `let LETSENCRYPT_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory";`

### `gc struct Account`

### `struct Dir`

### `struct Certificate`

### `gc struct Challenges`

### `fn challenges() -> Challenges`

### `fn http01(c: Challenges, path: str) -> opt[str]`

The body to answer a GET for path with, if it is a pending http-01 challenge ("/.well-known/acme-challenge/<token>").

### `fn account(directory_url: str, key: bytes, contact: [str], deadline: until) -> result[Account, str]`

Registers (or finds) the account for key at the CA, agreeing to its terms of service.

### `fn obtain(a: Account, store: Challenges, names: [str], deadline: until) -> result[Certificate, str]`

Orders a certificate for names (DNS names), answers their http-01 challenges through store, and returns the issued chain with its new key.

### `fn renew_due(chain_pem: str, days: int) -> bool`

Whether a certificate expires within days.

### `gc struct JValue`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
