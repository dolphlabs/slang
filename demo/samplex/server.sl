// samplex -- a small JSON REST server.
//
//   GET  /api/tasks       list every task
//   POST /api/tasks       create one from a JSON body
//   PUT  /api/tasks/{id}  replace one by id
//
// plus GET / , a one-page browser client so the API is clickable
// without reaching for curl.
//
// HTTP/1.1 on purpose, not HTTP/2: browsers only speak h2 over TLS, so
// an h2 server on a plain port is reachable from curl but not from the
// address bar. This is meant to be opened in a browser.
//
// Concurrency is the same shape the big demo/ uses: one acceptor task
// feeding a bounded queue that a fixed pool of worker tasks drains.
// Workers are green tasks, so the pool is sized in the hundreds without
// hundreds of OS threads.

import "http";
import "byteutil";
import "json";
import "log";
import "proc";
import "time";

// str -> int straight from libc; slang has no atoi builtin.
extern fn atoi(s: str) -> i32;

// ---- domain types ----------------------------------------------------
//
// Two shapes on purpose: NewTask is what a client may send, Task is what
// the server stores and returns. Keeping them apart is what stops a
// client from choosing its own `id`.

gc struct NewTask {
    title: str,
    done: opt[bool],
}

gc struct Task {
    id: int,
    title: str,
    done: bool,
}

// ---- shared state ----------------------------------------------------
//
// Every worker task touches this, so it needs mutual exclusion. slang
// has no mutex type; a chan[bool] holding exactly one token is one.
// Taking the token is chan_recv, releasing it is chan_send, and a task
// that finds the token gone parks until whoever holds it puts it back.

gc struct State {
    tasks: [Task],
    next_id: int,
    lock: chan[bool],
}

fn lock(st: State) {
    let v = chan_recv(st.lock);
    guard let _t = v else {
        log.error("state lock closed");
        exit(1);
    }
}

fn unlock(st: State) {
    chan_send(st.lock, true);
}

// ---- helpers ---------------------------------------------------------

// Pull the trailing integer out of "/api/tasks/42". Returns -1 when the
// path does not match the prefix or the remainder is not all digits, so
// /api/tasks/abc is a 404 rather than task 0.
fn path_id(path: str, prefix: str) -> int {
    let p = to_bytes(path);
    let pre = to_bytes(prefix);
    if !byteutil.has_prefix(p, pre) {
        return -1;
    }
    let rest = p[len(pre)..];
    if len(rest) == 0 {
        return -1;
    }
    let n = 0;
    let i = 0;
    while i < len(rest) {
        let c = rest[i];
        if c < 48 || c > 57 {
            return -1;
        }
        n = n * 10 + (c - 48);
        i = i + 1;
    }
    return n;
}

fn find_task(st: State, id: int) -> int {
    for i in 0..len(st.tasks) {
        if st.tasks[i].id == id {
            return i;
        }
    }
    return -1;
}

// ---- routes ----------------------------------------------------------

fn list_tasks(st: State) -> http.Response {
    lock(st);
    // Encode inside the lock: the list must not be mutated mid-encode.
    let body: str = json.encode(st.tasks);
    unlock(st);
    return http.ok_json(body);
}

fn create_task(st: State, req: http.Request) -> http.Response {
    let r: result[NewTask, str] = json.decode(req.body);
    guard let nt = r else let e = err_of(r) {
        return http.bad_request("invalid JSON: " + e);
    }
    if len(nt.title) == 0 {
        return http.bad_request("title is required");
    }
    lock(st);
    let t = Task {
        id: st.next_id,
        title: nt.title,
        done: nt.done ?? false
    };
    st.next_id = st.next_id + 1;
    push(st.tasks, t);
    unlock(st);
    return http.created_json(json.encode(t));
}

fn update_task(st: State, req: http.Request, id: int) -> http.Response {
    let r: result[NewTask, str] = json.decode(req.body);
    guard let nt = r else let e = err_of(r) {
        return http.bad_request("invalid JSON: " + e);
    }
    if len(nt.title) == 0 {
        return http.bad_request("title is required");
    }
    lock(st);
    let i = find_task(st, id);
    if i < 0 {
        unlock(st);
        return http.not_found();
    }
    let t = Task { id: id, title: nt.title, done: nt.done ?? false };
    st.tasks[i] = t;
    unlock(st);
    return http.ok_json(json.encode(t));
}

fn route(st: State, req: http.Request) -> http.Response {
    if req.path == "/" {
        if req.method == "GET" {
            return http.ok_html(index_html());
        }
        return http.method_not_allowed();
    }
    if req.path == "/api/tasks" {
        if req.method == "GET" {
            return list_tasks(st);
        }
        if req.method == "POST" {
            return create_task(st, req);
        }
        return http.method_not_allowed();
    }
    let id = path_id(req.path, "/api/tasks/");
    if id >= 0 {
        if req.method == "PUT" {
            return update_task(st, req, id);
        }
        return http.method_not_allowed();
    }
    return http.not_found();
}

// ---- connection handling ---------------------------------------------

