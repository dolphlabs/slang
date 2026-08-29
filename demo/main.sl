// Slang Arcade -- a demo server exercising every tier of the
// language: structs/opt/result/guard-let, the time/net/json/proc
// native packages, net.tls_*, spawn+chan[T] concurrency, local
// package imports (httpkit/arcade/content), and C interop via
// extern fn + link. See demo/README.md for the tour; `./run.sh`
// builds and runs it.

import "net";
import "proc";
import "time";
import "json";
import "httpkit";
import "arcade";
import "content";
import "stress";

link "slangarcade";
extern fn sl_demo_roll_die() -> i32;
extern fn getpid() -> i32;
extern fn atoi(s: str) -> i32;

// All mutable server state lives in one struct, passed explicitly to
// every handler. slang has no closures, so a plain top-level `let`
// declared in main's body is invisible to a separately-defined `fn`
// -- but struct instances are GC'd heap pointers (see the Types
// table), so passing this struct around and mutating its fields from
// any function that holds it is visible everywhere else that holds
// the same pointer, main() included. That's the pattern this whole
// file uses instead of globals or closures. Lists and maps are
// themselves heap pointers too, so `push`ing onto st.messages or
// indexing into st.leaderboard from inside a handler is visible back
// in main() the same way, with no extra plumbing.
//
// None of that makes concurrent access safe, though -- the README is
// explicit that slang gives you real threads and failure isolation,
// not an ownership/borrow checker, and "mutating a shared struct/
// list/map from more than one task concurrently is exactly as unsafe
// as it is in Go or Java: nothing currently stops you, so don't."
// This demo hit that directly during development: ten concurrent
// dice-roll requests, each mutating the shared leaderboard map from
// its own spawned connection handler with no synchronization, hung
// the process outright (most likely sl_map's open-addressing probe
// loop spinning on state torn by two unsynchronized writers, though
// this was diagnosed by symptom and fix, not a core dump). `lock` below
// is a `chan[T]`-as-mutex -- made with one token in it, acquired by
// receiving that token (chan_recv blocks until it's available) and
// released by sending it back -- guarding every access to the
// mutable fields. Real production code with hotter shared state would
// want finer-grained locking or a single owning task instead of one
// coarse lock; for a demo, correctness-over-throughput is the right
// tradeoff, and it's a direct, honest demonstration of exactly the
// gap the README calls out plus the `chan[T]` primitive that's
// already there to close it yourself.
struct AppState {
    messages: [arcade.Message],
    leaderboard: map[str]arcade.Player,
    request_count: int,
    start_ns: duration,
    lock: chan[bool],
    // stress_counter/stress_lock exist only for /api/stress/counter, to
    // isolate pure chan[T]-mutex contention from the rest of the app's
    // state -- kept separate from `lock` above so a stress run doesn't
    // conflate lock overhead with real (frontend) state contention.
    stress_counter: int,
    stress_lock: chan[bool],
}

fn lock_state(st: AppState) {
    let v = chan_recv(st.lock);
    guard let _token = v else {
        println("FAIL: state lock channel closed unexpectedly");
        exit(1);
    }
}

fn unlock_state(st: AppState) {
    chan_send(st.lock, true);
}

// ---- route handlers ----

fn route_stats(st: AppState) -> httpkit.Response {
    let uptime: duration = time.mono() - st.start_ns;
    lock_state(st);
    let s = arcade.Stats {
        uptime_ms: (uptime as int) / 1000000,
        requests: st.request_count,
        active_tasks: proc.active_tasks(),
        message_count: len(st.messages),
        player_count: len(st.leaderboard),
        pid: getpid()
    };
    unlock_state(st);
    let body: str = json.encode(s);
    return httpkit.ok_json(body);
}

fn route_list_messages(st: AppState) -> httpkit.Response {
    lock_state(st);
    let body: str = json.encode(st.messages);
    unlock_state(st);
    return httpkit.ok_json(body);
}

