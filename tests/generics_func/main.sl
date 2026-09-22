// Generic functions: `fn f[T](...) -> ...`. A call never writes the type
// arguments (`first[int](xs)` would collide with indexing) -- they are
// inferred, either from the arguments by unifying each parameter's
// declared type against the argument's actual type, or, for a parameter
// only the RETURN type mentions, from the expected type the same way
// `none` and `[]` already infer theirs.

fn first[T](xs: [T]) -> T {
    return xs[0];
}

fn identity[T](x: T) -> T {
    return x;
}

// several parameters, each its own type
fn choose_second[A, B](a: A, b: B) -> B {
    return b;
}

// a parameter the arguments never mention: bound from cg->expect against
// the return type alone, the same way `none` and `[]` already infer
// theirs -- so this only reaches an opt[T]/result/chan/join/[T]-shaped
// return, where that mechanism already applies.
fn empty_of[T]() -> [T] {
    let xs: [T] = [];
    return xs;
}
fn nothing_of[T]() -> opt[T] {
    return none;
}

// unifying through a container: [T], not T itself, is the parameter
fn sum_ints(xs: [int]) -> int {
    let t = 0;
    for x in xs {
        t = t + x;
    }
    return t;
}
fn map_len[T](xs: [T]) -> int {
    return len(xs);
}

// a generic struct as the unified shape
struct Box[T] {
    v: T,
}
fn unbox[T](b: Box[T]) -> T {
    return b.v;
}
fn rebox[T](v: T) -> Box[T] {
    return Box[T] { v: v };
}

// two type parameters unified through nested containers at once
fn zip_first[A, B](pairs: [Box[A]], _extra: B) -> A {
    return pairs[0].v;
}

// recursion through a generic function
fn count_down[T](xs: [T], n: int) -> int {
    if n == 0 {
        return 0;
    }
    return 1 + count_down(xs, n - 1);
}

// calling one generic function from inside another
fn first_len[T](xs: [[T]]) -> int {
    return len(first(xs));
}

println(first([1, 2, 3]));
println(first(["a", "b", "c"]));
println(identity(42));
println(identity("hi"));
println(choose_second(1, "two"));
println(choose_second("x", 9));

let z: [int] = empty_of();
println(len(z));
let w: opt[str] = nothing_of();
println(w ?? "none");

println(sum_ints([1, 2, 3]));
println(map_len([1, 2, 3, 4]));
println(map_len(["a", "b"]));

let b = Box[int] { v: 7 };
println(unbox(b));
let b2: Box[str] = rebox("boxed");
println(b2.v);

let pairs = [Box[int] { v: 5 }, Box[int] { v: 6 }];
println(zip_first(pairs, "ignored"));

println(count_down([1, 2, 3], 4));

println(first_len([[1, 2], [3, 4, 5]]));

// two instances of one template, in the SAME expression: the return of
// one call must not leak its type parameters into the other's
println(first([identity(1), identity(2)]) + first([identity(3)]));
