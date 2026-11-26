# webauthn

> Package webauthn.

Passkeys and security keys for a relying party: WebAuthn registration
and login, checked on the server.

```slang
import "webauthn";

let rp = webauthn.relying_party("example.com", "Example", ["https://example.com"]);

// Registration: send ch.options to the page, keep ch.value in the session.
guard let ch = webauthn.begin_registration(rp, user, existing_credentials) else |e| { return fail(e); }
// page: navigator.credentials.create({ publicKey:
//         PublicKeyCredential.parseCreationOptionsFromJSON(options) }),
//       then POST JSON.stringify(credential)
guard let cred = webauthn.finish_registration(rp, ch.value, posted_json) else |e| { return fail(e); }   // store cred

// Login: the same shape.
let lc = webauthn.begin_login(rp, []);          // [] lets the user pick any passkey
let id = webauthn.login_credential_id(posted_json) ?? b"";   // look up the stored credential
guard let login = webauthn.finish_login(rp, challenge, stored, posted_json) else |e| { return fail(e); }
stored.sign_count = login.sign_count;           // and store it back
```

What `finish_registration` and `finish_login` check:

- **Client data:** the type, the challenge, and that the origin is one of
  `rp.origins`. Cross-origin iframe requests are refused.
- **Authenticator data:** the RP ID hash and the user-present flag, and the
  user-verified flag when `rp.user_verification` is `"required"`.
  Trailing or malformed data is refused.
- **Signature:** ES256 (P-256, from DER), EdDSA (Ed25519) or RS256, with
  RSA keys at least 2048 bits. The options offer these three.
- **Counter:** for an authenticator that keeps one, the signature counter
  must have gone up. A counter that did not is reported as a possible
  cloned authenticator.

A `Credential` holds the id, the COSE public key, the algorithm, the
counter, the AAGUID, and the backup flags (`backup_eligible`, set on a
syncable passkey).

`Login.user_handle` is the `User.id` a passkey keeps. When it is not
empty, the caller must check that it names the account the credential
belongs to. Challenges are 32 random bytes; keep each per session and use
it once.

**Not done, deliberately:** attestation is not verified. The options ask
for `"none"`, and whatever format arrives is recorded in
`Credential.format` and trusted no further. There is no metadata-service
lookup by AAGUID.

## API

### `gc struct JValue`

### `let ES256 = -7;`

COSE algorithm ids.

### `let EDDSA = -8;`

### `let RS256 = -257;`

### `gc struct RelyingParty`

### `fn relying_party(id: str, name: str, origins: [str]) -> RelyingParty`

### `gc struct User`

The account a credential is made for. `id` is an opaque handle of at most 64 bytes, never an email or a name: authenticators show `name` and `display_name`, and may keep `id` where anyone holding the device can read it.

### `gc struct Challenge`

A challenge to keep (value) and the options to send (options: JSON for parseCreationOptionsFromJSON / parseRequestOptionsFromJSON).

### `gc struct Credential`

A registered credential: what to store for the user. public_key is the COSE key as the authenticator sent it.

### `gc struct Login`

A login that checked out. user_handle is the User.id the authenticator keeps for a passkey ("" for a security key that does not): when it is not empty it must name the account the credential belongs to.

### `fn begin_registration(rp: RelyingParty, user: User, exclude: [Credential]) -> result[Challenge, str]`

Options for navigator.credentials.create: ES256, EdDSA and RS256 keys, a discoverable credential (a passkey) preferred, no attestation, and `exclude` (the user's existing credentials) so one authenticator is not registered twice.

### `fn begin_login(rp: RelyingParty, allow: [Credential]) -> result[Challenge, str]`

Options for navigator.credentials.get. `allow` lists the credentials that may answer; empty lets the user pick any passkey for this site.

### `fn verify_registration(rp: RelyingParty, challenge: bytes, client_data: bytes, attestation_object: bytes) -> result[Credential, str]`

Checks a registration from its parts: the client data JSON and the attestation object, both raw bytes (not base64url).

### `fn finish_registration(rp: RelyingParty, challenge: bytes, response_json: str) -> result[Credential, str]`

Checks a registration as the browser posts it: JSON.stringify of the PublicKeyCredential (its toJSON()).

### `fn verify_login(rp: RelyingParty, challenge: bytes, cred: Credential, client_data: bytes, authenticator_data: bytes, signature: bytes) -> result[Login, str]`

Checks a login from its parts, all raw bytes: the client data JSON, the authenticator data and the signature over both. The caller looked up `cred` by the credential id the browser sent.

### `fn login_credential_id(response_json: str) -> result[bytes, str]`

The credential id a posted login names, to look the stored credential up by before finish_login.

### `fn finish_login(rp: RelyingParty, challenge: bytes, cred: Credential, response_json: str) -> result[Login, str]`

Checks a login as the browser posts it: JSON.stringify of the PublicKeyCredential.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
