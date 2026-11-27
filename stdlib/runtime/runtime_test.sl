import "time";
import "strings";

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

fn park_waiter(ch: chan[int]) {
    let _v = chan_recv(ch);
}

fn cpu_burner(done: chan[bool]) {
    let acc = 0;
    for i in 0..5000000 {
        acc = acc + (i * 3 + 1);
    }
    if acc < 0 { println("neg"); }
    chan_send(done, true);
}

fn test_should_dump_tasks_with_locations_and_wait_reasons() {
    let ch: chan[int] = make_chan(0);
    spawn park_waiter(ch);
    time.sleep(20000000);
    let dump = task_dump();
    chan_send(ch, 1);
    assert(strings.contains(dump, "# tasks:"), "missing header: " + dump);
    assert(strings.contains(dump, "[parked: chan recv]"), "missing wait reason: " + dump);
    assert(strings.contains(dump, "runtime_test.sl:"), "missing spawn location: " + dump);
    assert(strings.contains(dump, "(park_waiter)"), "missing callee name: " + dump);
}

fn test_should_format_heap_and_cpu_profiles_and_pprof_routes() {
    let _t = churn(200000);
    let hp = heap_profile();
    assert(strings.contains(hp, "# heap profile:"), "missing heap header: " + hp);
    assert(strings.contains(hp, "bytes"), "missing alloc bytes line: " + hp);

    let done: chan[bool] = make_chan(1);
    spawn cpu_burner(done);
    let cp = cpu_profile(80);
    let _ok = chan_recv(done);
    assert(strings.contains(cp, "# cpu profile: 80ms") ||
           strings.contains(cp, "# cpu profile: unavailable under sanitizer"),
           "missing cpu header: " + cp);

    let index_r = pprof_text("/debug/pprof/");
    guard let index_s = index_r else {
        assert(false, "index route failed");
        return;
    }
    assert(strings.contains(index_s, "/debug/pprof/tasks"), "index body");

    let tasks_r = pprof_text("/debug/pprof/tasks");
    guard let tasks_s = tasks_r else {
        assert(false, "tasks route failed");
        return;
    }
    assert(strings.contains(tasks_s, "# tasks:"), "tasks body");

    let heap_r = pprof_text("/debug/pprof/heap");
    guard let heap_s = heap_r else {
        assert(false, "heap route failed");
        return;
    }
    assert(strings.contains(heap_s, "# heap profile:"), "heap body");

    let stats_r = pprof_text("/debug/pprof/stats");
    guard let stats_s = stats_r else {
        assert(false, "stats route failed");
        return;
    }
    assert(strings.contains(stats_s, "gc_minors="), "stats body");

    let cpu_r = pprof_text("/debug/pprof/cpu?ms=40");
    guard let cpu_s = cpu_r else {
        assert(false, "cpu route failed");
        return;
    }
    assert(strings.contains(cpu_s, "# cpu profile: 40ms") ||
           strings.contains(cpu_s, "# cpu profile: unavailable under sanitizer"),
           "cpu body: " + cpu_s);

    let bad_cpu = pprof_text("/debug/pprof/cpu?ms=abc");
    guard let _bc = bad_cpu else {
        let missing = pprof_text("/debug/pprof/nope");
        guard let _m = missing else { return; }
        assert(false, "unknown pprof path must return err");
        return;
    }
    assert(false, "bad ms query must return err");
}
