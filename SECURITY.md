# Security policy

## Supported versions

slang is pre-1.0. Only the latest release (currently **v0.2.0**) and `main`
get security fixes. Fixes land on `dev` first and reach a release from
`main`.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Report it
privately through GitHub:

<https://github.com/dolphlabs/slang/security/advisories/new>

(or the repository's **Security** tab → **Report a vulnerability**). Only the
maintainers can see it.

If that form is not available, open a public issue titled
`security contact request` with **no details** in it, and a maintainer will
arrange a private way to talk.

A useful report has:

- the slang version (`slangc --version`), the OS and architecture, and the C
  compiler;
- the smallest program, or the exact request bytes, that shows it;
- what you expected, what happened, and what you think an attacker gains.

We will acknowledge the report, keep you informed while we work on it, and
credit you in the fix unless you would rather we did not. Please give us a
reasonable chance to fix a problem before you publish it.

## What counts as a vulnerability

In scope:

- **Memory safety** in the runtime (the collector, the scheduler and green
  threads, the compiler's generated code) that a well-typed program written
  without `unsafe` or `extern fn` can reach.
- The compiler **accepting a program that breaks a safety rule it claims to
  enforce** (moves, borrows, bounds) in a way that leads to memory unsafety.
- The **`http`, `http2` and `httpc`** implementations: request smuggling and
  parsing disagreements, and a small input that costs disproportionate CPU or
  memory.
- **TLS certificate and hostname verification** in `net`, the `pg` driver's
  authentication (SCRAM-SHA-256, md5), and `crypto`.

Not in scope:

- Anything inside an `unsafe` block or behind an `extern fn`: those are
  documented as unchecked (see *C interop* in the README).
- Bugs in a program's own logic.
- Problems in OpenSSL, SQLite or zlib themselves; report those upstream. slang
  links the copies installed on your system and does not bundle them (see
  [THIRD_PARTY.md](THIRD_PARTY.md)).

## Fixed before this policy existed

These were found by the project's own testing, not reported by users, and are
listed so the record is plain. There are no CVE identifiers for them.

- **HTTP request framing** in the `http` server accepted two disagreeing
  `Content-Length` headers (the last silently won), and a `Content-Length` of
  2^64 + 3 wrapped to 3, leaving the rest of the body to be read as the next
  request. Both are request-smuggling holes. They are now refused, along with
  `Transfer-Encoding` combined with `Content-Length`, `Transfer-Encoding` in
  HTTP/1.0, and bare LFs.
- **Quadratic request reading** in the `http` server: a 50 KB POST cost 1.0 s
  of CPU and a 200 KB one 24.7 s, because the receive buffer was rebuilt a
  byte at a time. A 200 KB body is now read in under 10 ms.
- **A use-after-free in the DNS resolver's handoff** (#159): the resolver
  thread read a lookup job after handing it back to the caller, which closed
  file descriptor 0 and, later, a live connection.

The details are in the pull requests: #138 for the first two, #159 for the
third.
