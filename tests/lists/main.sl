// Tier 1: arrays/lists — literals, builtins, iteration, slicing, concat

let xs = [10, 20, 30];
println(len(xs));        // 3

// push / pop (LIFO)
push(xs, 40);
println(xs[3]);          // 40
println(pop(xs));        // 40
println(len(xs));        // 3

// index assignment with bounds-checked access
xs[0] = 5;
println(xs[0]);          // 5

// for-in iteration
let total = 0;
for x in xs {
    total = total + x;
}
println(total);          // 55

// slicing (start inclusive, end exclusive; either end optional)
let ys = xs[0..2];
println(len(ys));        // 2
println(ys[1]);          // 20
let tail = xs[1..];
println(tail[0]);        // 20

// concatenation
let zs = xs + ys;
println(len(zs));        // 5
println(zs[4]);          // 20

// empty lists need a type annotation
let empty: [str] = [];
push(empty, "hi");
println(empty[0]);       // hi

// str elements and interpolation
let names = ["a", "b"];
println(names[0] + names[1]);   // ab

// nested lists
let grid = [[1, 2], [3, 4]];
println(grid[1][0]);     // 3
grid[1][0] = 9;
println(grid[1][0]);     // 9

// lists of fixed-width ints
let bytes8: [i16] = [1, 2, 300];
println(bytes8[2]);      // 300

// growing past the initial capacity exercises reallocation
let grown: [int] = [];
for i in 0..100 {
    push(grown, i * i);
}
println(grown[99]);      // 9801
println(len(grown));     // 100