import "http";
import "proc";
import "time";

fn serve(c: link) {
    let ra = arena_new(16384);
    let sa = arena_new(16384);
    let buf = ra.wire(8192);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let body = "<html><body><h1>Hello from slang</h1>"
            + "<p>served by the slang http package</p></body></html>";
        let wr = http.write(&mut c, http.ok_html(body), &mut sa, until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) {
            return;
        }
        filled = got.filled;
    }
}

fn accept_and_serve(ln: &mut link) {
    let ar = ln.accept(until_never());
    guard let c = ar else { return; }
    spawn serve(c);
}

let lr = link_listen(8080);
guard let ln = lr else {
    println("could not listen on 8080");
    exit(1);
}
println("listening on http://localhost:8080");

while !proc.shutdown_requested() {
    accept_and_serve(&mut ln);
}

println("shutting down: waiting for in-flight connections to finish");
while proc.active_tasks() > 0 {
    time.sleep(20000000);
}
println("done");
