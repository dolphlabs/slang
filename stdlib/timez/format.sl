// Text: the formats services exchange times in, both ways.
//
//   rfc3339 / rfc3339_milli / rfc3339_nano   2026-10-13T09:30:15Z, ...15.000Z, ...15.5Z
//   rfc3339_at(offset_seconds)               2026-10-13T11:30:15+02:00
//   parse_rfc3339 / parse_date               strict, offsets applied
//   http_date / parse_http_date              Tue, 13 Oct 2026 09:30:15 GMT (and the two
//                                            obsolete forms RFC 9110 says to accept)
//   rfc2822 / parse_rfc2822                  Tue, 13 Oct 2026 09:30:15 +0000 (email)
//   format(layout)                           strftime-style, locale-free English
//   relative(t, now)                         "3 minutes ago", "in 2 hours", "just now"
//
// Parsers are strict and say what is wrong: a time a client sends is
// input, and "close enough" is how two systems end up disagreeing about
// which day it is.

import "strings";

fn pad(n: int, width: int) -> str {
    let s = to_str(n);
    while len(s) < width {
        s = "0" + s;
    }
    return s;
}

fn short_weekday(w: Weekday) -> str {
    return strings.slice(weekday_name(w), 0, 3);
}

fn short_month(m: int) -> str {
    return strings.slice(month_name(m), 0, 3);
}

// "+02:00", "-05:30", "Z" for zero when `z` is set.
fn offset_text(off: int, colon: bool, z: bool) -> str {
    if off == 0 && z {
        return "Z";
    }
    let sign = "+";
    let a = off;
    if off < 0 {
        sign = "-";
        a = -off;
    }
    let h = a / 3600;
    let m = a % 3600 / 60;
    if colon {
        return sign + pad(h, 2) + ":" + pad(m, 2);
    }
    return sign + pad(h, 2) + pad(m, 2);
}

// Nine fraction digits with trailing zeros dropped, "" for none.
fn nano_fraction(ns: int) -> str {
    if ns == 0 {
        return "";
    }
    let f = pad(ns, 9);
    while strings.has_suffix(f, "0") {
        f = strings.slice(f, 0, len(f) - 1);
    }
    return "." + f;
}

fn date_time_text(t: Time) -> str {
    let d = t.date();
    return pad_year(d.year) + "-" + pad(d.month, 2) + "-" + pad(d.day, 2) + "T" +
           pad(t.hour(), 2) + ":" + pad(t.minute(), 2) + ":" + pad(t.second(), 2);
}

impl Time {
    // "2026-10-13T09:30:15Z": seconds, UTC.
    pub fn rfc3339(self: Time) -> str {
        return date_time_text(self) + "Z";
    }

    // "2026-10-13T09:30:15.000Z": always milliseconds, as JavaScript's
    // toISOString() writes them -- what a browser client parses most
    // happily.
    pub fn rfc3339_milli(self: Time) -> str {
        return date_time_text(self) + "." + pad(self.nsec / 1000000, 3) + "Z";
    }

    // "2026-10-13T09:30:15.5Z": every nanosecond the instant has, no
    // trailing zeros -- what round-trips exactly.
    pub fn rfc3339_nano(self: Time) -> str {
        return date_time_text(self) + nano_fraction(self.nsec) + "Z";
    }

    // The same instant as the wall time at a fixed offset from UTC
    // (seconds east, -64800 to 64800): "2026-10-13T11:30:15+02:00".
    pub fn rfc3339_at(self: Time, offset_seconds: int) -> str {
        let local = self.add(offset_seconds * 1000000000);
        return date_time_text(local) + nano_fraction(self.nsec) +
               offset_text(offset_seconds, true, true);
    }

    // "Tue, 13 Oct 2026 09:30:15 GMT": the HTTP date (RFC 9110 IMF-fixdate)
    // for Date, Last-Modified, Expires and cookie Expires.
    pub fn http_date(self: Time) -> str {
        let d = self.date();
        return short_weekday(self.weekday()) + ", " + pad(d.day, 2) + " " + short_month(d.month) +
               " " + pad(d.year, 4) + " " + pad(self.hour(), 2) + ":" + pad(self.minute(), 2) +
               ":" + pad(self.second(), 2) + " GMT";
    }

    // "Tue, 13 Oct 2026 09:30:15 +0000": email (RFC 5322) dates.
    pub fn rfc2822(self: Time) -> str {
        return strings.slice(self.http_date(), 0, 25) + " +0000";
    }

