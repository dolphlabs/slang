import "time";
import "net";
import "json";
import "proc";

link "m";
extern fn fabs(x: float) -> float;

pub struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        self.x + self.y
    }

    fn add(self: &mut Point, dx: int, dy: int) {
        self.x = self.x + dx;
        self.y = self.y + dy;
    }
}

struct Holder<'a> {
    r: &'a int,
}

gc struct Line {
    text: str,
    n: i32,
    extra: opt[str],
}

fn first<'a, 'b>(x: &'a int, y: &'b int) -> &'a int {
    return x;
}

fn abs_i(n: int) -> int {
    guard n >= 0 else {
        return -n;
    }
    n
}

fn tenth(n: int) -> opt[int] {
    if n % 10 == 0 {
        return some(n / 10);
    }
    return none;
}

fn parse_n(s: str) -> result[i32, str] {
    if s == "ok" {
        return ok(7);
    }
    return err("bad:" + s);
}

fn bump(p: &mut int) {
    *p = *p + 1;
}

fn take_own(p: own Point) -> int {
    return p.x + p.y;
}

fn raw_bump(p: *mut int) {
    unsafe {
        *p = *p + 1;
    }
}

fn ping(id: i32, ch: chan[i32]) {
    chan_send(ch, (id * 10) as i32);
}

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn values() {
    let name = "slang";
    let okb = true;
    let no = false;
    let w: i8 = 127;
    let u: u8 = 255;
    let s16: i16 = -1;
    let n32: i32 = 40;
    let n64: i64 = 2;
    let uu: u32 = 3;
    let u64v: u64 = 4;
    let f: f32 = 1.5;
    let pi = 3.14159;
    println("hello ${name} ${okb} ${no}");
    println(w);
    println(u);
    println(s16);
    println(widen(n32, n64));
    println(uu + (u64v as u32));
    println(f * 2.0);
    println("pi ${pi}");
    println(300 as i8);
    println(fabs(-3.5));
    println(abs_i(-7));
    print("range ");
    for i in 0..3 {
        print(i);
    }
    println("");
    for i in 1..=2 {
        println("tick ${i}");
    }
}

fn widen(a: i32, b: i64) -> i64 {
    a + b
}

fn opts_and_results() {
    println(tenth(40) ?? -1);
    println(tenth(41) ?? -1);
    println(parse_n("ok") ?? -1);
    println(parse_n("no") ?? -1);
    let r: result[i32, str] = parse_n("ok");
    guard let v = r else {
        fail("parse");
    }
    println(v);
    let missing: opt[int] = none;
    println(missing ?? 0);
}

fn collections() {
    let xs = [1, 2, 3];
    push(xs, 4);
    println(len(xs));
    println(xs[0]);
    xs[0] = 9;
    println(pop(xs));
    let tot = 0;
    for x in xs {
        tot = tot + x;
    }
    println(tot);
    println(len(xs[0..2]));
    println(len(xs[1..]));

    let raw = b"PING";
    println(len(raw));
    println(raw[0]);
    println(to_str(raw));
    println(len(to_bytes("hi")));
    println(from_le(to_le(258)));
    println(from_be(to_be(258)));
    for b in b"AB" {
        println(b);
    }

    let scores: map[str]int = {"ada": 90, "bob": 80};
    scores["cam"] = 70;
    println(has(scores, "ada"));
    del(scores, "bob");
    println(len(scores));
    let sum = 0;
    for _, n in scores {
        sum = sum + n;
    }
    println(sum);
}

