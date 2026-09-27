import "http";
import "httpc";
import "json";
import "log";
import "proc";
import "time";

// hero:start
// A tiny JSON router. Adding a route is one line in the table --
// handlers are values of type fn, so dispatch needs no chain of
// string comparisons and no framework.
gc struct Route {
    method: str,
    path: str,
    handler: fn(http.Request) -> http.Response,
}

fn hello(req: http.Request) -> http.Response {
    return http.ok_json("{\"hello\":\"world\"}");
}

fn echo(req: http.Request) -> http.Response {
    return http.ok_json(json.encode(to_str(req.body)));
}

let routes: [Route] = [
    Route { method: "GET", path: "/hi", handler: hello },
    Route { method: "POST", path: "/echo", handler: echo }
];

fn route(routes: [Route], req: http.Request) -> http.Response {
    for r in routes {
        if r.method == req.method && r.path == req.path {
            return r.handler(req);
        }
    }
    return http.not_found();
}

fn serve(ln: link, routes: [Route]) {
    while !proc.shutdown_requested() {
        let ar = ln.accept(until_never());
        guard let c = ar else { return; }
        spawn handle(c, routes);
    }
}
// hero:end

fn handle(c: link, routes: [Route]) {
    let ra = arena_new(65536);
    let sa = arena_new(65536);
    let buf = ra.wire(65536);
    while true {
        let rr = http.read(&mut c, buf, 0, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, route(routes, got.req), &mut sa,
                            until_never());
        guard let n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) { return; }
    }
}

let lr = link_listen(0);
guard let ln = lr else let e = err_of(lr) {
    log.error("listen: " + to_str(e));
    exit(1);
}
let port = ln.port();
spawn serve(ln, routes);

fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

let base = "http://127.0.0.1:" + to_str(port);
let h = httpc.get(base + "/hi", soon());
guard let hello_resp = h else let e = err_of(h) {
    log.error("self-hit: " + e);
    exit(1);
}
assert(hello_resp.status == 200, "hi status");

let p = httpc.post(base + "/echo", "text/plain", b"hey", soon());
guard let echo_resp = p else let e = err_of(p) {
    log.error("self-hit: " + e);
    exit(1);
}
assert(to_str(echo_resp.body) == "\"hey\"", "echo body");

let m = httpc.get(base + "/missing", soon());
guard let missing = m else let e = err_of(m) {
    log.error("self-hit: " + e);
    exit(1);
}
assert(missing.status == 404, "missing status");

println("router ok");
