import "strings";
import "time";

fn o_t(s: str) -> Time {
    let r = parse_rfc3339(s);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn o_cron(s: str) -> Cron {
    let r = parse_cron(s);
    guard let c = r else let e = err_of(r) { panic(e); }
    return c;
}

fn next_utc(spec: str, from: str) -> str {
    guard let n = o_cron(spec).next_after(o_t(from), utc_zone()) else {
        return "never";
    }
    return n.rfc3339();
}

fn test_fixed_clock_moves_only_when_told() {
    let c = fixed_clock(o_t("2026-10-13T09:00:00Z"));
    assert(c.now().rfc3339() == "2026-10-13T09:00:00Z");
    c.advance(90 * SECOND);
    assert(c.now().rfc3339() == "2026-10-13T09:01:30Z");
    c.set(o_t("2030-01-01T00:00:00Z"));
    assert(c.now().year() == 2030);
    let real = system_clock();
    assert(real.now().year() >= 2026);
}

fn test_stopwatch_measures_monotonic_time() {
    let sw = start_stopwatch();
    // A sleep, not a busy loop: a loop whose result goes unused has no
    // poll to keep it now, so the C compiler deletes it, and two
    // back-to-back clock reads can be equal (0 elapsed on arm64).
    time.sleep(1000000);
    let e = sw.elapsed();
    assert(e > 0 && e < 5 * SECOND, to_str(e));
    assert(strings.has_suffix(sw.elapsed_text(), "s"));
}

fn test_intervals_are_half_open() {
    let a = (interval(o_t("2026-10-13T09:00:00Z"), o_t("2026-10-13T10:00:00Z")) ?? Interval { start: unix(0), end: unix(0) });
    let b = (interval(o_t("2026-10-13T10:00:00Z"), o_t("2026-10-13T11:00:00Z")) ?? Interval { start: unix(0), end: unix(0) });
    let c = (interval(o_t("2026-10-13T09:30:00Z"), o_t("2026-10-13T10:30:00Z")) ?? Interval { start: unix(0), end: unix(0) });
    assert(a.contains(o_t("2026-10-13T09:00:00Z")) && !a.contains(o_t("2026-10-13T10:00:00Z")));
    assert(!a.overlaps(b), "back to back is not an overlap");
    assert(a.overlaps(c) && c.overlaps(b));
    guard let i = a.intersection(c) else { panic("no intersection"); }
    assert(i.start.rfc3339() == "2026-10-13T09:30:00Z" && i.length() == 30 * MINUTE);
    guard let _n = a.intersection(b) else {
        let bad = interval(o_t("2026-10-13T10:00:00Z"), o_t("2026-10-13T09:00:00Z"));
        guard let _x = bad else { return; }
        panic("an interval ending before it starts was accepted");
    }
    panic("back-to-back intervals intersected");
}

fn test_cron_next_run() {
    assert(next_utc("*/15 * * * *", "2026-10-13T09:07:30Z") == "2026-10-13T09:15:00Z");
    assert(next_utc("*/15 * * * *", "2026-10-13T09:15:00Z") == "2026-10-13T09:30:00Z", "strictly after");
    assert(next_utc("0 9-17 * * MON-FRI", "2026-10-16T17:30:00Z") == "2026-10-19T09:00:00Z", "Friday evening -> Monday");
    assert(next_utc("30 2 * * *", "2026-10-13T03:00:00Z") == "2026-10-14T02:30:00Z");
    assert(next_utc("0 0 1 * *", "2026-01-31T12:00:00Z") == "2026-02-01T00:00:00Z");
    assert(next_utc("0 12 29 2 *", "2026-01-01T00:00:00Z") == "2028-02-29T12:00:00Z", "the next leap day");
    assert(next_utc("0 0 1,15 * *", "2026-10-02T00:00:00Z") == "2026-10-15T00:00:00Z");
    assert(next_utc("0 0 13 * FRI", "2026-10-13T01:00:00Z") == "2026-10-16T00:00:00Z", "day OR weekday");
    assert(next_utc("@hourly", "2026-10-13T09:59:59Z") == "2026-10-13T10:00:00Z");
    assert(next_utc("@weekly", "2026-10-13T09:00:00Z") == "2026-10-18T00:00:00Z", "Sunday midnight");
    assert(next_utc("0 0 * * 7", "2026-10-13T09:00:00Z") == "2026-10-18T00:00:00Z", "7 is Sunday too");
    assert(next_utc("0 0 30 2 *", "2026-01-01T00:00:00Z") == "never");
    assert(next_utc("0 0 * JAN,jul *", "2026-02-01T00:00:00Z") == "2026-07-01T00:00:00Z");
}

fn test_cron_follows_the_zones_clocks() {
    let zr = load_zone("Europe/Berlin");
    guard let b = zr else let e = err_of(zr) { panic(e); }
    // 09:00 Berlin, from 06:00 UTC on a summer day: 07:00 UTC
    guard let n = o_cron("0 9 * * *").next_after(o_t("2026-07-01T06:00:00Z"), b) else { panic("none"); }
    assert(n.rfc3339() == "2026-07-01T07:00:00Z", n.rfc3339());
    // 02:30 does not exist on 2026-03-29 in Berlin: it runs at 03:30 CEST
    guard let g = o_cron("30 2 * * *").next_after(o_t("2026-03-28T12:00:00Z"), b) else { panic("none"); }
    assert(g.rfc3339() == "2026-03-29T01:30:00Z", g.rfc3339());
    // and 02:30 on the fall-back night runs once, at the first 02:30
    guard let o = o_cron("30 2 * * *").next_after(o_t("2026-10-24T12:00:00Z"), b) else { panic("none"); }
    assert(o.rfc3339() == "2026-10-25T00:30:00Z", o.rfc3339());
    guard let o2 = o_cron("30 2 * * *").next_after(o, b) else { panic("none"); }
    assert(o2.rfc3339() == "2026-10-26T01:30:00Z", "not a second time an hour later: " + o2.rfc3339());
}

fn test_cron_errors_name_the_field() {
    let cases = ["* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "*/0 * * * *", "x * * * *", "5-1 * * * *"];
    let words = ["needs 5 fields", "minute", "hour", "day of month", "month", "weekday", "step", "minute", "minute"];
    let i = 0;
    while i < len(cases) {
        let r = parse_cron(cases[i]);
        guard let _c = r else let e = err_of(r) {
            assert(strings.contains(e, words[i]), cases[i] + ": " + e);
            i = i + 1;
            continue;
        }
        panic("accepted '" + cases[i] + "'");
    }
}
