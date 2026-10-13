# timez

> Package timez.

Calendar time, written in slang on top of the native `time` clock:
instants, dates, durations, text formats, time zones, test clocks and
cron. Import `"timez"`.

```slang
import "timez";

let t = timez.now();                               // a Time: an instant, UTC
println(t.rfc3339());                              // 2026-10-13T09:30:15Z
println(t.rfc3339_milli());                        // 2026-10-13T09:30:15.000Z (toISOString)
println(t.http_date());                            // Tue, 13 Oct 2026 09:30:15 GMT
println(t.format("%A %e %B %Y, %H:%M"));          // Tuesday 13 October 2026, 09:30

let r = timez.parse_rfc3339("2026-10-13T11:30:15+02:00");   // offsets applied
let due = t.date().add_months(1);                  // Jan 31 + 1 month = Feb 28/29
let ttl = timez.parse_duration("1h30m") ?? 0;      // nanoseconds; "7d" works too
println(timez.relative(t.add(-3 * timez.MINUTE), t));  // 3 minutes ago

let zr = timez.load_zone("Europe/Berlin");         // the system's tz database
guard let berlin = zr else let e = err_of(zr) { println(e); exit(1); }
println(t.in_zone(berlin).format("%H:%M %Z"));     // 11:30 CEST

let cr = timez.parse_cron("*/15 9-17 * * MON-FRI");
guard let cron = cr else let e = err_of(cr) { println(e); exit(1); }
let next = cron.next_after(t, berlin);             // opt[Time], DST-aware
```

**Values.**
- **`Time`** is Unix seconds plus nanoseconds, so it spans 0001-01-01 to
  9999-12-31 and beyond. 64-bit nanoseconds stop at 1677-2262.
- **`Date`** is a calendar day: birthdays, due dates, report days.
- **Durations** are `int` nanoseconds, the unit `time.sleep` and deadlines
  take. Constants run from `NANOSECOND` to `HOUR` and `DAY` (24 hours).
- **The calendar** is proleptic Gregorian, with no leap seconds.

**Calendar.**
- Fields: `year()` to `nanosecond()`, `weekday()`, `year_day()`,
  `iso_week()`, `is_leap_year`, `days_in_month`.
- Arithmetic: `add(d)`, `sub(t)`, and `add_days`, `add_months` and
  `add_years`, which clamp to the end of the month.
- Rounding and periods: `truncate(d)`, `round(d)`, and `start_of_*` and
  `end_of_*` for minute, hour, day, week (Monday), month and year.
- Comparing: `before`, `after`, `equal`, `compare`, `min`, `max`.
- Dates: `days_until`, and `years_until`, which counts an age by whether
  the anniversary has passed.

**Text.**
- `rfc3339`, `rfc3339_milli`, `rfc3339_nano` and `rfc3339_at(offset)`.
- `parse_rfc3339` is strict: it refuses a timestamp with no offset,
  because one without names no instant.
- `parse_date`.
- `http_date`, and `parse_http_date` for all three forms RFC 9110 has
  recipients accept.
- `rfc2822` and `parse_rfc2822`.
- `format(layout)`: `strftime` directives, locale-free.
- `parse_duration` and `format_duration`, Go's format plus `d`.
- `relative`.

**Time zones.**
- **Loading.** `load_zone(name)` reads the IANA database, from `$ZONEINFO`
  or `/usr/share/zoneinfo`. It follows each file's POSIX-TZ rule past its
  last transition, and refuses names that could reach other files. A
  missing database is an error that says how to install it, never a
  silent UTC. `fixed_zone(name, offset)` gives a zone at a fixed offset.
- **Reading.** `t.in_zone(z)` gives a `ZonedTime`: local fields, `abbrev`,
  `is_dst`, `rfc3339` with the offset, and `format` with real `%z` and `%Z`.
- **Local arithmetic.** `add_days`, `add_months` and `start_of_day` work in
  local wall time, so a day across a DST change is 23 or 25 hours.
