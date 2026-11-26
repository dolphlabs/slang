struct P {
    x: int,
}

fn take(p: own P) -> int {
    return p.x;
}

fn bad() -> int {
    let r: result[int, own P] = err(P { x: 7 });
    guard let v = r else |e| {
        let p = &e.x;
        let _x = take(e);
        return *p;
    }
    return v;
}
println(bad());
