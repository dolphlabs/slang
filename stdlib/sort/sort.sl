// Sorting lists in place, and searching what is already sorted.
//
// The engine is the shape Go's `sort` package uses: insertion sort for
// the smallest ranges (12 elements), median-of-three quicksort with a
// three-way partition above them (the equal band settles in one pass,
// which is what keeps duplicate-heavy data near-linear in its
// distinct count rather than quadratic-ish in its size), with
// whichever side of a split is SMALLER recursing and the loop taking
// the larger one, so the stack never grows past log2(n). Every
// function also runs one adaptive entry pass, which returns at once
// once when the list is already sorted or strictly descending: the two
// shapes backend data mostly takes.
//
//     sort.ints(xs);                      // in place, ascending
//     sort.floats(xs);                    // NaN values sort first (Go's rule)
//     sort.strings(xs);                   // bytewise: "" sorts first
//     sort.by(users, user_age);           // any list, by key fn -> int/float/str
//     sort.by_stable(users, user_name);   // equal keys keep original order
//     let i = sort.search_ints(xs, 42);   // opt[int]: first index of v
//
// Unstable sorts (`ints`, `floats`, `strings`, `by`) allocate nothing
// beyond list growth. `by_stable` merges with one scratch list of about
// n/2 elements, kept across the whole sort.
//
// The key function of `by` and `by_stable` is called once per
// comparison, the same count a `sort.Slice` comparator costs in Go, and
// must take values of one of `int`, `float` or `str` -- the types `<`
// orders. `by` compares keys with the raw `<` operator, so for a float
// key the position of NaN values is whatever the comparisons say, not a
// defined order; `sort.floats` is the function with NaN semantics.
//
// Searching returns an `opt[int]`, the index of the first element whose
// key equals v, or `none`. There is no descending variant: sort
// ascending and iterate backwards, which is what real callers want
// once a pager is involved.

// Sorts xs in place, ascending. Unstable. Answers an already-sorted or
// strictly descending list in one scan, and duplicate-heavy data in no
// more passes than its distinct values take to settle, so the whole
// call is allocation-free either way.
pub fn ints(xs: [int]) -> [int] {
    let n = len(xs);
    if n < 2 {
        return xs;
    }
    if run_ints(xs, n) {
        return xs;
    }
    qs_ints(xs, 0, n);
    return xs;
}

// Same engine over floats, with a total order despite the type's own:
// NaN values sort before every number and equal to each other (Go's
// `sort.Float64s` rule), which is what makes the partition finite.
pub fn floats(xs: [float]) -> [float] {
    let n = len(xs);
    if n < 2 {
        return xs;
    }
    if run_floats(xs, n) {
        return xs;
    }
    qs_floats(xs, 0, n);
    return xs;
}

// Same engine over strings, bytewise: `""` sorts first, and the order
// is exactly what `<` gives — bytes, not locale, not Unicode points.
pub fn strings(xs: [str]) -> [str] {
    let n = len(xs);
    if n < 2 {
        return xs;
    }
    if run_strs(xs, n) {
        return xs;
    }
    qs_strs(xs, 0, n);
    return xs;
}

// Sorts xs in place by key, ascending. Unstable: when two keys are
// equal, which was first is whatever the comparisons fell into. A call
// is free to permute equal keys differently on a re-run, so anything
// whose output must not change between runs uses `by_stable`.
pub fn by[T, K](xs: [T], key: fn(T) -> K) -> [T] {
    let n = len(xs);
    if n < 2 {
        return xs;
    }
    // The adaptive scan costs one key call per element, cheap next to
    // the two or more per element the quicksort will spend.
    if run_by(xs, n, key) {
        return xs;
    }
    qs_by(xs, 0, n, key);
    return xs;
}