- **Wall time to instant.** `zoned(z, y, m, d, h, mi, s, how)` converts a
  local wall time to an instant. `how` decides the skipped and repeated
  hours: `COMPATIBLE` moves forward through a gap and takes the earlier of
  an overlap, as Temporal and java.time do. The others are `EARLIER`,
  `LATER` and `REJECT`.

**Operations.**
- `system_clock()` / `fixed_clock(t)`: a `Clock` to pass in state, so
  tests `advance` and `set` the time instead of sleeping.
- `start_stopwatch()`, which measures on the monotonic clock.
- `interval(a, b)`: half-open, with `contains`, `overlaps` and
  `intersection`.
- `deadline(t)` gives the `until` that socket and channel calls take.
- **`parse_cron`:** five fields, names, steps and `@daily` macros. When
  both day fields are set, a day matches either (Vixie). `next_after(t,
  zone)` evaluates in the zone's wall time: a run in a skipped hour
  happens when the clock reaches it, and a repeated hour runs once.

## API

### `fn rfc3339(self: Time) -> str`

"2026-10-13T09:30:15Z": seconds, UTC.

### `fn rfc3339_milli(self: Time) -> str`

"2026-10-13T09:30:15.000Z": always milliseconds, as JavaScript's toISOString() writes them -- what a browser client parses most happily.

### `fn rfc3339_nano(self: Time) -> str`

"2026-10-13T09:30:15.5Z": every nanosecond the instant has, no trailing zeros -- what round-trips exactly.

### `fn rfc3339_at(self: Time, offset_seconds: int) -> str`

The same instant as the wall time at a fixed offset from UTC (seconds east, -64800 to 64800): "2026-10-13T11:30:15+02:00".

### `fn http_date(self: Time) -> str`

"Tue, 13 Oct 2026 09:30:15 GMT": the HTTP date (RFC 9110 IMF-fixdate) for Date, Last-Modified, Expires and cookie Expires.

### `fn rfc2822(self: Time) -> str`

"Tue, 13 Oct 2026 09:30:15 +0000": email (RFC 5322) dates.

### `fn format(self: Time, layout: str) -> str`

strftime-style formatting, locale-free (English names), UTC:  %Y year (2026)   %m month 01-12   %d day 01-31   %e day, space-padded %H hour 00-23    %I hour 01-12    %M minute      %S second    %p AM/PM %L milliseconds (000-999)   %f microseconds   %N nanoseconds (9 digits) %a Tue  %A Tuesday  %b Oct  %B October  %j day of year 001-366 %u weekday 1-7 (Monday 1)  %G ISO year  %V ISO week 01-53 %s Unix seconds   %z +0000   %Z UTC   %F %Y-%m-%d   %T %H:%M:%S   %% %  An unknown directive is written as it is, so a typo shows in the output instead of vanishing.

### `fn parse_date(s: str) -> result[Date, str]`

"2026-10-13" (and only that): a calendar date.

### `fn parse_rfc3339(s: str) -> result[Time, str]`

An RFC 3339 timestamp: "2026-10-13T09:30:15Z", with an optional fraction of up to 9 digits and a "Z" or "+hh:mm"/"-hh:mm" offset, which is applied: the result is the instant, in UTC. "t" and "z" and a space for "T" are accepted, as RFC 3339 allows. A missing offset is refused: a timestamp without one names no instant.

### `fn parse_http_date(s: str) -> result[Time, str]`

An HTTP date. RFC 9110 has recipients accept three forms, and so does this:  Tue, 13 Oct 2026 09:30:15 GMT       IMF-fixdate (what everything sends) Tuesday, 13-Oct-26 09:30:15 GMT     RFC 850 (two-digit year: more than 50 years ahead means last century) Tue Oct 13 09:30:15 2026            asctime

### `fn parse_rfc2822(s: str) -> result[Time, str]`

An email date (RFC 5322): an optional weekday, a 1-2 digit day, a month, a 4-digit year, hh:mm with optional :ss, and a "+hhmm"/"-hhmm" offset or UT/GMT/Z.

### `fn relative(t: Time, now_t: Time) -> str`

