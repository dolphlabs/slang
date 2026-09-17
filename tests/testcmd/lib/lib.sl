// A library package: top-level lets are package globals.
let SCALE = 10;

pub fn scaled(x: int) -> int {
    return clamp(x, 0, 100) * SCALE;
}

fn clamp(x: int, lo: int, hi: int) -> int {
    if x < lo { return lo; }
    if x > hi { return hi; }
    return x;
}
