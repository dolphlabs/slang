// Clocks for tests, stopwatches, intervals and cron schedules.
//
//     let clock = timez.fixed_clock(start);       // in a test; system_clock() in main
//     clock.advance(5 * timez.MINUTE);
//     let sw = timez.start_stopwatch();           // monotonic: immune to clock changes
//     println(timez.format_duration(sw.elapsed()));
//     let cr = timez.parse_cron("*/15 9-17 * * MON-FRI");
//     let next = cron.next_after(timez.now(), berlin);   // the next run, DST-aware

import "strings";
import "time";

// ---- Clock --------------------------------------------------------------------

// Where code gets the time, so a test can set it instead of sleeping.
// Pass a Clock in your state; production uses system_clock().
pub gc struct Clock {
    fixed: bool,
    at: Time,
    lock: mutex,
}

pub fn system_clock() -> Clock {
    return Clock { fixed: false, at: unix(0), lock: make_mutex() };
}

// A clock that stays at `t` until advanced or set.
pub fn fixed_clock(t: Time) -> Clock {
    return Clock { fixed: true, at: t, lock: make_mutex() };
}

impl Clock {
    pub fn now(self: Clock) -> Time {
        if !self.fixed {
            return now();
        }
        mutex_lock(self.lock);
        let t = self.at;
        mutex_unlock(self.lock);
        return t;
    }

    // Moves a fixed clock forward by `d` (no effect on the system clock).
    pub fn advance(self: Clock, d: int) -> Time {
        mutex_lock(self.lock);
        self.at = self.at.add(d);
        let t = self.at;
        mutex_unlock(self.lock);
        return t;
    }

    pub fn set(self: Clock, t: Time) {
        mutex_lock(self.lock);
        self.at = t;
        mutex_unlock(self.lock);
    }
}

// ---- Stopwatch ----------------------------------------------------------------

// Measures elapsed time on the monotonic clock: a wall-clock correction
// (NTP, a person setting the time) cannot make it jump or go backwards.
pub struct Stopwatch {
    started: duration,
}

pub fn start_stopwatch() -> Stopwatch {
    return Stopwatch { started: time.mono() };
}

impl Stopwatch {
    // Nanoseconds since the stopwatch started.
    pub fn elapsed(self: Stopwatch) -> int {
        return (time.mono() - self.started) as int;
    }

    // "1.502s".
    pub fn elapsed_text(self: Stopwatch) -> str {
        return format_duration(self.elapsed());
    }
}

// ---- Interval -----------------------------------------------------------------

// A half-open span [start, end): it contains its start, not its end, so
// back-to-back intervals (09:00-10:00, 10:00-11:00) do not overlap.
pub struct Interval {
    start: Time,
    end: Time,
}

// err when `end` is before `start`.
pub fn interval(start: Time, end: Time) -> result[Interval, str] {
    if end.before(start) {
        return err("an interval cannot end (" + end.rfc3339_nano() + ") before it starts (" +
                   start.rfc3339_nano() + ")");
    }
    return ok(Interval { start: start, end: end });
}

impl Interval {
    pub fn contains(self: Interval, t: Time) -> bool {
        return !t.before(self.start) && t.before(self.end);
    }

    pub fn overlaps(self: Interval, o: Interval) -> bool {
        return self.start.before(o.end) && o.start.before(self.end);
    }

    // The span both cover, none when they do not overlap.
    pub fn intersection(self: Interval, o: Interval) -> opt[Interval] {
        if !self.overlaps(o) {
            return none;
        }
        return some(Interval { start: max(self.start, o.start), end: min(self.end, o.end) });
    }

    // Nanoseconds from start to end.
    pub fn length(self: Interval) -> int {
        return self.end.sub(self.start);
    }

    pub fn is_empty(self: Interval) -> bool {
        return self.start.equal(self.end);
    }
}

// ---- cron ---------------------------------------------------------------------

// A five-field cron schedule: minute hour day-of-month month day-of-week.
// Each field takes `*`, numbers, ranges (`9-17`), lists (`1,15`), steps
// (`*/15`, `0-30/10`), month names (JAN-DEC) and weekday names (SUN-SAT;
// 0 and 7 are both Sunday). Macros: @yearly @annually @monthly @weekly
// @daily @midnight @hourly. As in Vixie cron, when both day fields are
// restricted a day matches either one.
pub gc struct Cron {
    text: str,
    minutes: [bool],
    hours: [bool],
    dom: [bool],
    months: [bool],
    dow: [bool],
    dom_star: bool,
    dow_star: bool,
}

fn cron_name_value(s: str, names: [str], base: int) -> int {
    let u = strings.to_upper(s);
    let i = 0;
    while i < len(names) {
        if names[i] == u {
            return i + base;
        }
        i = i + 1;
    }
    let pr = to_int(s);
    if let v = pr {
        return v;
    }
    return -1;
}