How long ago `t` was, or how far ahead, from `now_t`, the way people say it: "just now", "45 seconds ago", "3 minutes ago", "in 2 hours", "yesterday", "5 days ago", "in 3 weeks", "2 months ago", "1 year ago". Rounded down, so "1 hour ago" means at least an hour.

### `gc struct Clock`

Where code gets the time, so a test can set it instead of sleeping. Pass a Clock in your state; production uses system_clock().

### `fn system_clock() -> Clock`

### `fn fixed_clock(t: Time) -> Clock`

A clock that stays at `t` until advanced or set.

### `fn now(self: Clock) -> Time`

### `fn advance(self: Clock, d: int) -> Time`

Moves a fixed clock forward by `d` (no effect on the system clock).

### `fn set(self: Clock, t: Time)`

### `struct Stopwatch`

Measures elapsed time on the monotonic clock: a wall-clock correction (NTP, a person setting the time) cannot make it jump or go backwards.

### `fn start_stopwatch() -> Stopwatch`

### `fn elapsed(self: Stopwatch) -> int`

Nanoseconds since the stopwatch started.

### `fn elapsed_text(self: Stopwatch) -> str`

"1.502s".

### `struct Interval`

A half-open span [start, end): it contains its start, not its end, so back-to-back intervals (09:00-10:00, 10:00-11:00) do not overlap.

### `fn interval(start: Time, end: Time) -> result[Interval, str]`

err when `end` is before `start`.

### `fn contains(self: Interval, t: Time) -> bool`

### `fn overlaps(self: Interval, o: Interval) -> bool`

### `fn intersection(self: Interval, o: Interval) -> opt[Interval]`

The span both cover, none when they do not overlap.

### `fn length(self: Interval) -> int`

Nanoseconds from start to end.

### `fn is_empty(self: Interval) -> bool`

### `gc struct Cron`

A five-field cron schedule: minute hour day-of-month month day-of-week. Each field takes `*`, numbers, ranges (`9-17`), lists (`1,15`), steps (`*/15`, `0-30/10`), month names (JAN-DEC) and weekday names (SUN-SAT; 0 and 7 are both Sunday). Macros: @yearly @annually @monthly @weekly @daily @midnight @hourly. As in Vixie cron, when both day fields are restricted a day matches either one.

### `fn parse_cron(spec: str) -> result[Cron, str]`

### `fn next_after(self: Cron, t: Time, z: Zone) -> opt[Time]`

The first run strictly after `t`, read on the clocks of `z`; none when the schedule never matches (Feb 30) within eight years. A run whose wall time a daylight-saving change skips happens when the clock reaches it (moved forward); one the change repeats runs once.

### `let NANOSECOND = 1;`

### `let MICROSECOND = 1000;`

### `let MILLISECOND = 1000000;`

### `let SECOND = 1000000000;`

### `let MINUTE = 60000000000;`

### `let HOUR = 3600000000000;`

### `let DAY = 86400000000000;`

24 hours.

### `struct Time`

An instant, in UTC.

### `struct Date`

A calendar day, with no time and no zone: a birthday, a due date, a day of a report.

### `struct IsoWeek`

An ISO 8601 week: weeks start on Monday, and week 1 is the one with the year's first Thursday, so early January can belong to the previous year's last week.

### `fn days_from_civil(y: int, m: int, d: int) -> int`

Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm: exact for every proleptic Gregorian date in range).

### `fn civil_from_days(days: int) -> Date`

The civil date `days` after 1970-01-01.

### `fn is_leap_year(y: int) -> bool`

### `fn days_in_month(y: int, m: int) -> int`

### `fn days_in_year(y: int) -> int`

### `fn weekday_index(w: Weekday) -> int`

Monday 0 through Sunday 6.

### `fn weekday_name(w: Weekday) -> str`

"Monday" ... "Sunday".

### `fn month_name(m: int) -> str`

"January" ... "December"; "" outside 1-12.

### `fn now() -> Time`

The current instant, from the system clock.

### `fn unix(sec: int) -> Time`

### `fn unix_milli(ms: int) -> Time`

