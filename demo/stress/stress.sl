// stress: pure workload generators for /api/stress/* -- endpoints that
// exist only to be hammered by a load generator, not to be linked from
// the frontend. Each one isolates a different cost center so a load
// test can tell CPU-bound work apart from allocation pressure, JSON
// (de)serialization, blocking I/O, and the spawn/chan concurrency
// primitives themselves. See demo/stress_harness/ for the driver and
// demo/README.md for how to run it and what it found.

pub gc struct CpuReq { n: int }
pub gc struct CpuResp { n: int, prime_count: int, elapsed_ms: int }

pub gc struct AllocReq { n: int }
pub gc struct AllocResp { n: int, sum: int, elapsed_ms: int }

pub gc struct JsonItem { key: str, value: int }
pub gc struct JsonReq { tag: str, items: [JsonItem] }
pub gc struct JsonResp { tag: str, item_count: int, total: int, elapsed_ms: int }

pub gc struct SleepReq { ms: int }
pub gc struct SleepResp { slept_ms: int }

pub gc struct ChanReq { n: int }
pub gc struct ChanResp { n: int, prime_count: int, elapsed_ms: int }

pub gc struct FanoutReq { n: int, workers: int }
pub gc struct FanoutResp { n: int, workers: int, prime_count: int, elapsed_ms: int }

pub gc struct CounterResp { count: int }

// Trial division up to sqrt(i) for every i in [lo, hi), deliberately
// with no early-exit once a factor is found (slang has no break) --
// that actually makes for a more predictable, steady CPU cost per
// call, which is more useful for a stress test than the usual
// early-exit optimization would be.
pub fn count_primes_range(lo: int, hi: int) -> int {
    let count = 0;
    for i in lo..hi {
        let is_prime = true;
        if i < 2 {
            is_prime = false;
        }
        let d = 2;
        while d * d <= i {
            if i % d == 0 {
                is_prime = false;
            }
            d = d + 1;
        }
        if is_prime {
            count = count + 1;
        }
    }
    return count;
}

pub fn count_primes(n: int) -> int {
    return count_primes_range(0, n);
}

// Allocates and walks a list and a map of n elements each -- pure
// allocator/GC pressure, no compute of note.
pub fn alloc_and_sum(n: int) -> int {
    let xs: [int] = [];
    for i in 0..n {
        push(xs, i);
    }
    let m: map[str]int = {};
    for i in 0..n {
        m[to_str(i)] = i;
    }
    let sum = 0;
    for v in xs {
        sum = sum + v;
    }
    for k, v in m {
        sum = sum + v;
    }
    return sum;
}
