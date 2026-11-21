// Time value of money, loans, fees and market data, for backends that
// move money or price things.
//
//     import "math/finance";
//     import "decimal";
//
//     finance.npv(0.08, [-1000.0, 300.0, 400.0, 500.0])     // 17.63
//     finance.irr([-1000.0, 300.0, 400.0, 500.0])            // ok(0.0889...)
//     finance.pmt(0.05 / 12.0, 360, 250000.0, 0.0, false)    // -1342.05...
//
//     let p = decimal.parse("250000.00") ?? decimal.zero();
//     let rate = decimal.parse("0.05") ?? decimal.zero();
//     finance.amortize(p, rate, 360, 12)                     // [Payment], to the cent
//     finance.progressive(amount, bounds, rates, 2, decimal.Rounding.HalfEven)
//
// Rates are per period as fractions (0.05 is 5%), and cash flows follow
// the spreadsheet sign convention: money paid out is negative, money
// received positive, so pmt() of a loan you receive is negative. The
// float functions are for analysis and pricing; anything that is booked
// (a schedule, a fee, a split) takes and returns decimal.Decimal and adds
// up to the cent.

import "decimal";
import "math";

// ---- present and future value ----------------------------------------

// Net present value at `rate` per period of flows[0] now, flows[1] one
// period later, and so on. Horner's rule: one division per flow.
pub fn npv(rate: float, flows: [float]) -> float {
    let acc = 0.0;
    let d = 1.0 + rate;
    let i = len(flows) - 1;
    while i >= 0 {
        acc = acc / d + flows[i];
        i -= 1;
    }
    return acc;
}

// The internal rate of return: the rate at which npv(rate, flows) is 0.
// Safeguarded Newton on the exact derivative inside a bracket found by
// scanning from -0.99 upward, so it converges whenever a root exists in
// (-0.99, 1000). An error when the flows never change sign (no rate can
// balance them) or no root lies in that range. Flows that change sign
// more than once can have several rates; this returns the lowest.
pub fn irr(flows: [float]) -> result[float, str] {
    if !sign_change(flows) {
        return err("finance: the cash flows never change sign, so there is no IRR");
    }
    return solve_rate(flows, [], false);
}

// npv for flows on given days: flows[i] lands days[i] days after day 0,
// discounted at the annual `rate` over actual/365 years (the XNPV
// convention). days need not be sorted.
pub fn xnpv(rate: float, flows: [float], days: [int]) -> float {
    let acc = 0.0;
    let n = math.min(len(flows), len(days));
    let base = 1.0 + rate;
    for i in 0..n {
        acc += flows[i] / math.pow(base, (days[i] as float) / 365.0);
    }
    return acc;
}

// The annual rate at which xnpv is 0 (XIRR).
pub fn xirr(flows: [float], days: [int]) -> result[float, str] {
    if len(days) != len(flows) {
        return err("finance: xirr needs one day per flow");
    }
    if !sign_change(flows) {
        return err("finance: the cash flows never change sign, so there is no IRR");
    }
    return solve_rate(flows, days, true);
}

fn sign_change(flows: [float]) -> bool {
    let pos = false;
    let neg = false;
    for f in flows {
        if f > 0.0 {
            pos = true;
        }
        if f < 0.0 {
            neg = true;
        }
    }
    return pos && neg;
}

// npv (or xnpv) and its derivative in the rate, in one pass.
fn npv_d(rate: float, flows: [float], days: [int], dated: bool) -> [float] {
    let v = 0.0;
    let dv = 0.0;
    let base = 1.0 + rate;
    for i in 0..len(flows) {
        let t = i as float;
        if dated {
            t = (days[i] as float) / 365.0;
        }
        let disc = math.pow(base, -t);
        v += flows[i] * disc;
        dv -= t * flows[i] * disc / base;
    }
    return [v, dv];
}

