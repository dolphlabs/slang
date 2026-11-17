// Unit tests: `slangc test stdlib/cache`.

import "strings";
import "time";

fn small(max: int) -> Cache[int] {
    let o = options();
    o.max_entries = max;
    o.shards = 1;
    let r: result[Cache[int], str] = new(o);
    guard let c = r else let e = err_of(r) { panic(e); }
    return c;
}

fn val(c: Cache[int], k: str) -> int {
    return get(c, k) ?? -1;
}

fn test_should_evict_the_least_recently_used() {
    let c = small(3);
    put(c, "a", 1);
    put(c, "b", 2);
    put(c, "c", 3);
    assert(val(c, "a") == 1, "a is there and now the most recent");
    put(c, "d", 4);
    assert(val(c, "b") == -1, "b was the least recently used");
    assert(val(c, "a") == 1 && val(c, "c") == 3 && val(c, "d") == 4, "the rest stay");
    assert(len_of(c) == 3, "three entries");
    put(c, "c", 30);
    put(c, "e", 5);
    assert(val(c, "c") == 30, "an update counts as a use and replaces the value");
    assert(val(c, "a") == -1, "a went next");
    let st = stats(c);
    assert(st.evictions == 2 && st.entries == 3, "evictions " + to_str(st.evictions));
}

fn test_should_expire_entries() {
    let o = options();
    o.ttl_ms = 30;
    o.shards = 1;
    let r: result[Cache[str], str] = new(o);
    guard let c = r else let e = err_of(r) { panic(e); }
    put(c, "short", "s");
    put_ttl(c, "long", "l", 10000);
    put_ttl(c, "forever", "f", 0);
    assert((get(c, "short") ?? "") == "s", "fresh");
    time.sleep(60000000);
    assert((get(c, "short") ?? "gone") == "gone", "expired after its ttl");
    assert((get(c, "long") ?? "") == "l" && (get(c, "forever") ?? "") == "f", "their own ttls");
    assert(stats(c).expirations == 1, "one expiration");
}

fn test_should_bound_bytes() {
    let o = options();
    o.max_bytes = 100;
    o.shards = 1;
    let r: result[Cache[str], str] = new(o);
    guard let c = r else let e = err_of(r) { panic(e); }
    put_sized(c, "a", "x", 40);
    put_sized(c, "b", "y", 40);
    assert(stats(c).used_bytes == 82, "sizes plus keys: " + to_str(stats(c).used_bytes));
    put_sized(c, "c", "z", 40);
    assert((get(c, "a") ?? "gone") == "gone" && len_of(c) == 2, "over 100 bytes: the oldest goes");
    put_sized(c, "huge", "h", 500);
    assert(len_of(c) == 1 && (get(c, "huge") ?? "") == "h", "an entry larger than the limit still fits alone");
}

fn test_should_remove_and_clear() {
    let c = small(10);
    put(c, "a", 1);
    put(c, "b", 2);
    assert(remove(c, "a") && !remove(c, "a"), "remove once");
    assert(val(c, "a") == -1 && len_of(c) == 1, "gone");
    clear(c);
    assert(len_of(c) == 0 && val(c, "b") == -1, "cleared");
    put(c, "c", 3);
    assert(val(c, "c") == 3, "usable after clear");
}

fn test_should_refuse_bad_options() {
    let o = options();
    o.max_entries = 0;
    let r: result[Cache[int], str] = new(o);
    guard let _c = r else let e = err_of(r) { assert(strings.has_prefix(e, "cache: "), e); return; }
    panic("a cache of 0 entries");
}

fn test_should_spread_keys_over_shards() {
    let o = options();
    o.max_entries = 100000;
    let r: result[Cache[int], str] = new(o);
    guard let c = r else let e = err_of(r) { panic(e); }
    for i in 0..1600 {
        put(c, "user:" + to_str(i), i);
    }
    let least = 1600;
    let most = 0;
    for s in c.shards {
        if s.count < least { least = s.count; }
        if s.count > most { most = s.count; }
    }
    assert(len(c.shards) == 16 && least > 60 && most < 140, "16 shards, " + to_str(least) + " to " + to_str(most));
}

gc struct Counter {
    calls: int,
    mu: mutex,
}

fn slow_load(n: Counter, key: str) -> result[int, str] {
    mutex_lock(n.mu);
    n.calls += 1;
    mutex_unlock(n.mu);
    time.sleep(50000000);
    if key == "bad" {
        return err("no such user " + key);
    }
    if key == "boom" {
        panic("the loader blew up");
    }
    return ok(len(key));
}

fn ask(c: Cache[int], key: str, n: Counter) -> int {
    let r = get_or_load(c, key, n, slow_load);
    guard let v = r else { return -1; }
    return v;
}

fn test_should_load_once_for_many_callers() {
    let c = small(100);
    let n = Counter { calls: 0, mu: make_mutex() };
    let hs: [join[int]] = [];
    for _i in 0..20 {
        push(hs, spawn ask(c, "hello", n));
    }
    let all_right = true;
    for h in hs {
        if (join_wait(h) ?? -2) != 5 {
            all_right = false;
        }
    }
    assert(all_right, "every caller got the value");
    assert(n.calls == 1, "loaded " + to_str(n.calls) + " times");
    assert(ask(c, "hello", n) == 5 && n.calls == 1, "then cached");
}

fn test_should_not_cache_a_failed_load() {
    let c = small(100);
    let n = Counter { calls: 0, mu: make_mutex() };
    let r = get_or_load(c, "bad", n, slow_load);
    guard let _v = r else let e = err_of(r) {
        assert(e == "no such user bad", e);
        let r2 = get_or_load(c, "bad", n, slow_load);
        assert(n.calls == 2, "an error is not cached");
        let r3 = get_or_load(c, "boom", n, slow_load);
        guard let _b = r3 else let e3 = err_of(r3) {
            assert(strings.contains(e3, "panicked: the loader blew up"), e3);
            return;
        }
        panic("a panicking loader returned a value");
    }
    panic("a failing loader returned a value");
}

fn churn(c: Cache[int], id: int) -> int {
    let hits = 0;
    for i in 0..5000 {
        let k = "k" + to_str((i * 7 + id * 13) % 300);
        if i % 3 == 0 {
            put(c, k, i);
        } else if (get(c, k) ?? -1) >= 0 {
            hits += 1;
        }
    }
    return hits;
}

fn test_should_stay_within_limits_under_concurrency() {
    let o = options();
    o.max_entries = 128;
    o.shards = 8;
    let r: result[Cache[int], str] = new(o);
    guard let c = r else let e = err_of(r) { panic(e); }
    let hs: [join[int]] = [];
    for id in 0..8 {
        push(hs, spawn churn(c, id));
    }
    for h in hs {
        join_wait(h);
    }
    let st = stats(c);
    assert(st.entries <= 128 && st.entries == len_of(c), "entries " + to_str(st.entries));
    // each task: 1667 puts (i % 3 == 0) and 3333 gets
    assert(st.hits + st.misses == 8 * 3333, "every get counted: " + to_str(st.hits + st.misses));
    for s in c.shards {
        let walked = 0;
        let cur = s.head;
        while true {
            guard let e = cur else { break; }
            walked += 1;
            cur = e.next;
        }
        let in_table = 0;
        for slot in s.table {
            if let _e = slot {
                in_table += 1;
            }
        }
        assert(walked == s.count && walked == in_table, "the list, the table and the count agree");
    }
}
