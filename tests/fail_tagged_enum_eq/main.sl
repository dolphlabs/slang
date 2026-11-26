enum Shape {
    Point,
    Circle(float),
}

let a = Shape.Point;
let b = Shape.Circle(1.0);
println(a == b);