fn route_post_message(st: AppState, req: httpkit.Request) -> httpkit.Response {
    let r: result[arcade.NewMessage, str] = json.decode(req.body);
    guard let nm = r else {
        return httpkit.bad_request("invalid message JSON");
    }
    if len(nm.author) == 0 || len(nm.text) == 0 {
        return httpkit.bad_request("author and text are required");
    }
    let msg = arcade.Message {
        author: nm.author,
        text: nm.text,
        mood: nm.mood,
        at_ms: time.wall() / 1000000
    };
    lock_state(st);
    push(st.messages, msg);
    unlock_state(st);
    let body: str = json.encode(msg);
    return httpkit.created_json(body);
}

fn route_leaderboard(st: AppState) -> httpkit.Response {
    lock_state(st);
    let body: str = json.encode(st.leaderboard);
    unlock_state(st);
    return httpkit.ok_json(body);
}

fn route_roll(st: AppState, req: httpkit.Request) -> httpkit.Response {
    let r: result[arcade.RollRequest, str] = json.decode(req.body);
    guard let rr = r else {
        return httpkit.bad_request("invalid roll JSON");
    }
    let name = rr.player;
    if len(name) == 0 {
        name = "anon";
    }

    let a = sl_demo_roll_die();
    let b = sl_demo_roll_die();
    let total = a + b;

    let best: i32 = total;
    let rolls: i32 = 1;
    lock_state(st);
    if has(st.leaderboard, name) {
        let prev = st.leaderboard[name];
        rolls = (prev.rolls + 1) as i32;
        if prev.best > best {
            best = prev.best;
        }
    }
    st.leaderboard[name] = arcade.Player { name: name, best: best, rolls: rolls };
    unlock_state(st);

    let result_body = arcade.RollResult {
        player: name,
        a: a,
        b: b,
        total: total,
        is_double: arcade.is_double(a, b),
        best: best,
        rolls: rolls
    };
    let body: str = json.encode(result_body);
    return httpkit.ok_json(body);
}

// ---- stress endpoints (demo/stress_harness/ drives these; not linked
// from the frontend at all -- see demo/README.md) ----

fn route_stress_ping() -> httpkit.Response {
    return httpkit.ok_json("{\"pong\":true}");
}

fn route_stress_cpu(req: httpkit.Request) -> httpkit.Response {
    let r: result[stress.CpuReq, str] = json.decode(req.body);
    guard let cr = r else {
        return httpkit.bad_request("invalid json");
    }
    let t0 = time.mono();
    let count = stress.count_primes(cr.n);
    let elapsed: duration = time.mono() - t0;
    let resp = stress.CpuResp { n: cr.n, prime_count: count, elapsed_ms: (elapsed as int) / 1000000 };
    return httpkit.ok_json(json.encode(resp));
}

fn route_stress_alloc(req: httpkit.Request) -> httpkit.Response {
    let r: result[stress.AllocReq, str] = json.decode(req.body);
    guard let ar = r else {
        return httpkit.bad_request("invalid json");
    }
    let t0 = time.mono();
    let sum = stress.alloc_and_sum(ar.n);
    let elapsed: duration = time.mono() - t0;
    let resp = stress.AllocResp { n: ar.n, sum: sum, elapsed_ms: (elapsed as int) / 1000000 };
    return httpkit.ok_json(json.encode(resp));
}

fn route_stress_json(req: httpkit.Request) -> httpkit.Response {
    let t0 = time.mono();
    let r: result[stress.JsonReq, str] = json.decode(req.body);
    guard let jr = r else {
        return httpkit.bad_request("invalid json");
    }
    let total = 0;
    for it in jr.items {
        total = total + it.value;
    }
    let elapsed: duration = time.mono() - t0;
    let resp = stress.JsonResp { tag: jr.tag, item_count: len(jr.items), total: total, elapsed_ms: (elapsed as int) / 1000000 };
    return httpkit.ok_json(json.encode(resp));
}

