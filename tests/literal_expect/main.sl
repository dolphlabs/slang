// List and map literals give their elements, keys and values the type
// that is expected of them, so `none`, `[]` and `{}` need no annotation
// of their own. Every site that supplies an expected type is
// here: an annotated let, a reassignment, a function argument, a return,
// a struct field, and literals nested inside each other. The loop at the
// end allocates inside the literals so collections land mid-literal.

struct Row {
    cells: [opt[int]],
    tags: map[str]opt[str],
}

fn total(xs: [opt[int]]) -> int {
    let t = 0;
    for x in xs {
        t += x ?? 0;
    }
    return t;
}

fn count(m: map[str]opt[int]) -> int {
    let c = 0;
    for k, v in m {
        if let x = v {
            c += x;
        }
    }
    return c;
}

fn pick() -> [opt[str]] {
    return [none, some("b")];
}

fn table() -> map[int][opt[int]] {
    return {1: [none], 2: [some(2), none]};
}

fn fresh() -> map[str]int {
    return {};
}

fn size(m: map[str]int) -> int {
    return len(m);
}

fn label(i: int) -> str {
    return "n" + i;
}

let a: [opt[int]] = [some(1), none, some(3)];
println(inspect(a));
let b: [opt[int]] = [none, some(2)];
println(inspect(b));
let n: [[opt[int]]] = [[none], [some(1), none], []];
println(inspect(n));
let m: map[str]opt[int] = {"a": none, "b": some(3)};
println(inspect(m));
let lm: [map[str]opt[int]] = [{"x": none}, {"y": some(1)}, {}];
println(inspect(lm));
let r: [opt[int]] = [some(9)];
r = [none, none];
println(inspect(r));
println(total([none, some(4), none, some(5)]));
println(count({"a": some(1), "b": none, "c": some(2)}));
println(inspect(pick()));
println(inspect(table()));
let row = Row{cells: [none, some(7)], tags: {"k": none}};
println(inspect(row.cells));
println(inspect(row.tags));
let mm: map[str]map[str]int = {"a": {}, "b": {"x": 1}};
println(inspect(mm));
let nn: [[int]] = [[], [1]];
println(inspect(nn));
println(size(fresh()) + size({}));

let sum = 0;
let names = 0;
for i in 0..3000 {
    let xs: [opt[str]] = [none, some(label(i)), none, some(label(i + 1))];
    let ms: map[str]opt[str] = {label(i): none, "k": some(label(i))};
    for x in xs {
        if let s = x {
            names += len(s);
        }
    }
    names += len(ms);
    sum += total([some(i), none]);
}
println(sum);
println(names);
