# sigv4

> Package sigv4.

AWS Signature Version 4 for any service. `s3` signs with it, and so do
clients for SQS, SNS and the rest.

```slang
import "sigv4";

let s = sigv4.new_signer(access_key, secret_key, "eu-west-1", "sqs");
s.session_token = token;                    // temporary credentials, or leave ""
let h: map[str]str = {};
h["content-type"] = "application/x-amz-json-1.0";
h["x-amz-target"] = "AmazonSQS.SendMessage";
let amzdate = sigv4.amz_date_now();         // "20150830T123600Z"
let auth = sigv4.sign(s, "POST", "sqs.eu-west-1.amazonaws.com", "/", {}, h,
                      sigv4.payload_hash(body), amzdate);
// send Authorization: auth, X-Amz-Date: amzdate, the headers in h, and
// X-Amz-Security-Token when there is a token
let url_query = sigv4.presign(s, "GET", host, "/", {}, 900, amzdate);
```

`sign` signs the given headers plus `host`, `x-amz-date` and any security
token. The signing key is derived once a day per signer and replaced as a
whole, so a request never pairs one day's date with another day's key.
`derive_key`, `authorization` and `presign_query` are the same steps for a
caller that keeps its own key, as `s3` does. `uri_encode` and
`canonical_query` encode the way SigV4 signs. The tests use AWS's published
test-suite vectors.

**Limits.** Objects are read and written whole, in memory (or as one byte
range). Redirects are not followed, since a redirect would change the host
the signature covers.

## API

### `gc struct DayKey { date: str, key: bytes }`

The signing key for one day, held as one object so a request never pairs one day's date with another day's key while the day turns.

### `gc struct Signer`

### `fn new_signer(access_key: str, secret_key: str, region: str, service: str) -> Signer`

### `fn amz_date_now() -> str`

"20130524T000000Z" for now, UTC.

### `fn payload_hash(body: bytes) -> str`

The hex SHA-256 SigV4 signs as the payload hash.

### `fn derive_key(secret_key: str, date: str, region: str, service: str) -> bytes`

kSigning = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, date), region), service), "aws4_request"). `date` is YYYYMMDD.

### `fn signing_key(s: Signer, date: str) -> bytes`

The signer's key for `date`, derived once a day.

### `fn scope(date: str, region: str, service: str) -> str`

### `fn uri_encode(s: str, keep_slash: bool) -> str`

RFC 3986 percent-encoding as SigV4 wants it: everything but A-Z a-z 0-9 - _ . ~ (and / in paths, when keep_slash).

### `fn canonical_query(q: map[str]str) -> str`

Parameters encoded, then sorted by their encoded form: the order SigV4 signs and the order a request should send.

### `fn authorization(access_key: str, key: bytes, region: str, service: str, method: str, path: str, query: map[str]str, headers: map[str]str, payload: str, amzdate: str) -> str`

The Authorization header for a request whose signed headers are exactly `headers` (which must hold host and x-amz-date, and x-amz-security-token with temporary credentials). For callers that keep their own key cache, as s3 does; most callers want `sign`.

### `fn sign(s: Signer, method: str, host: str, path: str, query: map[str]str, headers: map[str]str, payload: str, amzdate: str) -> str`

The Authorization header for a request to `host`: signs `headers` plus host, x-amz-date and, with temporary credentials, x-amz-security-token. The caller sends X-Amz-Date (and the token) with the same values.

### `fn presign_query(access_key: str, key: bytes, region: str, service: str, session_token: str, method: str, host: str, path: str, query: map[str]str, expires_seconds: int, payload: str, amzdate: str) -> str`

The query string of a presigned URL (with X-Amz-Signature last), for a request that signs only the host header. `query` holds the request's own parameters; payload is usually "UNSIGNED-PAYLOAD". For callers with their own key cache; most callers want `presign`.

### `fn presign(s: Signer, method: str, host: str, path: str, query: map[str]str, expires_seconds: int, amzdate: str) -> str`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