    // strftime-style formatting, locale-free (English names), UTC:
    //
    //   %Y year (2026)   %m month 01-12   %d day 01-31   %e day, space-padded
    //   %H hour 00-23    %I hour 01-12    %M minute      %S second    %p AM/PM
    //   %L milliseconds (000-999)   %f microseconds   %N nanoseconds (9 digits)
    //   %a Tue  %A Tuesday  %b Oct  %B October  %j day of year 001-366
    //   %u weekday 1-7 (Monday 1)  %G ISO year  %V ISO week 01-53
    //   %s Unix seconds   %z +0000   %Z UTC   %F %Y-%m-%d   %T %H:%M:%S   %% %
    //
    // An unknown directive is written as it is, so a typo shows in the
    // output instead of vanishing.
    pub fn format(self: Time, layout: str) -> str {
        let b = to_bytes(layout);
        let out: [str] = [];
        let d = self.date();
        let i = 0;
        let start = 0;
        while i < len(b) {
            if b[i] != 37 || i + 1 >= len(b) {
                i = i + 1;
                continue;
            }
            if i > start {
                push(out, strings.slice(layout, start, i));
            }
            let c = b[i + 1] as int;
            let piece = "";
            if c == 89 { piece = pad_year(d.year); }                     // Y
            else if c == 109 { piece = pad(d.month, 2); }                // m
            else if c == 100 { piece = pad(d.day, 2); }                  // d
            else if c == 101 {                                          // e
                piece = to_str(d.day);
                if d.day < 10 { piece = " " + piece; }
            }
            else if c == 72 { piece = pad(self.hour(), 2); }             // H
            else if c == 73 {                                           // I
                let h = self.hour() % 12;
                if h == 0 { h = 12; }
                piece = pad(h, 2);
            }
            else if c == 77 { piece = pad(self.minute(), 2); }           // M
            else if c == 83 { piece = pad(self.second(), 2); }           // S
            else if c == 112 {                                          // p
                piece = "AM";
                if self.hour() >= 12 { piece = "PM"; }
            }
            else if c == 76 { piece = pad(self.nsec / 1000000, 3); }     // L
            else if c == 102 { piece = pad(self.nsec / 1000, 6); }       // f
            else if c == 78 { piece = pad(self.nsec, 9); }               // N
            else if c == 97 { piece = short_weekday(self.weekday()); }   // a
            else if c == 65 { piece = weekday_name(self.weekday()); }    // A
            else if c == 98 { piece = short_month(d.month); }            // b
            else if c == 66 { piece = month_name(d.month); }             // B
            else if c == 106 { piece = pad(d.year_day(), 3); }           // j
            else if c == 117 { piece = to_str(weekday_index(self.weekday()) + 1); } // u
            else if c == 71 { piece = pad_year(d.iso_week().year); }     // G
            else if c == 86 { piece = pad(d.iso_week().week, 2); }       // V
            else if c == 115 { piece = to_str(self.sec); }               // s
            else if c == 122 { piece = "+0000"; }                        // z
            else if c == 90 { piece = "UTC"; }                           // Z
            else if c == 70 { piece = pad_year(d.year) + "-" + pad(d.month, 2) + "-" + pad(d.day, 2); } // F
            else if c == 84 { piece = pad(self.hour(), 2) + ":" + pad(self.minute(), 2) + ":" + pad(self.second(), 2); } // T
            else if c == 37 { piece = "%"; }
            else { piece = strings.slice(layout, i, i + 2); }
            push(out, piece);
            i = i + 2;
            start = i;
        }
        if start < len(b) {
            push(out, strings.slice(layout, start, len(b)));
        }
        return strings.join(out, "");
    }
}

// ---- parsing ------------------------------------------------------------------

// Reads `n` digits at `i` in `b`; -1 when any is not a digit.
fn digits_at(b: bytes, i: int, n: int) -> int {
    if i + n > len(b) {
        return -1;
    }
    let v = 0;
    let k = 0;
    while k < n {
        let c = b[i + k] as int;
        if c < 48 || c > 57 {
            return -1;
        }
        v = v * 10 + (c - 48);
        k = k + 1;
    }
    return v;
}

fn byte_is(b: bytes, i: int, c: int) -> bool {
    return i < len(b) && (b[i] as int) == c;
}

// "2026-10-13" (and only that): a calendar date.
pub fn parse_date(s: str) -> result[Date, str] {
    let b = to_bytes(s);
    if len(b) != 10 || !byte_is(b, 4, 45) || !byte_is(b, 7, 45) {
        return err("date '" + s + "' is not YYYY-MM-DD");
    }
    let y = digits_at(b, 0, 4);
    let m = digits_at(b, 5, 2);
    let d = digits_at(b, 8, 2);
    if y < 0 || m < 0 || d < 0 {
        return err("date '" + s + "' is not YYYY-MM-DD");
    }
    return date(y, m, d);
}

