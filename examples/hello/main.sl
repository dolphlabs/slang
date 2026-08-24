let name = "World";
println("Hello, ${name}! Welcome to slang v0.3.");

fn add(a: int, b: int) -> int {
    a + b
}
println(add(2, 40));

fn abs(n: int) -> int {
    guard n >= 0 else {
        return -n;
    }
    n
}
println(abs(-7));

for i in 0..5 {
    print(i);
}
println("");

for i in 1..=3 {
    println("tick ${i}");
}

let pi = 3.14159;
println("pi is ${pi}, doubled is ${pi * 2}");