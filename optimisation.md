# Optimisation — beating Go and Rust on HTTP p99 + RSS

Goal: Phase E win vs Go on **both** p99 and RSS (RPS already wins). Track top to bottom, tick as they land. Each item gets its own branch, merged to `dev` via PR.

Baseline (4-core Linux VM, wrk 3x10s, spawn-inline + for-in hoist): c=50 slang p99 5.98ms / RSS 18804KB vs Go 3.11ms / 14732KB vs Rust 1.14ms / 4208KB. RPS beats Go; tail + memory do not. Fairness note: slang bench does no HTTP parsing, Go/Rust do, C is the apples-to-apples peer.

- [x] 1. GC pause attribution (histogram + per-request alloc counters, behind a flag) — PR #41 `perf/gc-pause-attribution`
- [x] 2. Zero-alloc serve path (link.send_bytes, no wire copy) — PR #42 `perf/zero-alloc-serve`
- [x] 3. Safepoint elision (pure calls skip brackets) — PR #43 `perf/safepoint-elision`
- [x] 4. Multi-acceptor (link_listen reuse flag, SO_REUSEPORT) — PR #44 `perf/multi-acceptor`
- [x] 5. Per-worker run queues + fd-sharded reactor waiters — scheduler counters first (PR #45 `perf/per-worker-queues`); full striped queues reverted (hung: parked-task `next` reuse + global condvar sleep)
- [ ] 6. Thread-local allocation fast path + size-class pooling (no malloc per request)
- [ ] 7. Preemption tuning for IO-bound loads (longer quantum / ticker, gate on runq depth)
- [ ] 8. Memory release discipline (madvise on large freed chunks, cap freelist hoarding)