// An RFC 3339 timestamp: "2026-10-13T09:30:15Z", with an optional
// fraction of up to 9 digits and a "Z" or "+hh:mm"/"-hh:mm" offset, which
// is applied: the result is the instant, in UTC. "t" and "z" and a space
// for "T" are accepted, as RFC 3339 allows. A missing offset is refused:
// a timestamp without one names no instant.
pub fn parse_rfc3339(s: str) -> result[Time, str] {
    let b = to_bytes(s);
    let bad = "timestamp '" + s + "' is not RFC 3339 (2026-10-13T09:30:15Z)";
    if len(b) < 19 {
        return err(bad);
    }
    let dr = parse_date(strings.slice(s, 0, 10));
    guard let d = dr else let e = err_of(dr) {
        return err(bad);
    }
    let sep = b[10] as int;
    if sep != 84 && sep != 116 && sep != 32 {
        return err(bad);
    }
    let h = digits_at(b, 11, 2);
    let mi = digits_at(b, 14, 2);
    let sec = digits_at(b, 17, 2);
    if h < 0 || mi < 0 || sec < 0 || !byte_is(b, 13, 58) || !byte_is(b, 16, 58) {
        return err(bad);
    }
    let i = 19;
    let nanos = 0;
    if byte_is(b, i, 46) {
        i = i + 1;
        let digits = 0;
        while i < len(b) && (b[i] as int) >= 48 && (b[i] as int) <= 57 {
            if digits < 9 {
                nanos = nanos * 10 + (b[i] as int - 48);
            }
            digits = digits + 1;
            i = i + 1;
        }
        if digits == 0 {
            return err(bad);
        }
        if digits > 9 {
            return err("timestamp '" + s + "' has more than 9 fraction digits");
        }
        while digits < 9 {
            nanos = nanos * 10;
            digits = digits + 1;
        }
    }
    if i >= len(b) {
        return err("timestamp '" + s + "' has no offset: add Z for UTC, or +hh:mm");
    }
    let off = 0;
    let z = b[i] as int;
    if z == 90 || z == 122 {
        i = i + 1;
    } else if z == 43 || z == 45 {
        let oh = digits_at(b, i + 1, 2);
        let om = digits_at(b, i + 4, 2);
        if oh < 0 || om < 0 || !byte_is(b, i + 3, 58) || oh > 23 || om > 59 {
            return err(bad);
        }
        off = oh * 3600 + om * 60;
        if z == 45 {
            off = -off;
        }
        i = i + 6;
    } else {
        return err(bad);
    }
    if i != len(b) {
        return err(bad);
    }
    let tr = utc(d.year, d.month, d.day, h, mi, sec, nanos);
    guard let t = tr else let e = err_of(tr) {
        return err("timestamp '" + s + "': " + e);
    }
    return ok(t.add(-off * 1000000000));
}

fn month_from_short(m: str) -> int {
    let i = 1;
    while i <= 12 {
        if short_month(i) == m {
            return i;
        }
        i = i + 1;
    }
    return 0;
}

fn clock_at(b: bytes, i: int) -> int {
    let h = digits_at(b, i, 2);
    let m = digits_at(b, i + 3, 2);
    let s = digits_at(b, i + 6, 2);
    if h < 0 || m < 0 || s < 0 || !byte_is(b, i + 2, 58) || !byte_is(b, i + 5, 58) {
        return -1;
    }
    return h * 3600 + m * 60 + s;
}

// An HTTP date. RFC 9110 has recipients accept three forms, and so does
// this:
//
//   Tue, 13 Oct 2026 09:30:15 GMT       IMF-fixdate (what everything sends)
//   Tuesday, 13-Oct-26 09:30:15 GMT     RFC 850 (two-digit year: more than
//                                        50 years ahead means last century)
//   Tue Oct 13 09:30:15 2026            asctime
pub fn parse_http_date(s: str) -> result[Time, str] {
    let b = to_bytes(s);
    let bad = "'" + s + "' is not an HTTP date (Tue, 13 Oct 2026 09:30:15 GMT)";
    let comma = strings.find(s, ",");
    let y = 0;
    let m = 0;
    let d = 0;
    let clock = -1;
    if comma == 3 && len(b) == 29 {
        // IMF-fixdate
        d = digits_at(b, 5, 2);
        m = month_from_short(strings.slice(s, 8, 11));
        y = digits_at(b, 12, 4);
        clock = clock_at(b, 17);
        if strings.slice(s, 25, 29) != " GMT" {
            return err(bad);
        }
    } else if comma > 3 {
        // RFC 850: "Tuesday, 13-Oct-26 09:30:15 GMT"
        let rest = strings.slice(s, comma + 2, len(s));
        let rb = to_bytes(rest);
        if len(rb) != 22 || !byte_is(rb, 2, 45) || !byte_is(rb, 6, 45) ||
           strings.slice(rest, 18, 22) != " GMT" {
            return err(bad);
        }
        d = digits_at(rb, 0, 2);
        m = month_from_short(strings.slice(rest, 3, 6));
        let yy = digits_at(rb, 7, 2);
        clock = clock_at(rb, 10);
        if yy < 0 {
            return err(bad);
        }
        let this_year = now().year();
        y = this_year - this_year % 100 + yy;
        if y > this_year + 50 {
            y = y - 100;
        }
    } else if len(b) == 24 && byte_is(b, 3, 32) {
        // asctime: "Tue Oct 13 09:30:15 2026", day space-padded
        m = month_from_short(strings.slice(s, 4, 7));
        let ds = strings.trim(strings.slice(s, 8, 10));
        d = to_int(ds) ?? -1;
        clock = clock_at(b, 11);
        y = digits_at(b, 20, 4);
    } else {
        return err(bad);
    }
    if y < 0 || m == 0 || d < 0 || clock < 0 {
        return err(bad);
    }
    let tr = utc(y, m, d, clock / 3600, clock % 3600 / 60, clock % 60, 0);
    guard let t = tr else let e = err_of(tr) {
        return err("'" + s + "': " + e);
    }
    return ok(t);
}

