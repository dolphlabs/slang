import "rand";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

// ---- breaker ----

fn small_breaker() -> Breaker {
    let o = breaker_options();
    o.window = 10;
    o.min_calls = 4;
    o.failure_ratio = 0.5;
    o.open_ns = ms(30);
    o.probes = 2;
    return breaker(o);
}

fn test_should_trip_at_the_failure_ratio_and_not_before_min_calls() {
    let b = small_breaker();
    for _ in 0..3 { assert(allow(b), "closed breaker refused"); record(b, false); }
    assert(breaker_state(b) == "closed", "tripped before min_calls");
    assert(allow(b), "refused at 3 calls");
    record(b, false);
    assert(breaker_state(b) == "open" && trips(b) == 1, "did not trip at 4 of 4");
    assert(!allow(b), "open breaker allowed a call");
}

fn test_should_stay_closed_while_successes_dilute_failures() {
    let b = small_breaker();
    for i in 0..40 {
        assert(allow(b), "refused at " + to_str(i));
        record(b, i % 4 != 0);           // one failure in four
    }
    assert(breaker_state(b) == "closed" && trips(b) == 0, "tripped below the ratio");
}

fn test_should_close_after_enough_half_open_successes() {
    let b = small_breaker();
    for _ in 0..4 { let _a = allow(b); record(b, false); }
    time.sleep(ms(40));
    assert(breaker_state(b) == "half-open", "not half-open after open_ns");
    assert(allow(b) && allow(b), "probes refused");
    assert(!allow(b), "more than `probes` calls let through");
    record(b, true);
    record(b, true);
    assert(breaker_state(b) == "closed", "did not close after probes succeeded");
}

fn test_should_reopen_on_a_failed_probe() {
    let b = small_breaker();
    for _ in 0..4 { let _a = allow(b); record(b, false); }
    time.sleep(ms(40));
    assert(allow(b), "probe refused");
    record(b, false);
    assert(breaker_state(b) == "open" && trips(b) == 2, "failed probe did not reopen");
}

// ---- bulkhead ----

fn test_should_turn_away_calls_beyond_the_limit() {
    let b = bulkhead(2);
    assert(try_enter(b) && try_enter(b), "refused below the limit");
    assert(!try_enter(b), "let a third in");
    leave(b);
    assert(try_enter(b), "refused after a leave");
    assert(bulkhead_active(b) == 2 && bulkhead_rejected(b) == 1, "counters");
}

// ---- retry budget and retry ----

fn test_should_allow_retries_as_a_share_of_requests() {
    let b = retry_budget(0.1, 0);
    for _ in 0..10 { deposit(b); }
    assert(can_retry(b), "ten requests at 10% earn no retry");
    assert(!can_retry(b), "one request's worth spent twice");
}

fn test_should_allow_the_minimum_rate_without_requests() {
    let b = retry_budget(0.0, 5);
    let n = 0;
    for _ in 0..20 { if can_retry(b) { n = n + 1; } }
    assert(n == 5, "minimum allowed " + to_str(n));
    let t0 = time.mono();
    time.sleep(ms(450));
    let m = 0;
    for _ in 0..20 { if can_retry(b) { m = m + 1; } }
    // 5/s for however long the sleep really took (a loaded machine
    // oversleeps), capped at the 5 the allowance holds
    let slept_ms = ((time.mono() - t0) as int) / 1000000;
    let most = slept_ms * 5 / 1000 + 1;
    if most > 5 { most = 5; }
    assert(m >= 2 && m <= most, "refill after " + to_str(slept_ms) + " ms at 5/s gave " + to_str(m));
}

gc struct Calls {
    n: int,
    fail_first: int,
    msg: str,
    slow_first_ns: int,
}

fn flaky(c: Calls, u: until) -> result[int, str] {
    c.n = c.n + 1;
    if c.n <= c.fail_first { return err(c.msg); }
    return ok(c.n);
}

fn quick_retry() -> RetryOptions {
    let o = retry_options();
    o.attempts = 4;
    o.base_ns = ms(1);
    o.cap_ns = ms(2);
    return o;
}

fn test_should_retry_until_success() {
    let c = Calls { n: 0, fail_first: 2, msg: "busy", slow_first_ns: 0 };
    let r = retry(flaky, c, quick_retry(), retry_budget(1.0, 100), rand.new(1),
                  until_of(time.mono() + ms(2000)));
    assert((r ?? -1) == 3, "third call should succeed");
}

