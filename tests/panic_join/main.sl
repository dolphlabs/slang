fn boom() -> int {
    let xs: [int] = [1];
    return xs[5];
}

let h = spawn boom();
let r = join_wait(h);
guard let v = r else let e = err_of(r) {
    println("joined panic: " + e);
}
