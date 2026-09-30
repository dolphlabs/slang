# Task: auth (login, bearer tokens, middleware)

Two users exist: `alice` with password `wonderland`, and `bob` with password
`builder`.

- `GET /health`: `200` and `{"ok": true}`. Needs no token.
- `POST /login` with `{"user": ..., "password": ...}`: `200` and
  `{"token": "<opaque string>"}` for a correct pair; otherwise `401` with
  code `unauthorized`. Each login issues a new token; tokens must not be
  guessable (at least 128 bits from a cryptographically secure source).
- Every route below needs `Authorization: Bearer <token>`. A missing,
  malformed or unknown token gets `401` with code `unauthorized`.
- `GET /me`: `200` and `{"user": "<name>"}` for the token's user.
- `POST /logout`: `204`; the token stops working. Other tokens of the same
  user keep working.
