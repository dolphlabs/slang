import "geom";

enum Token {
    Eof,
    Int(int),
    Str(str, [int],),
}

// Recursive sum type via gc struct indirection.
enum Expr {
    Lit(int),
    Add(ExprNode),
}

gc struct ExprNode {
    op: str,
    left: Expr,
    right: Expr,
}

enum Outer {
    Empty,
    Wrapped(geom.Shape),
    Nested(opt[int], result[int, str]),
}

struct Holder {
    tag_name: str,
    shape: geom.Shape,
}

gc struct GcBox {
    item: geom.Shape,
    label: str,
}

enum Color {
    Red,
    Green,
    Blue(int),
}

fn id[T](x: T) -> T {
    return x;
}

fn eval_expr(e: Expr) -> int {
    return switch e {
        case Expr.Lit(n) { n }
        case Expr.Add(node) { eval_expr(node.left) + eval_expr(node.right) }
    };
}

fn mk_str(prefix: str, n: int) -> str {
    return prefix + "-" + to_str(n);
}

fn mk_nums(n: int) -> [int] {
    return [n, n + 1, n + 2];
}

fn worker_describe(s: geom.Shape) -> str {
    return switch s {
        case geom.Shape.Label(txt) { "worker:" + txt }
        case geom.Shape.Point { "worker:point" }
        case geom.Shape.Circle(r) { "worker:circle:" + to_str(r as int) }
        case geom.Shape.Rect(w, h) { "worker:rect:" + to_str((w * h) as int) }
    };
}

// Trailing comma in enum + ctor + switch expr multi-label unit + wildcard
let c0 = Color.Red;
let c1 = Color.Blue(42);
let c_tag = switch c0 {
    case Color.Red, Color.Green { "primary" }
    case Color.Blue(_) { "blue" }
};
println(c_tag);
let c_val = switch c1 {
    case Color.Red { 1 }
    case Color.Green { 2 }
    case Color.Blue(v,) { v }
};
println(c_val);

// Cross-package pub enum with payloads, switch statement, switch expression, generics
let sh = geom.Shape.Rect(3.0, 4.0,);
let sh2 = geom.Shape.Label("hello");
let sh3: geom.Shape = id(geom.Shape.Circle(2.0));
println(geom.area(sh));
println(geom.area(sh3));
println(geom.label_or(sh2, "none"));
println(geom.label_or(geom.Shape.Point, "fallback"));

switch sh2 {
    case geom.Shape.Label(txt) {
        println("stmt:" + txt);
    }
    case geom.Shape.Point { println("unreachable"); }
    case geom.Shape.Circle(_) { println("unreachable"); }
    case geom.Shape.Rect(_, _) { println("unreachable"); }
}

// switch break
switch sh3 {
    case geom.Shape.Circle(r) {
        if r > 1.0 {
            println("break-ok");
            break;
        }
        println("after-break");
    }
    default {
        println("default");
    }
}

// inspect()
println(inspect(geom.Shape.Point));
println(inspect(geom.Shape.Circle(1.5)));
println(inspect(geom.Shape.Rect(2.0, 5.0)));
println(inspect(geom.Shape.Label("hi")));

// Recursive enum via gc struct
let tree = Expr.Add(ExprNode {
    op: "+",
    left: Expr.Lit(10),
    right: Expr.Add(ExprNode {
        op: "+",
        left: Expr.Lit(20),
        right: Expr.Lit(12),
    }),
});
println(eval_expr(tree));

// Nested aggregates: opt, result, nested enum
let o1 = Outer.Wrapped(geom.Shape.Label("wrapped"));
let o2 = Outer.Nested(some(7), err("oops"));
let o3 = Outer.Nested(none, ok(99));
println(inspect(o1));
println(inspect(o2));
println(inspect(o3));

// Containers holding tagged enums + opt/result + value struct + gc struct
let list_sh: [geom.Shape] = [
    geom.Shape.Point,
    geom.Shape.Label(mk_str("item", 1)),
    geom.Shape.Rect(2.0, 3.0),
];
let map_sh: map[str]geom.Shape = {
    "a": geom.Shape.Label(mk_str("map", 1)),
    "b": geom.Shape.Circle(4.0),
};
let opt_sh: opt[geom.Shape] = some(geom.Shape.Label(mk_str("opt", 2)));
let opt_none: opt[geom.Shape] = none;
let res_sh: result[geom.Shape, str] = ok(geom.Shape.Label(mk_str("res", 3)));
println(len(list_sh));
println(len(map_sh));
println(inspect(opt_sh));
println(inspect(opt_none));
println(inspect(res_sh));

// spawn passing tagged enum with GC str payload
let jh = spawn worker_describe(geom.Shape.Label(mk_str("sp", 7)));
guard let jres = join_wait(jh) else |e| {
    println("FAIL: " + e);
    exit(1);
}
println(jres);

// GC stress across multi-arg ctor, switch stmt/expr bindings, containers, and gc struct
let gc_list: [GcBox] = [];
let hold_list: [Holder] = [];
let tok_list: [Token] = [];
let i = 0;
while i < 400 {
    let tok = Token.Str(mk_str("t", i), mk_nums(i));
    push(tok_list, tok);
    let label = mk_str("lbl", i);
    let box = GcBox {
        item: geom.Shape.Label(label),
        label: mk_str("box", i),
    };
    push(gc_list, box);
    map_sh["loop"] = geom.Shape.Label(mk_str("m", i));
    push(hold_list, Holder {
        tag_name: mk_str("h", i),
        shape: geom.Shape.Label(mk_str("hs", i)),
    });
    // Switch expr arm doing extra allocations while reading bound str & list
    let summary = switch tok {
        case Token.Str(s, xs) { s + ":" + to_str(xs[0] + xs[2]) + ":" + mk_str("tmp", i) }
        case Token.Int(v) { to_str(v) }
        case Token.Eof { "eof" }
    };
    if i == 399 {
        println("stress-last:" + summary);
    }
    i = i + 1;
}

switch tok_list[250] {
    case Token.Str(s, xs) {
        println("verify-tok:" + s + ":" + to_str(xs[1]));
    }
    default {
        println("FAIL tok");
        exit(1);
    }
}
switch gc_list[250].item {
    case geom.Shape.Label(s) {
        println("verify-gcbox:" + s + ":" + gc_list[250].label);
    }
    default {
        println("FAIL gcbox");
        exit(1);
    }
}
switch hold_list[250].shape {
    case geom.Shape.Label(s) {
        println("verify-holder:" + s + ":" + hold_list[250].tag_name);
    }
    default {
        println("FAIL holder");
        exit(1);
    }
}
switch map_sh["loop"] {
    case geom.Shape.Label(s) {
        println("verify-map:" + s);
    }
    default {
        println("FAIL map");
        exit(1);
    }
}