fn solve_rate(flows: [float], days: [int], dated: bool) -> result[float, str] {
    // bracket: scan rates on a geometric grid above -1
    let lo = -0.99;
    let flo = npv_d(lo, flows, days, dated)[0];
    if flo == 0.0 {
        return ok(lo);
    }
    let hi = lo;
    let fhi = flo;
    let found = false;
    let step = 0.01;
    while hi < 1000.0 {
        let next = hi + step;
        let fn_ = npv_d(next, flows, days, dated)[0];
        if math.is_nan(fn_) {
            return err("finance: the NPV is not finite while searching for the IRR");
        }
        if fn_ == 0.0 {
            return ok(next);
        }
        if (fhi < 0.0) != (fn_ < 0.0) {
            lo = hi;
            flo = fhi;
            hi = next;
            fhi = fn_;
            found = true;
            break;
        }
        hi = next;
        fhi = fn_;
        step *= 1.25;
    }
    if !found {
        return err("finance: no IRR between -99% and 100000%");
    }
    // safeguarded Newton (rtsafe) on [lo, hi]
    let xl = lo;
    let xh = hi;
    if flo > 0.0 {
        xl = hi;
        xh = lo;
    }
    let x = 0.5 * (lo + hi);
    let dxold = math.abs(hi - lo);
    let dx = dxold;
    let fd = npv_d(x, flows, days, dated);
    for it in 0..200 {
        let f = fd[0];
        let d = fd[1];
        let out = ((x - xh) * d - f) * ((x - xl) * d - f) > 0.0;
        if out || math.abs(2.0 * f) > math.abs(dxold * d) {
            dxold = dx;
            dx = 0.5 * (xh - xl);
            x = xl + dx;
        } else {
            dxold = dx;
            dx = f / d;
            x -= dx;
        }
        if math.abs(dx) < 1e-14 * math.max(1.0, math.abs(x)) {
            return ok(x);
        }
        fd = npv_d(x, flows, days, dated);
        if fd[0] == 0.0 {
            return ok(x);
        }
        if fd[0] < 0.0 {
            xl = x;
        } else {
            xh = x;
        }
    }
    return ok(x);
}

// The payment per period that repays present value pv (and leaves future
// value fv) over nper periods at rate per period: the PMT of a
// spreadsheet. at_start is true for payments at the start of each period
// (an annuity due). pmt(0.05/12, 360, 250000, 0, false) is -1342.05.
pub fn pmt(rate: float, nper: int, pv: float, fv: float, at_start: bool) -> float {
    let n = nper as float;
    if rate == 0.0 {
        return -(pv + fv) / n;
    }
    let g = math.pow(1.0 + rate, n);
    let due = 1.0;
    if at_start {
        due = 1.0 + rate;
    }
    return -(rate * (pv * g + fv)) / (due * (g - 1.0));
}

// The future value after nper periods of payment pmt from present value
// pv: the FV of a spreadsheet.
pub fn fv(rate: float, nper: int, pmt: float, pv: float, at_start: bool) -> float {
    let n = nper as float;
    if rate == 0.0 {
        return -(pv + pmt * n);
    }
    let g = math.pow(1.0 + rate, n);
    let due = 1.0;
    if at_start {
        due = 1.0 + rate;
    }
    return -(pv * g + pmt * due * (g - 1.0) / rate);
}

// The present value of nper payments of pmt and a final fv: the PV of a
// spreadsheet.
pub fn pv(rate: float, nper: int, pmt: float, fv: float, at_start: bool) -> float {
    let n = nper as float;
    if rate == 0.0 {
        return -(fv + pmt * n);
    }
    let g = math.pow(1.0 + rate, n);
    let due = 1.0;
    if at_start {
        due = 1.0 + rate;
    }
    return -(fv + pmt * due * (g - 1.0) / rate) / g;
}

// The number of periods for payments of pmt to take pv to fv: the NPER of
// a spreadsheet (fractional). NaN when they never can.
pub fn nper(rate: float, pmt: float, pv: float, fv: float, at_start: bool) -> float {
    if rate == 0.0 {
        if pmt == 0.0 {
            return math.nan;
        }
        return -(pv + fv) / pmt;
    }
    let due = 1.0;
    if at_start {
        due = 1.0 + rate;
    }
    let z = pmt * due / rate;
    let num = z - fv;
    let den = pv + z;
    if num / den <= 0.0 {
        return math.nan;
    }
    return math.log(num / den) / math.log1p(rate);
}

// The interest part of payment number `period` (1-based): IPMT.
pub fn ipmt(rate: float, period: int, nper: int, pv: float, fv: float, at_start: bool) -> float {
    if period < 1 || period > nper {
        return math.nan;
    }
    let p = pmt(rate, nper, pv, fv, at_start);
    if at_start && period == 1 {
        return 0.0;
    }
    let before = period - 1;
    let bal = fv_of_balance(rate, before, p, pv, at_start);
    let interest = bal * rate;
    if at_start {
        interest = interest / (1.0 + rate);
    }
    return interest;
}

