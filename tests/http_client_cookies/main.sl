// httpc cookie jar (RFC 6265, with 6265bis's Secure rules).
//
// The jar is OFF by default -- a server's Client is usually shared across
// the users it serves, and a jar there would send one user's session on
// another's request -- so every case below that expects cookies calls
// enable_cookies first, and the first case checks that nothing is kept
// without it.
//
// Expected cookie-date values were computed with Python's
// calendar.timegm, not with the parser under test.

import "net";
import "time";
import "strings";
import "httpc";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(got: str, want: str, what: str) {
    if got != want {
        die(what + ": got [" + got + "] want [" + want + "]");
    }
}

// ---- cookie dates -------------------------------------------------------

fn date_is(s: str, want: int, what: str) {
    expect(to_str(httpc.parse_cookie_date(s)), to_str(want), what);
}

date_is("Wed, 21 Oct 2037 07:28:00 GMT", 2139722880000000000, "RFC 1123");
date_is("Wednesday, 21-Oct-37 07:28:00 GMT", 2139722880000000000, "RFC 850, two-digit year");
date_is("Wed Oct 21 07:28:00 2037", 2139722880000000000, "asctime");
date_is("Thu, 01 Jan 1970 00:00:00 GMT", 0, "the epoch");
date_is("01 Jan 69 00:00:00", 3124224000000000000, "two-digit 69 is 2069");
date_is("Fri, 31 Dec 99 23:59:59 GMT", 946684799000000000, "two-digit 99 is 1999");
date_is("29 Feb 2024 00:00:00", 1709164800000000000, "leap day");
date_is("30 Feb 2024 00:00:00", -1, "no 30 February");
date_is("29 Feb 2023 00:00:00", -1, "no leap day in 2023");
date_is("21 Oct 2037 24:00:00", -1, "hour 24");
date_is("21 Oct 1600 00:00:00", -1, "before 1601");
date_is("not a date", -1, "garbage");
date_is("21 Oct 2037", -1, "no time");
println("cookie dates parse in all three historical formats, and refuse impossible ones");

// ---- server --------------------------------------------------------------

