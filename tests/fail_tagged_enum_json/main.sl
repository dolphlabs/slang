import "json";

enum Shape {
    Point,
    Circle(float),
}

let s = json.encode(Shape.Point);
println(s);