fn route_stress_sleep(req: httpkit.Request) -> httpkit.Response {
    let r: result[stress.SleepReq, str] = json.decode(req.body);
    guard let sr = r else {
        return httpkit.bad_request("invalid json");
    }
    time.sleep(sr.ms * 1000000);
    let resp = stress.SleepResp { slept_ms: sr.ms };
    return httpkit.ok_json(json.encode(resp));
}

fn chan_worker(n: int, results: chan[int]) {
    let c = stress.count_primes(n);
    chan_send(results, c);
}

fn route_stress_chan(req: httpkit.Request) -> httpkit.Response {
    let r: result[stress.ChanReq, str] = json.decode(req.body);
    guard let cr = r else {
        return httpkit.bad_request("invalid json");
    }
    let t0 = time.mono();
    let results: chan[int] = make_chan(1);
    spawn chan_worker(cr.n, results);
    let v = chan_recv(results);
    guard let total = v else {
        println("FAIL: stress chan closed unexpectedly");
        exit(1);
    }
    let elapsed: duration = time.mono() - t0;
    let resp = stress.ChanResp { n: cr.n, prime_count: total, elapsed_ms: (elapsed as int) / 1000000 };
    return httpkit.ok_json(json.encode(resp));
}

fn fanout_worker(lo: int, hi: int, results: chan[int]) {
    let c = stress.count_primes_range(lo, hi);
    chan_send(results, c);
}

// Each call to this endpoint spawns `workers` extra OS threads on top
// of its own connection-handling thread -- deliberately, to see how
// the thread-per-connection model behaves when a single request fans
// out internally instead of one thread doing all the work.
fn route_stress_fanout(req: httpkit.Request) -> httpkit.Response {
    let r: result[stress.FanoutReq, str] = json.decode(req.body);
    guard let fr = r else {
        return httpkit.bad_request("invalid json");
    }
    let workers = fr.workers;
    if workers < 1 {
        workers = 1;
    }
    let t0 = time.mono();
    let results: chan[int] = make_chan(workers);
    let chunk = fr.n / workers;
    for w in 0..workers {
        let lo = w * chunk;
        let hi = lo + chunk;
        if w == workers - 1 {
            hi = fr.n;
        }
        spawn fanout_worker(lo, hi, results);
    }
    let total = 0;
    for w in 0..workers {
        let v = chan_recv(results);
        guard let c = v else {
            println("FAIL: fanout chan closed unexpectedly");
            exit(1);
        }
        total = total + c;
    }
    let elapsed: duration = time.mono() - t0;
    let resp = stress.FanoutResp { n: fr.n, workers: workers, prime_count: total, elapsed_ms: (elapsed as int) / 1000000 };
    return httpkit.ok_json(json.encode(resp));
}

fn route_stress_counter(st: AppState) -> httpkit.Response {
    let sv = chan_recv(st.stress_lock);
    guard let _tok = sv else {
        println("FAIL: stress lock channel closed unexpectedly");
        exit(1);
    }
    st.stress_counter = st.stress_counter + 1;
    let c = st.stress_counter;
    chan_send(st.stress_lock, true);
    let resp = stress.CounterResp { count: c };
    return httpkit.ok_json(json.encode(resp));
}

