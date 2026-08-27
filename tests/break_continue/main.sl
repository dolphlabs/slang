// break/continue -- every loop kind, nesting, and the guard-let idiom
// they exist to replace. Each block also keeps a loop-carried GC
// pointer (acc*) alive across the break/continue itself, directly
// exercising the safepoint-bracket unwind fix: break/continue must
// close exactly the innermost loop's own bracket (never an outer
// one), the same way return already had to learn to do.

fn mk() -> [int] {
    return [1, 2, 3];
}

// while: break
let acc = mk();
let i = 0;
while true {
    if i == 5 {
        break;
    }
    println(i);
    i = i + 1;
}
println(len(acc));

// while: continue
let acc2 = mk();
let j = 0;
while j < 6 {
    j = j + 1;
    if j % 2 == 0 {
        continue;
    }
    println(j);
}
println(len(acc2));

// numeric for: break and continue together
let acc3 = mk();
for k in 0..10 {
    if k == 7 {
        break;
    }
    if k % 3 == 0 {
        continue;
    }
    println(k);
}
println(len(acc3));

// for-in over an array: break
let acc4 = mk();
let xs = [10, 20, 30, 40, 50];
for x in xs {
    if x == 30 {
        break;
    }
    println(x);
}
println(len(acc4));

// for-in over a map: continue
let acc5 = mk();
let m: map[str]int = {"a": 1, "b": 2, "c": 3};
for mk_key, mk_val in m {
    if mk_val == 2 {
        continue;
    }
    println(mk_key);
}
println(len(acc5));

// nested loops: an inner break only exits the inner loop
let acc6 = mk();
for a in 0..3 {
    for b in 0..3 {
        if b == 1 {
            break;
        }
        println(a * 10 + b);
    }
}
println(len(acc6));

// guard let ... else { break; } -- the idiomatic replacement for the
// guard let ... else { return; } workaround this feature exists to
// remove the need for.
fn maybe(n: int) -> opt[int] {
    if n < 3 {
        return some(n);
    }
    return none;
}
let acc7 = mk();
let n = 0;
while true {
    let v = maybe(n);
    guard let unwrapped = v else { break; }
    println(unwrapped);
    n = n + 1;
}
println(len(acc7));

println("done");
