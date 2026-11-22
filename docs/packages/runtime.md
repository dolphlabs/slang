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

## API

### `struct Stats`

### `fn stats() -> Stats`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