fn route(st: AppState, req: httpkit.Request) -> httpkit.Response {
    lock_state(st);
    st.request_count = st.request_count + 1;
    unlock_state(st);

    if req.method == "GET" && req.path == "/" {
        return httpkit.ok_html(content.index_html());
    }
    if req.method == "GET" && req.path == "/style.css" {
        return httpkit.ok_css(content.style_css());
    }
    if req.method == "GET" && req.path == "/app.js" {
        return httpkit.ok_js(content.app_js());
    }
    if req.method == "GET" && req.path == "/api/stats" {
        return route_stats(st);
    }
    if req.method == "GET" && req.path == "/api/messages" {
        return route_list_messages(st);
    }
    if req.method == "POST" && req.path == "/api/messages" {
        return route_post_message(st, req);
    }
    if req.method == "GET" && req.path == "/api/leaderboard" {
        return route_leaderboard(st);
    }
    if req.method == "POST" && req.path == "/api/roll" {
        return route_roll(st, req);
    }
    if req.method == "GET" && req.path == "/api/stress/ping" {
        return route_stress_ping();
    }
    if req.method == "POST" && req.path == "/api/stress/cpu" {
        return route_stress_cpu(req);
    }
    if req.method == "POST" && req.path == "/api/stress/alloc" {
        return route_stress_alloc(req);
    }
    if req.method == "POST" && req.path == "/api/stress/json" {
        return route_stress_json(req);
    }
    if req.method == "POST" && req.path == "/api/stress/sleep" {
        return route_stress_sleep(req);
    }
    if req.method == "POST" && req.path == "/api/stress/chan" {
        return route_stress_chan(req);
    }
    if req.method == "POST" && req.path == "/api/stress/fanout" {
        return route_stress_fanout(req);
    }
    if req.method == "POST" && req.path == "/api/stress/counter" {
        return route_stress_counter(st);
    }
    return httpkit.not_found();
}

// ---- connection handling: a bounded worker pool instead of a fresh
// OS thread per connection (Tier 9 in todo.md; see
// demo/stress_harness/'s "Arcade Under Load" report for why). Accepted
// connections flow through a bounded chan[T] queue instead of each
// getting spawn'd its own thread -- removes the per-request
// pthread_create/teardown cost this pattern was originally built to
// avoid. spawn's own semantics (Tier 5) are unchanged: this is purely
// how this file chooses to dispatch work, not a new compiler primitive.
//
// Plain HTTP now runs exactly ONE acceptor task (Tier 11's real kqueue
// reactor landed -- net.accept() parks the calling task instead of
// blocking the OS thread it runs on, so a single acceptor already lets
// the rest of the pool stay free for connection handling; the original
// Tier 9 stopgap ran N_ACCEPTORS=4 non-blocking, polling acceptor tasks
// specifically to work around accept() tying up a whole thread, which
// parking makes unnecessary). Running MORE than one acceptor on the
// SAME listening fd is no longer just wasteful, it's actively unsafe
// under the reactor: at most one task may be parked waiting on a given
// (fd, direction) at a time -- a second concurrent waiter silently
// overwrites the first's kqueue registration, permanently orphaning it
// (see the Tier 11 sixth-slice plan's own review finding 11). TLS
// (net.tls_*) is deliberately NOT converted to parking this slice --
// its own accept() call still genuinely blocks the OS thread, so its
// original multi-acceptor-plus-poll design (TLS_ACCEPTORS below) is
// still exactly as safe and necessary as it always was; that pattern
// simply doesn't apply to the (now-parked) plain HTTP path anymore.

let TLS_ACCEPTORS: int = 4;

fn handle_http_conn(st: AppState, cfd: i32) {
    let recv_r: result[bytes, str] = net.recv(cfd, 65536);
    guard let raw = recv_r else {
        net.close(cfd);
        return;
    }
    let parsed: result[httpkit.Request, str] = httpkit.parse(raw);
    guard let req = parsed else {
        net.send(cfd, httpkit.serialize(httpkit.bad_request("malformed request")));
        net.close(cfd);
        return;
    }
    let resp = route(st, req);
    net.send(cfd, httpkit.serialize(resp));
    net.close(cfd);
}

