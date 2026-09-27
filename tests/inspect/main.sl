// inspect(x): JavaScript-console-style rendering of any value.

println(inspect(42));            // 42
println(inspect(-7));            // -7
println(inspect(true));          // true
println(inspect(1.5));           // 1.5
println(inspect("hi"));          // "hi"
println(inspect(""));            // ""
println(inspect("a\"b\\c\nd"));  // "a\"b\\c\nd"

// lists, nested and empty
println(inspect([1, 2, 3]));         // [1, 2, 3]
println(inspect(["a", "b"]));        // ["a", "b"]
println(inspect([[1, 2], [3]]));     // [[1, 2], [3]]
let empty: [int] = [];
println(inspect(empty));             // []

// maps with str, int, and bool keys
println(inspect({"name": "ada", "city": "lagos"}));
println(inspect({1: "a", 2: "b"}));
println(inspect({true: 1}));

// opt and result
let o: opt[int] = some(7);
println(inspect(o));                 // some(7)
let n: opt[int] = none;
println(inspect(n));                 // none
let r: result[int, str] = ok(5);
println(inspect(r));                 // ok(5)
let e: result[int, str] = err("bad");
println(inspect(e));                 // err("bad")

// structs, plain and gc, nested in lists
struct Point { x: int, y: int }
println(inspect(Point { x: 1, y: 2 }));
gc struct GNode { v: int, next: opt[GNode] }
let g = GNode { v: 1, next: some(GNode { v: 2, next: none }) };
println(inspect(g));
println(inspect([Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]));

// enums render as bare variant names
enum Color { Red, Green }
println(inspect(Color.Red));

// bytes render quoted (base64), faults name themselves
println(inspect(to_bytes("hi")));
println(inspect(fault_timeout()));

// nesting past the depth cap terminates with ...
let deep: [[[[[[[[[[int]]]]]]]]]] = [[[[[[[[[[1]]]]]]]]]];
println(inspect(deep));

// inspect returns a str: it composes with concat and println
println("val=" + inspect([1, 2]));
