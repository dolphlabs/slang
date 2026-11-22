# otp

> Package otp.

One-time passwords for two-factor sign-in: HOTP (RFC 4226) and TOTP
(RFC 6238), the codes authenticator apps show.

```slang
import "otp";

// enrolment: keep the secret, show the URI as a QR code
let secret = otp.new_secret() ?? b"";
let uri = otp.uri(secret, "Acme", "ada@example.com", otp.totp_options());

// sign-in: accept each code once
let matched = otp.verify_totp(secret, code, now_unix_secs, otp.totp_options());
guard let step = matched else { return deny(); }
if step <= user.last_otp_step { return deny(); }   // a replay
user.last_otp_step = step;
```

`totp_options()` gives 6 digits, 30-second steps, one step of skew either
side, and SHA-1 (what apps assume; `"SHA256"` and `"SHA512"` also work).
`verify_totp` compares in constant time and returns the time step that
matched, so a code cannot be used twice: within its 30 seconds it is
otherwise valid for anyone who saw it. There are also `hotp`, `totp`,
`verify_hotp` (with a look-ahead window), `parse_secret` (base32 as apps
show it) and `new_secret` (160 random bits). Checked against both RFCs'
test vectors.

## API

### `struct Options`

### `fn totp_options() -> Options`

### `fn new_secret() -> result[bytes, str]`

A random 160-bit secret, the size RFC 4226 recommends for SHA-1.

### `fn hotp(secret: bytes, counter: int, o: Options) -> str`

The HOTP code for a counter value.

### `fn totp(secret: bytes, unix_secs: int, o: Options) -> str`

The TOTP code for a moment, in unix seconds.

### `fn step_of(unix_secs: int, o: Options) -> int`

The time step (counter) a TOTP code at unix_secs belongs to.

### `fn verify_totp(secret: bytes, code: str, unix_secs: int, o: Options) -> opt[int]`

The time step code is valid for, within o.skew steps of unix_secs; none if it matches none. Compare the step with the last one accepted for the user to refuse replays.

### `fn verify_hotp(secret: bytes, code: str, counter: int, window: int, o: Options) -> opt[int]`

The counter value code matches, looking ahead up to window counters from counter (HOTP resynchronisation); none if none does.

### `fn uri(secret: bytes, issuer: str, account: str, o: Options) -> str`

The otpauth:// URI authenticator apps read (usually from a QR code).

### `fn parse_secret(b32: str) -> result[bytes, str]`

A secret typed or pasted as base32 (spaces, lower case and missing padding allowed), as apps display it.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