// An email date (RFC 5322): an optional weekday, a 1-2 digit day, a
// month, a 4-digit year, hh:mm with optional :ss, and a "+hhmm"/"-hhmm"
// offset or UT/GMT/Z.
pub fn parse_rfc2822(s: str) -> result[Time, str] {
    let bad = "'" + s + "' is not an RFC 2822 date (Tue, 13 Oct 2026 09:30:15 +0000)";
    let rest = strings.trim(s);
    let comma = strings.find(rest, ",");
    if comma >= 0 {
        rest = strings.trim(strings.slice(rest, comma + 1, len(rest)));
    }
    let parts: [str] = [];
    for p in strings.split(rest, " ") {
        if len(p) > 0 {
            push(parts, p);
        }
    }
    if len(parts) != 5 {
        return err(bad);
    }
    let d = to_int(parts[0]) ?? -1;
    let m = month_from_short(parts[1]);
    let y = to_int(parts[2]) ?? -1;
    let cb = to_bytes(parts[3]);
    let h = digits_at(cb, 0, 2);
    let mi = digits_at(cb, 3, 2);
    let sec = 0;
    if len(cb) == 8 {
        sec = digits_at(cb, 6, 2);
    } else if len(cb) != 5 {
        return err(bad);
    }
    if d < 1 || m == 0 || y < 1000 || h < 0 || mi < 0 || sec < 0 || !byte_is(cb, 2, 58) {
        return err(bad);
    }
    let z = parts[4];
    let off = 0;
    if z == "UT" || z == "GMT" || z == "Z" {
        off = 0;
    } else {
        let zb = to_bytes(z);
        let oh = digits_at(zb, 1, 2);
        let om = digits_at(zb, 3, 2);
        if len(zb) != 5 || oh < 0 || om < 0 || (!byte_is(zb, 0, 43) && !byte_is(zb, 0, 45)) {
            return err(bad);
        }
        off = oh * 3600 + om * 60;
        if byte_is(zb, 0, 45) {
            off = -off;
        }
    }
    let tr = utc(y, m, d, h, mi, sec, 0);
    guard let t = tr else let e = err_of(tr) {
        return err("'" + s + "': " + e);
    }
    return ok(t.add(-off * 1000000000));
}

// ---- for people ---------------------------------------------------------------

fn plural(n: int, unit: str) -> str {
    if n == 1 {
        return "1 " + unit;
    }
    return to_str(n) + " " + unit + "s";
}

// How long ago `t` was, or how far ahead, from `now_t`, the way people
// say it: "just now", "45 seconds ago", "3 minutes ago", "in 2 hours",
// "yesterday", "5 days ago", "in 3 weeks", "2 months ago", "1 year ago".
// Rounded down, so "1 hour ago" means at least an hour.
pub fn relative(t: Time, now_t: Time) -> str {
    let d = now_t.sub(t);
    let past = d >= 0;
    let a = d;
    if !past {
        a = -d;
    }
    let s = a / 1000000000;
    if s < 10 {
        return "just now";
    }
    let phrase = "";
    if s < 60 {
        phrase = plural(s, "second");
    } else if s < 3600 {
        phrase = plural(s / 60, "minute");
    } else if s < 86400 {
        phrase = plural(s / 3600, "hour");
    } else {
        let days = s / 86400;
        if days == 1 {
            if past {
                return "yesterday";
            }
            return "tomorrow";
        }
        if days < 7 {
            phrase = plural(days, "day");
        } else if days < 30 {
            phrase = plural(days / 7, "week");
        } else if days < 365 {
            phrase = plural(days / 30, "month");
        } else {
            phrase = plural(days / 365, "year");
        }
    }
    if past {
        return phrase + " ago";
    }
    return "in " + phrase;
}
