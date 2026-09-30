// The plain form has the same rule: its else must leave the scope.
let x = 3;
guard x > 5 else {
    println("small");
}
println("after");
