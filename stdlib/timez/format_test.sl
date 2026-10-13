import "strings";

fn f_t(y: int, mo: int, d: int, h: int, mi: int, s: int, ns: int) -> Time {
    let r = utc(y, mo, d, h, mi, s, ns);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn f_parse(s: str) -> Time {
    let r = parse_rfc3339(s);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn test_rfc3339_forms() {
    let t = f_t(2026, 10, 13, 9, 30, 15, 500000000);
    assert(t.rfc3339() == "2026-10-13T09:30:15Z");
    assert(t.rfc3339_milli() == "2026-10-13T09:30:15.500Z", "toISOString's form");
    assert(t.rfc3339_nano() == "2026-10-13T09:30:15.5Z");
    assert(f_t(2026, 10, 13, 9, 30, 15, 0).rfc3339_nano() == "2026-10-13T09:30:15Z");
    assert(f_t(2026, 10, 13, 9, 30, 15, 1).rfc3339_nano() == "2026-10-13T09:30:15.000000001Z");
    assert(t.rfc3339_at(7200) == "2026-10-13T11:30:15.5+02:00");
    assert(t.rfc3339_at(-19800) == "2026-10-13T04:00:15.5-05:30");
    assert(f_t(2026, 10, 13, 23, 30, 0, 0).rfc3339_at(3600) == "2026-10-14T00:30:00+01:00", "the date moves too");
    assert(f_t(1, 1, 1, 0, 0, 0, 0).rfc3339() == "0001-01-01T00:00:00Z");
}

fn test_parse_rfc3339_applies_offsets() {
    assert(f_parse("2026-10-13T09:30:15Z").rfc3339() == "2026-10-13T09:30:15Z");
    assert(f_parse("2026-10-13T11:30:15+02:00").rfc3339() == "2026-10-13T09:30:15Z");
    assert(f_parse("2026-10-13T04:00:15-05:30").rfc3339() == "2026-10-13T09:30:15Z");
    assert(f_parse("2026-10-14T00:30:00+01:00").rfc3339() == "2026-10-13T23:30:00Z");
    assert(f_parse("2026-10-13t09:30:15.123456789z").nanosecond() == 123456789);
    assert(f_parse("2026-10-13 09:30:15.5Z").millisecond() == 500);
    for t in [f_t(2026, 10, 13, 9, 30, 15, 120000000), f_t(1969, 7, 20, 20, 17, 40, 0)] {
        assert(f_parse(t.rfc3339_nano()).equal(t), t.rfc3339_nano());
        assert(f_parse(t.rfc3339_milli()).equal(t), t.rfc3339_milli());
    }
}

fn test_parse_rfc3339_refuses_what_names_no_instant() {
    let cases = ["2026-10-13T09:30:15", "2026-10-13", "2026-10-13T25:30:15Z", "2026-02-30T09:30:15Z",
                 "2026-10-13T09:30:15.Z", "2026-10-13T09:30:15+2:00", "2026-10-13T09:30:15Z junk",
                 "2026-10-13T09:30:15.1234567890Z", "13/10/2026", ""];
    for c in cases {
        let r = parse_rfc3339(c);
        guard let _t = r else let e = err_of(r) {
            continue;
        }
        panic("accepted '" + c + "'");
    }
    let r = parse_rfc3339("2026-10-13T09:30:15");
    guard let _t = r else let e = err_of(r) {
        assert(strings.contains(e, "no offset"), e);
        return;
    }
}

fn test_parse_date() {
    let r = parse_date("2024-02-29");
    guard let d = r else let e = err_of(r) { panic(e); }
    assert(d.iso() == "2024-02-29");
    for bad in ["2026-02-29", "2026-1-01", "20261013", "2026-10-13T00:00:00Z"] {
        let b = parse_date(bad);
        guard let _d = b else { continue; }
        panic("accepted " + bad);
    }
}

fn test_http_dates_all_three_forms() {
    let t = f_t(2026, 10, 13, 9, 30, 15, 0);
    assert(t.http_date() == "Tue, 13 Oct 2026 09:30:15 GMT", t.http_date());
    for s in ["Tue, 13 Oct 2026 09:30:15 GMT", "Tuesday, 13-Oct-26 09:30:15 GMT", "Tue Oct 13 09:30:15 2026"] {
        let r = parse_http_date(s);
        guard let p = r else let e = err_of(r) { panic(e); }
        assert(p.equal(t), s);
    }
    let early = parse_http_date("Sun Nov  6 08:49:37 1994");
    guard let e1 = early else let e = err_of(early) { panic(e); }
    assert(e1.rfc3339() == "1994-11-06T08:49:37Z", "asctime with a space-padded day");
    for bad in ["Tue, 13 Oct 2026 09:30:15 UTC", "13 Oct 2026", "Tue, 31 Feb 2026 09:30:15 GMT"] {
        let r = parse_http_date(bad);
        guard let _p = r else { continue; }
        panic("accepted " + bad);
    }
}

fn test_rfc2822() {
    let t = f_t(2026, 10, 13, 9, 30, 15, 0);
    assert(t.rfc2822() == "Tue, 13 Oct 2026 09:30:15 +0000", t.rfc2822());
    for s in ["Tue, 13 Oct 2026 09:30:15 +0000", "13 Oct 2026 11:30:15 +0200", "Tue, 13 Oct 2026 04:00:15 -0530",
              "13 Oct 2026 09:30:15 GMT"] {
        let r = parse_rfc2822(s);
        guard let p = r else let e = err_of(r) { panic(s + ": " + e); }
        assert(p.equal(t), s + " -> " + p.rfc3339());
    }
    let short = parse_rfc2822("Tue, 13 Oct 2026 09:30 +0000");
    guard let p2 = short else let e = err_of(short) { panic(e); }
    assert(p2.second() == 0 && p2.minute() == 30, "seconds are optional");
}

fn test_format_layouts() {
    let t = f_t(2026, 10, 13, 9, 30, 15, 123456789);
    assert(t.format("%Y-%m-%d %H:%M:%S") == "2026-10-13 09:30:15");
    assert(t.format("%a %A %b %B %j %u %G %V") == "Tue Tuesday Oct October 286 2 2026 42", t.format("%a %A %b %B %j %u %G %V"));
    assert(t.format("%I:%M %p") == "09:30 AM");
    assert(f_t(2026, 10, 13, 0, 5, 0, 0).format("%I %p") == "12 AM");
    assert(f_t(2026, 10, 13, 15, 0, 0, 0).format("%I %p") == "03 PM");
    assert(t.format("%L %f %N") == "123 123456 123456789");
    assert(t.format("%F %T") == "2026-10-13 09:30:15");
    assert(f_t(2026, 10, 3, 0, 0, 0, 0).format("[%e]") == "[ 3]");
    assert(t.format("%s %z %Z %%") == "1791883815 +0000 UTC %");
    assert(t.format("%Q stays %") == "%Q stays %", "unknown directives and a trailing % are kept");
    assert(f_t(2027, 1, 1, 0, 0, 0, 0).format("%G-W%V") == "2026-W53", "1 Jan 2027 is in 2026's last week");
}

fn test_relative() {
    let now_t = f_t(2026, 10, 13, 12, 0, 0, 0);
    assert(relative(now_t.add(-3 * SECOND), now_t) == "just now");
    assert(relative(now_t.add(-45 * SECOND), now_t) == "45 seconds ago");
    assert(relative(now_t.add(-60 * SECOND), now_t) == "1 minute ago");
    assert(relative(now_t.add(-3 * MINUTE - 59 * SECOND), now_t) == "3 minutes ago", "rounded down");
    assert(relative(now_t.add(2 * HOUR), now_t) == "in 2 hours");
    assert(relative(now_t.add(-25 * HOUR), now_t) == "yesterday");
    assert(relative(now_t.add(30 * HOUR), now_t) == "tomorrow");
    assert(relative(now_t.add_days(-5), now_t) == "5 days ago");
    assert(relative(now_t.add_days(21), now_t) == "in 3 weeks");
    assert(relative(now_t.add_days(-65), now_t) == "2 months ago");
    assert(relative(now_t.add_days(-400), now_t) == "1 year ago");
}