// One connection, kept alive for as many requests as the client sends.
// `filled` carries any bytes of the NEXT request that arrived in the
// same read as this one -- dropping it would corrupt pipelined requests.
fn handle_conn(st: State, c: link) {
    let ra = arena_new(65536);
    let sa = arena_new(65536);
    let buf = ra.wire(65536);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else {
            return;                  // client hung up, or sent nonsense
        }
        let wr = http.write(&mut c, route(st, got.req), &mut sa,
                            until_never());
        guard let _n = wr else {
            return;
        }
        sa.reset();                  // reuse the send arena per request
        if http.wants_close(got.req) {
            return;
        }
        filled = got.filled;
    }
}

fn worker(st: State, work: chan[link]) {
    while true {
        let v = chan_recv(work);
        guard let c = v else { return; }
        handle_conn(st, c);
    }
}

// One acceptor only: link.accept parks on the reactor, and two tasks
// waiting on the same fd and direction silently orphan the first.
fn accept_loop(ln: link, work: chan[link]) {
    while !proc.shutdown_requested() {
        let ar = ln.accept(until_never());
        guard let c = ar else { return; }
        chan_send(work, c);
    }
}

// ---- browser client --------------------------------------------------

fn index_html() -> str {
    // One slang string per line, concatenated. slang has no multi-line
    // string literal, and the embedded JS deliberately avoids backtick
    // template literals because their ${...} would collide with slang's
    // own ${...} interpolation in this very file.
    let head = "<!doctype html>\n"
        + "<html><head><meta charset=\"utf-8\"><title>samplex</title>\n"
        + "<style>\n"
        + " body{font:15px/1.5 system-ui,sans-serif;max-width:44rem;"
        + "margin:3rem auto;padding:0 1rem}\n"
        + " h1{font-size:1.3rem} li{margin:.3rem 0}\n"
        + " input,button{padding:.4rem;font:inherit}\n"
        + " button{cursor:pointer}\n"
        + " .done{text-decoration:line-through;opacity:.55}\n"
        + " code{background:#f2f2f2;padding:.1rem .3rem;border-radius:3px}\n"
        + "</style></head><body>\n";

    let body = "<h1>samplex</h1>\n"
        + "<p>A slang REST server. <code>GET|POST /api/tasks</code>, "
        + "<code>PUT /api/tasks/&#123;id&#125;</code></p>\n"
        + "<form id=\"f\"><input id=\"t\" placeholder=\"new task\" "
        + "size=\"30\" autofocus> <button>add</button></form>\n"
        + "<ul id=\"list\"></ul>\n";

    let js = "<script>\n"
        + "const list = document.getElementById('list');\n"
        + "async function load() {\n"
        + "  const r = await fetch('/api/tasks');\n"
        + "  const tasks = await r.json();\n"
        + "  list.innerHTML = '';\n"
        + "  for (const t of tasks) {\n"
        + "    const li = document.createElement('li');\n"
        + "    const s = document.createElement('span');\n"
        + "    s.textContent = ' #' + t.id + ' ' + t.title + ' ';\n"
        + "    if (t.done) s.className = 'done';\n"
        + "    const b = document.createElement('button');\n"
        + "    b.textContent = t.done ? 'undo' : 'done';\n"
        + "    b.onclick = async () => {\n"
        + "      await fetch('/api/tasks/' + t.id, {\n"
        + "        method: 'PUT',\n"
        + "        headers: {'content-type': 'application/json'},\n"
        + "        body: JSON.stringify({title: t.title, done: !t.done})\n"
        + "      });\n"
        + "      load();\n"
        + "    };\n"
        + "    li.append(s, b);\n"
        + "    list.append(li);\n"
        + "  }\n"
        + "}\n"
        + "document.getElementById('f').onsubmit = async (e) => {\n"
        + "  e.preventDefault();\n"
        + "  const t = document.getElementById('t');\n"
        + "  if (!t.value.trim()) return;\n"
        + "  await fetch('/api/tasks', {\n"
        + "    method: 'POST',\n"
        + "    headers: {'content-type': 'application/json'},\n"
        + "    body: JSON.stringify({title: t.value})\n"
        + "  });\n"
        + "  t.value = '';\n"
        + "  load();\n"
        + "};\n"
        + "load();\n"
        + "</script></body></html>\n";

    return head + body + js;
}

// ---- startup ---------------------------------------------------------

let lock_ch: chan[bool] = make_chan(1);
chan_send(lock_ch, true);            // the single token: unlocked

let seed: [Task] = [];
let st = State { tasks: seed, next_id: 1, lock: lock_ch };

let port = atoi(proc.getenv("PORT") ?? "8080");
let workers = atoi(proc.getenv("WORKERS") ?? "64");

let lr = link_listen(port);
guard let ln = lr else {
    log.error("cannot listen on port " + to_str(port));
    exit(1);
}

let work: chan[link] = make_chan(256);
spawn accept_loop(ln, work);
for i in 0..workers {
    spawn worker(st, work);
}

println("samplex listening on http://localhost:" + to_str(port));
println("  GET  /api/tasks");
println("  POST /api/tasks       {\"title\":\"...\"}");
println("  PUT  /api/tasks/{id}  {\"title\":\"...\",\"done\":true}");

// Acceptor and workers do the real work; this task just waits for a
// signal, then lets in-flight connections drain.
while !proc.shutdown_requested() {
    time.sleep(50000000);
}
println("");
println("shutting down; draining in-flight connections...");
chan_close(work);
while proc.active_tasks() > 0 {
    time.sleep(20000000);
}
println("bye");
