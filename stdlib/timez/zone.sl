// Time zones: fixed offsets and the IANA database, daylight saving
// included.
//
//     let zr = timez.load_zone("Europe/Berlin");     // from the system's zoneinfo
//     guard let berlin = zr else let e = err_of(zr) { ... }
//     let local = timez.now().in_zone(berlin);       // a ZonedTime
//     println(local.rfc3339());                      // 2026-10-13T11:30:15+02:00
//     println(local.format("%H:%M %Z"));             // 11:30 CEST
//
//     // a wall time in a zone, to an instant -- with a rule for the hour
//     // that does not exist (spring forward) or happens twice (fall back)
//     let r = timez.zoned(berlin, 2026, 3, 29, 2, 30, 0, timez.Disambiguation.COMPATIBLE);
//
// Zones come from the TZif files (RFC 8536) under $ZONEINFO, else
// /usr/share/zoneinfo -- the IANA database every Linux and macOS ships
// and most container images carry as `tzdata`. Instants after the file's
// last transition follow its POSIX-TZ footer rule, which is how the
// current "slim" files describe every future year. A missing database
// is an error that says how to install it, never a silent UTC.
//
// A Zone is built once and shared: load it at startup and keep it in
// your state.

import "fs";
import "proc";
import "strings";

// What to do with a wall time that a daylight-saving change skips (a
// gap: 02:30 on the spring-forward night) or repeats (an overlap: 02:30
// on the fall-back night).
pub enum Disambiguation {
    // The gap moves forward by its length (02:30 -> 03:30), the overlap
    // takes the earlier instant: what JavaScript's Temporal, java.time
    // and most calendars do.
    COMPATIBLE,
    EARLIER,
    LATER,
    // err for both: when a wrong guess costs more than a refusal.
    REJECT,
}

// One side of a POSIX-TZ rule: when daylight saving starts or ends.
struct TzWhen {
    // 0 = Mm.w.d, 1 = Jn (1-365, no Feb 29), 2 = n (0-365)
    kind: int,
    month: int,
    week: int,
    weekday: int,
    day: int,
    // seconds after local midnight
    time: int,
}

// A POSIX-TZ string such as "CET-1CEST,M3.5.0,M10.5.0/3".
struct TzRule {
    std_name: str,
    // seconds east of UTC
    std_off: int,
    has_dst: bool,
    dst_name: str,
    dst_off: int,
    start: TzWhen,
    end: TzWhen,
}

pub gc struct Zone {
    name: str,
    // Unix seconds of each transition, ascending, and the local-time
    // type that applies from it.
    at: [int],
    kind: [int],
    // Per local-time type.
    offsets: [int],
    dst: [bool],
    abbrevs: [str],
    // For instants after the last transition (or with none).
    has_rule: bool,
    rule: TzRule,
}

fn no_when() -> TzWhen {
    return TzWhen { kind: 0, month: 0, week: 0, weekday: 0, day: 0, time: 0 };
}

fn fixed_rule(name: str, off: int) -> TzRule {
    return TzRule { std_name: name, std_off: off, has_dst: false, dst_name: "", dst_off: off,
                    start: no_when(), end: no_when() };
}

// UTC, as a Zone.
pub fn utc_zone() -> Zone {
    return fixed_zone("UTC", 0);
}

// A zone at a fixed offset (seconds east of UTC) that never changes.
pub fn fixed_zone(name: str, offset_seconds: int) -> Zone {
    return Zone { name: name, at: [], kind: [], offsets: [offset_seconds], dst: [false],
                  abbrevs: [name], has_rule: true, rule: fixed_rule(name, offset_seconds) };
}

// ---- loading ------------------------------------------------------------------

// A zone name is the path of a file under the database: letters, digits,
// "_", "-", "+" and "/" between parts, never "..", never absolute. A name
// that arrives in a request cannot reach anything else on the disk.
fn zone_name_ok(name: str) -> bool {
    if len(name) == 0 || len(name) > 128 || strings.has_prefix(name, "/") ||
       strings.contains(name, "..") || strings.contains(name, "//") {
        return false;
    }
    for c in to_bytes(name) {
        let x = c as int;
        let ok_byte = (x >= 97 && x <= 122) || (x >= 65 && x <= 90) || (x >= 48 && x <= 57) ||
                      x == 95 || x == 45 || x == 43 || x == 47;
        if !ok_byte {
            return false;
        }
    }
    return true;
}

