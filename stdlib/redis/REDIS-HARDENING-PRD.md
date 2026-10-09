# Redis driver hardening PRD

## Context

`stdlib/redis/redis.sl` is a RESP2 client implemented in slang. It exposes a
pure encoder/decoder, pooled connections, and blocking command helpers that
park tasks on socket I/O. Existing parsing limits cap one line, one bulk, one
array, and nesting depth. Earlier work removed whole-buffer copies between
ordinary replies, but a reply split across many receives still copies its
partial body repeatedly. Pool acquisition also polls every 2 ms when all
connections are checked out.

## Goal

Keep untrusted or unexpectedly large Redis replies within explicit resource
bounds, make fragmented reply reading scale with response size, and wake pool
waiters promptly and fairly under contention.

## Scope

1. Add per-reply aggregate byte and decoded-value budgets to `redis.Config`.
   Reject an over-limit reply before retaining or decoding bytes beyond the
   budget. Preserve the existing individual line, bulk, array, and nesting
   checks. Proposed defaults are 256 MiB total wire bytes and 1,000,000 total
   RESP array elements. Explicit larger limits let applications with
   large legitimate reads opt in.
2. Replace repeated concatenation of a growing partial reply with a bounded
   accumulation strategy whose work is linear or amortized linear in received
   bytes. Preserve `decode` and `decode_at` behavior for in-limit complete,
   incomplete, and concatenated replies.
3. Replace per-caller connection polling with FIFO waiter notification. Keep
   deadline expiry and pool close behavior; do not allocate GC objects while
   holding a mutex.

## Non-goals

No RESP3, command API redesign, cluster-routing changes, retry behavior,
automatic pool sizing, or driver-wide benchmark harness changes. No changes to
the Postgres driver. No new dependency on Redis server internals.

## Compatibility and safety

The wire encoding stays unchanged. The `Config` additions are a deliberate
public configuration API change. Replies over configured aggregate limits
return a protocol/resource-limit error and permanently break that connection,
like other corrupt replies. Limits above the defaults are permitted after
range validation, so large replies remain an explicit deployment choice. Pool
waiters retain FIFO order; timeout and close must wake each waiter exactly
once. Mutable connection state remains protected by the existing pool/connection
locks, and no GC allocation occurs under a mutex.

## Acceptance checks

- A regression input accepted by the old decoder exceeds the aggregate value
  limit and is rejected by the updated decoder. Include a wire-byte boundary
  check without requiring a huge fixture.
- Scripted-server coverage exercises a large reply delivered over many small
  reads, a reply at the configured limit, rejection above it, pool contention,
  deadline expiry, and pool close with waiters.
- The existing Redis unit, scripted-server, allocation-budget, and full test
  suites pass. Generated-C warning counts are reported.
- Measure old and new builds with ABBA ordering on a large fragmented reply
  and a saturated pool; record raw samples, allocations, throughput, and
  acquisition latency. Keep changes only when the copy/wait improvements are
  measurable and small-reply performance does not regress beyond run variance.
- Update `docs/packages/redis.md`, `next-steps.md`, and `todo.md` with the
  resulting limits, measurements, and any remaining limitations.

## Open decision

The owner approved configurable byte and element limits with those defaults.
Callers may raise either positive limit explicitly.
