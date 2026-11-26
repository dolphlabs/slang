struct OwnBox {
    x: int,
}

fn take(b: own OwnBox) {
    println("took=" + to_str(b.x));
}

fn f(x: int, do_break: bool) -> int {
    let b: own OwnBox = OwnBox { x: 55 };
    switch x {
        case 1 {
            defer take(b);
            if do_break {
                break;
            }
            return 10;
        }
        default {
            return 20;
        }
    }
    take(b);
    return 30;
}

println(f(1, true));