// The principal part of payment number `period`: PPMT.
pub fn ppmt(rate: float, period: int, nper: int, pv: float, fv: float, at_start: bool) -> float {
    return pmt(rate, nper, pv, fv, at_start) - ipmt(rate, period, nper, pv, fv, at_start);
}

// The (signed) value after `k` payments, as fv() computes it.
fn fv_of_balance(rate: float, k: int, p: float, pv: float, at_start: bool) -> float {
    return fv(rate, k, p, pv, at_start);
}

// The annual effective rate of a nominal rate compounded n times a year.
pub fn effective_rate(nominal: float, n: int) -> float {
    if n <= 0 {
        return math.expm1(nominal);
    }
    return math.expm1((n as float) * math.log1p(nominal / (n as float)));
}

// The nominal rate, compounded n times a year, with annual effective
// rate `effective`.
pub fn nominal_rate(effective: float, n: int) -> float {
    if n <= 0 {
        return math.log1p(effective);
    }
    return (n as float) * math.expm1(math.log1p(effective) / (n as float));
}

// principal grown at the annual `rate` for `years`, compounded n times a
// year (n <= 0: continuously).
pub fn compound(principal: float, rate: float, years: float, n: int) -> float {
    if n <= 0 {
        return principal * math.exp(rate * years);
    }
    let nf = n as float;
    return principal * math.exp(nf * years * math.log1p(rate / nf));
}

// The compound annual growth rate taking `start` to `end` over `years`.
pub fn cagr(start: float, end: float, years: float) -> float {
    if !(start > 0.0) || !(years > 0.0) || end < 0.0 {
        return math.nan;
    }
    return math.expm1(math.log(end / start) / years);
}

// ---- booked money: loans, fees, splits -------------------------------

// One line of an amortisation schedule.
pub struct Payment {
    period: int,
    payment: decimal.Decimal,
    interest: decimal.Decimal,
    principal: decimal.Decimal,
    balance: decimal.Decimal,
}

// The schedule repaying `principal` at `annual_rate` (0.05 for 5%) in
// `periods` equal payments, `per_year` a year, at the principal's scale.
// Interest each period is the balance times annual_rate / per_year,
// rounded half-even to the cent; the payment is the level payment
// rounded the same way, and the last payment is adjusted so the balance
// ends at exactly zero. Every line adds up: payment = interest +
// principal, and the principals sum to the loan.
pub fn amortize(principal: decimal.Decimal, annual_rate: decimal.Decimal, periods: int, per_year: int) -> result[[Payment], str] {
    if periods < 1 || periods > 100000 {
        return err("finance: periods must be between 1 and 100000");
    }
    if per_year < 1 || per_year > 365 {
        return err("finance: per_year must be between 1 and 365");
    }
    if decimal.is_neg(principal) || decimal.is_neg(annual_rate) {
        return err("finance: principal and rate must not be negative");
    }
    let scale = decimal.scale_of(principal);
    let he = decimal.Rounding.HalfEven;
    let pr = decimal.div(annual_rate, decimal.from_int(per_year), 18, he);
    guard let rate = pr else let e = err_of(pr) {
        return err("finance: " + e);
    }
    let level = pmt(decimal.float_of(rate), periods, decimal.float_of(principal), 0.0, false);
    guard let pay0 = decimal.from_float(-level, scale, he) else {
        return err("finance: the payment does not fit a decimal");
    }
    let out: [Payment] = [];
    let bal = principal;
    for k in 1..=periods {
        guard let raw = decimal.mul_round(bal, rate, scale, he) else {
            return err("finance: interest overflowed");
        }
        let interest = raw;
        let pay = pay0;
        guard let due = decimal.add(bal, interest) else {
            return err("finance: balance overflowed");
        }
        if k == periods || decimal.gt(pay, due) {
            pay = due;
        }
        guard let part = decimal.sub(pay, interest) else {
            return err("finance: payment overflowed");
        }
        guard let left = decimal.sub(bal, part) else {
            return err("finance: balance overflowed");
        }
        bal = left;
        push(out, Payment { period: k, payment: pay, interest: interest, principal: part, balance: bal });
        if decimal.is_zero(bal) {
            break;
        }
    }
    return ok(out);
}

