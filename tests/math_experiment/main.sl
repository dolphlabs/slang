// Experiment statistics against R / scipy values: t and chi-square
// distributions, the tests, Wilson intervals, sample sizes and SPRT.
import "math/stats";
import "math";

fn r6(x: float) -> float { return math.round_to(x, 6); }

let t5 = stats.student_t(5.0);
println(r6(t5.cdf(2.0)));                 // pt(2, 5) = 0.949030
println(r6(t5.quantile(0.975)));          // qt(.975, 5) = 2.570582
println(r6(t5.pdf(0.0)));                 // dt(0, 5) = 0.379607
println(r6(stats.student_t(1.0).cdf(1.0)));   // Cauchy: 0.75
println(r6(stats.student_t(30.0).quantile(0.05)));   // -1.697261
let c3 = stats.chi_squared(3.0);
println(r6(c3.cdf(7.814728)));            // 0.95
println(r6(c3.quantile(0.95)));           // qchisq(.95, 3) = 7.814728
println(r6(stats.chi_squared(1.0).quantile(0.99)));  // 6.634897
println(r6(stats.chi_squared(10.0).pdf(8.0)));       // dchisq(8, 10) = 0.097683
println(r6(stats.inc_beta(2.0, 3.0, 0.4)));          // pbeta(.4, 2, 3) = 0.5248
println(r6(stats.inc_gamma(2.5, 1.5)));              // pgamma(1.5, 2.5) = 0.300014

let z = stats.two_proportion_z(120, 2400, 156, 2380);
println(r6(z.statistic));                 // 2.231...
println(r6(z.p_value));
println(math.is_nan(stats.two_proportion_z(5, 4, 1, 10).p_value));
let w = stats.welch_t([19.8, 20.4, 19.6, 17.8, 18.5, 18.9, 18.3, 18.9, 19.5, 22.0],
                      [28.2, 26.6, 20.1, 23.3, 25.2, 22.1, 17.7, 27.6, 20.6, 13.7, 23.2, 17.5, 20.6, 18.0, 23.9, 21.6, 24.3, 20.4, 23.9, 13.3]);
println(r6(w.statistic));                 // scipy ttest_ind(equal_var=False): t = 2.2...
println(r6(w.df));
println(r6(w.p_value));
let one = stats.t_test([5.1, 4.9, 5.6, 5.8, 6.0, 5.4, 5.2], 5.0);
println(r6(one.statistic));
println(r6(one.p_value));
let ct = stats.chi_square_test([[10, 20, 30], [20, 20, 20]]);
println(r6(ct.statistic));
println(ct.df);
println(r6(ct.p_value));
let fit = stats.chi_square_fit([16, 18, 16, 14, 12, 12], [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]);
println(r6(fit.statistic));               // 2.0
println(r6(fit.p_value));                 // 0.849145
let wi = stats.wilson(156, 2380, 0.95);
println("${r6(wi.lo)} ${r6(wi.hi)}");
let w0 = stats.wilson(0, 50, 0.95);
println("${w0.lo} ${r6(w0.hi)}");
let mi = stats.mean_interval([5.1, 4.9, 5.6, 5.8, 6.0, 5.4, 5.2], 0.95);
println("${r6(mi.lo)} ${r6(mi.hi)}");
println(stats.sample_size_proportions(0.05, 0.06, 0.05, 0.8));   // about 8158
println(r6(stats.power_proportions(0.05, 0.06, 8158, 0.05)));
println(stats.sample_size_means(0.5, 2.0, 0.05, 0.8));           // 252
println(stats.sample_size_proportions(0.05, 0.05, 0.05, 0.8));

let s = stats.sprt(0.05, 0.10, 0.05, 0.2);
let dec = stats.Decision.Continue;
let i = 0;
// a stream converting at 10%: every tenth succeeds
while dec == stats.Decision.Continue && i < 100000 {
    dec = s.add(i % 10 == 0);
    i += 1;
}
println(dec);
println(s.count());
let s2 = stats.sprt(0.05, 0.10, 0.05, 0.2);
let d2 = s2.add_n(5, 400);
println(d2);
println(s2.add(true));
println(stats.sprt(0.5, 0.5, 0.05, 0.2).add_n(100, 100));