fn zoneinfo_dirs() -> [str] {
    let env = proc.getenv("ZONEINFO") ?? "";
    if len(env) > 0 {
        return [env];
    }
    return ["/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo"];
}

// A whole file of at most 4 MB (zone files are a few KB).
fn read_small_file(path: str) -> result[bytes, str] {
    let fr = fs.open(path);
    guard let fd = fr else let e = err_of(fr) {
        return err(e);
    }
    let parts: [bytes] = [];
    let total = 0;
    while true {
        let rr = fs.read(fd, 65536);
        guard let chunk = rr else let e = err_of(rr) {
            let _c = fs.close(fd);
            return err(e);
        }
        if len(chunk) == 0 {
            break;
        }
        total = total + len(chunk);
        if total > 4194304 {
            let _c = fs.close(fd);
            return err("larger than 4 MB");
        }
        push(parts, chunk);
    }
    let _c = fs.close(fd);
    return ok(strings.join_bytes(parts, b""));
}

// "UTC" and fixed zones need no database; anything else is read from it.
pub fn load_zone(name: str) -> result[Zone, str] {
    if name == "UTC" || name == "Etc/UTC" || name == "Z" {
        return ok(utc_zone());
    }
    if !zone_name_ok(name) {
        return err("'" + name + "' is not a time zone name (like Europe/Berlin)");
    }
    let tried: [str] = [];
    for dir in zoneinfo_dirs() {
        let path = dir + "/" + name;
        let r = read_small_file(path);
        if let data = r {
            let zr = parse_tzif(name, data);
            guard let z = zr else let e = err_of(zr) {
                return err("time zone " + name + " (" + path + "): " + e);
            }
            return ok(z);
        }
        push(tried, dir);
    }
    return err("unknown time zone '" + name + "': no file for it under " + strings.join(tried, ", ") +
               ". Install the tz database (apk add tzdata, apt-get install tzdata) or set ZONEINFO");
}

fn be32(b: bytes, i: int) -> int {
    let v = ((b[i] as int) << 24) | ((b[i + 1] as int) << 16) | ((b[i + 2] as int) << 8) |
            (b[i + 3] as int);
    if v >= 2147483648 {
        return v - 4294967296;
    }
    return v;
}

fn be64(b: bytes, i: int) -> int {
    let hi = be32(b, i);
    let lo = be32(b, i + 4);
    if lo < 0 {
        lo = lo + 4294967296;
    }
    return hi * 4294967296 + lo;
}

// RFC 8536: version 2 or later, whose 64-bit block and footer this reads
// (the 32-bit block before them is skipped).
pub fn parse_tzif(name: str, b: bytes) -> result[Zone, str] {
    if len(b) < 44 || to_str(b[0..4]) != "TZif" {
        return err("not a TZif file");
    }
    let version = b[4] as int;
    if version < 50 {
        return err("TZif version 1 has no 64-bit data; the tz database is too old");
    }
    // v1 header counts, to skip the v1 block
    let isut1 = be32(b, 20);
    let isstd1 = be32(b, 24);
    let leap1 = be32(b, 28);
    let time1 = be32(b, 32);
    let type1 = be32(b, 36);
    let char1 = be32(b, 40);
    let i = 44 + time1 * 4 + time1 + type1 * 6 + char1 + leap1 * 8 + isstd1 + isut1;
    if i + 44 > len(b) || to_str(b[i..i + 4]) != "TZif" {
        return err("truncated TZif file");
    }
    let isut = be32(b, i + 20);
    let isstd = be32(b, i + 24);
    let leapcnt = be32(b, i + 28);
    let timecnt = be32(b, i + 32);
    let typecnt = be32(b, i + 36);
    let charcnt = be32(b, i + 40);
    if typecnt < 1 || timecnt < 0 || timecnt > 100000 || typecnt > 256 {
        return err("bad TZif counts");
    }
    i = i + 44;
    let need = timecnt * 9 + typecnt * 6 + charcnt + leapcnt * 12 + isstd + isut;
    if i + need > len(b) {
        return err("truncated TZif data");
    }
    let at: [int] = [];
    let k = 0;
    while k < timecnt {
        push(at, be64(b, i + k * 8));
        k = k + 1;
    }
    i = i + timecnt * 8;
    let kind: [int] = [];
    k = 0;
    while k < timecnt {
        let t = b[i + k] as int;
        if t >= typecnt {
            return err("transition names a missing type");
        }
        push(kind, t);
        k = k + 1;
    }
    i = i + timecnt;
    let offsets: [int] = [];
    let dst: [bool] = [];
    let idx: [int] = [];
    k = 0;
    while k < typecnt {
        push(offsets, be32(b, i + k * 6));
        push(dst, (b[i + k * 6 + 4] as int) != 0);
        push(idx, b[i + k * 6 + 5] as int);
        k = k + 1;
    }
    i = i + typecnt * 6;
    let chars = b[i..i + charcnt];
    let abbrevs: [str] = [];
    for x in idx {
        let e = x;
        while e < charcnt && (chars[e] as int) != 0 {
            e = e + 1;
        }
        push(abbrevs, to_str(chars[x..e]));
    }
    i = i + charcnt + leapcnt * 12 + isstd + isut;
    // footer: "\n" POSIX-TZ "\n"
    let has_rule = false;
    let rule = fixed_rule(abbrevs[0], offsets[0]);
    if i < len(b) && (b[i] as int) == 10 {
        let e = i + 1;
        while e < len(b) && (b[e] as int) != 10 {
            e = e + 1;
        }
        let text = to_str(b[i + 1..e]);
        if len(text) > 0 {
            let rr = parse_posix_tz(text);
            guard let r = rr else let e2 = err_of(rr) {
                return err("footer '" + text + "': " + e2);
            }
            rule = r;
            has_rule = true;
        }
    }
    return ok(Zone { name: name, at: at, kind: kind, offsets: offsets, dst: dst, abbrevs: abbrevs,
                     has_rule: has_rule, rule: rule });
}