### `fn unix_nano(ns: int) -> Time`

### `fn utc(year: int, month: int, day: int, hour: int, minute: int, second: int, nanos: int) -> result[Time, str]`

The instant at a UTC civil date and time; err names the first field out of range. Seconds run 0-59: there are no leap seconds.

### `fn date(year: int, month: int, day: int) -> result[Date, str]`

A calendar date; err names what is out of range.

### `fn today() -> Date`

Today's date, in UTC.

### `fn min(a: Time, b: Time) -> Time`

### `fn max(a: Time, b: Time) -> Time`

### `fn since(t: Time) -> int`

Nanoseconds since `t` (negative when `t` is in the future).

### `fn until(t: Time) -> int`

Nanoseconds until `t` (negative when it has passed).

### `fn deadline(t: Time) -> until`

The `until` a socket or channel call takes, for the wall-clock instant `t`: deadlines run on the monotonic clock, so this measures the distance to `t` once and counts it from now.

### `fn unix(self: Time) -> int`

### `fn unix_milli(self: Time) -> int`

### `fn unix_nano(self: Time) -> int`

Nanoseconds since the epoch; saturates outside 1677-2262.

### `fn date(self: Time) -> Date`

### `fn year(self: Time) -> int`

### `fn month(self: Time) -> int`

### `fn day(self: Time) -> int`

### `fn hour(self: Time) -> int`

### `fn minute(self: Time) -> int`

### `fn second(self: Time) -> int`

### `fn nanosecond(self: Time) -> int`

### `fn millisecond(self: Time) -> int`

### `fn weekday(self: Time) -> Weekday`

### `fn year_day(self: Time) -> int`

1 to 366.

### `fn iso_week(self: Time) -> IsoWeek`

### `fn add(self: Time, d: int) -> Time`

`self` plus `d` nanoseconds (negative goes back).

### `fn sub(self: Time, o: Time) -> int`

Nanoseconds from `o` to `self`; saturates past ~292 years.

### `fn add_days(self: Time, n: int) -> Time`

Calendar days later, at the same time of day.

### `fn add_months(self: Time, n: int) -> Time`

Calendar months later, at the same time of day. A day past the end of the target month is clamped to its last day: Jan 31 + 1 month is Feb 28 (29 in a leap year), not Mar 3.

### `fn add_years(self: Time, n: int) -> Time`

Calendar years later; Feb 29 + 1 year is Feb 28.

### `fn before(self: Time, o: Time) -> bool`

### `fn after(self: Time, o: Time) -> bool`

### `fn equal(self: Time, o: Time) -> bool`

### `fn compare(self: Time, o: Time) -> int`

-1, 0 or 1.

### `fn truncate(self: Time, d: int) -> Time`

Rounded down to a multiple of `d` since the epoch (d <= 0 leaves it as is): truncate(MINUTE) drops seconds.

### `fn round(self: Time, d: int) -> Time`

Rounded to the nearest multiple of `d`, halves away from zero.

### `fn start_of_minute(self: Time) -> Time`

### `fn start_of_hour(self: Time) -> Time`

### `fn start_of_day(self: Time) -> Time`

### `fn start_of_week(self: Time) -> Time`

Monday 00:00 of this ISO week.

### `fn start_of_month(self: Time) -> Time`

### `fn start_of_year(self: Time) -> Time`

### `fn end_of_day(self: Time) -> Time`

The last nanosecond of the day, month and year: for inclusive range queries ("created <= end of day").

### `fn end_of_month(self: Time) -> Time`

### `fn end_of_year(self: Time) -> Time`

### `fn weekday(self: Date) -> Weekday`

### `fn year_day(self: Date) -> int`

### `fn iso_week(self: Date) -> IsoWeek`

### `fn is_leap_year(self: Date) -> bool`

### `fn add_days(self: Date, n: int) -> Date`

### `fn add_months(self: Date, n: int) -> Date`

Jan 31 + 1 month is Feb 28 (29 in a leap year).

### `fn add_years(self: Date, n: int) -> Date`

