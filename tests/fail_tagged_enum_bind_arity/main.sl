enum Shape {
    Point,
    Rect(float, float),
}

let s = Shape.Rect(1.0, 2.0);
switch s {
    case Shape.Point { println("point"); }
    case Shape.Rect(w) { println(w); }
}