// ---- POSIX TZ rules -----------------------------------------------------------

struct Cursor {
    b: bytes,
    i: int,
}

fn tz_name(c: Cursor) -> result[Cursor, str] {
    // <...> quoted, or 3+ letters
    if c.i < len(c.b) && (c.b[c.i] as int) == 60 {
        let e = c.i + 1;
        while e < len(c.b) && (c.b[e] as int) != 62 {
            e = e + 1;
        }
        if e >= len(c.b) {
            return err("unterminated <name>");
        }
        return ok(Cursor { b: c.b, i: e + 1 });
    }
    let e = c.i;
    while e < len(c.b) {
        let x = c.b[e] as int;
        if !((x >= 65 && x <= 90) || (x >= 97 && x <= 122)) {
            break;
        }
        e = e + 1;
    }
    if e - c.i < 3 {
        return err("zone abbreviation shorter than 3 letters");
    }
    return ok(Cursor { b: c.b, i: e });
}

fn name_between(b: bytes, from: int, to: int) -> str {
    if to - from >= 2 && (b[from] as int) == 60 {
        return to_str(b[from + 1..to - 1]);
    }
    return to_str(b[from..to]);
}

fn read_num(b: bytes, i: int) -> int {
    let v = 0;
    let k = i;
    while k < len(b) && (b[k] as int) >= 48 && (b[k] as int) <= 57 {
        v = v * 10 + (b[k] as int - 48);
        k = k + 1;
    }
    return v;
}

fn num_end(b: bytes, i: int) -> int {
    let k = i;
    while k < len(b) && (b[k] as int) >= 48 && (b[k] as int) <= 57 {
        k = k + 1;
    }
    return k;
}

// [+-]hh[:mm[:ss]] at i; returns [seconds, next index], or [0, -1].
fn hms(b: bytes, i: int) -> [int] {
    let sign = 1;
    let k = i;
    if k < len(b) && ((b[k] as int) == 43 || (b[k] as int) == 45) {
        if (b[k] as int) == 45 {
            sign = -1;
        }
        k = k + 1;
    }
    let e = num_end(b, k);
    if e == k {
        return [0, -1];
    }
    let v = read_num(b, k) * 3600;
    k = e;
    if k < len(b) && (b[k] as int) == 58 {
        let e2 = num_end(b, k + 1);
        v = v + read_num(b, k + 1) * 60;
        k = e2;
        if k < len(b) && (b[k] as int) == 58 {
            let e3 = num_end(b, k + 1);
            v = v + read_num(b, k + 1);
            k = e3;
        }
    }
    return [sign * v, k];
}