fn cron_field(text: str, lo: int, hi: int, names: [str], base: int,
              what: str) -> result[[bool], str] {
    let set: [bool] = [];
    let i = 0;
    while i <= hi {
        push(set, false);
        i = i + 1;
    }
    for part in strings.split(text, ",") {
        let step = 1;
        let range = part;
        let slash = strings.find(part, "/");
        if slash >= 0 {
            let sr = to_int(strings.slice(part, slash + 1, len(part)));
            guard let st = sr else {
                return err(what + " step '" + part + "' is not a number");
            }
            if st < 1 {
                return err(what + " step must be at least 1");
            }
            step = st;
            range = strings.slice(part, 0, slash);
        }
        let a = lo;
        let b = hi;
        if range != "*" {
            let dash = strings.find(range, "-");
            if dash > 0 {
                a = cron_name_value(strings.slice(range, 0, dash), names, base);
                b = cron_name_value(strings.slice(range, dash + 1, len(range)), names, base);
            } else {
                a = cron_name_value(range, names, base);
                b = a;
                if slash >= 0 {
                    b = hi;
                }
            }
        }
        if a < lo || b > hi || a > b {
            return err(what + " '" + part + "' is out of range (" + to_str(lo) + "-" + to_str(hi) + ")");
        }
        let v = a;
        while v <= b {
            set[v] = true;
            v = v + step;
        }
    }
    return ok(set);
}

pub fn parse_cron(spec: str) -> result[Cron, str] {
    let s = strings.trim(spec);
    if s == "@yearly" || s == "@annually" { s = "0 0 1 1 *"; }
    else if s == "@monthly" { s = "0 0 1 * *"; }
    else if s == "@weekly" { s = "0 0 * * 0"; }
    else if s == "@daily" || s == "@midnight" { s = "0 0 * * *"; }
    else if s == "@hourly" { s = "0 * * * *"; }
    let fields: [str] = [];
    for f in strings.split(s, " ") {
        if len(f) > 0 {
            push(fields, f);
        }
    }
    if len(fields) != 5 {
        return err("cron '" + spec + "' needs 5 fields (minute hour day month weekday), got " +
                   to_str(len(fields)));
    }
    let none_named: [str] = [];
    let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
    let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
    let mr = cron_field(fields[0], 0, 59, none_named, 0, "minute");
    guard let mi = mr else let e = err_of(mr) { return err("cron '" + spec + "': " + e); }
    let hr = cron_field(fields[1], 0, 23, none_named, 0, "hour");
    guard let h = hr else let e = err_of(hr) { return err("cron '" + spec + "': " + e); }
    let dr = cron_field(fields[2], 1, 31, none_named, 0, "day of month");
    guard let dm = dr else let e = err_of(dr) { return err("cron '" + spec + "': " + e); }
    let mor = cron_field(fields[3], 1, 12, months, 1, "month");
    guard let mo = mor else let e = err_of(mor) { return err("cron '" + spec + "': " + e); }
    let wr = cron_field(fields[4], 0, 7, days, 0, "weekday");
    guard let w = wr else let e = err_of(wr) { return err("cron '" + spec + "': " + e); }
    if w[7] {
        w[0] = true;
    }
    return ok(Cron { text: spec, minutes: mi, hours: h, dom: dm, months: mo, dow: w,
                     dom_star: fields[2] == "*", dow_star: fields[4] == "*" });
}

impl Cron {
    fn day_matches(self: Cron, d: Date) -> bool {
        if !self.months[d.month] {
            return false;
        }
        let dom_ok = self.dom[d.day];
        // Sunday 0 in cron; weekday_index has Monday 0
        let dow_ok = self.dow[(weekday_index(d.weekday()) + 1) % 7];
        if self.dom_star && self.dow_star {
            return true;
        }
        if self.dom_star {
            return dow_ok;
        }
        if self.dow_star {
            return dom_ok;
        }
        return dom_ok || dow_ok;
    }

    // The first run strictly after `t`, read on the clocks of `z`; none
    // when the schedule never matches (Feb 30) within eight years. A run
    // whose wall time a daylight-saving change skips happens when the
    // clock reaches it (moved forward); one the change repeats runs once.
    pub fn next_after(self: Cron, t: Time, z: Zone) -> opt[Time] {
        let local = t.in_zone(z);
        let wall = t.add(local.offset * 1000000000).truncate(MINUTE);
        let day = wall.date();
        let first_minute = wall.hour() * 60 + wall.minute() + 1;
        let tries = 0;
        while tries < 366 * 8 {
            if self.day_matches(day) {
                let m = first_minute;
                while m < 1440 {
                    let h = m / 60;
                    let mi = m % 60;
                    if self.hours[h] && self.minutes[mi] {
                        let w = day.start().add(m * MINUTE);
                        let r = from_wall(z, w.sec, 0, Disambiguation.COMPATIBLE);
                        if let at = r {
                            if at.after(t) {
                                return some(at);
                            }
                        }
                    }
                    m = m + 1;
                }
            }
            day = day.add_days(1);
            first_minute = 0;
            tries = tries + 1;
        }
        return none;
    }
}
