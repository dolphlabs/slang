import "json";
import "rand";

fn test_should_merge_counters_in_any_order_any_number_of_times() {
    let a = gcounter();
    let b = gcounter();
    gc_inc(a, "a", 3);
    gc_inc(b, "b", 4);
    gc_inc(b, "a", 1);              // b saw an older a? no: b's own view of "a"
    let ab = gcounter(); gc_merge(ab, a); gc_merge(ab, b);
    let ba = gcounter(); gc_merge(ba, b); gc_merge(ba, a);
    assert(gc_value(ab) == gc_value(ba) && gc_value(ab) == 7, "commutative: " + to_str(gc_value(ab)));
    gc_merge(ab, a);
    gc_merge(ab, ab);
    assert(gc_value(ab) == 7, "idempotent");
    let p = pncounter();
    let q = pncounter();
    pn_add(p, "p", 10);
    pn_add(q, "q", -4);
    pn_merge(p, q);
    pn_merge(p, q);
    assert(pn_value(p) == 6, "pn " + to_str(pn_value(p)));
}

fn test_should_let_a_concurrent_add_win_over_a_remove() {
    let a = orset();
    set_add(a, "a", "x");
    let b = orset();
    set_merge(b, a);                // b knows x
    set_remove(b, "x");             // b removes the x it saw
    set_add(a, "a", "x");           // a adds x again, concurrently
    set_merge(a, b);
    set_merge(b, a);
    assert(set_has(a, "x") && set_has(b, "x"), "the unseen add lost");
    // a remove of everything both sides saw sticks
    set_remove(a, "x");
    set_merge(b, a);
    assert(!set_has(b, "x"), "remove did not propagate");
    set_merge(a, b);
    assert(!set_has(a, "x"), "removed element came back");
}

fn test_should_not_bring_back_an_element_from_a_stale_replica() {
    let a = orset();
    set_add(a, "a", "x");
    let b = orset();
    set_merge(b, a);                // b holds x with a's dot
    set_remove(a, "x");             // a removes it
    set_merge(a, b);                // b is stale: it still has that dot
    assert(!set_has(a, "x"), "a stale replica brought a removed element back");
}

fn test_should_keep_an_orset_bounded_by_its_elements() {
    let s = orset();
    for i in 0..1000 {
        set_add(s, "n1", "k" + to_str(i % 3));
        if i % 2 == 0 { set_remove(s, "k" + to_str(i % 3)); }
    }
    let dots = 0;
    for _k, d in s.entries { dots = dots + len(d); }
    assert(dots <= 3 && len(s.clock) == 1, "state grew: " + to_str(dots) + " dots");
}

fn test_should_pick_the_last_writer_and_break_ties_by_node() {
    let a = lwwmap();
    let b = lwwmap();
    map_set(a, "a", "color", "red", 10);
    map_set(b, "b", "color", "blue", 20);
    map_merge(a, b);
    assert((map_get(a, "color") ?? "") == "blue", "later write lost");
    map_set(a, "a", "size", "S", 30);
    map_set(b, "b", "size", "M", 30);
    map_merge(a, b);
    map_merge(b, a);
    assert((map_get(a, "size") ?? "") == "M" && (map_get(b, "size") ?? "") == "M", "tie not by node");
    map_delete(b, "b", "color", 25);
    map_merge(a, b);
    assert(len(map_keys(a)) == 1, "delete did not win");
    map_set(a, "a", "color", "old", 15);    // older than the delete
    assert(!is_some(map_get(a, "color")), "older write resurrected a deleted key");
    map_compact(a, 100);
    assert(!has(a.entries, "color"), "compact kept the tombstone");
}

fn is_some(o: opt[str]) -> bool {
    if let _v = o { return true; }
    return false;
}

// Three replicas apply random operations and merge in random orders;
// once all have merged with all, they hold the same set.
fn test_should_converge_under_random_operations() {
    let r = rand.new(7);
    let reps = [orset(), orset(), orset()];
    let names = ["r0", "r1", "r2"];
    for _ in 0..400 {
        let i = rand.below(r, 3);
        let e = "e" + to_str(rand.below(r, 8));
        let op = rand.below(r, 10);
        if op < 5 { set_add(reps[i], names[i], e); }
        else if op < 8 { set_remove(reps[i], e); }
        else { set_merge(reps[i], reps[rand.below(r, 3)]); }
    }
    for _ in 0..2 {
        for i in 0..3 { for j in 0..3 { set_merge(reps[i], reps[j]); } }
    }
    let a = json.encode(set_items(reps[0]));
    assert(a == json.encode(set_items(reps[1])) && a == json.encode(set_items(reps[2])), "replicas differ");
}

fn test_should_round_trip_state_through_json() {
    let c = gcounter();
    gc_inc(c, "x", 5);
    let back: result[GCounter, str] = json.decode(json.encode(c));
    guard let d = back else let e = err_of(back) { panic(e); }
    assert(gc_value(d) == 5, "json round trip");
}
