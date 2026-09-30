# Task: jobs (background worker)

Clients submit jobs that run in the background, off the request path.

- `POST /jobs` with `{"n": <int 1..40>, "delay_ms": <int 0..2000>}`:
  `202` and `{"id": <int>, "status": "queued"}`, returned immediately
  (well before the job finishes). Ids start at 1. Invalid input: `400`
  with code `invalid`.
- A job waits `delay_ms` milliseconds, then computes the n-th Fibonacci
  number (fib(1) = 1, fib(2) = 1, fib(3) = 2, ...).
- `GET /jobs/<id>`: `200` and `{"id": ..., "status": "queued" | "running" |
  "done"}`, plus `"result": <int>` once done. Unknown id: `404` with code
  `not_found`.
- At least 4 jobs must be able to run at the same time: 4 jobs submitted
  together, each with `delay_ms` 500, must all be done within 1.5 seconds.
