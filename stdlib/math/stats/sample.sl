// Drawing from the distributions in dist.sl with a seeded generator from
// `rand`, so a load generator or a simulation replays exactly from one
// seed:
//
//     let r = rand.new(42);
//     stats.normal(100.0, 15.0).sample(r);
//     stats.poisson(3.5).sample(r);         // an int
//
// The algorithms are the ones numpy, rand_distr and TensorFlow use: the
// ziggurat for the normal and the exponential (rand.normal,
// rand.exponential), Hörmann's transformed rejection for the Poisson
// (PTRS) and the binomial (BTRS) once the mean is 10 or more, and plain
// multiplication or inversion below that. Every one is exact, not an
// approximation, and costs O(1) on average whatever the parameters.

import "math";
import "rand";

// Poisson and binomial draws past this many are refused as an answer
// rather than converted: a float that large has no exact int.
let INT_SAFE = 9007199254740992.0;

// PTRS: a draw from Poisson(lambda) for lambda >= 10 (Hörmann 1993, "The
// transformed rejection method for generating Poisson random variables").
// About 1.1 pairs of uniforms per draw.
fn poisson_ptrs(r: rand.Rng, lambda: float) -> int {
    let slam = math.sqrt(lambda);
    let loglam = math.log(lambda);
    let b = 0.931 + 2.53 * slam;
    let a = -0.059 + 0.02483 * b;
    let inv_alpha = 1.1239 + 1.1328 / (b - 3.4);
    let vr = 0.9277 - 3.6224 / (b - 2.0);
    while true {
        let u = rand.unit(r) - 0.5;
        let v = rand.unit(r);
        let us = 0.5 - math.abs(u);
        if us <= 0.0 {
            continue;
        }
        let kf = math.floor((2.0 * a / us + b) * u + lambda + 0.43);
        if kf < 0.0 || kf >= INT_SAFE {
            continue;
        }
        if us >= 0.07 && v <= vr {
            return kf as int;
        }
        if us < 0.013 && v > us {
            continue;
        }
        let lhs = math.log(v) + math.log(inv_alpha) - math.log(a / (us * us) + b);
        if lhs <= -lambda + kf * loglam - math.lgamma(kf + 1.0) {
            return kf as int;
        }
    }
    return 0;
}

// A draw from Poisson(lambda) for 0 < lambda < 10: multiply uniforms until
// the product falls below exp(-lambda), about lambda + 1 of them.
fn poisson_mult(r: rand.Rng, lambda: float) -> int {
    let limit = math.exp(-lambda);
    let k = 0;
    let prod = rand.unit(r);
    while prod > limit {
        k += 1;
        prod *= rand.unit(r);
    }
    return k;
}

// log(k!) - log of Stirling's approximation to it, the correction term
// BTRS needs: exact for k <= 9, the asymptotic series beyond (good to
// double precision there).
fn stirling_tail(k: float) -> float {
    if k <= 9.0 {
        return switch k as int {
            case 0 { 0.0810614667953272 }
            case 1 { 0.0413406959554092 }
            case 2 { 0.0276779256849983 }
            case 3 { 0.02079067210376509 }
            case 4 { 0.0166446911898211 }
            case 5 { 0.0138761288230707 }
            case 6 { 0.0118967099458917 }
            case 7 { 0.010411265261972 }
            case 8 { 0.00925546218271273 }
            default { 0.00833056343336287 }
        };
    }
    let kp1 = k + 1.0;
    let sq = kp1 * kp1;
    return (1.0 / 12.0 - (1.0 / 360.0 - 1.0 / 1260.0 / sq) / sq) / kp1;
}

// BTRS: a draw from Binomial(n, p) for p <= 0.5 and n*p >= 10 (Hörmann
// 1993, "The generation of binomial random variates").
fn binomial_btrs(r: rand.Rng, n: int, p: float) -> int {
    let nf = n as float;
    let q = 1.0 - p;
    let spq = math.sqrt(nf * p * q);
    let b = 1.15 + 2.53 * spq;
    let a = -0.0873 + 0.0248 * b + 0.01 * p;
    let c = nf * p + 0.5;
    let vr = 0.92 - 4.2 / b;
    let ratio = p / q;
    let alpha = (2.83 + 5.1 / b) * spq;
    let m = math.floor((nf + 1.0) * p);
    while true {
        let u = rand.unit(r) - 0.5;
        let v = rand.unit(r);
        let us = 0.5 - math.abs(u);
        if us <= 0.0 {
            continue;
        }
        let kf = math.floor((2.0 * a / us + b) * u + c);
        if kf < 0.0 || kf > nf {
            continue;
        }
        if us >= 0.07 && v <= vr {
            return kf as int;
        }
        let lv = math.log(v * alpha / (a / (us * us) + b));
        let bound = (m + 0.5) * math.log((m + 1.0) / (ratio * (nf - m + 1.0))) +
                    (nf + 1.0) * math.log((nf - m + 1.0) / (nf - kf + 1.0)) +
                    (kf + 0.5) * math.log(ratio * (nf - kf + 1.0) / (kf + 1.0)) +
                    stirling_tail(m) + stirling_tail(nf - m) -
                    stirling_tail(kf) - stirling_tail(nf - kf);
        if lv <= bound {
            return kf as int;
        }
    }
    return 0;
}

// A draw from Binomial(n, p) for p <= 0.5 and n*p < 10, by inversion:
// walk the pmf up from 0 until the uniform is used up, restarting on the
// (vanishingly rare) walk past a 10-sigma bound that float rounding can
// cause.
fn binomial_inv(r: rand.Rng, n: int, p: float) -> int {
    let nf = n as float;
    let q = 1.0 - p;
    let q0 = math.exp(nf * math.log1p(-p));
    let mean = nf * p;
    let bound = math.min(nf, mean + 10.0 * math.sqrt(mean * q + 1.0));
    let x = 0;
    let px = q0;
    let u = rand.unit(r);
    while u > px {
        x += 1;
        if (x as float) > bound {
            x = 0;
            px = q0;
            u = rand.unit(r);
        } else {
            u -= px;
            px = ((nf - (x as float) + 1.0) * p * px) / ((x as float) * q);
        }
    }
    return x;
}
