
import "strings";

struct TagCounter {
    s: str,
    n: int,
}

impl TagCounter {
    fn inc_tag(self: &mut TagCounter, tag: str) {
        self.n += 1;
        self.s = self.s + tag;
    }
}

gc struct GcCounterHolder {
    c: TagCounter,
}

fn make_tag() -> str {
    return "-" + strings.repeat("t", 20);
}

fn test_ex_method_lvalue_and_gc() {
    let h = Holder { c: Counter { n: 0 } };
    h.c.inc();
    println("after_direct_inc=" + to_str(h.c.n));

    let p = &mut h;
    (*p).c.inc();
    println("after_ptr_inc=" + to_str(h.c.n));

    let c = Counter { n: 5 };
    (c).inc();
    println("after_paren_inc=" + to_str(c.n));

    let rh = &h;
    defer rh.c.show();

    let g = GcCounterHolder {
        c: TagCounter { s: "base-" + strings.repeat("b", 20), n: 0 },
    };
    g.c.inc_tag(make_tag());
    defer g.c.inc_tag(make_tag());
    for i in 0..300 {
        let _ = GcCounterHolder { c: TagCounter { s: strings.repeat("x", 16), n: i } };
    }
    println("gc_holder=" + to_str(g.c.n) + ":" + to_str(len(g.c.s)));
}

gc struct MutOut {
    v: int,
}

fn mark_mut(s: &mut int, out: MutOut) {
    *s += 10;
    out.v = *s;
}

fn test_switch_outer_defer_break_return(x: int, do_break: bool, out: MutOut) -> int {
    let s = 1;
    let res = 0;
    switch x {
        case 1 {
            defer mark_mut(&mut s, out);
            if do_break {
                break;
            }
            res = 100;
            return res;
        }
        default {
            res = 2;
        }
    }
    res = 50;
    return res;
}

fn take_own_box_m(b: own Box) -> int {
    return b.n;
}

fn test_switch_break_no_false_positive(x: int, do_break: bool) -> int {
    let b: own Box = Box { n: 55 };
    switch x {
        case 1 {
            if do_break {
                break;
            }
            return take_own_box_m(b) + 10;
        }
        default {
            return 20;
        }
    }
    return take_own_box_m(b) + 30;
}

fn test_nested_switch_defer_lifo(a: int, b: int, brk1: bool, brk2: bool) -> int {
    let res = 0;
    switch a {
        case 1 {
            defer println("outer_d1");
            switch b {
                case 2 {
                    defer println("inner_d2");
                    if brk2 {
                        break;
                    }
                    return 77;
                }
                default {
                    res = 5;
                }
            }
            if brk1 {
                res = 11;
                break;
            }
            return 88;
        }
        default {
            res = 99;
        }
    }
    return res;
}

fn opt_num(ok_flag: bool) -> opt[int] {
    if ok_flag {
        return some(3);
    }
    return none;
}

fn test_switch_guard_break_lifo(x: int, ok_flag: bool) -> int {
    let res = 0;
    switch x {
        case 1 {
            defer println("guard_outer");
            guard let v = opt_num(ok_flag) else {
                defer println("guard_else");
                break;
            }
            res = v * 10;
            return res;
        }
        default {
            res = 1;
        }
    }
    return res + 2;
}

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

test_ex_method_lvalue_and_gc();
let mo_t = MutOut { v: 0 };
let r_t = test_switch_outer_defer_break_return(1, true, mo_t);
println("sw_outer_brkT=" + to_str(r_t) + ":" + to_str(mo_t.v));
let mo_f = MutOut { v: 0 };
let r_f = test_switch_outer_defer_break_return(1, false, mo_f);
println("sw_outer_brkF=" + to_str(r_f) + ":" + to_str(mo_f.v));
println("sw_nofpT=" + to_str(test_switch_break_no_false_positive(1, true)));
println("sw_nofpF=" + to_str(test_switch_break_no_false_positive(1, false)));
println("sw_nested=" + to_str(test_nested_switch_defer_lifo(1, 2, true, true)));
println("sw_guard=" + to_str(test_switch_guard_break_lifo(1, false)));
