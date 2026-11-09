// Reference values come from the published C code of splitmix64 and
// xoshiro256** (prng.di.unimi.it), compiled and run separately; the
// xoshiro vector from state (1, 2, 3, 4) is also the one Rust's
// rand_xoshiro tests against. They are written as decimal strings because a
// list literal takes its element type from the first element, and most
// 64-bit outputs do not fit an int.

fn take(r: Rng, n: int) -> [str] {
    let out: [str] = [];
    for _ in 0..n {
        push(out, to_str(next_u64(r)));
    }
    return out;
}

fn same(got: [str], want: [str]) -> bool {
    if len(got) != len(want) {
        return false;
    }
    for i in 0..len(got) {
        if got[i] != want[i] {
            return false;
        }
    }
    return true;
}

fn nan() -> float {
    let z = 0.0;
    return z / z;
}

// ---- the generator -------------------------------------------------------

fn test_should_match_reference_splitmix64() {
    let want: [str] = ["16294208416658607535", "7960286522194355700",
                       "487617019471545679", "17909611376780542444"];
    let sm: u64 = 0;
    for i in 0..4 {
        assert(to_str(splitmix(sm)) == want[i], "splitmix64 #" + to_str(i));
        sm = sm + GOLDEN;
    }
}

fn test_should_match_reference_xoshiro256starstar() {
    let r = Rng { s0: 1, s1: 2, s2: 3, s3: 4 };
    let want: [str] = ["11520", "0", "1509978240", "1215971899390074240",
                       "1216172134540287360", "607988272756665600",
                       "16172922978634559625", "8476171486693032832",
                       "10595114339597558777", "2904607092377533576"];
    assert(same(take(r, 10), want), "xoshiro256** from state 1, 2, 3, 4");
}

// These pin the sequence a seed gives. If one fails, every recorded seed
// in every test suite that uses rand now replays something else: change
// the algorithm only on purpose, and say so in the release notes.
fn test_should_pin_the_sequence_for_a_seed() {
    let s0: [str] = ["11091344671253066420", "13793997310169335082",
                     "1900383378846508768", "7684712102626143532",
                     "13521403990117723737"];
    let s42: [str] = ["1546998764402558742", "6990951692964543102",
                      "12544586762248559009", "17057574109182124193",
                      "18295552978065317476"];
    let sneg: [str] = ["10328197420357168392", "14156678507024973869",
                       "9357971779955476126", "13791585006304312367",
                       "10463432026814718762"];
    assert(same(take(new(0), 5), s0), "seed 0");
    assert(same(take(new(42), 5), s42), "seed 42");
    assert(same(take(new(-1), 5), sneg), "seed -1");
}

fn test_should_replay_the_same_sequence_from_the_same_seed() {
    let a = new(20261109);
    let b = new(20261109);
    for _ in 0..1000 {
        assert(below(a, 1000000) == below(b, 1000000), "sequences diverged");
    }
}

fn test_should_give_different_sequences_for_neighbouring_seeds() {
    assert(!same(take(new(1), 4), take(new(2), 4)), "seeds 1 and 2 agree");
}

fn test_should_fork_deterministically_and_apart_from_the_parent() {
    let a = new(7);
    let b = new(7);
    let ca = fork(a);
    let cb = fork(b);
    assert(same(take(ca, 8), take(cb, 8)), "forks of equal parents differ");
    assert(!same(take(fork(new(7)), 8), take(new(7), 8)),
           "fork repeats its parent");
    // The parent advanced by exactly one draw.
    let c = new(7);
    next_u64(c);
    assert(next_u64(a) == next_u64(c), "fork took more than one draw");
}

fn test_should_seed_from_the_os_differently_each_time() {
    let ra = from_os();
    let rb = from_os();
    guard let a = ra else let e = err_of(ra) { panic(e); }
    guard let b = rb else let e = err_of(rb) { panic(e); }
    assert(!same(take(a, 4), take(b, 4)), "two OS seeds gave one sequence");
}

// ---- ints ----------------------------------------------------------------

fn test_should_keep_below_in_range_and_reach_every_value() {
    let r = new(1);
    let counts: [int] = [0, 0, 0, 0, 0, 0];
    for _ in 0..60000 {
        let v = below(r, 6);
        assert(v >= 0 && v < 6, "below(6) gave " + to_str(v));
        counts[v] = counts[v] + 1;
    }
    // 10000 expected each; the standard deviation is about 91.
    for i in 0..6 {
        assert(counts[i] > 9500 && counts[i] < 10500,
               "face " + to_str(i) + " came up " + to_str(counts[i]));
    }
}

fn test_should_return_zero_for_below_one() {
    let r = new(3);
    for _ in 0..100 {
        assert(below(r, 1) == 0, "below(1) not 0");
    }
}

