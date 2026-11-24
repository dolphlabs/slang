fn bad(p: &int) -> &int {
    let r: result[int, int] = err(7);
    guard let v = r else |e| {
        return &e;
    }
    let _keep = v;
    return p;
}
let x = 1;
println(*bad(&x));
