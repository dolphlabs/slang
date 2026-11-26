enum Shape {
    Point,
    Circle(float),
}

let s = Shape.Circle(2.0);
switch s {
    case Shape.Point { println("point"); }
    case Shape.Circle { println("circle"); }
}
