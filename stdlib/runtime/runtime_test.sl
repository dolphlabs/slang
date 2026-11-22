import "time";

fn churn(n: int) -> int {
    let total = 0;
    for i in 0..n {
        let xs = [i, i + 1, i + 2, i + 3];
        total = total + len(xs);
    }
    return total;
}

fn test_should_count_collections_and_pauses_under_allocation() {
    let before = stats();
    let _t = churn(2000000);          // ~100 MB of short-lived lists
    let s = stats();
    assert(s.gc_minors > before.gc_minors, "no minor collections counted");
    assert(s.gc_majors >= before.gc_majors, "majors went down");
    assert(s.gc_pause_max_ns > 0, "no pause recorded");
    assert(s.gc_pause_max_ns <= s.gc_pause_total_ns, "max pause above the total");
    assert(s.gc_pause_total_ns > before.gc_pause_total_ns, "pause total did not grow");
}

fn test_should_report_memory() {
    let s = stats();
    assert(s.rss_bytes > 0 && s.rss_peak_bytes > 0, "no resident size");
    assert(s.rss_peak_bytes * 2 >= s.rss_bytes, "peak far below current");
    assert(s.heap_live_bytes >= 0 && s.heap_new_bytes >= 0, "negative heap");
}

fn sleeper(ns: int) {
    time.sleep(ns);
}

fn test_should_count_running_tasks_and_workers() {
    let base = stats().tasks;
    for _ in 0..5 { spawn sleeper(200000000); }
    time.sleep(20000000);
    let s = stats();
    assert(s.tasks == base + 5, "tasks " + to_str(s.tasks) + ", want " + to_str(base + 5));
    assert(s.workers >= 1, "no workers");
}
