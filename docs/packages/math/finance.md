# math/finance

> Package math/finance.

Time value of money, loans, fees and market data. Analysis takes
floats; anything booked (a schedule, a fee, a split) takes and returns
`decimal.Decimal` and adds up to the cent.

```slang
import "math/finance";
import "decimal";

finance.npv(0.08, [-1000.0, 300.0, 400.0, 500.0]);    // 17.629...
finance.irr([-1000.0, 300.0, 400.0, 500.0]);          // ok(0.08896...)
finance.xirr(flows, days);                            // dated flows, actual/365
finance.pmt(0.05 / 12.0, 360, 250000.0, 0.0, false);  // -1342.05

let p = decimal.parse("250000.00") ?? decimal.zero();
let rate = decimal.parse("0.05") ?? decimal.zero();
let rows = finance.amortize(p, rate, 360, 12);        // [Payment], to the cent
finance.progressive(amount, bounds, rates, 2, decimal.Rounding.HalfEven);
finance.prorate(total, [share_a, share_b]);           // largest remainder
```

- **Value:** `npv`, `irr` (safeguarded Newton on the exact derivative
  inside a scanned bracket), `xnpv`, `xirr`, and the spreadsheet set
  `pmt`, `fv`, `pv`, `nper`, `ipmt`, `ppmt` with their sign convention
  (money paid out is negative) and `at_start` for annuities due;
  `effective_rate`, `nominal_rate`, `compound` (n <= 0: continuous),
  `cagr`.
