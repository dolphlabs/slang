# Optimisation — beating Go and Rust on HTTP p99 + RSS

Goal: Phase E win vs Go on **both** p99 and RSS (RPS already wins). Track top to bottom, tick as they land. Each item gets its own branch, merged to `dev` via PR.

Baseline (4-core Linux VM, wrk 3x10s, spawn-inline + for-in hoist): c=50 slang p99 5.98ms / RSS 18804KB vs Go 3.11ms / 14732KB vs Rust 1.14ms / 4208KB. RPS beats Go; tail + memory do not. Fairness note: slang bench does no HTTP parsing, Go/Rust do, C is the apples-to-apples peer.

Raw-axis remasure (8a1c68b, same VM, wrk 3x10s, HTTP_ACCEPTORS=4, quantum 50ms / tick 10ms, frozen ruler untouched): c=50 slang_opt 91307 rps / 3.76ms / 16624KB vs go_raw 82572 / 1.47 / 10476 vs rust_raw 85371 / 1.06 / 3332 vs C 103187 / 1.31 / 1788. c=200 slang_opt 93352 / 7.21 / 18072 vs go_raw 88406 / 5.15 / 11736 vs rust_raw 87779 / 2.96 / 3596 vs C 102696 / 3.90 / 1788. RPS lead held; p99 and RSS still lose on a fair axis. Items 1-8 bought ~-37% p99 and ~-12% RSS, not a phase change.

## Round 1 (done)

- [x] 1. GC pause attribution (histogram + per-request alloc counters, behind a flag) — PR #41 `perf/gc-pause-attribution`
- [x] 2. Zero-alloc serve path (link.send_bytes, no wire copy) — PR #42 `perf/zero-alloc-serve`
- [x] 3. Safepoint elision (pure calls skip brackets) — PR #43 `perf/safepoint-elision`
- [x] 4. Multi-acceptor (link_listen reuse flag, SO_REUSEPORT) — PR #44 `perf/multi-acceptor`
- [x] 5. Per-worker run queues + fd-sharded reactor waiters — scheduler counters first (PR #45 `perf/per-worker-queues`); striped queues with split linkage + stripe-aware wakeup (PR #46 `perf/runq-wakeup-redesign`)
- [x] 6. Size-class pooling for hot fixed allocs (exact-total freelist, PR #47 `perf/tl-alloc-fastpath`)
- [x] 7. Preemption tuning for IO-bound loads (env quantum/ticker, yield/async counters, PR #49 `perf/preempt-tuning`)
- [x] 8. Memory release discipline (DONTNEED oversize arenas, freelist visibility, PR #50 `perf/memory-release`)

## Round 2 (raw-axis gaps)

Per-request allocated, parked, switched, and collected work that C/Rust/Go-raw skip. Same 200B job, different cost per request. In leverage order; ruler (`bench/http/main.sl`) stays frozen, work lands in `bench/http_opt` / runtime.

- [ ] 9. Static response bytes (no GC alloc on serve: intern `b"..."` or `send_static`; GC nearly never fires on the bench)
- [ ] 10. Per-worker reactor (one epoll + waiter shard per worker, fds pinned by accept stripe; remove the single global IO funnel)
- [ ] 11. Task + arena recycling (per-worker task/stack cache, reused recv arena; per-conn setup becomes pointer bumps)
- [ ] 12. GC-free fast-path detection (skip checkin/registration on zero-alloc serve paths; adaptive threshold when survival is ~0)
- [ ] 13. Split the axes in docs (raw-throughput vs real-server claims separated; ruler vs opt vs stdlib/http callouts)
