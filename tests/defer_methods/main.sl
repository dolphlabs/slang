struct Counter {
    n: int,
}

impl Counter {
    fn inc(self: &mut Counter) {
        self.n += 1;
    }

    fn show(self: &Counter) {
        println("show=" + to_str(self.n));
    }
}

struct Holder {
    c: Counter,
}

struct OwnRes {
    id: int,
}

impl OwnRes {
    fn close(self: &mut OwnRes) {
        println("own_close=" + to_str(self.id));
    }

    fn show(self: &OwnRes) {
        println("own_show=" + to_str(self.id));
    }
}

struct Box {
    n: int,
}

fn make_counter(n: int) -> Counter {
    return Counter { n: n };
}

fn make_own(id: int) -> own OwnRes {
    return OwnRes { id: id };
}

fn touch_own(b: &own Box) {
    println("touch_own=" + to_str((*b).n));
}

fn test_value_struct_methods() {
    let c = Counter { n: 10 };
    defer c.inc();
    println("val_before=" + to_str(10));

    let c2 = Counter { n: 22 };
    defer c2.show();
    println("val_read=" + to_str(c2.n));

    let c3 = Counter { n: 30 };
    let rc = &mut c3;
    defer rc.inc();

    let h = Holder { c: Counter { n: 40 } };
    defer h.c.inc();
    println("holder=" + to_str(40));

    defer make_counter(5).inc();
    defer make_own(9).close();
}

fn own_close_and_return() -> own OwnRes {
    let r: own OwnRes = OwnRes { id: 21 };
    r.close();
    return r;
}

fn test_own_struct_methods() {
    let r1: own OwnRes = OwnRes { id: 7 };
    defer r1.close();

    let r2: own OwnRes = OwnRes { id: 8 };
    defer r2.show();
    println("r2_id=" + to_str(r2.id));

    let r3: own OwnRes = OwnRes { id: 15 };
    r3.close();
    r3.show();
    println("r3_after=" + to_str(r3.id));

    let r4 = own_close_and_return();
    println("r4_ret=" + to_str(r4.id));
}

fn test_ref_own_no_warn() {
    let b: own Box = Box { n: 9 };
    touch_own(&b);
    defer touch_own(&b);
}

fn test_switch_if_defer_break(x: int, cond: bool) -> int {
    let res = 0;
    switch x {
        case 1 {
            if cond {
                defer println("sw_if_defer");
                res = 10;
                break;
            }
            res = 20;
        }
        default {
            res = 30;
        }
    }
    return res;
}

fn test_trip_defer() {
    let t = trip_new();
    defer t.pull();
    if t.down() {
        println("FAIL trip down early");
        exit(1);
    }
    let rt = &t;
    defer rt.pull();
}

fn send_bye_on_defer(s: link) {
    defer s.send_static(b"bye", until_never());
}

fn test_link_send_static_defer() {
    let lr = link_listen(0);
    guard let ln = lr else { println("FAIL listen"); exit(1); }
    let port = ln.port();
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { println("FAIL dial"); exit(1); }
    let ar = ln.accept(until_never());
    guard let s = ar else { println("FAIL accept"); exit(1); }

    send_bye_on_defer(s);

    let a = arena_new(64);
    let w = a.wire(16);
    let rr = c.recv(w, until_never());
    guard let n = rr else { println("FAIL recv"); exit(1); }
    if n != 3 {
        println("FAIL recv len=" + to_str(n));
        exit(1);
    }
    println("link_msg=" + to_str(w[0..n]));
}

test_value_struct_methods();
test_own_struct_methods();
test_ref_own_no_warn();
println("sw=" + to_str(test_switch_if_defer_break(1, true)));
test_trip_defer();
test_link_send_static_defer();
