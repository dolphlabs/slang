# oidc

> Package oidc.

OAuth 2.0 and OpenID Connect for a client: sign users in with Google,
Microsoft, Okta, Auth0, Keycloak and the like, and get tokens for
service-to-service calls.

```slang
import "oidc";

let pr = oidc.discover("https://accounts.google.com", deadline);
guard let provider = pr else { return err("no provider"); }
let o = oidc.client(provider, client_id, client_secret, "https://app.example/callback");

// 1. send the browser off; keep state, nonce and pk.verifier in the session
let pk = oidc.pkce() ?? fail();
let state = oidc.random_token() ?? "";
let nonce = oidc.random_token() ?? "";
redirect(oidc.authorize_url(o, ["openid", "email"], state, nonce, pk));

// 2. on the callback, after checking state: trade the code
let tr = oidc.exchange(o, code, pk.verifier, deadline);
guard let tokens = tr else { return err("sign-in failed"); }
let cr = oidc.verify_id_token(o, tokens.id_token, nonce, deadline);
guard let who = cr else { return err("bad ID token"); }     // who.sub, who.email
```

`discover` checks that the document's issuer is the one asked for and
that the endpoints are HTTPS. `exchange`, `refresh` and
`client_credentials` authenticate with `client_secret_basic`.
`verify_id_token` follows OpenID Connect Core 3.1.3.7:

- the signature is checked against the provider's published keys, RS256
  or ES256 only (`none` and HMAC are refused);
- the issuer, the audience (and `azp` when there are several), expiry
  with a minute of leeway, and the nonce are checked.

Keys are cached by `kid` and refetched, at most once a minute, when a
token names one not seen yet. `Claims.raw` holds every claim.

## API

### `gc struct JValue`

### `struct Provider`

### `gc struct Client`

### `struct Pkce`

### `struct Tokens`

### `struct Claims`

### `fn discover(issuer: str, deadline: until) -> result[Provider, str]`

The provider's configuration from its discovery document. Its issuer must equal the one asked for, and endpoints must be https (http is allowed only on localhost, for tests).

### `fn client(p: Provider, client_id: str, client_secret: str, redirect_uri: str) -> Client`

### `fn pkce() -> result[Pkce, str]`

A PKCE verifier (keep it in the session) and its S256 challenge.

### `fn random_token() -> result[str, str]`

32 random bytes, base64url: for state and nonce.

### `fn authorize_url(o: Client, scopes: [str], state: str, nonce: str, pk: Pkce) -> str`

Where to send the browser to sign in.

### `fn exchange(o: Client, code: str, verifier: str, deadline: until) -> result[Tokens, str]`

Trades an authorization code (with its PKCE verifier) for tokens.

### `fn refresh(o: Client, refresh_token: str, deadline: until) -> result[Tokens, str]`

### `fn client_credentials(o: Client, scopes: [str], deadline: until) -> result[Tokens, str]`

Tokens for the client itself (service to service).

### `fn verify_id_token(o: Client, token: str, nonce: str, deadline: until) -> result[Claims, str]`

Checks an ID token and returns its claims.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