// Pulls accepted fds off the shared work queue and handles them to
// completion, one at a time, for as long as the queue stays open --
// chan_recv keeps returning real work while a closed channel still
// has buffered items, and only returns none once it's truly closed
// and drained, which is exactly the shutdown signal this loop needs.
fn http_worker(st: AppState, work: chan[i32]) {
    while true {
        let v = chan_recv(work);
        guard let cfd = v else { return; }
        handle_http_conn(st, cfd);
    }
}

fn accept_and_queue_http(lfd: i32, work: chan[i32]) -> bool {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return false; }
    chan_send(work, cfd);
    return true;
}

// Runs as the ONE spawned background acceptor task for plain HTTP
// (see the big comment above TLS_ACCEPTORS for why exactly one, not
// several). net.accept() itself parks this task -- no OS thread is
// held hostage while nothing's pending, and no polling backoff is
// needed the way TLS's own still-blocking accept loop still needs one:
// a genuine connection resumes this task via the reactor, and a
// shutdown signal resumes it too, returning Err("interrupted") from
// net.accept() so the loop's own shutdown_requested() check catches it
// on the very next iteration. Signals its own exit on `done` so the
// shutdown sequence knows precisely when the acceptor has stopped --
// and so can no longer send to `work` -- before it's safe to close the
// queue.
fn http_accept_loop(lfd: i32, work: chan[i32], done: chan[bool]) {
    while !proc.shutdown_requested() {
        accept_and_queue_http(lfd, work);
    }
    chan_send(done, true);
}

// Same shape as handle_http_conn, but through net.tls_* instead of
// net.* -- the only difference TLS makes to the application layer is
// which functions read/write/close a connection; routing is identical
// either way.
fn handle_tls_conn(st: AppState, conn: rawptr) {
    let recv_r: result[bytes, str] = net.tls_recv(conn, 65536);
    guard let raw = recv_r else {
        net.tls_close(conn);
        return;
    }
    let parsed: result[httpkit.Request, str] = httpkit.parse(raw);
    guard let req = parsed else {
        net.tls_send(conn, httpkit.serialize(httpkit.bad_request("malformed request")));
        net.tls_close(conn);
        return;
    }
    let resp = route(st, req);
    net.tls_send(conn, httpkit.serialize(resp));
    net.tls_close(conn);
}

fn tls_worker(st: AppState, work: chan[rawptr]) {
    while true {
        let v = chan_recv(work);
        guard let conn = v else { return; }
        handle_tls_conn(st, conn);
    }
}

fn accept_and_queue_tls(lfd: i32, sctx: rawptr, work: chan[rawptr]) -> bool {
    let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);
    guard let conn = ar else { return false; }
    chan_send(work, conn);
    return true;
}

fn tls_accept_loop(lfd: i32, sctx: rawptr, work: chan[rawptr], done: chan[bool]) {
    while !proc.shutdown_requested() {
        let got = accept_and_queue_tls(lfd, sctx, work);
        if !got {
            time.sleep(1000000); // 1ms -- see http_accept_loop's comment
        }
    }
    chan_send(done, true);
}

// Attempts to bring up the HTTPS listener; returns false (and starts
// nothing) if the cert/key aren't there instead of failing the whole
// program -- run.sh generates a self-signed pair, but running
// main.sl directly without it should still serve plain HTTP fine.
// work/done are created unconditionally at startup (see below) so the
// shutdown sequence can always reference them, whether or not TLS
// actually came up.
fn try_start_tls(st: AppState, tls_port: i32, acceptors: int, workers: int,
                 work: chan[rawptr], done: chan[bool]) -> bool {
    let sctx_r: result[rawptr, str] = net.tls_server_ctx("cert.pem", "key.pem");
    guard let sctx = sctx_r else {
        return false;
    }
    let lr: result[i32, str] = net.listen(tls_port);
    guard let lfd = lr else {
        return false;
    }
    // non-blocking so the acceptor loops' polling actually polls
    // instead of blocking indefinitely in accept() -- see their comment
    let nb: result[bool, str] = net.nonblock(lfd);
    guard let _ok = nb else {
        return false;
    }
    for i in 0..acceptors {
        spawn tls_accept_loop(lfd, sctx, work, done);
    }
    for i in 0..workers {
        spawn tls_worker(st, work);
    }
    return true;
}

