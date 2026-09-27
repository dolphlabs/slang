struct Point {
    x: int,
    y: int,
}

fn take(p: own Point) -> int {
    return p.x;
}

let a: own Point = Point { x: 1, y: 2 };
let ch: chan[int] = make_chan(1);
select {
    case chan_send(ch, take(a)) {
        println("sent");
    }
    default {
        println("d");
    }
}
println(a.x);
