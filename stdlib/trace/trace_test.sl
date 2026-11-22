import "net";
import "strings";
import "time";

fn test_should_parse_valid_traceparents_and_refuse_bad_ones() {
    let p = parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    guard let sc = p else { panic("valid header refused"); }
    assert(sc.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736" && sc.span_id == "00f067aa0ba902b7" && sc.sampled, "fields");
    let u = parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00");
    guard let us = u else { panic("unsampled refused"); }
    assert(!us.sampled, "flags 00 read as sampled");
    // a later version may carry more fields
    if let _f = parse_traceparent("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra") { } else { panic("future version refused"); }
    for bad in ["", "garbage", "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
                "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
                "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
                "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01",
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra",
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902bz-01"] {
        if let _x = parse_traceparent(bad) { panic("accepted " + bad); }
    }
}

fn test_should_start_roots_and_children_in_one_trace() {
    let t = tracer("svc", "");
    let root = start(t, "root", none);
    assert(len(root.ctx.trace_id) == 32 && len(root.ctx.span_id) == 16, "id lengths");
    assert(root.ctx.sampled && len(root.parent_span_id) == 0, "root");
    let c = child(root, "child");
    assert(c.ctx.trace_id == root.ctx.trace_id && c.parent_span_id == root.ctx.span_id, "child link");
    assert(c.ctx.span_id != root.ctx.span_id, "child reused the span id");
    let tp = traceparent(c);
    let back = parse_traceparent(tp);
    guard let b = back else { panic("own traceparent unparseable: " + tp); }
    assert(b.span_id == c.ctx.span_id, "round trip");
}

fn test_should_record_nothing_for_unsampled_traces() {
    let o = options();
    o.sample_ratio = 0.0;
    let t = tracer_with("svc", "", o);
    let s = start(t, "dropped", none);
    set_str(s, "k", "v");
    end(s);
    assert(!s.ctx.sampled && len(s.attrs) == 0 && len(drain(t)) == 0, "unsampled span kept");
    assert(strings.has_suffix(traceparent(s), "-00"), "unsampled flag");
}

fn test_should_queue_once_and_drop_past_max_queue() {
    let o = options();
    o.max_batch = 2;
    o.max_queue = 2;
    let t = tracer_with("svc", "", o);
    let a = start(t, "a", none);
    end(a);
    end(a);
    let b = start(t, "b", none);
    end(b);
    let c = start(t, "c", none);
    end(c);
    assert(len(drain(t)) == 2 && counts(t).dropped == 1, "queue bound");
}

fn test_should_encode_otlp_json() {
    let t = tracer("checkout", "");
    let s = start(t, "POST \"orders\"", none);
    set_kind(s, KIND_SERVER);
    set_str(s, "http.route", "/orders");
    set_int(s, "http.status_code", 201);
    set_float(s, "ratio", 0.5);
    set_bool(s, "cached", true);
    set_error(s, "boom");
    end(s);
    let j = to_str(encode_otlp(t, drain(t)));
    for want in ["{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"checkout\"}}]}",
                 "\"name\":\"POST \\\"orders\\\"\"", "\"kind\":2",
                 "{\"key\":\"http.route\",\"value\":{\"stringValue\":\"/orders\"}}",
                 "{\"key\":\"http.status_code\",\"value\":{\"intValue\":\"201\"}}",
                 "{\"key\":\"ratio\",\"value\":{\"doubleValue\":0.5}}",
                 "{\"key\":\"cached\",\"value\":{\"boolValue\":true}}",
                 "\"status\":{\"code\":2,\"message\":\"boom\"}"] {
        assert(strings.contains(j, want), "missing " + want + " in " + j);
    }
}

// A one-request-at-a-time collector: answers each POST with `status` and
// reports each body.
fn collector(lfd: i32, status: int, n: int, bodies: chan[str]) {
    for _ in 0..n {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        let buf = "";
        while true {
            let rr = net.recv_until(fd, 65536, until_of(time.mono() + 5000000000));
            guard let b = rr else { break; }
            if len(b) == 0 { break; }
            buf = buf + to_str(b);
            let he = strings.find(buf, "\r\n\r\n");
            if he >= 0 {
                let head = strings.to_lower(strings.slice(buf, 0, he));
                let cl = strings.find(head, "content-length:");
                if cl >= 0 {
                    let rest = strings.slice(head, cl + 15, len(head));
                    let line_end = strings.find(rest, "\r\n");
                    if line_end >= 0 { rest = strings.slice(rest, 0, line_end); }
                    let want = to_int(strings.trim(rest)) ?? 0;
                    if len(buf) - he - 4 >= want { break; }
                }
            }
        }
        let reason = "OK";
        if status != 200 { reason = "Error"; }
        let _s = net.send(fd, to_bytes("HTTP/1.1 " + to_str(status) + " " + reason +
                                       "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
        net.close(fd);
        chan_send(bodies, buf);
    }
}

fn test_should_export_to_a_collector() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let bodies: chan[str] = make_chan(4);
    spawn collector(lfd, 200, 1, bodies);
    let t = tracer("svc", "http://127.0.0.1:" + to_str(port) + "/");
    let s = start(t, "exported-span", none);
    end(s);
    let r = flush(t, until_of(time.mono() + 5000000000));
    assert((r ?? -1) == 1, "flush: " + err_of(r));
    let body = chan_recv(bodies) ?? "";
    assert(strings.has_prefix(body, "POST /v1/traces HTTP/1.1"), "request line: " + strings.slice(body, 0, 40));
    assert(strings.contains(strings.to_lower(body), "content-type: application/json"), "content type");
    assert(strings.contains(body, "exported-span"), "span not in body");
    assert(counts(t).exported == 1 && counts(t).queued == 0, "counts");
    net.close(lfd);
}

fn test_should_count_a_failed_export_as_dropped() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let bodies: chan[str] = make_chan(4);
    spawn collector(lfd, 503, 1, bodies);
    let t = tracer("svc", "http://127.0.0.1:" + to_str(port));
    end(start(t, "lost", none));
    let r = flush(t, until_of(time.mono() + 5000000000));
    if let _n = r { panic("503 counted as sent"); }
    let _b = chan_recv(bodies);
    let c = counts(t);
    assert(c.failures == 1 && c.dropped == 1 && c.last_error == "collector answered 503", "failure counts");
    net.close(lfd);
}