// ---- startup ----

// empty list/map literals need an explicit annotation to infer their
// element type; a struct field's declared type doesn't propagate
// into an empty [] or {} literal the way it does for a plain `let`
let no_messages: [arcade.Message] = [];
let no_players: map[str]arcade.Player = {};
let state_lock: chan[bool] = make_chan(1);
chan_send(state_lock, true); // one token in the box == unlocked
let stress_lock: chan[bool] = make_chan(1);
chan_send(stress_lock, true);
let st = AppState {
    messages: no_messages,
    leaderboard: no_players,
    request_count: 0,
    start_ns: time.mono(),
    lock: state_lock,
    stress_counter: 0,
    stress_lock: stress_lock
};

let port_env: opt[str] = proc.getenv("PORT");
let port_str: str = port_env ?? "8090";
let port = atoi(port_str);
let workers_str: str = proc.getenv("WORKERS") ?? "128";
let workers = atoi(workers_str);

let lr: result[i32, str] = net.listen(port);
guard let lfd = lr else {
    println("could not listen on port " + to_str(port));
    exit(1);
}
// No net.nonblock() call here anymore -- net.accept() itself parks the
// calling task now (Tier 11's real kqueue reactor), so the listener
// stays in its default mode and http_accept_loop's single acceptor
// task just blocks-via-parking until a connection or a shutdown signal
// resumes it. See the big comment above TLS_ACCEPTORS for why TLS's
// own listener still needs net.nonblock() below and plain HTTP's
// doesn't.
let http_work: chan[i32] = make_chan(256);
let http_done: chan[bool] = make_chan(1);
spawn http_accept_loop(lfd, http_work, http_done);
for i in 0..workers {
    spawn http_worker(st, http_work);
}

let tls_work: chan[rawptr] = make_chan(256);
let tls_done: chan[bool] = make_chan(TLS_ACCEPTORS);
let tls_port_str: str = proc.getenv("TLS_PORT") ?? "8091";
let tls_port = atoi(tls_port_str);
let tls_ok = try_start_tls(st, tls_port, TLS_ACCEPTORS, workers, tls_work, tls_done);

println("Slang Arcade listening on http://localhost:" + to_str(port));
if tls_ok {
    println("  and https://localhost:" + to_str(tls_port)
        + " (self-signed cert -- browsers will warn; that's expected)");
} else {
    println("  TLS disabled: no cert.pem/key.pem here -- run via "
        + "./run.sh to generate one, or see examples/httpsd/");
}
println("1 HTTP acceptor, " + to_str(TLS_ACCEPTORS) + " TLS acceptors, "
    + to_str(workers) + " workers per protocol (override with WORKERS=n)");
println("Ctrl-C (or SIGTERM) for a graceful shutdown -- in-flight requests");
println("are drained, not dropped. See demo/README.md.");

while !proc.shutdown_requested() {
    time.sleep(50000000); // 50ms -- acceptors/workers do the real work now
}

println("");
println("shutting down: waiting for acceptors to stop...");
let hv = chan_recv(http_done);
guard let _htok = hv else {
    println("FAIL: http acceptor done-channel closed unexpectedly");
    exit(1);
}
chan_close(http_work);
if tls_ok {
    for i in 0..TLS_ACCEPTORS {
        let tv = chan_recv(tls_done);
        guard let _ttok = tv else {
            println("FAIL: tls acceptor done-channel closed unexpectedly");
            exit(1);
        }
    }
    chan_close(tls_work);
}

println("waiting for in-flight connections to finish...");
while proc.active_tasks() > 0 {
    time.sleep(20000000); // 20ms
}
net.close(lfd);
println("goodbye!");
