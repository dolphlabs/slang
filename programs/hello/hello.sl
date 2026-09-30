fn fib(n: int) -> int {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}

for k in 1..=3 {
    println("tick ${k}");
}
println("fib(20) = ${fib(20)}");