fn find_head_end(b: bytes) -> int {
    let i = 0;
    while i + 3 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

gc struct Req {
    path: str,
    cookie: str,
}

fn read_one(fd: i32) -> opt[Req] {
    let buf = b"";
    while find_head_end(buf) < 0 {
        let rr = net.recv(fd, 4096);
        guard let got = rr else { return none; }
        if len(got) == 0 {
            return none;
        }
        buf = buf + got;
    }
    let head = to_str(buf[0..find_head_end(buf)]);
    let parts = strings.split(strings.slice(head, 0, strings.find(head, "\r\n")), " ");
    let cookie = "none";
    let lower = strings.to_lower(head);
    let at = strings.find(lower, "\r\ncookie:");
    if at >= 0 {
        let after = strings.slice(head, at + 9, len(head));
        let eol = strings.find(after, "\r");
        if eol < 0 {
            eol = len(after);
        }
        cookie = strings.trim(strings.slice(after, 0, eol));
    }
    return some(Req { path: parts[1], cookie: cookie });
}

fn answer(fd: i32, set: [str], body: str) {
    let h = "HTTP/1.1 200 OK\r\n";
    for sc in set {
        h = h + "Set-Cookie: " + sc + "\r\n";
    }
    net.send(fd, to_bytes(h + "Content-Length: " + to_str(len(body)) + "\r\n\r\n" + body));
}

fn redirect(fd: i32, to: str, set: str) {
    net.send(fd, to_bytes("HTTP/1.1 302 Found\r\nLocation: " + to +
                          "\r\nSet-Cookie: " + set +
                          "\r\nContent-Length: 0\r\n\r\n"));
}

fn one(s: str) -> [str] {
    return [s];
}

fn conn_loop(fd: i32, port: int) {
    let none_set: [str] = [];
    while true {
        let rq = read_one(fd);
        guard let r = rq else {
            net.close(fd);
            return;
        }
        let p = r.path;
        if strings.has_suffix(p, "/echo") {
            answer(fd, none_set, r.cookie);
        } else if p == "/set-two" {
            // The comma inside Expires is the point: joined with ", ",
            // these two lines could not be split apart again.
            answer(fd, ["a=1; Path=/",
                        "b=2; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/"], "ok");
        } else if p == "/p/set" {
            answer(fd, one("c=3"), "ok");                 // default path /p
        } else if p == "/order" {
            answer(fd, ["x=1; Path=/", "y=2; Path=/p"], "ok");
        } else if p == "/del-a" {
            answer(fd, one("a=; Max-Age=0; Path=/"), "ok");
        } else if p == "/del-b" {
            answer(fd, one("b=gone; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Path=/"), "ok");
        } else if p == "/replace-a" {
            answer(fd, one("a=9; Path=/"), "ok");
        } else if p == "/maxage-wins" {
            // Max-Age wins over Expires even when Expires comes last
            answer(fd, one("m=1; Max-Age=0; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/"), "ok");
        } else if p == "/secure-over-http" {
            answer(fd, one("s=1; Secure; Path=/"), "ok");
        } else if p == "/foreign-domain" {
            answer(fd, one("e=1; Domain=evil.example; Path=/"), "ok");
        } else if p == "/tld-domain" {
            answer(fd, one("t=1; Domain=com; Path=/"), "ok");
        } else if p == "/host-prefix" {
            answer(fd, one("__Host-x=1; Path=/"), "ok");  // no Secure
        } else if p == "/oversized" {
            answer(fd, one("big=" + strings.repeat("v", 5000) + "; Path=/"), "ok");
        } else if p == "/nameless" {
            answer(fd, one("justavalue; Path=/"), "ok");
        } else if p == "/login" {
            redirect(fd, "/home/echo", "session=abc; Path=/");
        } else if p == "/cross-login" {
            // sets a host-only cookie for 127.0.0.1, then sends the client
            // to localhost -- the same machine under a different host name
            redirect(fd, "http://localhost:" + to_str(port) + "/echo", "h=1; Path=/");
        } else {
            net.send(fd, b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        }
    }
}

fn serve(lfd: i32, port: int) {
    while true {
        let ar = net.accept(lfd);
        guard let cfd = ar else { return; }
        spawn conn_loop(cfd, port);
    }
}

let lr = net.listen(0);
guard let lfd = lr else { die("listen"); }
let pr = net.port(lfd);
guard let port = pr else { die("port"); }
spawn serve(lfd, port);
let base = "http://127.0.0.1:" + to_str(port);

fn dl() -> until {
    return until_of(time.mono() + 10000000000);
}

fn get(c: httpc.Client, url: str) -> httpc.Response {
    let r = httpc.client_get(c, url, dl());
    guard let resp = r else let e = err_of(r) { die(url + ": " + e); }
    return resp;
}

fn body(c: httpc.Client, url: str) -> str {
    return to_str(get(c, url).body);
}

fn jar_client() -> httpc.Client {
    let c = httpc.new_client();
    httpc.enable_cookies(c);
    return c;
}

// ---- off by default --------------------------------------------------------

let plain = httpc.new_client();
get(plain, base + "/set-two");
expect(body(plain, base + "/echo"), "none", "a client without a jar sends nothing");
println("the jar is off unless enable_cookies is called");

// ---- storing and sending -----------------------------------------------------

let c1 = jar_client();
let two = get(c1, base + "/set-two");
expect(to_str(len(two.set_cookies)), "2", "two Set-Cookie lines stay two entries");
if !strings.contains(two.set_cookies[1], "Expires=Wed, 21 Oct 2037") {
    die("the Expires comma survived intact: " + two.set_cookies[1]);
}
expect(body(c1, base + "/echo"), "a=1; b=2", "both cookies sent back");
println("Set-Cookie lines with Expires commas are kept apart, and both cookies return");

// replacement keeps the ORIGINAL position (RFC 6265 5.3 step 11)
get(c1, base + "/replace-a");
expect(body(c1, base + "/echo"), "a=9; b=2", "replaced cookie keeps its place");

// deletion by Max-Age=0, and by an Expires in the past
get(c1, base + "/del-a");
expect(body(c1, base + "/echo"), "b=2", "Max-Age=0 deletes");
get(c1, base + "/del-b");
expect(body(c1, base + "/echo"), "none", "an Expires in the past deletes");
println("replacement keeps order; Max-Age=0 and a past Expires both delete");

let cm = jar_client();
get(cm, base + "/maxage-wins");
expect(body(cm, base + "/echo"), "none", "Max-Age wins over a later Expires");

// ---- paths ---------------------------------------------------------------

let cp = jar_client();
get(cp, base + "/p/set");
expect(body(cp, base + "/echo"), "none", "a /p cookie is not sent to /");
expect(body(cp, base + "/p/echo"), "c=3", "a /p cookie is sent to /p/...");
expect(body(cp, base + "/pathx/echo"), "none", "a /p cookie is NOT sent to /pathx");
println("default path is the request's directory, and /p does not match /pathx");

let co = jar_client();
get(co, base + "/order");
expect(body(co, base + "/p/echo"), "y=2; x=1", "longer path first");
println("more specific paths are sent first");

// ---- refusals ------------------------------------------------------------
//
// Each rule is checked by looking at the jar FROM THE URL THAT WOULD EXPOSE
// A WRONGLY STORED COOKIE. The first version of this section looked from
// the host that sent it, over http, and every security refusal passed
// with its check deleted: a stored Secure cookie is still not SENT over
// http, and a stored evil.example cookie does not match 127.0.0.1. The
// storage bug was real and the test could not see it.
//
// set_cookie applies a Set-Cookie line exactly as a response would, which
// is what lets these use real-looking hosts without a network.

fn stored_for(c: httpc.Client, url: str) -> str {
    let out = "";
    for ck in httpc.cookies(c, url) {
        if out != "" {
            out = out + "; ";
        }
        out = out + ck.name + "=" + ck.value;
    }
    if out == "" {
        return "none";
    }
    return out;
}

let cs = jar_client();
httpc.set_cookie(cs, "http://a.example.com/", "s=1; Secure; Path=/");
expect(stored_for(cs, "https://a.example.com/"), "none", "a Secure cookie from http:// is not stored");
httpc.set_cookie(cs, "https://a.example.com/", "s=2; Secure; Path=/");
expect(stored_for(cs, "https://a.example.com/"), "s=2", "a Secure cookie from https:// is stored");
expect(stored_for(cs, "http://a.example.com/"), "none", "...and never sent over http");
println("Secure cookies: only set from https, only sent to https");

let cd = jar_client();
httpc.set_cookie(cd, "http://a.example.com/", "e=1; Domain=evil.example; Path=/");
expect(stored_for(cd, "http://evil.example/"), "none", "a cookie for a foreign domain is not stored");
httpc.set_cookie(cd, "http://a.example.com/", "t=1; Domain=com; Path=/");
expect(stored_for(cd, "http://other.com/"), "none", "a cookie for a bare TLD is not stored");
httpc.set_cookie(cd, "http://1.2.3.4/", "i=1; Domain=2.3.4; Path=/");
expect(stored_for(cd, "http://9.2.3.4/"), "none", "an IP address has no parent domain");
println("refused: a foreign Domain, a bare TLD, and a Domain that is part of an IP address");

let cdom = jar_client();
httpc.set_cookie(cdom, "http://a.example.com/", "p=1; Domain=.example.com; Path=/");
httpc.set_cookie(cdom, "http://a.example.com/", "q=1; Path=/");
expect(stored_for(cdom, "http://b.example.com/"), "p=1", "a Domain cookie reaches siblings; a host-only one does not");
expect(stored_for(cdom, "http://a.example.com/"), "p=1; q=1", "both reach the host that set them");
println("Domain=.example.com is shared with siblings; a host-only cookie is not");

fn refused_line(url: str, line: str, look: str, what: str) {
    let c = jar_client();
    httpc.set_cookie(c, url, line);
    expect(to_str(len(httpc.cookies(c, look))), "0", what);
}

refused_line("http://a.example.com/", "__Host-x=1; Path=/", "https://a.example.com/", "__Host- without Secure");
refused_line("https://a.example.com/", "__Host-x=1; Secure; Domain=example.com; Path=/", "https://a.example.com/", "__Host- with a Domain");
refused_line("http://a.example.com/", "big=" + strings.repeat("v", 5000) + "; Path=/", "http://a.example.com/", "over 4096 bytes");
refused_line("http://a.example.com/", "justavalue; Path=/", "http://a.example.com/", "no '='");
println("refused: __Host- without Secure or with a Domain, oversized, nameless");

// And one refusal through a real response, so the network path is not
// only ever exercised by cookies that succeed.
let cn = jar_client();
get(cn, base + "/oversized");
expect(to_str(len(httpc.cookies(cn, base + "/"))), "0", "oversized cookie in a real response");

// ---- redirects -----------------------------------------------------------

// A cookie set BY the redirect reaches the page it points to. This is
// how nearly every login works.
let cl = jar_client();
expect(body(cl, base + "/login"), "session=abc", "cookie set by a 302 is sent to its target");

// Host-only means the exact host. 127.0.0.1 and localhost are the same
// machine and different cookie scopes.
let cx = jar_client();
expect(body(cx, base + "/cross-login"), "none", "a host-only cookie does not follow to another host");
expect(to_str(len(httpc.cookies(cx, base + "/"))), "1", "...but was stored for the host that set it");
println("cookies set by a redirect apply to its target, and host-only cookies stay on their host");

// ---- a caller's own Cookie header is kept, and the jar's appended -------

let ch = jar_client();
get(ch, base + "/set-two");
let rq = httpc.new_request("GET", base + "/echo");
rq.headers["Cookie"] = "mine=1";
let rr = httpc.client_send(ch, rq, dl());
guard let mixed = rr else let e = err_of(rr) { die("caller cookie: " + e); }
expect(to_str(mixed.body), "mine=1; a=1; b=2", "caller's Cookie first, jar's after");
println("a caller's own Cookie header is kept and the jar's cookies appended");

httpc.clear_cookies(ch);
expect(body(ch, base + "/echo"), "none", "clear_cookies empties the jar");

// ---- concurrent writers --------------------------------------------------
//
// Storing is read-filter-write on the jar list. Without the client's lock,
// two tasks storing at once each rebuild the list from the same snapshot
// and one of the two cookies is silently lost.

fn setter(c: httpc.Client, n: int) -> int {
    let i = 0;
    while i < 3 {
        httpc.set_cookie(c, "http://a.example.com/",
                         "k" + to_str(n) + "_" + to_str(i) + "=v; Path=/");
        i = i + 1;
    }
    return 3;
}

let cc = jar_client();
let hs: [join[int]] = [];
let n = 0;
while n < 16 {
    push(hs, spawn setter(cc, n));
    n = n + 1;
}
for h in hs {
    let jr = join_wait(h);
    guard let _v = jr else { die("a setter panicked"); }
}
// 48 distinct cookies, deliberately UNDER the 50-per-domain cap. The first
// version wrote 400 and expected the cap, which could not see a lost
// update: later writes simply refilled the jar to 50.
expect(to_str(len(httpc.cookies(cc, "http://a.example.com/"))), "48",
       "16 concurrent writers x 3 cookies, none lost");
println("16 concurrent writers store 48 cookies and lose none");

println("done");
exit(0);
