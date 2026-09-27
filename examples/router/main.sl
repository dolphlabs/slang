import "http";
import "httpc";
import "log";
import "proc";
import "time";

// hero:start
// Handlers take a Ctx: the request plus the app's own state,
// typed together so nothing arrives untyped.
gc struct Config {
    greeting: str,
}
gc struct Ctx[S] {
    req: http.Request,
    state: S,
}
fn hello(ctx: Ctx[Config]) -> http.Response {
    return http.ok_json("{\"hello\":\"" + ctx.state.greeting + "\"}");
}
gc struct Route {
    method: str,
    path: str,
    handler: fn(Ctx[Config]) -> http.Response,
}
let routes: [Route] = [
    Route { method: "GET", path: "/hi", handler: hello }
];
// hero:end

fn route(routes: [Route], ctx: Ctx[Config]) -> http.Response {
    for r in routes {
        if r.method == ctx.req.method && r.path == ctx.req.path {
            return r.handler(ctx);
        }
    }
    return http.not_found();
}

fn handle(c: link, routes: [Route], cfg: Config) {
    let ra = arena_new(65536);
    let sa = arena_new(65536);
    let buf = ra.wire(65536);
    while true {
        let rr = http.read(&mut c, buf, 0, until_never());
        guard let got = rr else { return; }
        let ctx = Ctx[Config] { req: got.req, state: cfg };
        let wr = http.write(&mut c, route(routes, ctx), &mut sa,
                            until_never());
        guard let n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) { return; }
    }
}

fn serve(ln: link, routes: [Route], cfg: Config) {
    while !proc.shutdown_requested() {
        let ar = ln.accept(until_never());
        guard let c = ar else { return; }
        spawn handle(c, routes, cfg);
    }
}

let cfg = Config { greeting: "world" };
let lr = link_listen(0);
guard let ln = lr else let e = err_of(lr) {
    log.error("listen: " + to_str(e));
    exit(1);
}
let port = ln.port();
spawn serve(ln, routes, cfg);

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

let m = httpc.get(base + "/missing", soon());
guard let missing = m else let e = err_of(m) {
    log.error("self-hit: " + e);
    exit(1);
}
assert(missing.status == 404, "missing status");

println("router ok");