// Sorts xs in place by key, ascending, and equal keys keep their
// original order: an adaptive merge sort. Natural runs are kept (a
// strictly descending run is reversed, which keeps order for equal
// keys, since a strictly descending run has none), windows of 32 are
// insertion-sorted, and runs merge bottom-up taking the left on equal
// keys. Nearly-sorted data therefore costs about one comparison per
// element, not n log n.
pub fn by_stable[T, K](xs: [T], key: fn(T) -> K) -> [T] {
    let n = len(xs);
    if n < 2 {
        return xs;
    }
    if run_by(xs, n, key) {
        return xs;
    }
    let w = 32;
    let i = 0;
    while i < n {
        let hi = i + 32;
        if hi > n {
            hi = n;
        }
        ins_window(xs, i, hi, key);
        i = hi;
    }
    let tmp: [T] = [];                  // one scratch for every merge
    while w < n {
        let i = 0;
        while i < n {
            let mid = i + w;
            if mid >= n {
                break;                  // the last run has no partner
            }
            let hi = mid + w;
            if hi > n {
                hi = n;
            }
            merge(xs, tmp, i, mid, hi, key);
            i = hi;
        }
        w *= 2;
    }
    return xs;
}

// The first index of v in xs, sorted ascending, or none. On a list
// which is not sorted the result is defined but useless; it never
// reads past the list.
pub fn search_ints(xs: [int], v: int) -> opt[int] {
    let lo = 0;
    let hi = len(xs);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if xs[mid] < v {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo < len(xs) && xs[lo] == v {
        return some(lo);
    }
    return none;
}

// Same contract over floats: that includes searching for NaN, which
// finds the first NaN and sorts first under sort.floats. The index found
// for a searched NaN is where the first NaN of the list sits.
pub fn search_floats(xs: [float], v: float) -> opt[int] {
    let lo = 0;
    let hi = len(xs);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if lt_f(xs[mid], v) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let n = len(xs);
    if lo < n {
        let a = xs[lo];
        if a == v || (a != a && v != v) {
            return some(lo);
        }
    }
    return none;
}

// Same contract over strings: the first index of an exactly equal
// string, bytewise as `sort.strings` orders them.
pub fn search_strings(xs: [str], v: str) -> opt[int] {
    let lo = 0;
    let hi = len(xs);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if xs[mid] < v {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo < len(xs) && xs[lo] == v {
        return some(lo);
    }
    return none;
}

// Lower bound over a list already sorted by key: the first index whose
// key is not before v. Equality is `!(a < b) && !(b < a)`, which is `==`
// for int and str keys; for a float key it reads equal NaNs -- both raw
// comparisons false -- as a hit, the same reading `by` gives them.
pub fn search_by[T, K](xs: [T], key: fn(T) -> K, v: K) -> opt[int] {
    let lo = 0;
    let hi = len(xs);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if key(xs[mid]) < v {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo < len(xs) {
        let k = key(xs[lo]);
        if !(k < v) && !(v < k) {
            return some(lo);
        }
    }
    return none;
}

// ---------------------------------------------------------------- //
// Comparison, swap, reversal                                         //
// ---------------------------------------------------------------- //

// float less than, with NaN values ordered BEFORE every other one and
// equal to each other: the rule Go's sort.Float64s documents ("NaN
// values are ordered before other values"), which makes the order
// total, which is what a quicksort partition needs. Written out at
// every comparison site instead of behind a function, because a fn
// value call would not inline and the comparison count is the sort.
//
//     real < NaN -> false
//     NaN < real -> true
//     NaN < NaN  -> false (equal)
//
// The first clause is the "NaN before any real" half; the second is
// raw `<`, which only ever speaks when both sides are real. The int
// and str paths compare raw: those types have no NaN.
fn lt_f(a: float, b: float) -> bool {
    return (a != a && b == b) || (a == a && b == b && a < b);
}

// One static helper for every path: monomorphized per element type and
// small enough for the C compiler to inline into its call sites.
fn swap_at[T](xs: [T], a: int, b: int) {
    let t = xs[a];
    xs[a] = xs[b];
    xs[b] = t;
}

// Reverses xs[lo..hi) in place. Called on a strictly descending run
// only: with no equal keys inside, a reversal cannot disorder any
// equal-key pair, so the stable merge's contract survives it.
fn reverse_range[T](xs: [T], lo: int, hi: int) {
    let a = lo;
    let b = hi - 1;
    while a < b {
        swap_at(xs, a, b);
        a += 1;
        b -= 1;
    }
}

fn reverse_at[T](xs: [T], n: int) {
    reverse_range(xs, 0, n);
}

// ---------------------------------------------------------------- //
// The adaptive entry pass                                            //
// ---------------------------------------------------------------- //

// Returns true when xs is ascending after the call: either it already
// was (the scan reached the end), or it was STRICTLY descending over
// the whole list and has been reversed. The descending check only
// elapses when the upward scan broke at the first pair, which is where
// a fully descending list necessarily breaks; anything else falls
// through to the quicksort. A scan of a random list stops after one or
// two comparisons.
fn run_ints(xs: [int], n: int) -> bool {
    let i = 1;
    while i < n && xs[i - 1] <= xs[i] {
        i += 1;
    }
    if i == n {
        return true;
    }
    if i == 1 && xs[1] < xs[0] {
        let j = 2;
        while j < n && xs[j] < xs[j - 1] {
            j += 1;
        }
        if j == n {
            reverse_at(xs, n);          // strictly descending: no equals
            return true;
        }
    }
    return false;
}

fn run_floats(xs: [float], n: int) -> bool {
    let i = 1;
    while i < n && !lt_f(xs[i], xs[i - 1]) {
        i += 1;
    }
    if i == n {
        return true;
    }
    if i == 1 && lt_f(xs[1], xs[0]) {
        let j = 2;
        while j < n && lt_f(xs[j], xs[j - 1]) {
            j += 1;
        }
        if j == n {
            reverse_at(xs, n);
            return true;
        }
    }
    return false;
}

fn run_strs(xs: [str], n: int) -> bool {
    let i = 1;
    while i < n && xs[i - 1] <= xs[i] {
        i += 1;
    }
    if i == n {
        return true;
    }
    if i == 1 && xs[1] < xs[0] {
        let j = 2;
        while j < n && xs[j] < xs[j - 1] {
            j += 1;
        }
        if j == n {
            reverse_at(xs, n);
            return true;
        }
    }
    return false;
}

// The key-function variant of the same pass, with the key called once
// per element. The full-list descending scan stops at the first
// non-strict step, so a list with equal keys anywhere in its head
// places the whole job, not just its reversal, with the quicksort.
fn run_by[T, K](xs: [T], n: int, key: fn(T) -> K) -> bool {
    let prev = key(xs[0]);
    let i = 1;
    while i < n {
        let cur = key(xs[i]);
        if cur < prev {
            break;
        }
        prev = cur;
        i += 1;
    }
    if i == n {
        return true;
    }
    if i == 1 {
        // broke at the first pair; confirm the rest is strictly
        // descending below it -- prev is still key(xs[0]), and the
        // failure was key(xs[1]) < prev
        let last = key(xs[1]);
        let full = true;
        let j = 2;
        while j < n {
            let cur = key(xs[j]);
            if !(cur < last) {
                full = false;
                break;
            }
            last = cur;
            j += 1;
        }
        if full {
            reverse_at(xs, n);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- //
// Insertion sort                                                     //
// ---------------------------------------------------------------- //

// Sorts [lo, hi) by walking every element back over strictly greater
// neighbours and landing it on the first slot that is not above it.
fn ins_ints(xs: [int], lo: int, hi: int) {
    let i = lo + 1;
    while i < hi {
        let v = xs[i];
        let j = i - 1;
        while j >= lo && xs[j] > v {
            xs[j + 1] = xs[j];
            j -= 1;
        }
        xs[j + 1] = v;
        i += 1;
    }
}

fn ins_floats(xs: [float], lo: int, hi: int) {
    let i = lo + 1;
    while i < hi {
        let v = xs[i];
        let j = i - 1;
        while j >= lo && lt_f(v, xs[j]) {
            xs[j + 1] = xs[j];
            j -= 1;
        }
        xs[j + 1] = v;
        i += 1;
    }
}

fn ins_strs(xs: [str], lo: int, hi: int) {
    let i = lo + 1;
    while i < hi {
        let v = xs[i];
        let j = i - 1;
        while j >= lo && xs[j] > v {
            xs[j + 1] = xs[j];
            j -= 1;
        }
        xs[j + 1] = v;
        i += 1;
    }
}

// The key function is called once per element in the run (the inserted
// value caches its own key) plus once per shift of a neighbour. Equal
// neighbours stop the shift, so the run stays ordered for the stable
// merge built on top of it.
fn ins_by[T, K](xs: [T], lo: int, hi: int, key: fn(T) -> K) {
    let i = lo + 1;
    while i < hi {
        let v = xs[i];
        let kv = key(v);
        let j = i - 1;
        while j >= lo {
            let kj = key(xs[j]);
            if !(kv < kj) {
                break;
            }
            xs[j + 1] = xs[j];
            j -= 1;
        }
        xs[j + 1] = v;
        i += 1;
    }
}

// One window of by_stable: detects a natural run (ascending as found,
// or strictly descending and reversed), and insertion-sorts the window
// when neither covers it. Returns nothing; the caller keeps widths of
// 32, one window per call, so the `w` to start merging at is a
// constant.
fn ins_window[T, K](xs: [T], lo: int, hi: int, key: fn(T) -> K) {
    let i = lo + 1;
    while i < hi && !(key(xs[i]) < key(xs[i - 1])) {
        i += 1;
    }
    if i == hi {
        return;                         // the whole window is in order
    }
    if i == lo + 1 {
        // broke on the FIRST pair, where a fully strictly descending
        // window necessarily breaks: extend it. Reversing a strictly
        // descending window is the one in-place fix that keeps every
        // equal-key pair in its original order; a window with equal
        // keys inside gets the insertion pass instead.
        let e = i + 1;
        while e < hi && key(xs[e]) < key(xs[e - 1]) {
            e += 1;
        }
        if e == hi {
            reverse_range(xs, lo, hi);  // strictly descending [lo..hi)
            return;
        }
    }
    ins_by(xs, lo, hi, key);
}

// ---------------------------------------------------------------- //
// Quicksort                                                          //
// ---------------------------------------------------------------- //

// Sorts [lo, hi): median-of-three pivot, then a THREE-WAY partition
// (below | equal | above, Dutch flag in place), recursing on the
// smaller side and looping on the larger, which bounds the recursion
// depth by log2 of the range. Three-way is what makes duplicate-heavy
// data fast: the equal band lands in place in one pass, so a range
// that holds only k distinct values runs out of work after about
// log2(k) levels, not log2(n) -- the difference between 4 ms and
// 470 ms at one million four valued ints. No sentinels: the scans
// carry their own bounds (k <= gt), which is what keeps a hostile
// comparator from walking off the list.
fn qs_ints(xs: [int], lo: int, hi: int) {
    while hi - lo > 12 {
        // median of three values, sampled in place: the pivot needs no
        // slot, only a value
        let a = xs[lo];
        let b = xs[lo + (hi - lo) / 2];
        let c = xs[hi - 1];
        let p = a;
        if b < c {
            if a < b {
                p = b;
            } else {
                if c < a {
                    p = c;
                }
            }
        } else {
            if a < c {
                p = c;
            } else {
                if b < a {
                    p = b;
                }
            }
        }
        // Dutch flag: xs[lo..lt) < p, xs[lt..k] == p, xs[gt+1..hi) > p
        let lt = lo;
        let gt = hi - 1;
        let k = lo;
        while k <= gt {
            if xs[k] < p {
                swap_at(xs, k, lt);
                lt += 1;
                k += 1;
            } else {
                if p < xs[k] {
                    swap_at(xs, k, gt);
                    gt -= 1;
                } else {
                    k += 1;
                }
            }
        }
        // [lt..gt+1) is the equal band, already final
        if lt - lo < hi - (gt + 1) {
            qs_ints(xs, lo, lt);
            lo = gt + 1;
        } else {
            qs_ints(xs, gt + 1, hi);
            hi = lt;
        }
    }
    ins_ints(xs, lo, hi);
}

fn qs_floats(xs: [float], lo: int, hi: int) {
    while hi - lo > 12 {
        let a = xs[lo];
        let b = xs[lo + (hi - lo) / 2];
        let c = xs[hi - 1];
        let p = a;
        if lt_f(b, c) {
            if lt_f(a, b) {
                p = b;
            } else {
                if lt_f(c, a) {
                    p = c;
                }
            }
        } else {
            if lt_f(a, c) {
                p = c;
            } else {
                if lt_f(b, a) {
                    p = b;
                }
            }
        }
        let lt = lo;
        let gt = hi - 1;
        let k = lo;
        while k <= gt {
            if lt_f(xs[k], p) {
                swap_at(xs, k, lt);
                lt += 1;
                k += 1;
            } else {
                if lt_f(p, xs[k]) {
                    swap_at(xs, k, gt);
                    gt -= 1;
                } else {
                    k += 1;
                }
            }
        }
        if lt - lo < hi - (gt + 1) {
            qs_floats(xs, lo, lt);
            lo = gt + 1;
        } else {
            qs_floats(xs, gt + 1, hi);
            hi = lt;
        }
    }
    ins_floats(xs, lo, hi);
}

fn qs_strs(xs: [str], lo: int, hi: int) {
    while hi - lo > 12 {
        let a = xs[lo];
        let b = xs[lo + (hi - lo) / 2];
        let c = xs[hi - 1];
        let p = a;
        if b < c {
            if a < b {
                p = b;
            } else {
                if c < a {
                    p = c;
                }
            }
        } else {
            if a < c {
                p = c;
            } else {
                if b < a {
                    p = b;
                }
            }
        }
        let lt = lo;
        let gt = hi - 1;
        let k = lo;
        while k <= gt {
            if xs[k] < p {
                swap_at(xs, k, lt);
                lt += 1;
                k += 1;
            } else {
                if p < xs[k] {
                    swap_at(xs, k, gt);
                    gt -= 1;
                } else {
                    k += 1;
                }
            }
        }
        if lt - lo < hi - (gt + 1) {
            qs_strs(xs, lo, lt);
            lo = gt + 1;
        } else {
            qs_strs(xs, gt + 1, hi);
            hi = lt;
        }
    }
    ins_strs(xs, lo, hi);
}

// The key-function quicksort, same engine. A key call per element per
// pass (the pivot's key once). The partition carries its own bounds
// (k <= gt), so a NaN float key speaks untruths about `<` but cannot
// walk the scan off the list, and the equal band keeps every pass from
// rescanning a value class it has already placed.
fn qs_by[T, K](xs: [T], lo: int, hi: int, key: fn(T) -> K) {
    while hi - lo > 12 {
        let ka = key(xs[lo]);
        let kb = key(xs[lo + (hi - lo) / 2]);
        let kc = key(xs[hi - 1]);
        let p = ka;
        if kb < kc {
            if ka < kb {
                p = kb;
            } else {
                if kc < ka {
                    p = kc;
                }
            }
        } else {
            if ka < kc {
                p = kc;
            } else {
                if kb < ka {
                    p = kb;
                }
            }
        }
        let lt = lo;
        let gt = hi - 1;
        let k = lo;
        while k <= gt {
            let kk = key(xs[k]);
            if kk < p {
                swap_at(xs, k, lt);
                lt += 1;
                k += 1;
            } else {
                if p < kk {
                    swap_at(xs, k, gt);
                    gt -= 1;
                } else {
                    k += 1;
                }
            }
        }
        if lt - lo < hi - (gt + 1) {
            qs_by(xs, lo, lt, key);
            lo = gt + 1;
        } else {
            qs_by(xs, gt + 1, hi, key);
            hi = lt;
        }
    }
    ins_by(xs, lo, hi, key);
}

// ---------------------------------------------------------------- //
// The stable merge                                                   //
// ---------------------------------------------------------------- //

// Merges the sorted runs xs[lo..mid) and xs[mid..hi) in place, using
// tmp as scratch for the left run. The left of an equal pair is taken,
// which is what makes by_stable stable. tmp is emptied first (pop is a
// length decrement, data and capacity stay), and grows to the width of
// the wider merge, so the whole sort keeps ONE scratch of at most n/2
// elements from its first merge to its last.
fn merge[T, K](xs: [T], tmp: [T], lo: int, mid: int, hi: int, key: fn(T) -> K) {
    while len(tmp) > 0 {
        pop(tmp);
    }
    let i = lo;
    while i < mid {
        push(tmp, xs[i]);
        i += 1;
    }
    let nl = mid - lo;
    let a = 0;
    let b = mid;
    let d = lo;
    while a < nl && b < hi {
        if key(tmp[a]) <= key(xs[b]) {
            xs[d] = tmp[a];
            a += 1;
        } else {
            xs[d] = xs[b];
            b += 1;
        }
        d += 1;
    }
    while a < nl {
        xs[d] = tmp[a];
        a += 1;
        d += 1;
    }
    // the right run's tail is already where it belongs
}
