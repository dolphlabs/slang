struct OwnBox {
    x: int,
}

fn take(b: own OwnBox) {
    println("took=" + to_str(b.x));
}

fn get_opt(ok_flag: bool) -> opt[int] {
    if ok_flag {
        return some(1);
    }
    return none;
}

fn f(x: int, ok_flag: bool) -> int {
    let b: own OwnBox = OwnBox { x: 55 };
    switch x {
        case 1 {
            guard let v = get_opt(ok_flag) else {
                defer take(b);
                break;
            }
            return v + 10;
        }
        default {
            return 20;
        }
    }
    take(b);
    return 30;
}

println(f(1, false));