// `amount` split in proportion to decimal weights (shares, hours, usage),
// adding up to `amount` exactly at its scale, by largest remainder as
// decimal.allocate does for int weights.
pub fn prorate(amount: decimal.Decimal, weights: [decimal.Decimal]) -> result[[decimal.Decimal], str] {
    let s = 0;
    for w in weights {
        if decimal.is_neg(w) {
            return err("finance: a weight is negative");
        }
        s = math.max(s, decimal.scale_of(w));
    }
    let units: [int] = [];
    for w in weights {
        guard let u = decimal.to_units(w, s, decimal.Rounding.HalfEven) else {
            return err("finance: a weight is too large to prorate by");
        }
        push(units, u);
    }
    return decimal.allocate(amount, units);
}

// amount * bps / 10000, rounded to amount's scale: a fee or spread in
// basis points. none on overflow.
pub fn apply_bps(amount: decimal.Decimal, bps: decimal.Decimal, mode: decimal.Rounding) -> opt[decimal.Decimal] {
    guard let prod = decimal.mul(amount, bps) else {
        return none;
    }
    let r = decimal.div(prod, decimal.from_int(10000), decimal.scale_of(amount), mode);
    guard let v = r else {
        return none;
    }
    return some(v);
}

// The change from a to b in basis points: 10000 * (b - a) / a.
pub fn bps_change(a: float, b: float) -> float {
    return 10000.0 * (b - a) / a;
}

// A marginal (progressive) charge: the part of `amount` in each bracket is
// charged at that bracket's rate, like income tax or tiered card fees.
// `bounds` are the ascending upper edges of every bracket but the last;
// `rates` has one more entry than `bounds`. progressive(1500, [1000],
// [0.02, 0.01]) is 1000 * 0.02 + 500 * 0.01 = 25. Rounded once, at the
// end, to `scale`.
pub fn progressive(amount: decimal.Decimal, bounds: [decimal.Decimal], rates: [decimal.Decimal], scale: int, mode: decimal.Rounding) -> result[decimal.Decimal, str] {
    if len(rates) != len(bounds) + 1 {
        return err("finance: progressive needs one more rate than bounds");
    }
    for i in 1..len(bounds) {
        if !decimal.gt(bounds[i], bounds[i - 1]) {
            return err("finance: bounds must increase");
        }
    }
    let total = decimal.zero();
    let below = decimal.zero();
    for i in 0..len(rates) {
        if !decimal.gt(amount, below) {
            break;
        }
        let top = amount;
        if i < len(bounds) && decimal.lt(bounds[i], amount) {
            top = bounds[i];
        }
        guard let slice = decimal.sub(top, below) else {
            return err("finance: overflow");
        }
        guard let part = decimal.mul(slice, rates[i]) else {
            return err("finance: overflow");
        }
        guard let t = decimal.add(total, part) else {
            return err("finance: overflow");
        }
        total = t;
        if i < len(bounds) {
            below = bounds[i];
        }
    }
    guard let rounded = decimal.round(total, scale, mode) else {
        return err("finance: overflow");
    }
    return ok(rounded);
}

// A volume-tier charge: the whole amount at the rate of the tier it falls
// in (bounds as in progressive: the tier is the first bound at or above
// amount, else the last). Rounded to `scale`.
pub fn tiered(amount: decimal.Decimal, bounds: [decimal.Decimal], rates: [decimal.Decimal], scale: int, mode: decimal.Rounding) -> result[decimal.Decimal, str] {
    if len(rates) != len(bounds) + 1 {
        return err("finance: tiered needs one more rate than bounds");
    }
    let i = 0;
    while i < len(bounds) && decimal.gt(amount, bounds[i]) {
        i += 1;
    }
    guard let v = decimal.mul_round(amount, rates[i], scale, mode) else {
        return err("finance: overflow");
    }
    return ok(v);
}

// ---- market data -----------------------------------------------------

// The volume-weighted average price. NaN when the volumes sum to 0.
pub fn vwap(prices: [float], volumes: [float]) -> float {
    let pv = 0.0;
    let v = 0.0;
    let n = math.min(len(prices), len(volumes));
    for i in 0..n {
        pv += prices[i] * volumes[i];
        v += volumes[i];
    }
    if v == 0.0 {
        return math.nan;
    }
    return pv / v;
}