// ",Mm.w.d[/time]" / ",Jn[/time]" / ",n[/time]" at i (just past the
// comma); returns the rule and the next index.
fn tz_when(b: bytes, i: int) -> result[TzWhen, str] {
    let w = no_when();
    w.time = 7200;
    let k = i;
    if k < len(b) && (b[k] as int) == 77 {
        let m_end = num_end(b, k + 1);
        w.month = read_num(b, k + 1);
        if m_end >= len(b) || (b[m_end] as int) != 46 {
            return err("bad M rule");
        }
        let w_end = num_end(b, m_end + 1);
        w.week = read_num(b, m_end + 1);
        if w_end >= len(b) || (b[w_end] as int) != 46 {
            return err("bad M rule");
        }
        let d_end = num_end(b, w_end + 1);
        w.weekday = read_num(b, w_end + 1);
        k = d_end;
        w.kind = 0;
        if w.month < 1 || w.month > 12 || w.week < 1 || w.week > 5 || w.weekday > 6 {
            return err("M rule out of range");
        }
    } else if k < len(b) && (b[k] as int) == 74 {
        w.kind = 1;
        w.day = read_num(b, k + 1);
        k = num_end(b, k + 1);
    } else {
        w.kind = 2;
        w.day = read_num(b, k);
        k = num_end(b, k);
    }
    if k < len(b) && (b[k] as int) == 47 {
        let t = hms(b, k + 1);
        if t[1] < 0 {
            return err("bad rule time");
        }
        w.time = t[0];
    }
    return ok(w);
}

fn when_end(b: bytes, i: int) -> int {
    let k = i;
    while k < len(b) && (b[k] as int) != 44 {
        k = k + 1;
    }
    return k;
}

pub fn parse_posix_tz(s: str) -> result[TzRule, str] {
    let b = to_bytes(s);
    let n1 = tz_name(Cursor { b: b, i: 0 });
    guard let c1 = n1 else let e = err_of(n1) {
        return err(e);
    }
    let std_name = name_between(b, 0, c1.i);
    let o = hms(b, c1.i);
    if o[1] < 0 {
        return err("missing standard offset");
    }
    // POSIX offsets are west of UTC: "CET-1" is UTC+1.
    let std_off = -o[0];
    let k = o[1];
    if k >= len(b) {
        return ok(fixed_rule(std_name, std_off));
    }
    let n2 = tz_name(Cursor { b: b, i: k });
    guard let c2 = n2 else let e = err_of(n2) {
        return err(e);
    }
    let dst_name = name_between(b, k, c2.i);
    k = c2.i;
    let dst_off = std_off + 3600;
    if k < len(b) && (b[k] as int) != 44 {
        let o2 = hms(b, k);
        if o2[1] < 0 {
            return err("bad daylight offset");
        }
        dst_off = -o2[0];
        k = o2[1];
    }
    if k >= len(b) || (b[k] as int) != 44 {
        return err("daylight saving without start and end rules");
    }
    let sr = tz_when(b, k + 1);
    guard let start = sr else let e = err_of(sr) {
        return err(e);
    }
    k = when_end(b, k + 1);
    if k >= len(b) {
        return err("daylight saving without an end rule");
    }
    let er = tz_when(b, k + 1);
    guard let end = er else let e = err_of(er) {
        return err(e);
    }
    return ok(TzRule { std_name: std_name, std_off: std_off, has_dst: true, dst_name: dst_name,
                       dst_off: dst_off, start: start, end: end });
}

// Days since the epoch of the rule's day in `year`.
fn when_day(w: TzWhen, year: int) -> int {
    if w.kind == 1 {
        // Jn: 1-365, February 29 never counted
        let d = w.day;
        if is_leap_year(year) && d >= 60 {
            d = d + 1;
        }
        return days_from_civil(year, 1, 1) + d - 1;
    }
    if w.kind == 2 {
        return days_from_civil(year, 1, 1) + w.day;
    }
    // Mm.w.d: the w-th weekday d (0 = Sunday) of month m; week 5 = last
    let first = days_from_civil(year, w.month, 1);
    // weekday of the 1st with Sunday 0: 1970-01-01 was a Thursday (4)
    let wd1 = fmod(first + 4, 7);
    let day = first + fmod(w.weekday - wd1, 7) + (w.week - 1) * 7;
    let last = days_from_civil(year, w.month, days_in_month(year, w.month));
    while day > last {
        day = day - 7;
    }
    return day;
}

