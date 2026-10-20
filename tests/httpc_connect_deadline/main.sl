// A connect that never completes (an address that drops SYNs) must give
// up at the caller's deadline, not the OS connect timeout (over a minute
// on macOS): httpc dialled with net.dial and net.tls_dial, which took
// none. Networks that reject the address outright answer even sooner;
// either way each call returns an error well inside the bound.
import "httpc";
import "net";
import "time";

fn elapsed_ms(t0: duration) -> int {
    return ((time.mono() - t0) as int) / 1000000;
}

fn bounded(what: str, ms: int) {
    if ms > 2500 {
        println("FAIL " + what + " took " + to_str(ms) + " ms with a 300 ms deadline");
        exit(1);
    }
}

let host = "10.255.255.1";

let t0 = time.mono();
let d = net.dial_until(host, 81, until_of(time.mono() + 300000000));
if let _fd = d { println("FAIL dial reached " + host); exit(1); }
bounded("net.dial_until", elapsed_ms(t0));

let cr = net.tls_client_ctx("");
guard let ctx = cr else let e = err_of(cr) { println("FAIL tls ctx: " + e); exit(1); }
let t1 = time.mono();
let td = net.tls_dial_until(host, 443, ctx, until_of(time.mono() + 300000000));
if let _s = td { println("FAIL tls dial reached " + host); exit(1); }
bounded("net.tls_dial_until", elapsed_ms(t1));

for url in ["http://" + host + ":81/", "https://" + host + "/"] {
    let t2 = time.mono();
    let r = httpc.get(url, until_of(time.mono() + 300000000));
    if let _resp = r { println("FAIL " + url + " answered"); exit(1); }
    bounded("httpc.get " + url, elapsed_ms(t2));
}
println("connect deadlines hold");
