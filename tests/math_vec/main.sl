// math/vec: every kernel on [float] and [f32] against values worked by
// hand, lengths that are not multiples of the unroll (the tails), top-k
// order and ties, NaN handling, and int8 quantization error.
import "math/vec";
import "math";

fn r6(x: float) -> float { return math.round_to(x, 6); }

let a = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0];
let b = [11.0, 10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0];
println(vec.dot(a, b));                     // 286
println(vec.sum(a));                        // 66
println(r6(vec.norm(a)));                   // sqrt(506)
println(r6(vec.distance(a, b)));            // sqrt(440)
println(vec.distance2(a, b));               // 440
println(r6(vec.cosine(a, b)));
println(math.is_nan(vec.cosine([0.0, 0.0], [1.0, 2.0])));
println(vec.argmax(a));
println(vec.argmin(a));
println(vec.argmax([math.nan, 2.0, math.nan, 5.0, 1.0]));
let empty: [float] = [];
println(vec.argmax(empty));
println(vec.sum(empty));

let f: [f32] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0];
let g: [f32] = [11.0, 10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0];
println(vec.dot(f, g));
println(r6(vec.norm(f)));
println(r6(vec.cosine(f, g)));

let y = [1.0, 1.0, 1.0];
vec.axpy(2.0, [1.0, 2.0, 3.0], y);
println(inspect(y));                        // [3, 5, 7]
vec.add(y, [1.0, 1.0, 1.0]);
vec.sub(y, [0.5, 0.5, 0.5]);
vec.mul(y, [2.0, 2.0, 2.0]);
println(inspect(y));                        // [7, 11, 15]
vec.scale(y, 0.5);
println(inspect(y));
let u = [3.0, 4.0];
println(vec.normalize(u));                  // 5, and u is now unit length
println(inspect(u));
let z = [0.0, 0.0];
println(vec.normalize(z));
println(inspect(z));

println(inspect(vec.top_k([0.5, 9.0, 3.0, 7.0, 9.0, math.nan], 3)));   // ties: lower index first
println(inspect(vec.top_k([1.0, 2.0], 10)));
println(inspect(vec.top_k([1.0, 2.0], 0)));

// rows: 4 vectors of dim 3, row-major
let rows = [1.0, 0.0, 0.0,   0.0, 1.0, 0.0,   1.0, 1.0, 0.0,   -1.0, 0.0, 0.0];
let q = [1.0, 0.1, 0.0];
println(inspect(vec.scores(q, rows, 3)));
println(inspect(vec.top_k_dot(q, rows, 3, 2)));
println(inspect(vec.top_k_cosine(q, rows, 3, 4)));
let rf = vec.to_f32(rows);
let qf = vec.to_f32(q);
println(inspect(vec.top_k_dot(qf, rf, 3, 2)));
println(inspect(vec.to_f64(vec.to_f32([0.5, 1.25]))));

// int8: within half a step of the scale per element, and dot close
let xs: [float] = [];
let ys: [float] = [];
for i in 0..1000 {
    push(xs, math.sin(i as float));
    push(ys, math.cos(0.7 * (i as float)));
}
let qx = vec.quantize(xs);
let qy = vec.quantize(ys);
println(len(qx));
let back = vec.dequantize(qx);
let worst = 0.0;
for i in 0..1000 {
    worst = math.max(worst, math.abs(back[i] - xs[i]));
}
println(worst <= 0.5 / 127.0 + 1e-6);
println(math.abs(vec.dot_q(qx, qy) - vec.dot(xs, ys)) < 0.05 * math.sqrt(1000.0));
println(len(vec.quantize(empty)));
