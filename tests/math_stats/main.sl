// math/stats against values checked by hand and against Python's statistics
// module: the descriptive functions on int and float lists, Running merged
// across two halves of a stream, Ewma, a t-digest's quantiles on 100,000
// values within tolerance, and the distributions at known points.
import "math/stats";
import "math";
let xs = [12.5, 9.0, 14.25, 11.0];
let ys = [2.0, 4.0, 6.0, 8.0];
let is: [int] = [3, 1, 4, 1, 5, 9, 2, 6];
println(stats.mean(xs));
println(stats.median(xs));
println(stats.variance(xs));
println(stats.stddev(is));
println(stats.quantile(is, 0.9));
println(stats.mode(is) ?? -1);
println(stats.min(is) ?? -1);
println(inspect(stats.ranks([10, 20, 20, 30])));
println(stats.correlation(xs, ys));
println(stats.spearman(xs, ys));
let fit = stats.linear_regression([1, 2, 3, 4], [3.0, 5.0, 7.0, 9.0]);
println(inspect(fit));
println(fit.at(10.0));
println(inspect(stats.histogram(is, 4)));
println(stats.sum([0.1, 0.2, 0.3]));
println(stats.mad(is));
println(stats.skewness(is));
println(stats.kurtosis(is));
println(inspect(stats.quartiles(is)));
let r = stats.running();
r.add(2.0).add(4.0).add(4.0).add(4.0).add(5.0).add(5.0).add(7.0).add(9.0);
println(r.count());
println(r.mean());
println(r.pvariance());
println(r.stddev());
let a = stats.running();
let b = stats.running();
for i in 0..1000 { a.add(i as float); }
for i in 1000..3000 { b.add(i as float); }
a.merge(b);
println(a.mean());
println(a.variance());
println(a.min());
println(a.max());
let e = stats.ewma(0.5);
e.add(10.0).add(20.0).add(20.0);
println(e.value());
println(stats.ewma_half_life(1.0).add(0.0).add(8.0).value());
// digest on 0..99999 in a scrambled order (a linear congruence mod 100000)
let d = stats.digest();
let x = 0;
for i in 0..100000 {
    x = (x + 37813) % 100000;
    d.add(x as float);
}
println(d.count());
println(d.min());
println(d.max());
let p50 = d.quantile(0.5);
let p99 = d.quantile(0.99);
let p999 = d.quantile(0.999);
println(math.abs(p50 - 49999.5) < 500.0);
println(math.abs(p99 - 98999.0) < 100.0);
println(math.abs(p999 - 99899.0) < 20.0);
println(math.abs(d.cdf(25000.0) - 0.25) < 0.005);
println(len(d.means) < 200);
let d2 = stats.digest();
for i in 0..1000 { d2.add(1000000.0 + (i as float)); }
d.merge(d2);
println(d.count());
println(d.max());
// distributions
let n = stats.normal(100.0, 15.0);
println(n.cdf(130.0));
println(n.quantile(0.95));
println(n.pdf(100.0));
println(stats.normal(0.0, 1.0).cdf(-10.0));
println(stats.normal(0.0, 1.0).quantile(0.975));
println(stats.exponential(2.0).cdf(1.0));
println(stats.exponential(2.0).quantile(0.5));
println(stats.poisson(3.0).pmf(5));
println(stats.poisson(3.0).cdf(2));
println(stats.binomial(10, 0.5).pmf(5));
println(stats.binomial(10, 0.5).cdf(5));
println(stats.uniform(0.0, 10.0).quantile(0.25));
println(stats.log_normal(0.0, 1.0).cdf(1.0));
println(math.is_nan(stats.normal(0.0, 0.0).cdf(1.0)));