### `fn days_until(self: Date, o: Date) -> int`

Days from `self` to `o`: 1 for tomorrow, negative for the past.

### `fn years_until(self: Date, o: Date) -> int`

Whole years from `self` to `o`, counting a year only once its anniversary has passed: an age, a tenure.

### `fn start(self: Date) -> Time`

00:00:00 UTC on this date.

### `fn at(self: Date, hour: int, minute: int, second: int) -> result[Time, str]`

The instant at this date and a UTC time of day.

### `fn before(self: Date, o: Date) -> bool`

### `fn after(self: Date, o: Date) -> bool`

### `fn equal(self: Date, o: Date) -> bool`

### `fn compare(self: Date, o: Date) -> int`

### `fn start_of_month(self: Date) -> Date`

### `fn end_of_month(self: Date) -> Date`

### `fn iso(self: Date) -> str`

"2026-10-13" (ISO 8601).

### `fn parse_duration(s: str) -> result[int, str]`

A duration written as Go writes them -- "1h30m", "1.5s", "300ms", "-2m", "2us" -- plus "d" for 24-hour days ("7d"), the unit config files reach for. "0" alone is zero. err names what was wrong; values past ~292 years are refused, not wrapped.

### `fn format_duration(d: int) -> str`

A duration the way Go prints one and parse_duration reads it back: "1h30m0s", "1.5s", "300ms", "2µs", "0s".

### `gc struct Zone`

### `fn utc_zone() -> Zone`

UTC, as a Zone.

### `fn fixed_zone(name: str, offset_seconds: int) -> Zone`

A zone at a fixed offset (seconds east of UTC) that never changes.

### `fn load_zone(name: str) -> result[Zone, str]`

"UTC" and fixed zones need no database; anything else is read from it.

### `fn parse_tzif(name: str, b: bytes) -> result[Zone, str]`

RFC 8536: version 2 or later, whose 64-bit block and footer this reads (the 32-bit block before them is skipped).

### `fn parse_posix_tz(s: str) -> result[TzRule, str]`

### `fn offset_at(self: Zone, t: Time) -> int`

Seconds east of UTC at instant `t`.

### `fn is_dst_at(self: Zone, t: Time) -> bool`

### `fn abbrev_at(self: Zone, t: Time) -> str`

"CEST", "PST", "+0530": the abbreviation in use at `t`.

### `struct ZonedTime`

An instant together with the zone it is read in: what a person in that zone sees on a clock.

### `fn in_zone(self: Time, z: Zone) -> ZonedTime`

### `fn zoned(z: Zone, year: int, month: int, day: int, hour: int, minute: int, second: int, how: Disambiguation) -> result[Time, str]`

The instant for a wall time in `z`, by `how` when daylight saving makes it skipped or repeated.

### `fn date(self: ZonedTime) -> Date`

### `fn year(self: ZonedTime) -> int`

### `fn month(self: ZonedTime) -> int`

### `fn day(self: ZonedTime) -> int`

### `fn hour(self: ZonedTime) -> int`

### `fn minute(self: ZonedTime) -> int`

### `fn second(self: ZonedTime) -> int`

### `fn weekday(self: ZonedTime) -> Weekday`

### `fn abbrev(self: ZonedTime) -> str`

### `fn is_dst(self: ZonedTime) -> bool`

### `fn rfc3339(self: ZonedTime) -> str`

"2026-10-13T11:30:15+02:00".

### `fn format(self: ZonedTime, layout: str) -> str`

As Time.format, with %z the real offset (+0200) and %Z the zone's abbreviation (CEST).

### `fn add_days(self: ZonedTime, n: int) -> ZonedTime`

Calendar days later at the same wall time, across daylight-saving changes (a day is then 23 or 25 hours). A wall time that does not exist on the target day moves forward, as COMPATIBLE does.

### `fn add_months(self: ZonedTime, n: int) -> ZonedTime`

### `fn start_of_day(self: ZonedTime) -> ZonedTime`

Local midnight: the first instant of this date in the zone (01:00 where midnight is skipped).

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
