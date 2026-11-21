// Sampling from math/stats distributions and rand's normal/exponential:
// moments and goodness of fit on fixed seeds. Every check is against a
// bound several standard errors wide, so it holds for these seeds on every
// platform; the first draws print exactly for the integer distributions,
// which use libm only in comparisons far from their thresholds.
import "math";
import "math/stats";
import "rand";

fn check(name: str, ok: bool) {
    if ok {
        println(name + " ok");
    } else {
        println(name + " FAILED");
    }
}

// Pearson chi-square of observed counts against expected ones, bins with
// expected >= 5 only; compared with a generous critical value.
fn chi2(obs: [int], expect: [float]) -> float {
    let x = 0.0;
    for i in 0..len(obs) {
        if expect[i] >= 5.0 {
            let d = (obs[i] as float) - expect[i];
            x += d * d / expect[i];
        }
    }
    return x;
}

let r = rand.new(2026);
let n = 400000;

// rand.normal / rand.exponential
let a = stats.running();
let b = stats.running();
let tails = 0;
for i in 0..n {
    let z = rand.normal(r);
    a.add(z);
    if z > 3.0 || z < -3.0 {
        tails += 1;
    }
    b.add(rand.exponential(r));
}
check("normal mean", math.abs(a.mean()) < 0.006);
check("normal variance", math.abs(a.variance() - 1.0) < 0.01);
check("normal 3-sigma tails", math.abs((tails as float) / (n as float) - 0.0026998) < 0.0005);
check("exponential mean", math.abs(b.mean() - 1.0) < 0.006);
check("exponential variance", math.abs(b.variance() - 1.0) < 0.02);

// Kolmogorov-Smirnov against the normal cdf: D below the 1% critical value.
let zs: [float] = [];
for i in 0..100000 {
    push(zs, rand.normal(r));
}
let sorted = stats.sorted_floats(zs);
let nd = stats.normal(0.0, 1.0);
let d = 0.0;
for i in 0..len(sorted) {
    let lo = nd.cdf(sorted[i]) - (i as float) / 100000.0;
    let hi = ((i + 1) as float) / 100000.0 - nd.cdf(sorted[i]);
    d = math.max(d, math.max(lo, hi));
}
check("normal KS", d < 1.63 / math.sqrt(100000.0));

// The distributions' own sample()
let norm = stats.normal(100.0, 15.0);
let ln = stats.log_normal(0.0, 0.5);
let un = stats.uniform(-2.0, 6.0);
let ex = stats.exponential(4.0);
let rn = stats.running();
let rl = stats.running();
let ru = stats.running();
let re = stats.running();
for i in 0..n {
    rn.add(norm.sample(r));
    rl.add(ln.sample(r));
    ru.add(un.sample(r));
    re.add(ex.sample(r));
}
check("Normal(100, 15)", math.abs(rn.mean() - 100.0) < 0.1 && math.abs(rn.stddev() - 15.0) < 0.1);
check("LogNormal(0, 0.5)", math.abs(rl.mean() - math.exp(0.125)) < 0.005);
check("Uniform(-2, 6)", math.abs(ru.mean() - 2.0) < 0.02 && ru.min() >= -2.0 && ru.max() < 6.0);
check("Exponential(4)", math.abs(re.mean() - 0.25) < 0.002);
println(math.is_nan(stats.normal(0.0, -1.0).sample(r)));

// Poisson: both algorithms (lambda below and above 10), mean, variance and
// a chi-square fit to the pmf.
let lambdas = [0.5, 3.0, 9.5, 10.0, 47.0, 1000.0];
for lam in lambdas {
    let pd = stats.poisson(lam);
    let rp = stats.running();
    let bins = 0;
    let obs: [int] = [];
    let width = (lam + 10.0 * math.sqrt(lam) + 10.0) as int;
    for k in 0..width {
        push(obs, 0);
    }
    for i in 0..200000 {
        let k = pd.sample(r);
        rp.add(k as float);
        if k < width {
            obs[k] += 1;
        }
    }
    let expect: [float] = [];
    for k in 0..width {
        push(expect, pd.pmf(k) * 200000.0);
    }
    let se = math.sqrt(lam / 200000.0);
    check("Poisson(${lam}) mean", math.abs(rp.mean() - lam) < 5.0 * se);
    check("Poisson(${lam}) variance", math.abs(rp.variance() / lam - 1.0) < 0.02);
    // df at most width; critical value at p = 0.001 is below df + 4 sqrt(2 df)
    let df = width as float;
    check("Poisson(${lam}) chi2", chi2(obs, expect) < df + 4.0 * math.sqrt(2.0 * df));
}
check("Poisson(0)", stats.poisson(0.0).sample(r) == 0);

// Binomial: inversion (n p < 10), BTRS, p above one half (mirrored), and
// the edges.
let cases = [[20, 30], [100, 5], [1000, 40], [60, 90], [5000, 1]];
for c in cases {
    let bn = c[0];
    let bp = (c[1] as float) / 100.0;
    let bd = stats.binomial(bn, bp);
    let rb = stats.running();
    let obs: [int] = [];
    for k in 0..bn + 1 {
        push(obs, 0);
    }
    for i in 0..200000 {
        let k = bd.sample(r);
        assert(k >= 0 && k <= bn, "binomial out of range");
        rb.add(k as float);
        obs[k] += 1;
    }
    let expect: [float] = [];
    for k in 0..bn + 1 {
        push(expect, bd.pmf(k) * 200000.0);
    }
    let mu = (bn as float) * bp;
    let sd = math.sqrt(mu * (1.0 - bp));
    check("Binomial(${bn}, ${bp}) mean", math.abs(rb.mean() - mu) < 5.0 * sd / math.sqrt(200000.0));
    check("Binomial(${bn}, ${bp}) variance", math.abs(rb.variance() / (sd * sd) - 1.0) < 0.03);
    let df = math.min((bn + 1) as float, 12.0 * sd + 1.0);
    check("Binomial(${bn}, ${bp}) chi2", chi2(obs, expect) < df + 4.0 * math.sqrt(2.0 * df) + 10.0);
}
check("Binomial edges", stats.binomial(0, 0.3).sample(r) == 0 && stats.binomial(7, 0.0).sample(r) == 0 && stats.binomial(7, 1.0).sample(r) == 7);

// Replay: the same seed gives the same draws.
let r1 = rand.new(99);
let r2 = rand.new(99);
let same = true;
for i in 0..1000 {
    if rand.normal(r1) != rand.normal(r2) || stats.poisson(30.0).sample(r1) != stats.poisson(30.0).sample(r2) {
        same = false;
    }
}
check("replay", same);
let r3 = rand.new(1);
let first: [int] = [];
for i in 0..8 {
    push(first, stats.poisson(4.0).sample(r3));
}
println(inspect(first));
