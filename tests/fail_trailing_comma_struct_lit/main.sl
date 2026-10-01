// A trailing comma in a struct literal is refused, and the error says so
// (it used to say only "expected a field name but found '}'").
gc struct Point {
    x: int,
    y: int,
}

let p = Point {
    x: 1,
    y: 2,
};
println(to_str(p.x));
