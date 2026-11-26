gc struct Node {
    id: int,
    label: str,
    tags: [str],
}

struct OwnPair {
    id: int,
    text: str,
}

fn make_node(id: int, prefix: str) -> Node {
    return Node {
        id: id,
        label: prefix + "-" + to_str(id),
        tags: [prefix, to_str(id), "z" + to_str(id * 2)],
    };
}

fn verify_node(n: Node, expect_id: int, acc: Node) {
    if n.id != expect_id || len(n.tags) != 3 {
        println("FAIL verify_node id=" + to_str(n.id) + " expect=" + to_str(expect_id));
        exit(1);
    }
    let tmp = make_node(expect_id + 1000, "clean");
    acc.id += tmp.id - 1000;
}

fn consume_own_pair(p: own OwnPair, acc: Node) {
    if len(p.text) == 0 {
        println("FAIL empty own pair text");
        exit(1);
    }
    let tmp = make_node(p.id, p.text);
    acc.id += tmp.id;
}

fn touch_str(s: &mut str, acc: Node) {
    let n = make_node(1, *s + "-tail");
    acc.id += n.id;
}

fn generic_defer[T](val: T, acc: Node, delta: int) {
    let _ = val;
    defer verify_node(make_node(delta, "gen"), delta, acc);
}

fn work_with_defers(iter: int, acc: Node, take_branch: bool) -> Node {
    let first = make_node(iter, "first");
    defer verify_node(first, iter, acc);

    let msg = "msg-" + to_str(iter);
    defer touch_str(&mut msg, acc);

    if take_branch {
        let inner = make_node(iter + 10, "inner");
        defer verify_node(inner, iter + 10, acc);
        let op: own OwnPair = OwnPair { id: 5, text: "own-" + to_str(iter) };
        defer consume_own_pair(op, acc);
    }

    defer verify_node(make_node(iter + 20, "multi"), iter + 20, acc);

    let junk = "";
    for k in 0..40 {
        let g = make_node(k, "junk");
        junk = g.label;
    }
    let _ = junk;

    let ch: chan[Node] = make_chan(1);
    chan_send(ch, make_node(iter + 30, "sel"));
    select {
        case let sv_opt = chan_recv(ch) {
            guard let sv = sv_opt else {
                println("FAIL select closed");
                exit(1);
            }
            if sv.id != iter + 30 {
                println("FAIL select node");
                exit(1);
            }
        }
    }

    return make_node(iter + 50, "ret");
}

fn run_gc_test() {
    let acc = make_node(0, "acc");
    let sum_ret = 0;
    for i in 0..200 {
        let r = work_with_defers(i, acc, (i % 2) == 0);
        if r.id != i + 50 || len(r.tags) != 3 {
            println("FAIL return node corrupted");
            exit(1);
        }
        generic_defer(r, acc, 2);
        sum_ret += r.id;
    }
    println("acc=" + to_str(acc.id) + " sum=" + to_str(sum_ret));
}

run_gc_test();
