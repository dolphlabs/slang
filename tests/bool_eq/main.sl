// `==` and `!=` on bools. Used to be a compile error ("cannot compare
// bool and bool"). Ordering (`<` etc.) on bools stays an error; see
// tests/fail_bool_order.

fn is_even(n: int) -> bool {
    return n % 2 == 0;
}

let t = true;
let f = false;
println(t == true);
println(t == f);
println(t != f);
println(f != false);

// both sides from calls: the non-flat, sequenced codegen path
println(is_even(2) == is_even(4));
println(is_even(2) == is_even(3));
println(is_even(1) != is_even(2));

// the case that motivated it: two predicates agreeing
let a = 7;
if (a > 5) == (a > 3) {
    println("predicates agree");
}
if (a > 5) != (a > 10) {
    println("predicates disagree");
}
