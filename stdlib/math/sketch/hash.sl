// Fixed-memory, mergeable estimates for live servers: how many distinct
// users (HyperLogLog), how often each key (CountMin), which keys are the
// heaviest (TopK), have we seen this before (Bloom, Cuckoo), latency
// percentiles (Histogram), and a fair sample of a stream (Reservoir).
//
//     import "math/sketch";
//
//     let users = sketch.hyperloglog(14);      // 16 KB, about 0.8% error
//     users.add_str(user_id);
//     users.count();
//
//     let seen = sketch.bloom(1000000, 0.01);  // 1M keys, 1% false positives
//     seen.add_str(key);
//     seen.contains_str(key);
//
//     let lat = sketch.histogram(60000000, 7); // up to 60 s in us, 0.8% buckets
//     lat.record(elapsed_us);
//     lat.quantile(0.99);
//
// Every sketch of a kind merges with another built with the same
// parameters, so each task or host can keep its own and they combine
// without locks. Keys are hashed with hash_str, hash_int or hash_bytes;
// add_hash takes a hash computed elsewhere. The hashes are fixed for a
// slang release on little-endian machines (every server CPU in use), so
// sketches serialised with encode() merge across hosts.
//
// None of these locks: give each task its own and merge, or guard a
// shared one with a mutex.

import "strings";

// splitmix64's increment: keeps 0 from hashing to 0.
let SEED: u64 = 0x9e3779b97f4a7c15;

// MurmurHash3's 64-bit finaliser: a bijection with full avalanche, so a
// change in any input bit flips each output bit with odds near 1/2.
fn mix64(x: u64) -> u64 {
    let h = x ^ (x >> 33);
    h = h * 0xff51afd7ed558ccd;
    h = h ^ (h >> 33);
    h = h * 0xc4ceb9fe1a85ec53;
    return h ^ (h >> 33);
}

// A 64-bit hash of an int, every bit well mixed.
pub fn hash_int(x: int) -> u64 {
    return mix64((x as u64) + SEED);
}

// A 64-bit hash of a str (strings.hash, widened and remixed to 64 bits).
pub fn hash_str(s: str) -> u64 {
    return mix64((strings.hash(s) as u64) ^ SEED);
}

// A 64-bit hash of bytes: FNV-1a over the bytes, then the finaliser.
pub fn hash_bytes(b: bytes) -> u64 {
    let h: u64 = 0xcbf29ce484222325;
    for i in 0..len(b) {
        h = (h ^ (b[i] as u64)) * 0x100000001b3;
    }
    return mix64(h ^ SEED);
}
