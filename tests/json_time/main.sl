// timez.Time in json.encode/json.decode: written as timez's rfc3339_nano()
// writes it, read with parse_rfc3339()'s rules. The codec is C in the JSON
// runtime, so this checks it against timez itself: every encoded instant
// equals rfc3339_nano(), and every input string decodes exactly when
// parse_rfc3339 accepts it, to the same instant.
import "json";
import "strings";
import "timez";

struct Event {
    name: str,
    at: timez.Time,
    ends: opt[timez.Time],
    marks: [timez.Time],
    by_zone: map[str]timez.Time,
}

gc struct Holder {
    t: timez.Time,
}

fn quoted(t: timez.Time) -> str {
    return "\"" + t.rfc3339_nano() + "\"";
}

// encode agrees with rfc3339_nano across eras, fractions and signs
let bad = 0;
let sec = -62135596800;     // 0001-01-01T00:00:00Z
let step = 7919 * 86400 + 3607;
let n = 0;
while sec < 253402300799 {
    let ns = (n * 123456789) % 1000000000;
    let t = timez.Time { sec: sec, nsec: ns };
    if json.encode(t) != quoted(t) {
        println("encode differs: " + json.encode(t) + " vs " + quoted(t));
        bad = bad + 1;
    }
    sec = sec + step;
    n = n + 1;
}
println("encoded " + to_str(n) + " instants, " + to_str(bad) + " differ");

// decode accepts exactly what parse_rfc3339 accepts
let inputs = [
    "2026-10-13T09:30:15Z", "2026-10-13t09:30:15z", "2026-10-13 09:30:15Z",
    "2026-10-13T09:30:15.5Z", "2026-10-13T09:30:15.123456789Z",
    "2026-10-13T09:30:15.1234567890Z", "2026-10-13T09:30:15+05:45",
    "2026-10-13T09:30:15-08:00", "2026-10-13T09:30:15", "2026-10-13T09:30:15.Z",
    "2026-13-01T00:00:00Z", "2025-02-29T00:00:00Z", "2024-02-29T23:59:59Z",
    "2026-10-13T24:00:00Z", "2026-10-13T09:60:00Z", "2026-10-13T09:30:15+24:00",
    "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999999Z", "2026-10-13",
    "2026-10-13T09:30:15ZZ", "", "x026-10-13T09:30:15Z"
];
let agree = 0;
for s in inputs {
    let want = timez.parse_rfc3339(s);
    let got: result[Holder, str] = json.decode("{\"t\":\"" + s + "\"}");
    if let w = want {
        if let g = got {
            if g.t.equal(w) {
                agree = agree + 1;
            } else {
                println("different instant for " + s);
            }
        } else {
            println("json refused what timez accepts: " + s + " (" + err_of(got) + ")");
        }
    } else {
        if let _g = got {
            println("json accepted what timez refuses: " + s);
        } else {
            agree = agree + 1;
        }
    }
}
println(to_str(agree) + " of " + to_str(len(inputs)) + " inputs agree with parse_rfc3339");

// an escaped timestamp goes through the string reader and still parses
let esc: result[Holder, str] = json.decode("{\"t\":\"2026-10-13\\u005409:30:15Z\"}");
if let h = esc { println(h.t.rfc3339()); } else { println("escaped: " + err_of(esc)); }

// a whole struct round-trips, null and empty containers included
let t0 = timez.parse_rfc3339("2026-10-13T09:30:15.5+02:00") ?? timez.unix(0);
let zones: map[str]timez.Time = {};
zones["utc"] = t0;
let e = Event { name: "launch", at: t0, ends: none, marks: [timez.unix(0), t0], by_zone: zones };
let text = json.encode(e);
println(text);
let back: result[Event, str] = json.decode(text);
guard let b = back else let msg = err_of(back) {
    println("round trip failed: " + msg);
    exit(1);
}
println(json.encode(b) == text);

// the messages say what is wrong
let msgs = [
    "{\"t\":\"2026-10-13T09:30:15\"}", "{\"t\":12}",
    "{\"t\":\"2026-10-13T09:30:15.1234567891Z\"}", "{\"t\":\"2026-02-30T00:00:00Z\"}"
];
for m in msgs {
    let r: result[Holder, str] = json.decode(m);
    if let _x = r { println("accepted " + m); } else { println(err_of(r)); }
}