fn owns_and_borrows() {
    let p = Point { x: 3, y: 4 };
    println(p.sum());
    let rp: &Point = &p;
    println(rp.x);
    let mutp: &mut Point = &mut p;
    mutp.add(1, 1);
    println(p.sum());

    let n = 10;
    let a = first(&n, &n);
    println(*a);
    let h = Holder { r: &n };
    println(*h.r);
    bump(&mut n);
    println(n);

    let boxed: gc Point = Point { x: 1, y: 2 };
    println(boxed.sum());

    let o: own Point = Point { x: 5, y: 6 };
    println(take_own(o));

    let x = 7;
    let raw: *mut int = &mut x;
    raw_bump(raw);
    let slot: i32 = 0;
    let typed: ptr[i32] = &mut slot;
    unsafe {
        *typed = 8;
        println(*raw);
        println(*typed);
    }
    let ro: *int = &x;
    unsafe {
        println(*ro);
    }
    if nullptr == nullptr {
        println("nullptr");
    }
    let buf = b"hi";
    if bytes_ptr(buf) != nullptr {
        println(len(buf));
    }
}

fn arena_wire() {
    let a = arena_new(64);
    let p: &mut int = a.alloc(3);
    *p = *p + 4;
    println(*p);
    let w = a.wire(4);
    w[0] = 65;
    w[1] = 66;
    println(len(w));
    println(w[0]);
    let view = w[0..2];
    print(view);
    println("");
    a.reset();
    let q = a.alloc(1);
    println(*q);
}

fn control() {
    let i = 0;
    while i < 4 {
        i = i + 1;
        if i == 2 {
            continue;
        }
        if i == 4 {
            break;
        }
        println(i);
    }
    if true && !false {
        println("bool");
    } else {
        fail("bool");
    }
}

fn tasks() {
    let ch: chan[i32] = make_chan(2);
    spawn ping(1, ch);
    spawn ping(2, ch);
    let got = 0;
    for _ in 0..2 {
        let msg = chan_recv(ch);
        guard let n = msg else { fail("chan"); }
        got = got + n;
    }
    chan_close(ch);
    println(got);
    println(proc.active_tasks() >= 0);
    println(proc.shutdown_requested());
    let path = proc.getenv("PATH") ?? "";
    println(len(path) > 0);
}

fn clocks() {
    let t0: duration = time.mono();
    time.sleep(1000000);
    let t1 = time.mono();
    println(t1 > t0);
    println(time.wall() > 0);
    println(until_hit(until_never()));
    println(until_hit(until_of(1)));
    let f = fault_timeout();
    println(fault_kind(f));
    println(f == fault_timeout());
    println(f);
    println(fault_reset());
    println(fault_closed());
    println(fault_io());
    println(fault_refused());
    let peer = peer_v4(127, 0, 0, 1, 8080);
    println(peer_port(peer));
    println(peer);
    let t = trip_new();
    println(t.down());
    t.pull();
    println(t.down());
}

fn codec() {
    let line = Line { text: "hi", n: 2, extra: some("x") };
    let s = json.encode(line);
    println(s);
    let back: result[Line, str] = json.decode(s);
    guard let v = back else { fail("json"); }
    println(v.text);
}

fn sockets() {
    let nr = net.listen(0);
    guard let nfd = nr else { fail("net.listen"); }
    let pr = net.port(nfd);
    guard let nport = pr else { fail("net.port"); }
    println(nport > 0);
    net.close(nfd);

    let lr = link_listen(0);
    guard let ln = lr else { fail("link_listen"); }
    let port = ln.port();
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { fail("dial"); }
    let pool = arena_new(128);
    let out = pool.wire(4);
    out[0] = 80;
    out[1] = 73;
    out[2] = 78;
    out[3] = 71;
    let sr = c.send(out, until_never());
    guard let n = sr else { fail("send"); }
    println(n);

    let ar = ln.accept(until_never());
    guard let s = ar else { fail("accept"); }
    let inp = pool.wire(16);
    let rr = s.recv(inp, until_never());
    guard let got = rr else { fail("recv"); }
    println(got);
    println(peer_port(s.peer()) > 0);

    let dead = s.recv(inp, until_of(time.mono()));
    guard let _z = dead else {
        println("timeout");
        return;
    }
    fail("expected timeout");
}

values();
opts_and_results();
collections();
owns_and_borrows();
arena_wire();
control();
tasks();
clocks();
codec();
sockets();
println("tour ok");
