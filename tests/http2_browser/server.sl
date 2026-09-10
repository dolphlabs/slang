// An HTTP/2 server for a REAL BROWSER, driven by tests/http2_browser/run.sh.
//
// Not part of `make test`: it needs Chrome. Run it by hand, or run the
// server alone and open https://localhost:8443/ yourself.
//
// TLS with ALPN, because that is the only way a browser will speak h2:
// there is no in-band upgrade in a browser, so h2c is unreachable from
// the address bar no matter how conformant it is.
//
// The page pulls six deliberately-slow sub-resources so multiplexing is
// visible in DevTools: on HTTP/1.1 the browser would open six sockets
// or queue them; here they all ride one connection and land together.

import "http2";
import "log";
import "net";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

fn page() -> str {
    return "<!doctype html>\n"
        + "<html><head><meta charset=\"utf-8\"><title>slang over h2</title>\n"
        + "<style>\n"
        + " body{font:16px/1.6 system-ui,sans-serif;max-width:40rem;"
        + "margin:4rem auto;padding:0 1rem}\n"
        + " .ok{color:#0a7d32;font-weight:600}\n"
        + " li{margin:.2rem 0} code{background:#f1f1f1;padding:.1rem .3rem}\n"
        + "</style></head><body>\n"
        + "<h1>Served by slang over <span class=\"ok\">HTTP/2</span></h1>\n"
        + "<p>Your browser negotiated <code>h2</code> via ALPN, then sent a\n"
        + "connection preface and HPACK-compressed headers. Everything you\n"
        + "are reading was framed, compressed and flow-controlled by\n"
        + "<code>stdlib/http2/</code>.</p>\n"
        + "<p>The six items below each sleep 300ms on the server. They are\n"
        + "fetched on <strong>one</strong> connection, concurrently &mdash;\n"
        + "open DevTools &rarr; Network and check the Protocol column says\n"
        + "<code>h2</code>, and that the waterfall shows them overlapping\n"
        + "rather than queued.</p>\n"
        + "<ul id=\"out\"></ul>\n"
        + "<p id=\"timing\"></p>\n"
        + "<script>\n"
        + "const out = document.getElementById('out');\n"
        + "const t0 = performance.now();\n"
        + "const urls = ['/slow/1','/slow/2','/slow/3',"
        + "'/slow/4','/slow/5','/slow/6'];\n"
        + "Promise.all(urls.map(async u => {\n"
        + "  const r = await fetch(u);\n"
        + "  const t = await r.text();\n"
        + "  const li = document.createElement('li');\n"
        + "  li.textContent = u + ' -> ' + t;\n"
        + "  out.append(li);\n"
        + "})).then(() => {\n"
        + "  const ms = Math.round(performance.now() - t0);\n"
        + "  document.getElementById('timing').textContent =\n"
        + "    'six 300ms requests finished in ' + ms + 'ms "
        + "(serialised would be ~1800ms)';\n"
        + "});\n"
        + "</script></body></html>\n";
}

fn handle(stream: i32, path: str, wch: chan[http2.WMsg]) {
    let ct = "text/plain; charset=utf-8";
    let body = b"";
    let status = "200";

    if path == "/" {
        ct = "text/html; charset=utf-8";
        body = to_bytes(page());
    } else {
        if path == "/favicon.ico" {
            status = "404";
        } else {
            // Every /slow/N sleeps, so the browser's waterfall shows
            // whether they really overlapped.
            time.sleep(ms(300));
            body = to_bytes("done after 300ms");
        }
    }

    let extra: [http2.Header] = [
        http2.Header { name: "content-type", value: ct },
        http2.Header { name: "cache-control", value: "no-store" }
    ];
    chan_send(wch, http2.response_msg(stream as int, status, extra, body));
}

fn serve(ssl: rawptr, n: int) {
    let proto = net.tls_alpn(ssl);
    if !http2.alpn_is_h2(proto) {
        log.warn("conn ${n}: peer chose \"" + proto + "\", not h2 -- closing");
        net.tls_close(ssl);
        return;
    }
    log.info("conn ${n}: ALPN negotiated h2");

    let t = http2.transport_tls(ssl);
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(64);
    let lim = http2.default_limits();
    spawn http2.writer_task(t, wch, lim.write);

    let pr = http2.accept_preface(rd, t, wch,
                                  until_of(time.mono() + lim.handshake));
    guard let _p = pr else let e = err_of(pr) {
        // Browsers PRECONNECT: Chrome opens a spare TLS connection,
        // sends nothing, and closes it if the page did not need it.
        // That is ordinary behaviour, not a fault, and logging it at
        // error level would train everyone to ignore the level.
        if e == "connection closed before preface" {
            log.info("conn ${n}: peer connected and left (preconnect)");
            net.tls_close(ssl);
            return;
        }
        log.error("conn ${n}: preface: " + e);
        chan_close(wch);
        http2.tr_close(t);
        return;
    }

    while true {
        let rr = http2.read_request(cn, rd, t, wch, lim);
        guard let req = rr else let e = err_of(rr) {
            if http2.is_timeout(e) {
                log.info("conn ${n}: idle timeout, closing");
            } else {
                log.info("conn ${n}: " + e);
            }
            chan_close(wch);
            http2.tr_close(t);
            return;
        }
        log.info("conn ${n}: stream ${req.stream} " + req.method + " " + req.path);
        spawn handle(req.stream as i32, req.path, wch);
    }
}

fn run() {
    let sr = net.tls_server_ctx("cert.pem", "key.pem");
    guard let sctx = sr else let e = err_of(sr) {
        println("tls ctx: " + e);
        exit(1);
    }
    // Offer h2 first, http/1.1 as a fallback -- exactly what a real
    // server advertises. A browser will pick h2.
    let ar = net.tls_ctx_alpn(sctx, "h2,http/1.1");
    guard let _a = ar else let e = err_of(ar) {
        println("alpn: " + e);
        exit(1);
    }

    let lr = net.listen(8443);
    guard let lfd = lr else let e = err_of(lr) {
        println("listen: " + to_str(e));
        exit(1);
    }
    log.info("open https://localhost:8443/  (self-signed: click through)");

    let n = 0;
    while true {
        let ac = net.tls_accept(lfd, sctx);
        guard let ssl = ac else let e = err_of(ac) {
            println("accept: " + e);
            continue;
        }
        n = n + 1;
        spawn serve(ssl, n);
    }
}

run();
