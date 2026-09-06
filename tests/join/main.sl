fn work(n: int) -> int {
    n * 2
}

fn boom() -> int {
    return 1 / 0;
}

let h: join[int] = spawn work(21);
let r: result[int, str] = join_wait(h);
guard let v = r else {
    println("BUG: work should succeed");
    exit(1);
}
println(v);

let p: join[int] = spawn boom();
let pr: result[int, str] = join_wait(p);
guard let _x = pr else {
    println("task panicked");
    exit(0);
}
println("BUG: expected panic result");
exit(1);