// The offset the rule gives at Unix second `t`, and whether it is DST.
fn rule_at(r: TzRule, t: int) -> [int] {
    if !r.has_dst {
        return [r.std_off, 0];
    }
    let year = civil_from_days(fdiv(t + r.std_off, 86400)).year;
    // DST starts at the start time, local standard time; ends at the end
    // time, local daylight time.
    let start = when_day(r.start, year) * 86400 + r.start.time - r.std_off;
    let end = when_day(r.end, year) * 86400 + r.end.time - r.dst_off;
    let in_dst = false;
    if start < end {
        in_dst = t >= start && t < end;
    } else {
        // southern hemisphere: DST spans the new year
        in_dst = t >= start || t < end;
    }
    if in_dst {
        return [r.dst_off, 1];
    }
    return [r.std_off, 0];
}

// ---- lookups ------------------------------------------------------------------

// The local-time type in force at Unix second `t`: [offset, is_dst (0/1),
// abbreviation index or -1 for the rule's names].
fn zone_info(z: Zone, t: int) -> [int] {
    let n = len(z.at);
    if n == 0 || t >= z.at[n - 1] {
        if z.has_rule && (n == 0 || t >= z.at[n - 1]) {
            let ri = rule_at(z.rule, t);
            return [ri[0], ri[1], -1];
        }
        if n == 0 {
            return [z.offsets[0], 0, 0];
        }
        let k = z.kind[n - 1];
        return [z.offsets[k], bool_int(z.dst[k]), k];
    }
    if t < z.at[0] {
        // before the first transition: the first standard-time type
        let k = 0;
        let i = 0;
        while i < len(z.dst) {
            if !z.dst[i] {
                k = i;
                break;
            }
            i = i + 1;
        }
        return [z.offsets[k], bool_int(z.dst[k]), k];
    }
    // binary search: the last transition at or before t
    let lo = 0;
    let hi = n - 1;
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        if z.at[mid] <= t {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    let k = z.kind[lo];
    return [z.offsets[k], bool_int(z.dst[k]), k];
}

fn bool_int(b: bool) -> int {
    if b {
        return 1;
    }
    return 0;
}

impl Zone {
    // Seconds east of UTC at instant `t`.
    pub fn offset_at(self: Zone, t: Time) -> int {
        return zone_info(self, t.sec)[0];
    }

    pub fn is_dst_at(self: Zone, t: Time) -> bool {
        return zone_info(self, t.sec)[1] == 1;
    }

    // "CEST", "PST", "+0530": the abbreviation in use at `t`.
    pub fn abbrev_at(self: Zone, t: Time) -> str {
        let zi = zone_info(self, t.sec);
        if zi[2] >= 0 {
            return self.abbrevs[zi[2]];
        }
        if zi[1] == 1 {
            return self.rule.dst_name;
        }
        return self.rule.std_name;
    }
}

// ---- wall time in a zone ----------------------------------------------------

// An instant together with the zone it is read in: what a person in
// that zone sees on a clock.
pub struct ZonedTime {
    time: Time,
    zone: Zone,
    offset: int,
}

impl Time {
    pub fn in_zone(self: Time, z: Zone) -> ZonedTime {
        return ZonedTime { time: self, zone: z, offset: z.offset_at(self) };
    }
}

// The instant for a wall time in `z`, by `how` when daylight saving
// makes it skipped or repeated.
pub fn zoned(z: Zone, year: int, month: int, day: int, hour: int, minute: int, second: int,
             how: Disambiguation) -> result[Time, str] {
    let wr = utc(year, month, day, hour, minute, second, 0);
    guard let wall = wr else let e = err_of(wr) {
        return err(e);
    }
    return from_wall(z, wall.sec, 0, how);
}

// `wall` read as seconds of a clock in `z` (not an instant): which
// instants show it?
fn from_wall(z: Zone, wall: int, nsec: int, how: Disambiguation) -> result[Time, str] {
    // Offsets in force a day either side bound every offset that could
    // apply; try each, keep those that map back to this wall time.
    let o1 = zone_info(z, wall - 86400)[0];
    let o2 = zone_info(z, wall + 86400)[0];
    let cands: [int] = [];
    for o in [o1, o2] {
        let t = wall - o;
        if zone_info(z, t)[0] == o {
            let dup = false;
            for c in cands {
                if c == t {
                    dup = true;
                }
            }
            if !dup {
                push(cands, t);
            }
        }
    }
    if len(cands) == 1 {
        return ok(Time { sec: cands[0], nsec: nsec });
    }
    if len(cands) == 2 {
        // an overlap: the clock showed this twice
        let early = cands[0];
        let late = cands[1];
        if early > late {
            early = cands[1];
            late = cands[0];
        }
        if how == Disambiguation.REJECT {
            return err("that time happens twice in " + z.name + " (clocks go back)");
        }
        if how == Disambiguation.LATER {
            return ok(Time { sec: late, nsec: nsec });
        }
        return ok(Time { sec: early, nsec: nsec });
    }
    // a gap: no instant shows this wall time
    if how == Disambiguation.REJECT {
        return err("that time does not exist in " + z.name + " (clocks go forward)");
    }
    // In a gap the offset went up: o1 is the one before it, o2 after.
    if how == Disambiguation.EARLIER {
        // back by the gap's length: read with the later offset
        return ok(Time { sec: wall - o2, nsec: nsec });
    }
    // COMPATIBLE and LATER: forward by the gap's length, read with the
    // earlier offset
    return ok(Time { sec: wall - o1, nsec: nsec });
}

impl ZonedTime {
    fn wall(self: ZonedTime) -> Time {
        return self.time.add(self.offset * 1000000000);
    }

    pub fn date(self: ZonedTime) -> Date {
        return self.wall().date();
    }

    pub fn year(self: ZonedTime) -> int { return self.wall().year(); }
    pub fn month(self: ZonedTime) -> int { return self.wall().month(); }
    pub fn day(self: ZonedTime) -> int { return self.wall().day(); }
    pub fn hour(self: ZonedTime) -> int { return self.wall().hour(); }
    pub fn minute(self: ZonedTime) -> int { return self.wall().minute(); }
    pub fn second(self: ZonedTime) -> int { return self.wall().second(); }
    pub fn weekday(self: ZonedTime) -> Weekday { return self.wall().weekday(); }

    pub fn abbrev(self: ZonedTime) -> str {
        return self.zone.abbrev_at(self.time);
    }

    pub fn is_dst(self: ZonedTime) -> bool {
        return self.zone.is_dst_at(self.time);
    }

    // "2026-10-13T11:30:15+02:00".
    pub fn rfc3339(self: ZonedTime) -> str {
        return self.time.rfc3339_at(self.offset);
    }

    // As Time.format, with %z the real offset (+0200) and %Z the zone's
    // abbreviation (CEST).
    pub fn format(self: ZonedTime, layout: str) -> str {
        // %z and %Z are the zone's; everything else is the wall time's.
        // `%%` is copied through untouched so "%%z" stays a literal "%z".
        let b = to_bytes(layout);
        let out: [str] = [];
        let i = 0;
        let start = 0;
        while i + 1 < len(b) {
            if (b[i] as int) != 37 {
                i = i + 1;
                continue;
            }
            let c = b[i + 1] as int;
            if c == 122 || c == 90 {
                push(out, self.wall().format(strings.slice(layout, start, i)));
                if c == 122 {
                    push(out, offset_text(self.offset, false, false));
                } else {
                    push(out, self.abbrev());
                }
                start = i + 2;
            }
            i = i + 2;
        }
        push(out, self.wall().format(strings.slice(layout, start, len(b))));
        return strings.join(out, "");
    }

    // Calendar days later at the same wall time, across daylight-saving
    // changes (a day is then 23 or 25 hours). A wall time that does not
    // exist on the target day moves forward, as COMPATIBLE does.
    pub fn add_days(self: ZonedTime, n: int) -> ZonedTime {
        let w = self.wall().add_days(n);
        let r = from_wall(self.zone, w.sec, w.nsec, Disambiguation.COMPATIBLE);
        let t = r ?? self.time.add_days(n);
        return t.in_zone(self.zone);
    }

    pub fn add_months(self: ZonedTime, n: int) -> ZonedTime {
        let w = self.wall().add_months(n);
        let r = from_wall(self.zone, w.sec, w.nsec, Disambiguation.COMPATIBLE);
        let t = r ?? self.time.add_months(n);
        return t.in_zone(self.zone);
    }

    // Local midnight: the first instant of this date in the zone (01:00
    // where midnight is skipped).
    pub fn start_of_day(self: ZonedTime) -> ZonedTime {
        let w = self.wall().start_of_day();
        let r = from_wall(self.zone, w.sec, 0, Disambiguation.COMPATIBLE);
        let t = r ?? self.time.start_of_day();
        return t.in_zone(self.zone);
    }
}
