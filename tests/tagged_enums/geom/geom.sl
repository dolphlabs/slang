pub enum Shape {
    Point,
    Circle(float),
    Rect(float, float),
    Label(str),
}

pub fn area(s: Shape) -> float {
    return switch s {
        case Shape.Point { 0.0 }
        case Shape.Circle(r) { 3.0 * r * r }
        case Shape.Rect(w, h) { w * h }
        case Shape.Label(_) { 0.0 }
    };
}

pub fn label_or(s: Shape, fb: str) -> str {
    switch s {
        case Shape.Label(text) {
            return text + "!";
        }
        default {
            return fb;
        }
    }
}