// With n = 1.5 * 2^63, plain `x % n` maps three raw values onto each
// result under 2^62 and two onto the rest, so 75% of draws would land
// under 2^62 instead of the correct two thirds. Only the rejection step
// in `uniform` brings it to 2/3.
fn test_should_not_bias_below_towards_small_values() {
    let r = new(99);
    let n = 6917529027641081856;
    let low = 0;
    for _ in 0..6000 {
        if below(r, n) < 4611686018427387904 {
            low = low + 1;
        }
    }
    // 4000 expected unbiased (sd about 37), 4500 if biased.
    assert(low > 3850 && low < 4150, "under 2^62: " + to_str(low) + " of 6000");
}

fn test_should_include_both_ends_in_between() {
    let r = new(5);
    let seen_lo = false;
    let seen_hi = false;
    for _ in 0..1000 {
        let v = between(r, -3, 3);
        assert(v >= -3 && v <= 3, "between(-3, 3) gave " + to_str(v));
        if v == -3 { seen_lo = true; }
        if v == 3 { seen_hi = true; }
    }
    assert(seen_lo && seen_hi, "an end of the range never came up");
}

fn test_should_return_lo_when_between_has_one_value() {
    let r = new(6);
    assert(between(r, 42, 42) == 42, "between(42, 42)");
    assert(between(r, -9223372036854775807 - 1, -9223372036854775807 - 1)
           == -9223372036854775807 - 1, "between(MIN, MIN)");
}

fn test_should_cover_the_full_int_range_in_between() {
    let r = new(8);
    let neg = 0;
    for _ in 0..1000 {
        if between(r, -9223372036854775807 - 1, 9223372036854775807) < 0 {
            neg = neg + 1;
        }
    }
    assert(neg > 400 && neg < 600, "negative: " + to_str(neg) + " of 1000");
}

fn test_should_span_more_than_max_int_in_between() {
    // hi - lo overflows an int; the span is computed in u64.
    let r = new(10);
    let lo = -9000000000000000000;
    let hi = 9000000000000000000;
    let pos = 0;
    for _ in 0..1000 {
        let v = between(r, lo, hi);
        assert(v >= lo && v <= hi, "out of range: " + to_str(v));
        if v > 0 { pos = pos + 1; }
    }
    assert(pos > 400 && pos < 600, "positive: " + to_str(pos) + " of 1000");
}

// ---- floats and chance ---------------------------------------------------

fn test_should_keep_unit_in_the_unit_interval() {
    let r = new(11);
    let sum = 0.0;
    for _ in 0..20000 {
        let f = unit(r);
        assert(f >= 0.0 && f < 1.0, "unit gave " + to_str(f));
        sum = sum + f;
    }
    let mean = sum / 20000.0;
    assert(mean > 0.49 && mean < 0.51, "mean " + to_str(mean));
}

fn test_should_never_or_always_hit_chance_at_the_edges() {
    let r = new(12);
    for _ in 0..200 {
        assert(!chance(r, 0.0), "chance(0)");
        assert(!chance(r, -1.0), "chance(-1)");
        assert(!chance(r, nan()), "chance(NaN)");
        assert(chance(r, 1.0), "chance(1)");
        assert(chance(r, 2.0), "chance(2)");
    }
}

fn test_should_hit_chance_at_its_rate() {
    let r = new(13);
    let hits = 0;
    for _ in 0..20000 {
        if chance(r, 0.25) { hits = hits + 1; }
    }
    // 5000 expected; sd about 61.
    assert(hits > 4700 && hits < 5300, "hits " + to_str(hits) + " of 20000");
}

// ---- lists ---------------------------------------------------------------

fn test_should_shuffle_into_a_permutation() {
    let r = new(14);
    let xs: [int] = [];
    for i in 0..100 { push(xs, i); }
    shuffle(r, xs);
    let seen: [bool] = [];
    for _ in 0..100 { push(seen, false); }
    for x in xs {
        assert(!seen[x], "repeated " + to_str(x));
        seen[x] = true;
    }
    let moved = 0;
    for i in 0..100 {
        if xs[i] != i { moved = moved + 1; }
    }
    assert(moved > 90, "only " + to_str(moved) + " of 100 moved");
}

fn test_should_produce_every_order_of_three() {
    let r = new(15);
    let orders: map[str]int = {};
    for _ in 0..6000 {
        let xs = ["a", "b", "c"];
        shuffle(r, xs);
        let k = xs[0] + xs[1] + xs[2];
        if has(orders, k) {
            orders[k] = orders[k] + 1;
        } else {
            orders[k] = 1;
        }
    }
    assert(len(orders) == 6, "orders seen: " + to_str(len(orders)));
    // 1000 each expected; sd about 29. A biased shuffle (j drawn from the
    // whole list each step) gives some orders over 1100 and some under 900.
    for k, c in orders {
        assert(c > 900 && c < 1100, k + " came up " + to_str(c) + " times");
    }
}

