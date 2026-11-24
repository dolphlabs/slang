import "fs";
import "os";
import "strings";

enum Mode {
    Fast,
    Safe,
}

gc struct Log {
    items: [str],
    val: int,
    m: mutex,
}

gc struct Resource {
    id: int,
    log: Log,
    on_close: fn(int),
}

struct ValHelper {
    tag: str,
    log: Log,
}

impl Resource {
    fn close(self: Resource) -> result[bool, str] {
        push(self.log.items, "close:" + to_str(self.id));
        if self.id < 0 {
            return err("neg");
        }
        return ok(true);
    }
}

impl ValHelper {
    fn finish(self: ValHelper) {
        push(self.log.items, "val:" + self.tag);
    }
}

fn push_msg(l: Log, msg: str) {
    push(l.items, msg);
}

fn record_mode(l: Log, m: Mode) {
    switch m {
        case Mode.Fast { push(l.items, "mode:fast"); }
        case Mode.Safe { push(l.items, "mode:safe"); }
    }
}

fn nonvoid_cleanup(l: Log, tag: str) -> result[int, str] {
    push(l.items, "nv:" + tag);
    if tag == "err" {
        return err("boom");
    }
    return ok(99);
}

fn read_ref(x: &int) -> int {
    return *x;
}

fn check_read_borrow() -> int {
    let x = 41;
    defer read_ref(&x);
    return x + 1;
}

fn test_lifo_and_fallthrough(l: Log) {
    let x = 10;
    defer push_msg(l, "first:" + to_str(x));
    x = 20;
    defer push_msg(l, "second:" + to_str(x));
    defer nonvoid_cleanup(l, "ok");
    defer nonvoid_cleanup(l, "err");
    push_msg(l, "body");
}

fn set_val(l: Log, v: int) {
    l.val = v;
}

fn test_ret_eval_before_defer(l: Log) -> int {
    l.val = 7;
    defer set_val(l, 777);
    return l.val;
}

fn fn_noop(id: int) {
    let _ = id;
}

fn test_branches_and_guard(l: Log, flag: bool, r: result[int, str]) -> int {
    defer push_msg(l, "outer");
    if flag {
        defer push_msg(l, "if_true");
        let res = Resource { id: 1, log: l, on_close: fn_noop };
        defer res.close();
        guard let v = r else |e| {
            defer push_msg(l, "guard_else:" + e);
            return -1;
        }
        defer push_msg(l, "after_guard:" + to_str(v));
        return v * 2;
    } else {
        defer push_msg(l, "if_false");
    }
    let o: opt[int] = some(5);
    if let n = o {
        defer push_msg(l, "if_let:" + to_str(n));
    } else {
        defer push_msg(l, "if_let_else");
    }
    return 100;
}

fn test_loops_and_select(l: Log, early: bool) -> int {
    defer push_msg(l, "loop_fn_exit");
    let sum = 0;
    for i in 0..4 {
        if i == 1 {
            continue;
        }
        if i == 3 {
            if early {
                return sum;
            }
            break;
        }
        sum += i;
    }
    let w = 0;
    while w < 3 {
        w += 1;
        if w == 2 && !early {
            break;
        }
    }
    switch w {
        case 2 {
            defer push_msg(l, "sw2");
        }
        default {
            defer push_msg(l, "sw_def");
        }
    }
    let ch: chan[int] = make_chan(1);
    chan_send(ch, 55);
    select {
        case let v = chan_recv(ch) {
            guard let n = v else {
                return -98;
            }
            defer push_msg(l, "sel_recv:" + to_str(n));
            return sum + n;
        }
        default {
            return -99;
        }
    }
}

fn make_res(l: Log, id: int) -> Resource {
    return Resource { id: id, log: l, on_close: fn_noop };
}

fn test_methods_and_indirect(l: Log) {
    let vh = ValHelper { tag: "h1", log: l };
    defer vh.finish();
    defer make_res(l, 42).close();
    let r = Resource { id: 9, log: l, on_close: fn_noop };
    defer r.on_close(9);
    let fns: [fn(Log, str)] = [push_msg];
    defer fns[0](l, "indirect_idx");
    defer record_mode(l, Mode.Fast);
}

fn test_mutex_early_return(l: Log, fail_early: bool) -> int {
    mutex_lock(l.m);
    defer mutex_unlock(l.m);
    if fail_early {
        return -5;
    }
    return 5;
}

fn test_defer_print() {
    let s = "printed_on_defer";
    defer println(s);
    s = "changed";
    print("before_print:");
}

fn test_fs_nonvoid() {
    let path = os.tmpdir() + "/sl_test_defer_fs_" + to_str(os.pid()) + ".txt";
    guard let f = fs.create(path) else |e| {
        println("FAIL fs.create: " + e);
        exit(1);
    }
    defer fs.close(f);
    let _w = fs.write(f, b"ok");
    let _rm = os.remove(path);
}

fn main_runner() {
    let l = Log { items: [], val: 0, m: make_mutex() };

    test_lifo_and_fallthrough(l);
    println(strings.join(l.items, ","));

    l.items = [];
    let r = test_ret_eval_before_defer(l);
    println("ret=" + to_str(r) + " after=" + to_str(l.val));

    l.items = [];
    let b1 = test_branches_and_guard(l, true, err("bad"));
    println("b1=" + to_str(b1) + " " + strings.join(l.items, ","));

    l.items = [];
    let b2 = test_branches_and_guard(l, true, ok(11));
    println("b2=" + to_str(b2) + " " + strings.join(l.items, ","));

    l.items = [];
    let b3 = test_branches_and_guard(l, false, ok(1));
    println("b3=" + to_str(b3) + " " + strings.join(l.items, ","));

    l.items = [];
    let ls1 = test_loops_and_select(l, true);
    println("ls1=" + to_str(ls1) + " " + strings.join(l.items, ","));

    l.items = [];
    let ls2 = test_loops_and_select(l, false);
    println("ls2=" + to_str(ls2) + " " + strings.join(l.items, ","));

    l.items = [];
    test_methods_and_indirect(l);
    println(strings.join(l.items, ","));

    let m1 = test_mutex_early_return(l, true);
    let m2 = test_mutex_early_return(l, false);
    let got = mutex_trylock(l.m);
    if got {
        mutex_unlock(l.m);
    }
    println("m=" + to_str(m1) + "," + to_str(m2) + ",free=" + to_str(got));

    println("ref=" + to_str(check_read_borrow()));
    test_defer_print();
    test_fs_nonvoid();
}

main_runner();
