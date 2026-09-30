// A minor collection traces a remembered list or map only from its
// gc_clean position on (runtime sl_arr's comment): everything below it
// must hold no pointer written since the last minor. Each section below
// is a way a store can land BELOW the position a naive frontier would
// keep, and tests/run_tests.sh runs this under SLANG_GC_VERIFY_MINOR with
// a 16KB nursery, where a young entry the minor skipped is reported as
// missed. On its own it checks every value survives.
gc struct Item {
    name: str,
    n: int,
}

fn label(i: int) -> str {
    return "v" + to_str(i);
}

fn churn(n: int) -> int {
    let s = 0;
    let i = 0;
    while i < n {
        s = s + len(label(i));
        i = i + 1;
    }
    return s;
}

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn check_list(xs: [Item], what: str) {
    let i = 0;
    while i < len(xs) {
        let it = xs[i];
        if it.name != label(it.n) {
            fail(what + " at " + to_str(i));
        }
        i = i + 1;
    }
}

// Appends to a list that is already old, across many minors: the case the
// frontier exists for.
fn appends() {
    let xs: [Item] = [];
    push(xs, Item { name: label(0), n: 0 });
    churn(20000);
    let i = 1;
    while i < 20000 {
        push(xs, Item { name: label(i), n: i });
        i = i + 1;
    }
    churn(20000);
    check_list(xs, "appends");
    println("appends");
}

// pop leaves len below the frontier a minor set, so the next push writes
// under it and must lower it.
fn pop_then_push() {
    let xs: [Item] = [];
    let i = 0;
    while i < 1000 {
        push(xs, Item { name: label(i), n: i });
        i = i + 1;
    }
    churn(20000);
    let round = 0;
    while round < 200 {
        let k = 0;
        while k < 5 {
            let _p = pop(xs);
            k = k + 1;
        }
        k = 0;
        while k < 5 {
            let n = len(xs);
            push(xs, Item { name: label(n), n: n });
            k = k + 1;
        }
        churn(300);
        round = round + 1;
    }
    churn(20000);
    check_list(xs, "pop_then_push");
    println("pop_then_push");
}

// a[i] = v below the frontier, in an old list.
fn index_stores() {
    let xs: [Item] = [];
    let i = 0;
    while i < 2000 {
        push(xs, Item { name: label(i), n: i });
        i = i + 1;
    }
    churn(20000);
    let round = 0;
    while round < 400 {
        let at = (round * 37) % 2000;
        xs[at] = Item { name: label(at), n: at };
        churn(200);
        round = round + 1;
    }
    churn(20000);
    check_list(xs, "index_stores");
    println("index_stores");
}

// Maps: new keys (the append case), updates of existing keys, and
// deletes, whose shift of the order array can move a fresh entry below
// the frontier.
fn maps() {
    let m: map[str]Item = {};
    let i = 0;
    while i < 3000 {
        m[label(i)] = Item { name: label(i), n: i };
        i = i + 1;
    }
    churn(20000);
    // New keys, each followed by a delete earlier in the order array:
    // the delete shifts the new entry down, below where the frontier sat.
    // No updates in this phase -- an update resets the frontier to 0 and
    // would hide a delete that failed to lower it.
    let next = 3000;
    let round = 0;
    while round < 300 {
        m[label(next)] = Item { name: label(next), n: next };
        next = next + 1;
        del(m, label(round * 3));
        churn(150);
        round = round + 1;
    }
    churn(20000);
    // Updates of keys that are still there.
    round = 0;
    while round < 300 {
        let u = round * 3 + 1;
        m[label(u)] = Item { name: label(u), n: u };
        churn(150);
        round = round + 1;
    }
    churn(20000);
    for k, v in m {
        if v.name != k || label(v.n) != k {
            fail("maps key " + k);
        }
    }
    if len(m) != 3000 {
        fail("maps size " + to_str(len(m)));
    }
    println("maps");
}

appends();
pop_then_push();
index_stores();
maps();
println("done");
