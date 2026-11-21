import "sort";

// One of the heaviest keys: `count` overestimates the key's true count by
// at most `error` (count - error is a guaranteed lower bound).
pub struct Item {
    key: str,
    count: int,
    error: int,
}

// The k heaviest keys of a stream in O(k) memory (Space-Saving, Metwally
// et al. 2005): every key whose true count is above total / k is in the
// list. A key not being tracked replaces the one with the smallest count
// and inherits that count as its possible error. O(log k) per add.
//
// Each key lives in a fixed slot; the min-heap orders slot numbers, so a
// heap swap moves two ints and the key map is touched once or twice per
// add, never per swap.
pub gc struct TopK {
    cap: int,
    keys: [str],      // by slot
    counts: [int],
    errs: [int],
    heap: [int],      // slots, a min-heap on counts: heap[0] is the eviction victim
    hpos: [int],      // where each slot sits in the heap
    slot_of: map[str]int,
    sum: int,
}

// Tracks up to k keys (k at least 1).
pub fn top_k(k: int) -> TopK {
    let cap = k;
    if cap < 1 {
        cap = 1;
    }
    return TopK {
        cap: cap, keys: [], counts: [], errs: [], heap: [], hpos: [], slot_of: {},
        sum: 0
    };
}

impl TopK {
    pub fn add(self: TopK, key: str) -> TopK {
        return self.add_n(key, 1);
    }

    // Adds n (ignored unless positive) occurrences of key.
    pub fn add_n(self: TopK, key: str, n: int) -> TopK {
        if n <= 0 {
            return self;
        }
        self.sum += n;
        if has(self.slot_of, key) {
            let sl = self.slot_of[key];
            self.counts[sl] += n;
            self.sift_down(self.hpos[sl]);
            return self;
        }
        if len(self.keys) < self.cap {
            let sl = len(self.keys);
            push(self.keys, key);
            push(self.counts, n);
            push(self.errs, 0);
            push(self.heap, sl);
            push(self.hpos, sl);
            self.slot_of[key] = sl;
            self.sift_up(sl);
            return self;
        }
        let victim = self.heap[0];
        let floor = self.counts[victim];
        del(self.slot_of, self.keys[victim]);
        self.keys[victim] = key;
        self.counts[victim] = floor + n;
        self.errs[victim] = floor;
        self.slot_of[key] = victim;
        self.sift_down(0);
        return self;
    }

    // The tracked keys, heaviest first (ties by key).
    pub fn top(self: TopK) -> [Item] {
        let out: [Item] = [];
        for i in 0..len(self.keys) {
            push(out, Item { key: self.keys[i], count: self.counts[i], error: self.errs[i] });
        }
        sort.by_stable(out, item_key);
        sort.by_stable(out, item_weight);
        return out;
    }

    // The estimated count of key, or none if it is not tracked (then its
    // true count is at most the smallest tracked count).
    pub fn count(self: TopK, key: str) -> opt[int] {
        if !has(self.slot_of, key) {
            return none;
        }
        return some(self.counts[self.slot_of[key]]);
    }

    // The total of every n added.
    pub fn total(self: TopK) -> int {
        return self.sum;
    }

    pub fn size(self: TopK) -> int {
        return len(self.keys);
    }

    // Combines `other` into this summary (Agarwal et al. 2012): a key's
    // counts add, and a key one side does not track is credited with that
    // side's smallest count when it is full, the most it could have had.
    // The heaviest `k` of the combined keys are kept.
    pub fn merge(self: TopK, other: TopK) {
        let mine = self.min_if_full();
        let theirs = other.min_if_full();
        let items: [Item] = [];
        for i in 0..len(self.keys) {
            let k = self.keys[i];
            let c = self.counts[i];
            let e = self.errs[i];
            if has(other.slot_of, k) {
                let j = other.slot_of[k];
                c += other.counts[j];
                e += other.errs[j];
            } else {
                c += theirs;
                e += theirs;
            }
            push(items, Item { key: k, count: c, error: e });
        }
        for j in 0..len(other.keys) {
            let k = other.keys[j];
            if !has(self.slot_of, k) {
                push(items, Item {
                    key: k, count: other.counts[j] + mine, error: other.errs[j] + mine
                });
            }
        }
        sort.by_stable(items, item_key);
        sort.by_stable(items, item_weight);
        let sum = self.sum + other.sum;
        self.clear();
        self.sum = sum;
        let n = len(items);
        if n > self.cap {
            n = self.cap;
        }
        for i in 0..n {
            push(self.keys, items[i].key);
            push(self.counts, items[i].count);
            push(self.errs, items[i].error);
            push(self.heap, i);
            push(self.hpos, i);
            self.slot_of[items[i].key] = i;
            self.sift_up(i);
        }
    }

    pub fn clear(self: TopK) {
        let ks: [str] = [];
        let cs: [int] = [];
        let es: [int] = [];
        let hp: [int] = [];
        let ps: [int] = [];
        let so: map[str]int = {};
        self.keys = ks;
        self.counts = cs;
        self.errs = es;
        self.heap = hp;
        self.hpos = ps;
        self.slot_of = so;
        self.sum = 0;
    }

    fn min_if_full(self: TopK) -> int {
        if len(self.keys) < self.cap {
            return 0;
        }
        return self.counts[self.heap[0]];
    }

    fn swap(self: TopK, a: int, b: int) {
        let sa = self.heap[a];
        let sb = self.heap[b];
        self.heap[a] = sb;
        self.heap[b] = sa;
        self.hpos[sb] = a;
        self.hpos[sa] = b;
    }

    fn sift_up(self: TopK, at: int) {
        let i = at;
        while i > 0 {
            let parent = (i - 1) / 2;
            if self.counts[self.heap[parent]] <= self.counts[self.heap[i]] {
                return;
            }
            self.swap(i, parent);
            i = parent;
        }
    }

    fn sift_down(self: TopK, at: int) {
        let n = len(self.heap);
        let i = at;
        while true {
            let l = 2 * i + 1;
            if l >= n {
                return;
            }
            let small = l;
            if l + 1 < n && self.counts[self.heap[l + 1]] < self.counts[self.heap[l]] {
                small = l + 1;
            }
            if self.counts[self.heap[i]] <= self.counts[self.heap[small]] {
                return;
            }
            self.swap(i, small);
            i = small;
        }
    }
}

fn item_weight(x: Item) -> int {
    return -x.count;
}

fn item_key(x: Item) -> str {
    return x.key;
}