fn test_should_shuffle_empty_and_single_lists() {
    let r = new(16);
    let none_: [int] = [];
    shuffle(r, none_);
    assert(len(none_) == 0, "empty list changed");
    let one = ["x"];
    shuffle(r, one);
    assert(one[0] == "x", "single list changed");
}

fn test_should_pin_a_seeded_shuffle() {
    let xs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    shuffle(new(42), xs);
    let got = "";
    for x in xs { got = got + to_str(x); }
    assert(got == SHUFFLE_42, "seed 42 shuffled to " + got);
}

fn test_should_pick_none_from_an_empty_list() {
    let r = new(17);
    let xs: [str] = [];
    assert((pick(r, xs) ?? "nothing") == "nothing", "picked from empty");
}

fn test_should_pick_every_element() {
    let r = new(18);
    let xs = ["red", "green", "blue"];
    let seen: map[str]bool = {};
    for _ in 0..300 {
        seen[pick(r, xs) ?? ""] = true;
    }
    assert(len(seen) == 3 && !has(seen, ""), "picked: " + to_str(len(seen)));
}

// ---- backoff and jitter --------------------------------------------------

fn test_should_keep_backoff_under_the_doubling_ceiling() {
    let r = new(19);
    let base = 100;
    for attempt in 0..6 {
        let ceiling = base << attempt;
        let top = 0;
        for _ in 0..2000 {
            let d = backoff(r, attempt, base, 1000000);
            assert(d >= 0 && d <= ceiling,
                   "attempt " + to_str(attempt) + " gave " + to_str(d));
            if d > top { top = d; }
        }
        // Full jitter reaches near the top of the interval, not only its base.
        assert(top * 10 >= ceiling * 9,
               "attempt " + to_str(attempt) + " stayed far under "
               + to_str(ceiling));
    }
}

fn test_should_cap_backoff_without_overflow() {
    let r = new(20);
    let cap = 30000000000;
    for attempt in [10, 40, 63, 64, 1000, 9223372036854775807] {
        for _ in 0..200 {
            let d = backoff(r, attempt, 1000000, cap);
            assert(d >= 0 && d <= cap,
                   "attempt " + to_str(attempt) + " gave " + to_str(d));
        }
    }
    // A base above the cap starts at the cap.
    for _ in 0..200 {
        assert(backoff(r, 0, 5000, 100) <= 100, "base above cap");
    }
    // Doubling near the int limit saturates rather than wrapping negative.
    for _ in 0..200 {
        let d = backoff(r, 3, 4611686018427387904, 9223372036854775807);
        assert(d >= 0, "wrapped: " + to_str(d));
    }
}

fn test_should_return_zero_backoff_for_bad_inputs() {
    let r = new(21);
    assert(backoff(r, 3, 0, 100) == 0, "base 0");
    assert(backoff(r, 3, -5, 100) == 0, "negative base");
    assert(backoff(r, 3, 100, 0) == 0, "cap 0");
    for _ in 0..200 {
        assert(backoff(r, -4, 100, 1000) <= 100, "negative attempt not 0");
    }
}

fn test_should_keep_jitter_within_its_fraction() {
    let r = new(22);
    let d = 1000000000;
    let lo_seen = d;
    let hi_seen = d;
    for _ in 0..5000 {
        let j = jitter(r, d, 0.1);
        assert(j >= 900000000 && j <= 1100000000, "jitter gave " + to_str(j));
        if j < lo_seen { lo_seen = j; }
        if j > hi_seen { hi_seen = j; }
    }
    assert(lo_seen < 905000000 && hi_seen > 1095000000, "jitter stayed near d");
}

fn test_should_handle_jitter_edge_inputs() {
    let r = new(23);
    assert(jitter(r, 500, 0.0) == 500, "frac 0");
    assert(jitter(r, 500, -0.5) == 500, "negative frac");
    assert(jitter(r, 500, nan()) == 500, "NaN frac");
    assert(jitter(r, 0, 0.5) == 0, "d 0");
    assert(jitter(r, -500, 0.5) == 0, "negative d");
    for _ in 0..1000 {
        let j = jitter(r, 500, 3.0);
        assert(j >= 0 && j <= 1000, "frac above 1 not clamped: " + to_str(j));
        let big = jitter(r, 9223372036854775807, 0.5);
        assert(big > 0, "jitter near the int limit gave " + to_str(big));
    }
}

// Seed 42's shuffle of 0..9, from the same C reference code running
// Fisher-Yates with the same rejection step.
let SHUFFLE_42 = "7389564102";
