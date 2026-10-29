import "math";

fn split(total: int, parts: int) -> int {
    return math.div_floor(total, parts);
}

println(split(10, 0));
