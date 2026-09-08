fn spinner(n: int) -> int {
    let i = 0;
    let acc = 0;
    while i < n {
        acc = acc + i;
        i = i + 1;
    }
    return acc;
}

let h1 = spawn spinner(20000000);
let h2 = spawn spinner(20000000);
let r1 = join_wait(h1);
guard let v1 = r1 else {
    println("FAIL spinner 1");
    exit(1);
}
let r2 = join_wait(h2);
guard let v2 = r2 else {
    println("FAIL spinner 2");
    exit(1);
}
println(v1);
println(v2);
println("preempt probe done");