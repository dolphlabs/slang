enum Shape {
    Point,
    Circle(float),
    Rect(float, float),
}

let s = Shape.Point;
switch s {
    case Shape.Point { println("point"); }
    case Shape.Circle(r) { println(r); }
}
