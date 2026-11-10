// The websocket client against the Autobahn TestSuite's fuzzing server,
// the conformance suite WebSocket implementations are measured by: about
// 500 cases of framing, fragmentation, UTF-8, close handling, limits and
// permessage-deflate. Each case is a connection that sends messages; the
// client echoes them back, and the server grades what it saw. check.py
// then fails the run on any case graded below OK, NON-STRICT or
// INFORMATIONAL.
//
//     docker run -d --name fuzzingserver -p 9001:9001 \
//         -v "$PWD/tests/live/websocket:/config" -v /tmp/autobahn:/reports \
//         crossbario/autobahn-testsuite wstest -m fuzzingserver -s /config/fuzzingserver.json
//     ./slangc tests/live/websocket/main.sl --run
//     python3 tests/live/websocket/check.py /tmp/autobahn/clients/index.json

import "proc";
import "strings";
import "time";
import "websocket";

fn soon(s: int) -> until {
    return until_of(time.mono() + s * 1000000000);
}

fn base() -> str {
    let u = proc.getenv("AUTOBAHN_URL") ?? "";
    if u == "" {
        return "ws://127.0.0.1:9001";
    }
    return u;
}

fn opts() -> websocket.Options {
    let o = websocket.options();
    o.compress = true;
    // the suite's largest message is 16 MiB
    o.max_message = 67108864;
    return o;
}

fn case_count() -> int {
    let r = websocket.dial(base() + "/getCaseCount", soon(10));
    guard let c = r else let e = err_of(r) { panic("getCaseCount: " + e); }
    let mr = websocket.recv(c, soon(10));
    guard let got = mr else let e = err_of(mr) { panic(e); }
    guard let m = got else { panic("getCaseCount: no answer"); }
    websocket.close(c, 1000, "", soon(5));
    return to_int(websocket.text(m)) ?? 0;
}

fn run_case(i: int) {
    let r = websocket.dial_with(base() + "/runCase?case=" + to_str(i) + "&agent=slang", opts(), soon(10));
    guard let c = r else let e = err_of(r) {
        println("case " + to_str(i) + ": dial: " + e);
        return;
    }
    while true {
        let mr = websocket.recv(c, soon(60));
        guard let got = mr else { return; }
        guard let m = got else {
            websocket.close_now(c);
            return;
        }
        if m.kind == websocket.Kind.Close {
            return;
        }
        let sr = if_text(c, m);
        guard let _s = sr else { return; }
    }
}

fn if_text(c: websocket.Conn, m: websocket.Message) -> result[bool, str] {
    if m.kind == websocket.Kind.Text {
        // m.data, not text(m): a case sends U+0000, which a str cannot hold
        return websocket.send_text_bytes(c, m.data, soon(60));
    }
    return websocket.send_binary(c, m.data, soon(60));
}

let n = case_count();
println("cases: " + to_str(n));
let t0 = time.mono() as int;
for i in 1..n + 1 {
    run_case(i);
}
let r = websocket.dial(base() + "/updateReports?agent=slang", soon(30));
guard let c = r else let e = err_of(r) { panic("updateReports: " + e); }
while true {
    let mr = websocket.recv(c, soon(120));
    guard let got = mr else { break; }
    guard let m = got else { break; }
    if m.kind == websocket.Kind.Close {
        break;
    }
}
println("ran " + to_str(n) + " cases in " + to_str(((time.mono() as int) - t0) / 1000000) + " ms");
