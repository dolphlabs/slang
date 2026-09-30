# Task: ratelimit (per-client rate limiting)

- `GET /ping`: `200` and `{"pong": true}`.
- Requests are limited per client, identified by the `X-Client-Id` header
  (a request without it counts as the client `anonymous`): each client may
  make at most 5 requests in any rolling 1-second window.
- A request over the limit gets `429` with code `rate_limited` and a
  `Retry-After` header: a whole number of seconds, at least 1.
- Clients are independent: one client being limited never affects another.
- Once a client's window has passed, its requests succeed again.
