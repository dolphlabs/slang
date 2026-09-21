// an error inside an instance names the instance and where it was asked for.
struct Keyed[K] { m: map[K]int }
fn ok_one(x: Keyed[int]) {}
fn bad_one(x: Keyed[float]) {}
