let scores: map[str]int = {"alice": 90, "bob": 85};
println(len(scores));
scores["carol"] = 78;
println(scores["alice"] + scores["bob"] + scores["carol"]);
println(has(scores, "dave"));
del(scores, "bob");
println(has(scores, "bob"));
println(len(scores));

let flags: map[int]bool = {1: true, 2: false};
if flags[1] {
    println("one");
}
for k, v in flags {
    println(k);
    println(v);
}

let empty: map[str]str = {};
println(len(empty));

let widths: map[str]int = {};
widths["a"] = 5;
println(widths["a"]);

let squares: map[int]int = {1: 1, 2: 4, 3: 9};
let total = 0;
for _, sq in squares {
    total = total + sq;
}
println(total);
