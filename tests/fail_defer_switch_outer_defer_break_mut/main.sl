fn mark(s: &mut int) {
    *s += 10;
}

fn f(x: int, do_break: bool) -> int {
    let s = 1;
    let res = 0;
    switch x {
        case 1 {
            defer mark(&mut s);
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
    s = 99;
    return res + s;
}

println(f(1, true));
