struct Point {
    x: int,
    y: int,
}

fn take(p: own Point) -> int {
    return p.x;
}

let a: own Point = Point { x: 1, y: 2 };
switch 1 {
    case 1 {
        println(take(a));
    }
    default {
        println("d");
    }
}
println(a.x);