// VWAP in decimals, exact until the final division at `scale`.
pub fn vwap_decimal(prices: [decimal.Decimal], volumes: [decimal.Decimal], scale: int, mode: decimal.Rounding) -> result[decimal.Decimal, str] {
    if len(prices) != len(volumes) {
        return err("finance: vwap needs one volume per price");
    }
    let pv = decimal.zero();
    let v = decimal.zero();
    for i in 0..len(prices) {
        guard let p = decimal.mul(prices[i], volumes[i]) else {
            return err("finance: overflow");
        }
        guard let s = decimal.add(pv, p) else {
            return err("finance: overflow");
        }
        guard let t = decimal.add(v, volumes[i]) else {
            return err("finance: overflow");
        }
        pv = s;
        v = t;
    }
    if decimal.is_zero(v) {
        return err("finance: the volumes sum to zero");
    }
    return decimal.div(pv, v, scale, mode);
}

// The time-weighted average price over [times[0], end]: each price holds
// from its time until the next one (or end). times ascend. NaN when the
// span is empty.
pub fn twap(prices: [float], times: [int], end: int) -> float {
    let n = math.min(len(prices), len(times));
    if n == 0 || end <= times[0] {
        return math.nan;
    }
    let acc = 0.0;
    for i in 0..n {
        let until = end;
        if i + 1 < n {
            until = math.min(times[i + 1], end);
        }
        if until > times[i] {
            acc += prices[i] * ((until - times[i]) as float);
        }
    }
    return acc / ((end - times[0]) as float);
}

// One bar of open, high, low, close and volume for [start, start + width).
pub struct Candle {
    start: int,
    open: float,
    high: float,
    low: float,
    close: float,
    volume: float,
    trades: int,
}

// Trades (times ascending, in any unit) rolled into candles of `width`,
// aligned to multiples of width; intervals without trades are skipped.
pub fn candles(times: [int], prices: [float], volumes: [float], width: int) -> [Candle] {
    let out: [Candle] = [];
    let b = candle_builder(width);
    let n = math.min(len(times), math.min(len(prices), len(volumes)));
    for i in 0..n {
        if let c = b.add(times[i], prices[i], volumes[i]) {
            push(out, c);
        }
    }
    if let c = b.flush() {
        push(out, c);
    }
    return out;
}

// Builds candles from a live trade feed, one trade at a time.
pub gc struct CandleBuilder {
    width: int,
    open: bool,
    cur: Candle,
}

// A builder of candles `width` wide (at least 1).
pub fn candle_builder(width: int) -> CandleBuilder {
    let empty = Candle { start: 0, open: 0.0, high: 0.0, low: 0.0, close: 0.0, volume: 0.0, trades: 0 };
    return CandleBuilder { width: math.max(width, 1), open: false, cur: empty };
}

impl CandleBuilder {
    // Adds a trade; returns the previous candle when this trade starts a
    // new interval. A trade earlier than the current candle is counted in
    // it (late prints are not dropped).
    pub fn add(self: CandleBuilder, t: int, price: float, volume: float) -> opt[Candle] {
        let start = math.div_floor(t, self.width) * self.width;
        if self.open && start > self.cur.start {
            let done = self.cur;
            self.cur = Candle { start: start, open: price, high: price, low: price, close: price, volume: volume, trades: 1 };
            return some(done);
        }
        if !self.open {
            self.cur = Candle { start: start, open: price, high: price, low: price, close: price, volume: volume, trades: 1 };
            self.open = true;
            return none;
        }
        let c = self.cur;
        self.cur = Candle {
            start: c.start, open: c.open, high: math.max(c.high, price),
            low: math.min(c.low, price), close: price, volume: c.volume + volume,
            trades: c.trades + 1
        };
        return none;
    }

    // The candle in progress, if any, ending it.
    pub fn flush(self: CandleBuilder) -> opt[Candle] {
        if !self.open {
            return none;
        }
        self.open = false;
        return some(self.cur);
    }
}

// The largest fall from a running peak, as a fraction of the peak (0.25
// for a 25% drawdown). 0 for fewer than two prices or a series that only
// rises.
pub fn max_drawdown(prices: [float]) -> float {
    let peak = math.neg_inf;
    let worst = 0.0;
    for p in prices {
        if p > peak {
            peak = p;
        }
        if peak > 0.0 {
            let dd = (peak - p) / peak;
            if dd > worst {
                worst = dd;
            }
        }
    }
    return worst;
}
