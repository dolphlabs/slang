// geometry/shapes.sl - exported and private functions

// pub: callable as geometry.area(...) from importers
pub fn area(w: float, h: float) -> float {
    return scale(w * h);
}

pub fn perimeter(w: float, h: float) -> float {
    return 2.0 * (w + h);
}

// private: only visible inside the geometry package
fn scale(v: float) -> float {
    return v * 2.0;
}