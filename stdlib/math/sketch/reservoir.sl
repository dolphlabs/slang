import "math";
import "rand";

// A uniform random sample of k items from a stream of unknown length, in
// O(k) memory: every item seen so far is in the sample with the same
// probability. Algorithm L (Li 1994) skips ahead between replacements, so
// most items cost a counter increment and no random draw.
//
// The sample is your own list, of any type: offer() says where the
// current item goes.
//
//     let keep: [Event] = [];
//     let rs = sketch.reservoir(100, rand.new(7));
//     for e in events {
//         if let slot = rs.offer() {
//             if slot == len(keep) { push(keep, e); } else { keep[slot] = e; }
//         }
//     }
pub gc struct Reservoir {
    k: int,
    seen: int,
    next: int,       // the (1-based) number of the next item to keep
    w: float,
    r: rand.Rng,
}

// A reservoir of k items (at least 1), drawing from r.
pub fn reservoir(k: int, r: rand.Rng) -> Reservoir {
    return Reservoir { k: math.max(k, 1), seen: 0, next: 0, w: 1.0, r: r };
}

impl Reservoir {
    // Counts one more item and says what to do with it: some(slot) to
    // store it at keep[slot] (slot == len(keep) while the sample fills:
    // push it), none to drop it.
    pub fn offer(self: Reservoir) -> opt[int] {
        self.seen += 1;
        if self.seen <= self.k {
            if self.seen == self.k {
                self.w = math.exp(math.log(unit_open(self.r)) / (self.k as float));
                self.skip();
            }
            return some(self.seen - 1);
        }
        if self.seen < self.next {
            return none;
        }
        let slot = rand.below(self.r, self.k);
        self.w *= math.exp(math.log(unit_open(self.r)) / (self.k as float));
        self.skip();
        return some(slot);
    }

    // Items offered so far.
    pub fn seen(self: Reservoir) -> int {
        return self.seen;
    }

    pub fn size(self: Reservoir) -> int {
        return self.k;
    }

    // Starts over for a new stream, keeping the generator.
    pub fn reset(self: Reservoir) {
        self.seen = 0;
        self.next = 0;
        self.w = 1.0;
    }

    fn skip(self: Reservoir) {
        // floor(log(u) / log(1 - w)) items pass before the next keep;
        // capped so a vanishing w cannot overflow the count
        let gap = math.floor(math.log(unit_open(self.r)) / math.log1p(-self.w));
        if !(gap < 4611686018427387904.0) {
            gap = 4611686018427387904.0;
        }
        self.next = self.seen + (gap as int) + 1;
    }
}

// A uniform float in (0, 1]: never 0, so its log is finite.
fn unit_open(r: rand.Rng) -> float {
    return 1.0 - rand.unit(r);
}
