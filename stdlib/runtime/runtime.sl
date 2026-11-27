// What the program's runtime is doing: garbage collection, memory, and
// tasks, for a /debug endpoint or metrics.
//
//     import "runtime";
//
//     let s = runtime.stats();
//     println(to_str(s.rss_bytes / 1048576) + " MB resident, " +
//             to_str(s.tasks) + " tasks, longest GC pause " +
//             to_str(s.gc_pause_max_ns / 1000) + " us");
//
// Reading them is cheap (a few atomic loads and one system call for the
// resident size); the counters are kept whether or not anything reads
// them, at a few atomic adds per collection.

import "proc";
import "strings";

pub struct Stats {
    gc_majors: int,          // full collections so far
    gc_minors: int,          // young-generation collections so far
    gc_pause_total_ns: int,  // time the program was stopped for both
    gc_pause_max_ns: int,    // the longest single stop
    heap_live_bytes: int,    // live after the last full collection
    heap_new_bytes: int,     // allocated since it
    rss_bytes: int,          // resident set size now (0 if unknown)
    rss_peak_bytes: int,     // the most it has been
    tasks: int,              // spawned tasks running
    workers: int,            // OS threads running tasks
}

pub fn stats() -> Stats {
    let v = proc.runtime_stats();
    return Stats {
        gc_majors: v[0], gc_minors: v[1], gc_pause_total_ns: v[2],
        gc_pause_max_ns: v[3], heap_live_bytes: v[4], heap_new_bytes: v[5],
        rss_bytes: v[6], rss_peak_bytes: v[7], tasks: v[8], workers: v[9]
    };
}

// Snapshot all live tasks (running, runnable, parked) with IDs, wait
// reasons, and spawn file/line locations.
pub fn task_dump() -> str {
    return proc.task_dump();
}

// Sample running worker PCs at 100 Hz for `duration_ms` (clamped to
// 10..60000 ms) and format hotspots mapped to Slang functions/lines.
pub fn cpu_profile(duration_ms: int) -> str {
    return proc.cpu_profile(duration_ms);
}

// Format GC/memory summary plus sampled allocation hotspots (defaults
// to 1 sample per 512 KB allocated; override via SLANG_ALLOC_PROFILE_RATE).
pub fn heap_profile() -> str {
    return proc.heap_profile();
}

// Text handler for HTTP /debug/pprof endpoints:
//   /debug/pprof, /debug/pprof/
//   /debug/pprof/tasks
//   /debug/pprof/heap
//   /debug/pprof/cpu[?ms=500]
//   /debug/pprof/stats
pub fn pprof_text(path: str) -> result[str, str] {
    if path == "/debug/pprof" || path == "/debug/pprof/" {
        return ok(
            "profiles:\n" +
            "  /debug/pprof/tasks\n" +
            "  /debug/pprof/heap\n" +
            "  /debug/pprof/cpu?ms=500\n" +
            "  /debug/pprof/stats\n"
        );
    }
    if path == "/debug/pprof/tasks" {
        return ok(task_dump());
    }
    if path == "/debug/pprof/heap" {
        return ok(heap_profile());
    }
    if path == "/debug/pprof/stats" {
        let s = stats();
        return ok(
            "gc_majors=" + to_str(s.gc_majors) +
            " gc_minors=" + to_str(s.gc_minors) +
            " gc_pause_total_ns=" + to_str(s.gc_pause_total_ns) +
            " gc_pause_max_ns=" + to_str(s.gc_pause_max_ns) +
            " heap_live_bytes=" + to_str(s.heap_live_bytes) +
            " heap_new_bytes=" + to_str(s.heap_new_bytes) +
            " rss_bytes=" + to_str(s.rss_bytes) +
            " rss_peak_bytes=" + to_str(s.rss_peak_bytes) +
            " tasks=" + to_str(s.tasks) +
            " workers=" + to_str(s.workers) + "\n"
        );
    }
    if path == "/debug/pprof/cpu" || strings.has_prefix(path, "/debug/pprof/cpu?") {
        let ms = 500;
        if strings.has_prefix(path, "/debug/pprof/cpu?") {
            let q = strings.slice(path, len("/debug/pprof/cpu?"), len(path));
            let pos = strings.find(q, "ms=");
            if pos >= 0 {
                let rest = strings.slice(q, pos + 3, len(q));
                let amp = strings.find(rest, "&");
                let raw = rest;
                if amp >= 0 {
                    raw = strings.slice(rest, 0, amp);
                }
                guard let parsed = to_int(raw) else {
                    return err("invalid ms query parameter");
                }
                ms = parsed;
            }
        }
        return ok(cpu_profile(ms));
    }
    return err("unknown pprof endpoint: " + path);
}
