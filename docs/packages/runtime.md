# runtime

> Package runtime.

What the program's runtime is doing, for a `/debug` endpoint or metrics.

```slang
import "runtime";

let s = runtime.stats();
println(to_str(s.rss_bytes / 1048576) + " MB resident, " + to_str(s.tasks) +
        " tasks, longest GC pause " + to_str(s.gc_pause_max_ns / 1000) + " us");
```

`runtime.stats()` returns `gc_majors` and `gc_minors` (collections so
far), `gc_pause_total_ns` and `gc_pause_max_ns` (time the program was
stopped for them), `heap_live_bytes` (live after the last full
collection), `heap_new_bytes` (allocated since), `rss_bytes` and
`rss_peak_bytes` (resident memory now and at most), `tasks` (spawned
tasks running, the caller included if it is one) and `workers` (OS
threads running tasks). The counters are kept whether or not anything
reads them, at a few atomic adds per collection; reading them is a few
loads and one system call.

For live task inspection and built-in profiling (`pprof`-style text
endpoints and `SIGQUIT` task dumps):

- `runtime.task_dump()` snapshots all running, runnable, and parked tasks
  with task IDs, wait reasons (`chan recv`, `chan send`, `mutex`,
  `select`, `join`, `sleep`, `net io`, `wait_idle`), and spawn `file.sl:line`.
- `runtime.cpu_profile(duration_ms)` samples active workers at 100 Hz and
  aggregates hotspots resolved to Slang function names and source lines.
- `runtime.heap_profile()` formats GC/RSS totals and allocation hotspots
  (sampled every 512 KB by default; tune or disable via
  `SLANG_ALLOC_PROFILE_RATE`).
- `runtime.pprof_text(path)` dispatches `/debug/pprof/`, `/debug/pprof/tasks`,
  `/debug/pprof/heap`, `/debug/pprof/cpu?ms=500`, and `/debug/pprof/stats`
  directly for HTTP debug routes.
- Sending `SIGQUIT` (`kill -QUIT <pid>`) writes the live task dump to
  stderr without terminating the process.

## API

### `struct Stats`

### `fn stats() -> Stats`

### `fn task_dump() -> str`

Snapshot all live tasks (running, runnable, parked) with IDs, wait reasons, and spawn file/line locations.

### `fn cpu_profile(duration_ms: int) -> str`

Sample running worker PCs at 100 Hz for `duration_ms` (clamped to 10..60000 ms) and format hotspots mapped to Slang functions/lines.

### `fn heap_profile() -> str`

Format GC/memory summary plus sampled allocation hotspots (defaults to 1 sample per 512 KB allocated; override via SLANG_ALLOC_PROFILE_RATE).

### `fn pprof_text(path: str) -> result[str, str]`

Text handler for HTTP /debug/pprof endpoints: /debug/pprof, /debug/pprof/ /debug/pprof/tasks /debug/pprof/heap /debug/pprof/cpu[?ms=500] /debug/pprof/stats

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
