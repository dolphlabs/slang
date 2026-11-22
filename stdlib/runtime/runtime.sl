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
