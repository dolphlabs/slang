// math/finance against spreadsheet values (NPV, IRR, XIRR, PMT, FV, PV,
// NPER, IPMT, PPMT, EFFECT, NOMINAL), a mortgage schedule that must add
// up to the cent, fee brackets by hand, and market data.
import "math/finance";
import "decimal";
import "math";

fn near(a: float, b: float, tol: float) -> bool {
    return math.abs(a - b) <= tol;
}
fn d(s: str) -> decimal.Decimal {
    return decimal.parse(s) ?? decimal.zero();
}

let flows = [-1000.0, 300.0, 400.0, 500.0];
println(math.round_to(finance.npv(0.08, flows), 6));           // 17.629426
let irr = finance.irr(flows) ?? math.nan;
println(math.round_to(irr, 10));                               // 0.0889633947
println(near(finance.npv(irr, flows), 0.0, 1e-9));
let noirr = finance.irr([100.0, 200.0]);
if let x = noirr { println("no!"); } else let e = err_of(noirr) { println(e); }
println(math.round_to(finance.irr([-100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]) ?? 0.0, 8));
// XIRR: Excel's documentation example, 0.373362535
let xr = finance.xirr([-10000.0, 2750.0, 4250.0, 3250.0, 2750.0], [0, 60, 303, 411, 456]) ?? 0.0;
println(math.round_to(xr, 9));
println(near(finance.xnpv(xr, [-10000.0, 2750.0, 4250.0, 3250.0, 2750.0], [0, 60, 303, 411, 456]), 0.0, 1e-6));

println(math.round_to(finance.pmt(0.05 / 12.0, 360, 250000.0, 0.0, false), 6));   // -1342.054...
println(math.round_to(finance.pmt(0.0, 10, 1000.0, 0.0, false), 6));
println(math.round_to(finance.pmt(0.01, 12, 1000.0, 0.0, true), 6));
println(math.round_to(finance.fv(0.06 / 12.0, 120, -200.0, -500.0, false), 6));   // 33685.567728
println(math.round_to(finance.pv(0.08 / 12.0, 240, 500.0, 0.0, false), 6));       // -59777.145...
println(math.round_to(finance.nper(0.01, -100.0, -1000.0, 10000.0, true), 6));    // 59.673866
println(math.round_to(finance.ipmt(0.1 / 12.0, 1, 36, 8000.0, 0.0, false), 6));   // -66.666667
println(math.round_to(finance.ppmt(0.1 / 12.0, 1, 24, 2000.0, 0.0, false), 6));   // -75.623186
println(math.round_to(finance.effective_rate(0.0525, 4), 10));                     // 0.0535426673
println(math.round_to(finance.nominal_rate(0.053543, 4), 10));                     // 0.0525003...
println(math.round_to(finance.compound(1000.0, 0.05, 10.0, 12), 6));
println(math.round_to(finance.compound(1000.0, 0.05, 10.0, 0), 6));
println(math.round_to(finance.cagr(100.0, 200.0, 5.0), 8));

// a 30-year mortgage, to the cent
let sched = finance.amortize(d("250000.00"), d("0.05"), 360, 12);
guard let rows = sched else let e = err_of(sched) { println(e); exit(1); }
println(len(rows));
println(decimal.format(rows[0].payment));
println(decimal.format(rows[0].interest));
println(decimal.format(rows[0].principal));
let total_principal = decimal.zero();
let total_interest = decimal.zero();
let lines_ok = true;
for p in rows {
    total_principal = decimal.add(total_principal, p.principal) ?? total_principal;
    total_interest = decimal.add(total_interest, p.interest) ?? total_interest;
    let sum = decimal.add(p.interest, p.principal) ?? decimal.zero();
    if !decimal.eq(sum, p.payment) { lines_ok = false; }
}
println(lines_ok);
println(decimal.format(total_principal));
println(decimal.format(total_interest));
println(decimal.format(rows[359].balance));
println(decimal.format(rows[359].payment));
let zero_rate = finance.amortize(d("1000.00"), d("0"), 3, 12) ?? [];
println(decimal.format(zero_rate[0].payment) + " " + decimal.format(zero_rate[2].payment) + " " + decimal.format(zero_rate[2].balance));
let badam = finance.amortize(d("100.00"), d("0.05"), 0, 12);
if let x = badam { println("no!"); } else let e = err_of(badam) { println(e); }

let parts = finance.prorate(d("100.00"), [d("1.5"), d("1.5"), d("0.75")]) ?? [];
let shown: [str] = [];
for p in parts { push(shown, decimal.format(p)); }
println(inspect(shown));
println(decimal.format(finance.apply_bps(d("12345.67"), d("25"), decimal.Rounding.HalfEven) ?? decimal.zero()));
println(finance.bps_change(100.0, 100.25));
let he = decimal.Rounding.HalfEven;
println(decimal.format(finance.progressive(d("1500"), [d("1000")], [d("0.02"), d("0.01")], 2, he) ?? decimal.zero()));
println(decimal.format(finance.progressive(d("700"), [d("1000"), d("5000")], [d("0.03"), d("0.02"), d("0.01")], 2, he) ?? decimal.zero()));
println(decimal.format(finance.progressive(d("9000"), [d("1000"), d("5000")], [d("0.03"), d("0.02"), d("0.01")], 2, he) ?? decimal.zero()));
println(decimal.format(finance.tiered(d("9000"), [d("1000"), d("5000")], [d("0.03"), d("0.02"), d("0.01")], 2, he) ?? decimal.zero()));
println(decimal.format(finance.tiered(d("1000"), [d("1000"), d("5000")], [d("0.03"), d("0.02"), d("0.01")], 2, he) ?? decimal.zero()));
let badp = finance.progressive(d("1"), [d("1")], [d("0.1")], 2, he);
if let x = badp { println("no!"); } else let e = err_of(badp) { println(e); }

println(finance.vwap([10.0, 11.0, 12.0], [100.0, 200.0, 100.0]));
println(math.is_nan(finance.vwap([10.0], [0.0])));
println(decimal.format(finance.vwap_decimal([d("10.00"), d("11.00"), d("12.00")], [d("100"), d("200"), d("100")], 4, he) ?? decimal.zero()));
println(finance.twap([10.0, 20.0], [0, 30], 60));
let cs = finance.candles([0, 10, 59, 60, 61, 200], [10.0, 12.0, 9.0, 11.0, 13.0, 8.0], [1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 60);
println(len(cs));
println(inspect(cs[0]));
println(inspect(cs[2]));
println(finance.max_drawdown([100.0, 120.0, 90.0, 130.0, 104.0]));
