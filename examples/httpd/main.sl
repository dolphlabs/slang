import "http";
import "proc";
import "time";

fn serve(c: link) {
    let a = arena_new(16384);
    let buf = a.wire(8192);
    let rr = http.read(&mut c, buf, until_never());
    guard let _req = rr else { return; }
    let body = "<html><body><h1>Hello from slang</h1>"
        + "<p>served by the slang http package</p></body></html>";
    let wr = http.write(&mut c, http.ok_html(body), &mut a, until_never());
    guard let _n = wr else { return; }
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
