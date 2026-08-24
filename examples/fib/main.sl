// fib.sl - recursion in slang

fn fib(n: int) -> int {
    if n < 2 {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

let i = 0;
while i < 15 {
    print("fib(");
    print(i);
    print(") = ");
    println(fib(i));
    i = i + 1;
}