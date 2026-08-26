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
    return httpkit.not_found();
}

// ---- connection handling (spawned per-connection, so one slow
// client can't stall the others) ----

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

fn accept_and_serve_http(st: AppState, lfd: i32) {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return; }
    spawn handle_http_conn(st, cfd);
}

// Same shape as handle_http_conn/accept_and_serve_http, but through
// net.tls_* instead of net.* -- the only difference TLS makes to the
// application layer is which functions read/write/close a
// connection; routing is identical either way.
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

// Returns whether a connection was actually accepted, so
// tls_accept_loop below knows whether to back off before trying
// again.
fn accept_and_serve_tls(st: AppState, lfd: i32, sctx: rawptr) -> bool {
    let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);
    guard let conn = ar else { return false; }
    spawn handle_tls_conn(st, conn);
    return true;
}

// Runs as its own spawned background task, which matters for exactly
// one reason: every spawned thread has SIGTERM/SIGINT blocked in its
// own mask from birth (see stmt.c's ST_SPAWN codegen), so the OS can
// only ever pick the main thread to run proc's signal handler -- a
// blocking net.tls_accept() call here would NEVER be interrupted, and
// would sit there forever even after shutdown_requested() goes true,
// which would in turn keep this task counted in proc.active_tasks()
// forever and hang the drain loop in main() below. (An earlier
// version of this file did exactly that -- worth keeping in mind as
// the concrete failure mode.) Fixed by making lfd non-blocking
// (try_start_tls below) and polling: this loop actually re-checks its
// own condition every ~50ms instead of blocking indefinitely, so it
// notices shutdown promptly even with nothing connecting.
fn tls_accept_loop(st: AppState, lfd: i32, sctx: rawptr) {
    while !proc.shutdown_requested() {
        let got = accept_and_serve_tls(st, lfd, sctx);
        if !got {
            time.sleep(50000000); // 50ms
        }
    }
}

// Attempts to bring up the HTTPS listener; returns false (and starts
// nothing) if the cert/key aren't there instead of failing the whole
// program -- run.sh generates a self-signed pair, but running
// main.sl directly without it should still serve plain HTTP fine.
fn try_start_tls(st: AppState, tls_port: i32) -> bool {
    let sctx_r: result[rawptr, str] = net.tls_server_ctx("cert.pem", "key.pem");
    guard let sctx = sctx_r else {
        return false;
    }
    let lr: result[i32, str] = net.listen(tls_port);
    guard let lfd = lr else {
        return false;
    }
    // non-blocking so tls_accept_loop's polling actually polls
    // instead of blocking indefinitely in accept() -- see its comment
    let nb: result[bool, str] = net.nonblock(lfd);
    guard let _ok = nb else {
        return false;
    }
    spawn tls_accept_loop(st, lfd, sctx);
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
let st = AppState {
    messages: no_messages,
    leaderboard: no_players,
    request_count: 0,
    start_ns: time.mono(),
    lock: state_lock
};

let port_env: opt[str] = proc.getenv("PORT");
let port_str: str = port_env ?? "8090";
let port = atoi(port_str);

let lr: result[i32, str] = net.listen(port);
guard let lfd = lr else {
    println("could not listen on port " + to_str(port));
    exit(1);
}
let tls_port_str: str = proc.getenv("TLS_PORT") ?? "8091";
let tls_port = atoi(tls_port_str);
let tls_ok = try_start_tls(st, tls_port);

println("Slang Arcade listening on http://localhost:" + to_str(port));
if tls_ok {
    println("  and https://localhost:" + to_str(tls_port)
        + " (self-signed cert -- browsers will warn; that's expected)");
} else {
    println("  TLS disabled: no cert.pem/key.pem here -- run via "
        + "./run.sh to generate one, or see examples/httpsd/");
}
println("Ctrl-C (or SIGTERM) for a graceful shutdown -- in-flight requests");
println("are drained, not dropped. See demo/README.md.");

while !proc.shutdown_requested() {
    accept_and_serve_http(st, lfd);
}

println("");
println("shutting down: waiting for in-flight connections to finish...");
while proc.active_tasks() > 0 {
    time.sleep(20000000); // 20ms
}
net.close(lfd);
println("goodbye!");