- **Booked money:** `amortize` (interest rounded half-even each period,
  the level payment rounded to the cent, the last payment absorbing the
  difference so the balance ends at exactly zero; every line adds up),
  `prorate` (by decimal weights, through `decimal.allocate`),
  `apply_bps`, `progressive` (marginal brackets, as income tax),
  `tiered` (the whole amount at its tier's rate).
- **Market data:** `vwap`, `vwap_decimal`, `twap`, `candles` and
  `candle_builder` (OHLCV bars from a trade feed, aligned to the
  interval), `max_drawdown`, `bps_change`.

`irr` and `xirr` are an error, not a guess, when the flows never change
sign or no rate in (-99%, 100000%) balances them; with several sign
changes they return the lowest rate.

## API

### `fn npv(rate: float, flows: [float]) -> float`

Net present value at `rate` per period of flows[0] now, flows[1] one period later, and so on. Horner's rule: one division per flow.

### `fn irr(flows: [float]) -> result[float, str]`

The internal rate of return: the rate at which npv(rate, flows) is 0. Safeguarded Newton on the exact derivative inside a bracket found by scanning from -0.99 upward, so it converges whenever a root exists in (-0.99, 1000). An error when the flows never change sign (no rate can balance them) or no root lies in that range. Flows that change sign more than once can have several rates; this returns the lowest.

### `fn xnpv(rate: float, flows: [float], days: [int]) -> float`

npv for flows on given days: flows[i] lands days[i] days after day 0, discounted at the annual `rate` over actual/365 years (the XNPV convention). days need not be sorted.

### `fn xirr(flows: [float], days: [int]) -> result[float, str]`

The annual rate at which xnpv is 0 (XIRR).

### `fn pmt(rate: float, nper: int, pv: float, fv: float, at_start: bool) -> float`

The payment per period that repays present value pv (and leaves future value fv) over nper periods at rate per period: the PMT of a spreadsheet. at_start is true for payments at the start of each period (an annuity due). pmt(0.05/12, 360, 250000, 0, false) is -1342.05.

### `fn fv(rate: float, nper: int, pmt: float, pv: float, at_start: bool) -> float`

The future value after nper periods of payment pmt from present value pv: the FV of a spreadsheet.

### `fn pv(rate: float, nper: int, pmt: float, fv: float, at_start: bool) -> float`

The present value of nper payments of pmt and a final fv: the PV of a spreadsheet.

### `fn nper(rate: float, pmt: float, pv: float, fv: float, at_start: bool) -> float`

The number of periods for payments of pmt to take pv to fv: the NPER of a spreadsheet (fractional). NaN when they never can.

### `fn ipmt(rate: float, period: int, nper: int, pv: float, fv: float, at_start: bool) -> float`

The interest part of payment number `period` (1-based): IPMT.

### `fn ppmt(rate: float, period: int, nper: int, pv: float, fv: float, at_start: bool) -> float`

The principal part of payment number `period`: PPMT.

### `fn effective_rate(nominal: float, n: int) -> float`

The annual effective rate of a nominal rate compounded n times a year.

### `fn nominal_rate(effective: float, n: int) -> float`

The nominal rate, compounded n times a year, with annual effective rate `effective`.

### `fn compound(principal: float, rate: float, years: float, n: int) -> float`

principal grown at the annual `rate` for `years`, compounded n times a year (n <= 0: continuously).

### `fn cagr(start: float, end: float, years: float) -> float`

The compound annual growth rate taking `start` to `end` over `years`.

### `struct Payment`

One line of an amortisation schedule.

### `fn amortize(principal: decimal.Decimal, annual_rate: decimal.Decimal, periods: int, per_year: int) -> result[[Payment], str]`

The schedule repaying `principal` at `annual_rate` (0.05 for 5%) in `periods` equal payments, `per_year` a year, at the principal's scale. Interest each period is the balance times annual_rate / per_year, rounded half-even to the cent; the payment is the level payment rounded the same way, and the last payment is adjusted so the balance ends at exactly zero. Every line adds up: payment = interest + principal, and the principals sum to the loan.

### `fn prorate(amount: decimal.Decimal, weights: [decimal.Decimal]) -> result[[decimal.Decimal], str]`

`amount` split in proportion to decimal weights (shares, hours, usage), adding up to `amount` exactly at its scale, by largest remainder as decimal.allocate does for int weights.

### `fn apply_bps(amount: decimal.Decimal, bps: decimal.Decimal, mode: decimal.Rounding) -> opt[decimal.Decimal]`

amount * bps / 10000, rounded to amount's scale: a fee or spread in basis points. none on overflow.

### `fn bps_change(a: float, b: float) -> float`

The change from a to b in basis points: 10000 * (b - a) / a.

### `fn progressive(amount: decimal.Decimal, bounds: [decimal.Decimal], rates: [decimal.Decimal], scale: int, mode: decimal.Rounding) -> result[decimal.Decimal, str]`

A marginal (progressive) charge: the part of `amount` in each bracket is charged at that bracket's rate, like income tax or tiered card fees. `bounds` are the ascending upper edges of every bracket but the last; `rates` has one more entry than `bounds`. progressive(1500, [1000], [0.02, 0.01]) is 1000 * 0.02 + 500 * 0.01 = 25. Rounded once, at the end, to `scale`.

### `fn tiered(amount: decimal.Decimal, bounds: [decimal.Decimal], rates: [decimal.Decimal], scale: int, mode: decimal.Rounding) -> result[decimal.Decimal, str]`

A volume-tier charge: the whole amount at the rate of the tier it falls in (bounds as in progressive: the tier is the first bound at or above amount, else the last). Rounded to `scale`.

### `fn vwap(prices: [float], volumes: [float]) -> float`

The volume-weighted average price. NaN when the volumes sum to 0.

### `fn vwap_decimal(prices: [decimal.Decimal], volumes: [decimal.Decimal], scale: int, mode: decimal.Rounding) -> result[decimal.Decimal, str]`

VWAP in decimals, exact until the final division at `scale`.

### `fn twap(prices: [float], times: [int], end: int) -> float`

The time-weighted average price over [times[0], end]: each price holds from its time until the next one (or end). times ascend. NaN when the span is empty.

### `struct Candle`

One bar of open, high, low, close and volume for [start, start + width).

### `fn candles(times: [int], prices: [float], volumes: [float], width: int) -> [Candle]`

Trades (times ascending, in any unit) rolled into candles of `width`, aligned to multiples of width; intervals without trades are skipped.

### `gc struct CandleBuilder`

Builds candles from a live trade feed, one trade at a time.

### `fn candle_builder(width: int) -> CandleBuilder`

A builder of candles `width` wide (at least 1).

### `fn add(self: CandleBuilder, t: int, price: float, volume: float) -> opt[Candle]`

Adds a trade; returns the previous candle when this trade starts a new interval. A trade earlier than the current candle is counted in it (late prints are not dropped).

### `fn flush(self: CandleBuilder) -> opt[Candle]`

The candle in progress, if any, ending it.

### `fn max_drawdown(prices: [float]) -> float`

The largest fall from a running peak, as a fraction of the peak (0.25 for a 25% drawdown). 0 for fewer than two prices or a series that only rises.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
