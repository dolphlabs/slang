import "sub";

extern fn atoi(
    s: str,
) -> i32;

enum Color {
    Red,
    Green,
    Blue,
}

struct Single {
    v: int,
}

gc struct Point {
    x: int,
    y: int,
}

impl Point {
    fn moved(
        self: Point,
        dx: int,
        dy: int,
    ) -> Point {
        return Point {
            x: self.x + dx,
            y: self.y + dy,
        };
    }

    fn sum(self: Point,) -> int {
        return self.x + self.y;
    }
}

struct Box[T,] {
    v: T,
}

struct Pair[A, B,] {
    k: A,
    v: B,
}

impl Pair[A, B,] {
    fn key(self: Pair[A, B,],) -> A {
        return self.k;
    }

    fn flip(self: Pair[A, B,],) -> Pair[B, A,] {
        return Pair[B, A,] {
            k: self.v,
            v: self.k,
        };
    }
}

struct View<'a,> {
    r: &'a int,
}

fn borrow_first<'a, 'b,>(
    x: &'a int,
    y: &'b int,
) -> &'a int {
    return x;
}

fn id(x: int,) -> int {
    return x;
}

fn add(
    a: int,
    b: int,
) -> int {
    return a + b;
}

fn notify(msg: str,) {
    println(msg,);
}

fn pick[A, B,](
    a: A,
    b: B,
) -> A {
    return a;
}

fn parse_pos(
    n: int,
) -> result[int, str,] {
    if n > 0 {
        return ok(n,);
    }
    return err("non-positive",);
}

fn apply_bin(
    f: fn(int, int,) -> int,
    a: int,
    b: int,
) -> int {
    return f(a, b,);
}

// 1. EX_LIST (single, multi-line, nested, empty)
let empty_xs: [int] = [];
let single_xs = [42,];
let multi_xs = [
    1,
    2,
    3,
];
let nested_xs = [
    [1,],
    [2, 3,],
];
println(len(empty_xs,));
println(single_xs[0]);
println(multi_xs[2]);
println(nested_xs[1][1]);

// 2. EX_MAPLIT (single, multi-line, empty)
let empty_m: map[str]int = {};
let single_m = {"a": 1,};
let multi_m = {
    "x": 10,
    "y": 20,
};
println(len(empty_m,));
println(single_m["a"]);
println(multi_m["y"]);

// 3. EX_STRUCTLIT (single-field, multi-line gc, generic, package-qualified)
let s1 = Single { v: 7, };
let pt = Point {
    x: 3,
    y: 4,
};
let pair_val = Pair[int, str,] {
    k: 9,
    v: "ok",
};
let sub_item = sub.Item {
    id: 5,
    label: "pkg",
};
println(s1.v);
println(pt.x + pt.y);
println(pair_val.v);
println(sub_item.label);

// 4. EX_CALL (direct, dotted, spawn, indirect) & EX_METHOD
println(id(11,));
println(add(
    1,
    2,
));
let made = sub.make(
    8,
    "made",
);
println(made.id);
guard let spawned = join_wait(spawn add(10, 20,)) else {
    println("spawn-failed");
    exit(1);
}
println(spawned);
println(pt.moved(1, 2,).sum());

// 5. fn(...) types + canonical equivalence + indirect call
let fn_eq: fn(int, int) -> int = add;
let fn_tc: fn(int, int,) -> int = fn_eq;
let fn_back: fn(int, int) -> int = fn_tc;
let ops: [fn(int, int,) -> int] = [
    fn_back,
];
println(fn_tc(3, 4,));
println(ops[0](5, 6,));
println(apply_bin(add, 20, 22,));
let fn_void: fn(str,) = notify;
fn_void("void-ok",);

// 6. Generic type args canonical equivalence & nesting + generic fn re-parse
let b1: Box[int,] = Box[int,] { v: 100, };
let b2: Box[int] = b1;
let nested_box = Box[Box[int,],] { v: b2, };
println(nested_box.v.v);
println(pair_val.key());
println(pair_val.flip().key());
println(pick(77, "ignored",));

// 7. result[T, E,] canonical equivalence
let r1: result[int, str,] = parse_pos(5,);
let r2: result[int, str] = r1;
guard let rv = r2 else {
    println("unexpected");
    exit(1);
}
println(rv);

// 8. Lifetimes
let la = 12;
let lb = 34;
let lr = borrow_first(&la, &lb,);
let vw = View { r: lr, };
println(*vw.r);

// 9. extern fn with trailing comma
println(atoi("45",) as int);

// 10. switch stmt & expr case value lists
let code = 2;
switch code {
    case 1, 2, {
        println("stmt-12");
    }
    case 3, {
        println("stmt-3");
    }
    default {
        println("stmt-other");
    }
}

let c = Color.Green;
switch c {
    case Color.Red, Color.Green, {
        println("color-rg");
    }
    case Color.Blue, {
        println("color-b");
    }
}

let label = switch code {
    case 1, 2, { "expr-12" }
    case 3, { "expr-3" }
    default { "expr-other" }
};
println(label);

// 11. String interpolation with trailing comma expressions
println("interp=${add(3, 4,)}:${[10, 20,][1]}");
