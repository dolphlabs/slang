// Calendar time: instants, dates, durations and their arithmetic.
//
// The native `time` package is the clock (`time.wall`, `time.mono`,
// `time.sleep`). `timez` is everything built on it, in slang:
//
//     import "timez";
//
//     let t = timez.now();                          // a Time: an instant, UTC
//     let d = t.date();                             // a Date: 2026-10-13
//     let due = d.add_months(1);                    // Jan 31 + 1 month = Feb 28/29
//     let r = timez.utc(2026, 10, 13, 9, 30, 0, 0); // result[Time, str]
//     let ttl = timez.parse_duration("1h30m");      // result[int, str], nanoseconds
//     println(timez.format_duration(t.sub(start))); // "1.502s"
//
// A Time is Unix seconds plus nanoseconds, like Go's, so it spans every
// date a database or a birth certificate holds: 0001-01-01 and 9999-12-31
// included, which 64-bit nanoseconds (1677-2262) do not reach. A duration
// is an int of nanoseconds, the unit `time.sleep` and deadlines take, so
// it reaches about 292 years either way.
//
// The calendar is proleptic Gregorian, in UTC; there are no leap seconds
// (as in every Unix clock). Days in DAY are 24 hours: across a daylight
// saving change in a named zone a calendar day is not, which is why
// add_days is a separate operation from add(DAY).

import "strings";
import "time";

pub let NANOSECOND = 1;
pub let MICROSECOND = 1000;
pub let MILLISECOND = 1000000;
pub let SECOND = 1000000000;
pub let MINUTE = 60000000000;
pub let HOUR = 3600000000000;
// 24 hours.
pub let DAY = 86400000000000;

pub enum Weekday {
    MONDAY,
    TUESDAY,
    WEDNESDAY,
    THURSDAY,
    FRIDAY,
    SATURDAY,
    SUNDAY,
}

// An instant, in UTC.
pub struct Time {
    // Seconds since 1970-01-01T00:00:00Z.
    sec: int,
    // 0 to 999,999,999.
    nsec: int,
}

// A calendar day, with no time and no zone: a birthday, a due date, a
// day of a report.
pub struct Date {
    year: int,
    month: int,
    day: int,
}

// An ISO 8601 week: weeks start on Monday, and week 1 is the one with
// the year's first Thursday, so early January can belong to the
// previous year's last week.
pub struct IsoWeek {
    year: int,
    week: int,
}

// ---- arithmetic helpers ---------------------------------------------------------

// Floor division and its remainder: -1 / 86400 is day -1, not day 0.
fn fdiv(a: int, b: int) -> int {
    let q = a / b;
    if (a % b != 0) && ((a < 0) != (b < 0)) {
        q = q - 1;
    }
    return q;
}

fn fmod(a: int, b: int) -> int {
    return a - fdiv(a, b) * b;
}

// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm:
// exact for every proleptic Gregorian date in range).
pub fn days_from_civil(y: int, m: int, d: int) -> int {
    let yy = y;
    if m <= 2 {
        yy = yy - 1;
    }
    let era = fdiv(yy, 400);
    let yoe = yy - era * 400;
    let mp = m + 9;
    if m > 2 {
        mp = m - 3;
    }
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// The civil date `days` after 1970-01-01.
pub fn civil_from_days(days: int) -> Date {
    let z = days + 719468;
    let era = fdiv(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + 3;
    if mp >= 10 {
        m = mp - 9;
    }
    let y = yoe + era * 400;
    if m <= 2 {
        y = y + 1;
    }
    return Date { year: y, month: m, day: d };
}

pub fn is_leap_year(y: int) -> bool {
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

pub fn days_in_month(y: int, m: int) -> int {
    if m == 2 {
        if is_leap_year(y) {
            return 29;
        }
        return 28;
    }
    if m == 4 || m == 6 || m == 9 || m == 11 {
        return 30;
    }
    return 31;
}

pub fn days_in_year(y: int) -> int {
    if is_leap_year(y) {
        return 366;
    }
    return 365;
}

fn weekday_from_index(i: int) -> Weekday {
    if i == 0 { return Weekday.MONDAY; }
    if i == 1 { return Weekday.TUESDAY; }
    if i == 2 { return Weekday.WEDNESDAY; }
    if i == 3 { return Weekday.THURSDAY; }
    if i == 4 { return Weekday.FRIDAY; }
    if i == 5 { return Weekday.SATURDAY; }
    return Weekday.SUNDAY;
}

// Monday 0 through Sunday 6.
pub fn weekday_index(w: Weekday) -> int {
    switch w {
        case Weekday.MONDAY { return 0; }
        case Weekday.TUESDAY { return 1; }
        case Weekday.WEDNESDAY { return 2; }
        case Weekday.THURSDAY { return 3; }
        case Weekday.FRIDAY { return 4; }
        case Weekday.SATURDAY { return 5; }
        case Weekday.SUNDAY { return 6; }
    }
    return 0;
}

// "Monday" ... "Sunday".
pub fn weekday_name(w: Weekday) -> str {
    switch w {
        case Weekday.MONDAY { return "Monday"; }
        case Weekday.TUESDAY { return "Tuesday"; }
        case Weekday.WEDNESDAY { return "Wednesday"; }
        case Weekday.THURSDAY { return "Thursday"; }
        case Weekday.FRIDAY { return "Friday"; }
        case Weekday.SATURDAY { return "Saturday"; }
        case Weekday.SUNDAY { return "Sunday"; }
    }
    return "";
}

// "January" ... "December"; "" outside 1-12.
pub fn month_name(m: int) -> str {
    let names = ["January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December"];
    if m < 1 || m > 12 {
        return "";
    }
    return names[m - 1];
}

// 1970-01-01 was a Thursday.
fn weekday_of_days(days: int) -> Weekday {
    return weekday_from_index(fmod(days + 3, 7));
}

// ---- constructing -------------------------------------------------------------

// The current instant, from the system clock.
pub fn now() -> Time {
    return unix_nano(time.wall());
}

pub fn unix(sec: int) -> Time {
    return Time { sec: sec, nsec: 0 };
}

pub fn unix_milli(ms: int) -> Time {
    return Time { sec: fdiv(ms, 1000), nsec: fmod(ms, 1000) * 1000000 };
}

pub fn unix_nano(ns: int) -> Time {
    return Time { sec: fdiv(ns, 1000000000), nsec: fmod(ns, 1000000000) };
}

// The instant at a UTC civil date and time; err names the first field
// out of range. Seconds run 0-59: there are no leap seconds.
pub fn utc(year: int, month: int, day: int, hour: int, minute: int, second: int,
           nanos: int) -> result[Time, str] {
    let dr = date(year, month, day);
    guard let d = dr else let e = err_of(dr) {
        return err(e);
    }
    if hour < 0 || hour > 23 {
        return err("hour " + to_str(hour) + " is out of range (0-23)");
    }
    if minute < 0 || minute > 59 {
        return err("minute " + to_str(minute) + " is out of range (0-59)");
    }
    if second < 0 || second > 59 {
        return err("second " + to_str(second) + " is out of range (0-59)");
    }
    if nanos < 0 || nanos > 999999999 {
        return err("nanosecond " + to_str(nanos) + " is out of range (0-999999999)");
    }
    let days = days_from_civil(d.year, d.month, d.day);
    return ok(Time { sec: days * 86400 + hour * 3600 + minute * 60 + second, nsec: nanos });
}

// A calendar date; err names what is out of range.
pub fn date(year: int, month: int, day: int) -> result[Date, str] {
    if year < -999999 || year > 999999 {
        return err("year " + to_str(year) + " is out of range");
    }
    if month < 1 || month > 12 {
        return err("month " + to_str(month) + " is out of range (1-12)");
    }
    let dim = days_in_month(year, month);
    if day < 1 || day > dim {
        return err("day " + to_str(day) + " is out of range for " + month_name(month) + " " +
                   to_str(year) + " (1-" + to_str(dim) + ")");
    }
    return ok(Date { year: year, month: month, day: day });
}

// Today's date, in UTC.
pub fn today() -> Date {
    return now().date();
}

pub fn min(a: Time, b: Time) -> Time {
    if a.before(b) {
        return a;
    }
    return b;
}

pub fn max(a: Time, b: Time) -> Time {
    if a.after(b) {
        return a;
    }
    return b;
}

// Nanoseconds since `t` (negative when `t` is in the future).
pub fn since(t: Time) -> int {
    return now().sub(t);
}

// Nanoseconds until `t` (negative when it has passed).
pub fn until(t: Time) -> int {
    return t.sub(now());
}

// The `until` a socket or channel call takes, for the wall-clock instant
// `t`: deadlines run on the monotonic clock, so this measures the
// distance to `t` once and counts it from now.
pub fn deadline(t: Time) -> until {
    return until_of(time.mono() + until(t));
}

// ---- Time ---------------------------------------------------------------------

fn days_of(t: Time) -> int {
    return fdiv(t.sec, 86400);
}

fn secs_of_day(t: Time) -> int {
    return fmod(t.sec, 86400);
}

// Saturating, so a difference of more than ~292 years clamps instead of
// wrapping around.
fn sat_ns(sec: int, nsec: int) -> int {
    let lim = 9223372035;
    if sec > lim {
        return 9223372036854775807;
    }
    if sec < -lim {
        return -9223372036854775807;
    }
    return sec * 1000000000 + nsec;
}

impl Time {
    pub fn unix(self: Time) -> int {
        return self.sec;
    }

    pub fn unix_milli(self: Time) -> int {
        return self.sec * 1000 + self.nsec / 1000000;
    }

    // Nanoseconds since the epoch; saturates outside 1677-2262.
    pub fn unix_nano(self: Time) -> int {
        return sat_ns(self.sec, self.nsec);
    }

    pub fn date(self: Time) -> Date {
        return civil_from_days(days_of(self));
    }

    pub fn year(self: Time) -> int {
        return self.date().year;
    }

    pub fn month(self: Time) -> int {
        return self.date().month;
    }

    pub fn day(self: Time) -> int {
        return self.date().day;
    }

    pub fn hour(self: Time) -> int {
        return secs_of_day(self) / 3600;
    }

    pub fn minute(self: Time) -> int {
        return secs_of_day(self) % 3600 / 60;
    }

    pub fn second(self: Time) -> int {
        return secs_of_day(self) % 60;
    }

    pub fn nanosecond(self: Time) -> int {
        return self.nsec;
    }

    pub fn millisecond(self: Time) -> int {
        return self.nsec / 1000000;
    }

    pub fn weekday(self: Time) -> Weekday {
        return weekday_of_days(days_of(self));
    }

    // 1 to 366.
    pub fn year_day(self: Time) -> int {
        return self.date().year_day();
    }

    pub fn iso_week(self: Time) -> IsoWeek {
        return self.date().iso_week();
    }

    // `self` plus `d` nanoseconds (negative goes back).
    pub fn add(self: Time, d: int) -> Time {
        let sec = self.sec + fdiv(d, 1000000000);
        let nsec = self.nsec + fmod(d, 1000000000);
        if nsec >= 1000000000 {
            nsec = nsec - 1000000000;
            sec = sec + 1;
        }
        return Time { sec: sec, nsec: nsec };
    }

    // Nanoseconds from `o` to `self`; saturates past ~292 years.
    pub fn sub(self: Time, o: Time) -> int {
        let ds = self.sec - o.sec;
        let dn = self.nsec - o.nsec;
        if dn < 0 {
            dn = dn + 1000000000;
            ds = ds - 1;
        }
        return sat_ns(ds, dn);
    }

    // Calendar days later, at the same time of day.
    pub fn add_days(self: Time, n: int) -> Time {
        return Time { sec: self.sec + n * 86400, nsec: self.nsec };
    }

    // Calendar months later, at the same time of day. A day past the end
    // of the target month is clamped to its last day: Jan 31 + 1 month is
    // Feb 28 (29 in a leap year), not Mar 3.
    pub fn add_months(self: Time, n: int) -> Time {
        let d = self.date().add_months(n);
        return Time { sec: days_from_civil(d.year, d.month, d.day) * 86400 + secs_of_day(self),
                      nsec: self.nsec };
    }

    // Calendar years later; Feb 29 + 1 year is Feb 28.
    pub fn add_years(self: Time, n: int) -> Time {
        return self.add_months(n * 12);
    }

    pub fn before(self: Time, o: Time) -> bool {
        return self.sec < o.sec || (self.sec == o.sec && self.nsec < o.nsec);
    }

    pub fn after(self: Time, o: Time) -> bool {
        return o.before(self);
    }

    pub fn equal(self: Time, o: Time) -> bool {
        return self.sec == o.sec && self.nsec == o.nsec;
    }

    // -1, 0 or 1.
    pub fn compare(self: Time, o: Time) -> int {
        if self.before(o) {
            return -1;
        }
        if o.before(self) {
            return 1;
        }
        return 0;
    }

    // Rounded down to a multiple of `d` since the epoch (d <= 0 leaves it
    // as is): truncate(MINUTE) drops seconds.
    pub fn truncate(self: Time, d: int) -> Time {
        if d <= 0 {
            return self;
        }
        if d % 1000000000 == 0 {
            let ds = d / 1000000000;
            return Time { sec: self.sec - fmod(self.sec, ds), nsec: 0 };
        }
        if 1000000000 % d == 0 {
            return Time { sec: self.sec, nsec: self.nsec - self.nsec % d };
        }
        let ns = self.unix_nano();
        return unix_nano(ns - fmod(ns, d));
    }

    // Rounded to the nearest multiple of `d`, halves away from zero.
    pub fn round(self: Time, d: int) -> Time {
        if d <= 0 {
            return self;
        }
        let down = self.truncate(d);
        if self.sub(down) * 2 >= d {
            return down.add(d);
        }
        return down;
    }

    pub fn start_of_minute(self: Time) -> Time {
        return Time { sec: self.sec - fmod(self.sec, 60), nsec: 0 };
    }

    pub fn start_of_hour(self: Time) -> Time {
        return Time { sec: self.sec - fmod(self.sec, 3600), nsec: 0 };
    }

    pub fn start_of_day(self: Time) -> Time {
        return Time { sec: days_of(self) * 86400, nsec: 0 };
    }

    // Monday 00:00 of this ISO week.
    pub fn start_of_week(self: Time) -> Time {
        let days = days_of(self);
        return Time { sec: (days - fmod(days + 3, 7)) * 86400, nsec: 0 };
    }

    pub fn start_of_month(self: Time) -> Time {
        let d = self.date();
        return Time { sec: days_from_civil(d.year, d.month, 1) * 86400, nsec: 0 };
    }

    pub fn start_of_year(self: Time) -> Time {
        return Time { sec: days_from_civil(self.year(), 1, 1) * 86400, nsec: 0 };
    }

    // The last nanosecond of the day, month and year: for inclusive
    // range queries ("created <= end of day").
    pub fn end_of_day(self: Time) -> Time {
        return self.start_of_day().add_days(1).add(-1);
    }

    pub fn end_of_month(self: Time) -> Time {
        return self.start_of_month().add_months(1).add(-1);
    }

    pub fn end_of_year(self: Time) -> Time {
        return self.start_of_year().add_years(1).add(-1);
    }
}

// ---- Date ---------------------------------------------------------------------

impl Date {
    fn days(self: Date) -> int {
        return days_from_civil(self.year, self.month, self.day);
    }

    pub fn weekday(self: Date) -> Weekday {
        return weekday_of_days(self.days());
    }

    pub fn year_day(self: Date) -> int {
        return self.days() - days_from_civil(self.year, 1, 1) + 1;
    }

    pub fn iso_week(self: Date) -> IsoWeek {
        // The Thursday of this date's week decides the week's year.
        let days = self.days();
        let thursday = days - fmod(days + 3, 7) + 3;
        let ty = civil_from_days(thursday).year;
        let week = (thursday - days_from_civil(ty, 1, 1)) / 7 + 1;
        return IsoWeek { year: ty, week: week };
    }

    pub fn is_leap_year(self: Date) -> bool {
        return is_leap_year(self.year);
    }

    pub fn add_days(self: Date, n: int) -> Date {
        return civil_from_days(self.days() + n);
    }

    // Jan 31 + 1 month is Feb 28 (29 in a leap year).
    pub fn add_months(self: Date, n: int) -> Date {
        let total = self.year * 12 + (self.month - 1) + n;
        let y = fdiv(total, 12);
        let m = fmod(total, 12) + 1;
        let d = self.day;
        let dim = days_in_month(y, m);
        if d > dim {
            d = dim;
        }
        return Date { year: y, month: m, day: d };
    }

    pub fn add_years(self: Date, n: int) -> Date {
        return self.add_months(n * 12);
    }

    // Days from `self` to `o`: 1 for tomorrow, negative for the past.
    pub fn days_until(self: Date, o: Date) -> int {
        return o.days() - self.days();
    }

    // Whole years from `self` to `o`, counting a year only once its
    // anniversary has passed: an age, a tenure.
    pub fn years_until(self: Date, o: Date) -> int {
        let y = o.year - self.year;
        if o.month < self.month || (o.month == self.month && o.day < self.day) {
            y = y - 1;
        }
        return y;
    }

    // 00:00:00 UTC on this date.
    pub fn start(self: Date) -> Time {
        return Time { sec: self.days() * 86400, nsec: 0 };
    }

    // The instant at this date and a UTC time of day.
    pub fn at(self: Date, hour: int, minute: int, second: int) -> result[Time, str] {
        return utc(self.year, self.month, self.day, hour, minute, second, 0);
    }

    pub fn before(self: Date, o: Date) -> bool {
        return self.days() < o.days();
    }

    pub fn after(self: Date, o: Date) -> bool {
        return self.days() > o.days();
    }

    pub fn equal(self: Date, o: Date) -> bool {
        return self.year == o.year && self.month == o.month && self.day == o.day;
    }

    pub fn compare(self: Date, o: Date) -> int {
        let a = self.days();
        let b = o.days();
        if a < b {
            return -1;
        }
        if a > b {
            return 1;
        }
        return 0;
    }

    pub fn start_of_month(self: Date) -> Date {
        return Date { year: self.year, month: self.month, day: 1 };
    }

    pub fn end_of_month(self: Date) -> Date {
        return Date { year: self.year, month: self.month,
                      day: days_in_month(self.year, self.month) };
    }

    // "2026-10-13" (ISO 8601).
    pub fn iso(self: Date) -> str {
        return pad_year(self.year) + "-" + pad2(self.month) + "-" + pad2(self.day);
    }
}

fn pad2(n: int) -> str {
    if n < 10 {
        return "0" + to_str(n);
    }
    return to_str(n);
}

// Four digits, signed outside 0-9999 as ISO 8601 expands it.
fn pad_year(y: int) -> str {
    if y < 0 {
        let s = to_str(-y);
        while len(s) < 4 {
            s = "0" + s;
        }
        return "-" + s;
    }
    let s = to_str(y);
    while len(s) < 4 {
        s = "0" + s;
    }
    if y > 9999 {
        return "+" + s;
    }
    return s;
}

// ---- durations ----------------------------------------------------------------

fn unit_ns(u: str) -> int {
    if u == "ns" { return 1; }
    if u == "us" || u == "µs" { return 1000; }
    if u == "ms" { return 1000000; }
    if u == "s" { return 1000000000; }
    if u == "m" { return 60000000000; }
    if u == "h" { return 3600000000000; }
    if u == "d" { return 86400000000000; }
    return 0;
}

// A duration written as Go writes them -- "1h30m", "1.5s", "300ms",
// "-2m", "2us" -- plus "d" for 24-hour days ("7d"), the unit config
// files reach for. "0" alone is zero. err names what was wrong; values
// past ~292 years are refused, not wrapped.
pub fn parse_duration(s: str) -> result[int, str] {
    let b = to_bytes(s);
    let n = len(b);
    if n == 0 {
        return err("empty duration");
    }
    let i = 0;
    let neg = false;
    if b[0] == 45 || b[0] == 43 {
        neg = b[0] == 45;
        i = 1;
    }
    if i == n - 1 && b[i] == 48 {
        return ok(0);
    }
    if i >= n {
        return err("duration '" + s + "' has no number");
    }
    let total = 0;
    while i < n {
        // the number: digits, optionally a fraction
        let whole = 0;
        let digits = 0;
        while i < n && b[i] >= 48 && b[i] <= 57 {
            if whole > 922337203685477580 {
                return err("duration '" + s + "' is too large");
            }
            whole = whole * 10 + (b[i] as int - 48);
            i = i + 1;
            digits = digits + 1;
        }
        let frac = 0;
        let scale = 1;
        if i < n && b[i] == 46 {
            i = i + 1;
            while i < n && b[i] >= 48 && b[i] <= 57 {
                if scale < 1000000000000000000 {
                    frac = frac * 10 + (b[i] as int - 48);
                    scale = scale * 10;
                }
                i = i + 1;
                digits = digits + 1;
            }
        }
        if digits == 0 {
            return err("duration '" + s + "' has a unit with no number before it");
        }
        // the unit: letters (and µ)
        let start = i;
        while i < n && !(b[i] >= 48 && b[i] <= 57) && b[i] != 46 {
            i = i + 1;
        }
        if start == i {
            return err("duration '" + s + "' is missing a unit (ns, us, ms, s, m, h or d)");
        }
        let u = to_str(b[start..i]);
        let per = unit_ns(u);
        if per == 0 {
            return err("duration '" + s + "' has an unknown unit '" + u +
                       "' (ns, us, ms, s, m, h or d)");
        }
        if whole > 9223372036854775807 / per {
            return err("duration '" + s + "' is too large");
        }
        let v = whole * per;
        if frac > 0 {
            // The fraction of a unit, as Go computes it: through a float,
            // exact to the nanosecond for every unit here.
            v = v + ((frac as float) * ((per as float) / (scale as float))) as int;
        }
        if total > 9223372036854775807 - v {
            return err("duration '" + s + "' is too large");
        }
        total = total + v;
    }
    if neg {
        return ok(-total);
    }
    return ok(total);
}

// A duration the way Go prints one and parse_duration reads it back:
// "1h30m0s", "1.5s", "300ms", "2µs", "0s".
pub fn format_duration(d: int) -> str {
    if d == 0 {
        return "0s";
    }
    let neg = d < 0;
    let u = d;
    if neg {
        u = -d;
    }
    let out = "";
    if u < 1000000000 {
        // below a second: the largest unit that keeps it >= 1
        if u < 1000 {
            out = to_str(u) + "ns";
        } else if u < 1000000 {
            out = fraction(u, 1000) + "µs";
        } else {
            out = fraction(u, 1000000) + "ms";
        }
    } else {
        let h = u / 3600000000000;
        let rest = u % 3600000000000;
        let m = rest / 60000000000;
        let s_ns = rest % 60000000000;
        let sec = fraction(s_ns, 1000000000) + "s";
        if h > 0 {
            out = to_str(h) + "h" + to_str(m) + "m" + sec;
        } else if m > 0 {
            out = to_str(m) + "m" + sec;
        } else {
            out = sec;
        }
    }
    if neg {
        return "-" + out;
    }
    return out;
}

// `v / unit` as a decimal with trailing zeros dropped: 1500 / 1000 = "1.5".
fn fraction(v: int, unit: int) -> str {
    let whole = v / unit;
    let rem = v % unit;
    if rem == 0 {
        return to_str(whole);
    }
    let digits = to_str(rem);
    let width = len(to_str(unit)) - 1;
    while len(digits) < width {
        digits = "0" + digits;
    }
    while strings.has_suffix(digits, "0") {
        digits = strings.slice(digits, 0, len(digits) - 1);
    }
    return to_str(whole) + "." + digits;
}