fn test_should_not_retry_a_permanent_error_or_beyond_attempts() {
    let c = Calls { n: 0, fail_first: 10, msg: "permanent: bad request", slow_first_ns: 0 };
    let r = retry(flaky, c, quick_retry(), retry_budget(1.0, 100), rand.new(1), until_never());
    if let _v = r { panic("succeeded"); }
    assert(c.n == 1, "retried a permanent error " + to_str(c.n) + " times");
    let d = Calls { n: 0, fail_first: 10, msg: "busy", slow_first_ns: 0 };
    let r2 = retry(flaky, d, quick_retry(), retry_budget(1.0, 100), rand.new(1), until_never());
    assert(err_of(r2) == "busy" && d.n == 4, "attempts " + to_str(d.n));
}

fn test_should_stop_retrying_when_the_budget_is_spent() {
    let c = Calls { n: 0, fail_first: 10, msg: "busy", slow_first_ns: 0 };
    let r = retry(flaky, c, quick_retry(), retry_budget(0.0, 0), rand.new(1), until_never());
    if let _v = r { panic("succeeded"); }
    assert(c.n == 1, "retried without budget");
}

// ---- token bucket ----

fn test_should_take_up_to_the_burst_then_refill_at_the_rate() {
    let tb = token_bucket(100.0, 5);
    for i in 0..5 { assert(take(tb), "refused token " + to_str(i)); }
    assert(!take(tb), "took beyond the burst");
    let w = wait_ns(tb, 1);
    assert(w > 0 && w <= ms(11), "wait " + to_str(w));
    time.sleep(w);
    assert(take(tb), "no token after waiting");
    assert(wait_ns(tb, 6) == -1, "more than the bucket holds");
    assert(!take_n(tb, 6), "took more than the burst");
}

// ---- GCRA ----

fn test_should_limit_each_key_separately() {
    let g = gcra(10.0, 2);
    assert(gcra_allow(g, "a").allowed && gcra_allow(g, "a").allowed, "burst refused");
    let d = gcra_allow(g, "a");
    assert(!d.allowed, "third in a burst of 2 allowed");
    assert(d.retry_after_ns > 0 && d.retry_after_ns <= ms(100), "retry_after " + to_str(d.retry_after_ns));
    assert(gcra_allow(g, "b").allowed, "another key limited");
    time.sleep(d.retry_after_ns + ms(1));
    assert(gcra_allow(g, "a").allowed, "refused after retry_after");
}

fn test_should_forget_keys_that_are_full_again() {
    let g = gcra(1000000.0, 1);
    for i in 0..5000 {
        let _d = gcra_allow(g, "k" + to_str(i));
        if i % 1000 == 999 { time.sleep(ms(2)); }
    }
    assert(gcra_keys(g) < 2100, "keys kept: " + to_str(gcra_keys(g)));
}

// ---- hedging ----

fn slow_then_fast(c: Calls, u: until) -> result[int, str] {
    c.n = c.n + 1;
    let me = c.n;
    if me == 1 && c.slow_first_ns > 0 { time.sleep(c.slow_first_ns); }
    if me <= c.fail_first { return err(c.msg); }
    return ok(me);
}

fn test_should_take_the_hedged_call_when_the_first_is_slow() {
    let c = Calls { n: 0, fail_first: 0, msg: "", slow_first_ns: ms(300) };
    let t0 = time.mono();
    let r = hedge(slow_then_fast, c, ms(20), until_of(time.mono() + ms(2000)));
    let took = time.mono() - t0;
    assert((r ?? -1) == 2, "answer from call " + to_str(r ?? -1));
    assert(took < ms(200), "waited for the slow call: " + to_str(took / 1000000) + " ms");
}

fn test_should_not_hedge_a_fast_call() {
    let c = Calls { n: 0, fail_first: 0, msg: "", slow_first_ns: 0 };
    let r = hedge(slow_then_fast, c, ms(50), until_never());
    assert((r ?? -1) == 1, "fast call");
    time.sleep(ms(80));
    assert(c.n == 1, "hedged a call that had answered");
}

fn test_should_return_a_fast_failure_without_hedging() {
    let c = Calls { n: 0, fail_first: 1, msg: "boom", slow_first_ns: 0 };
    let r = hedge(slow_then_fast, c, ms(50), until_never());
    assert(err_of(r) == "boom", "error");
    time.sleep(ms(80));
    assert(c.n == 1, "hedged after a failure");
}
