enum Shape {
    Point,
    Rect(float, float),
}

let s = Shape.Rect(1.0);
switch s {
    default {}
}
