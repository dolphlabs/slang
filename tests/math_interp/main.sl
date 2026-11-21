// math/interp: each curve through its knots, between them against hand
// values, monotonicity of the monotone cubic, the spline against a cubic
// it must reproduce, extrapolation modes, input checks, and the grid.
import "math/interp";
import "math";

fn near(a: float, b: float, tol: float) -> bool {
    return math.abs(a - b) <= tol;
}

let xs = [0.0, 1000.0, 10000.0];
let ys = [2.5, 1.8, 0.9];
let lin = interp.linear(xs, ys) ?? interp.empty();
println(lin.at(4200.0));
println(lin.at(0.0));
println(lin.at(10000.0));
println(lin.at(-5.0));                         // Clamp
println(lin.set_extrapolate(interp.Extrapolate.Linear).at(-1000.0));
println(math.is_nan(lin.set_extrapolate(interp.Extrapolate.None).at(20000.0)));
println(lin.set_extrapolate(interp.Extrapolate.Clamp).slope(500.0));
println(inspect(lin.at_all([0.0, 500.0, 1000.0, 5500.0])));

let st = interp.step([0.0, 100.0, 500.0], [10.0, 8.0, 5.0]) ?? interp.empty();
println(st.at(250.0));
println(st.at(100.0));
println(st.at(99.999));
println(st.at(1e9));
println(st.at(-1.0));
println(math.is_nan(st.set_extrapolate(interp.Extrapolate.None).at(-1.0)));

// monotone data stays monotone, with no overshoot past the data's range
let mx = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0];
let my = [0.0, 0.1, 0.2, 5.0, 5.1, 5.2];
let mono = interp.monotone(mx, my) ?? interp.empty();
let prev = -1.0;
let ok_mono = true;
let x = 0.0;
while x <= 5.0 {
    let v = mono.at(x);
    if v < prev - 1e-12 || v < 0.0 || v > 5.2 { ok_mono = false; }
    prev = v;
    x += 0.01;
}
println(ok_mono);
println(mono.at(3.0));
// the natural spline overshoots on the same data; monotone does not
let sp = interp.spline(mx, my) ?? interp.empty();
println(sp.at(2.2) < 0.2 || sp.at(3.8) > 5.1);
// a natural spline reproduces a straight line exactly
let line = interp.spline([0.0, 1.0, 3.0, 7.0], [1.0, 3.0, 7.0, 15.0]) ?? interp.empty();
println(near(line.at(2.0), 5.0, 1e-12) && near(line.at(5.5), 12.0, 1e-12));
println(near(line.slope(4.0), 2.0, 1e-12));
// through every knot
let ok_knots = true;
for i in 0..len(mx) {
    if !near(sp.at(mx[i]), my[i], 1e-12) || !near(mono.at(mx[i]), my[i], 1e-12) { ok_knots = false; }
}
println(ok_knots);
// the spline's interior second derivative matches a finite difference
let s1 = sp.slope(2.5);
let s2 = (sp.at(2.5 + 1e-6) - sp.at(2.5 - 1e-6)) / 2e-6;
println(near(s1, s2, 1e-6));
// one point
let one = interp.monotone([3.0], [7.0]) ?? interp.empty();
println(one.at(-100.0) + one.at(100.0));

// descending queries still work (binary search), ascending use the cache
let desc = 0.0;
let q = 10000.0;
while q >= 0.0 { desc += lin.at(q); q -= 250.0; }
println(math.round_to(desc, 6));
let cp = lin.copy();
println(cp.at(4200.0) == lin.at(4200.0));

let bad1 = interp.linear([0.0, 1.0], [1.0]);
if let c = bad1 { println("no!"); } else let e = err_of(bad1) { println(e); }
let bad2 = interp.linear([0.0, 0.0], [1.0, 2.0]);
if let c = bad2 { println("no!"); } else let e = err_of(bad2) { println(e); }
let bad3 = interp.spline([0.0, math.nan], [1.0, 2.0]);
if let c = bad3 { println("no!"); } else let e = err_of(bad3) { println(e); }
let bad4 = interp.step([], []);
if let c = bad4 { println("no!"); } else let e = err_of(bad4) { println(e); }
println(math.is_nan(interp.empty().at(1.0)));

let g = interp.grid([0.0, 10.0], [0.0, 100.0, 200.0], [1.0, 2.0, 3.0, 11.0, 12.0, 13.0]);
if let gr = g {
    println(gr.at(5.0, 50.0));
    println(gr.at(10.0, 200.0));
    println(gr.at(-5.0, 500.0));
}
let gb = interp.grid([0.0, 1.0], [0.0], [1.0]);
if let gr = gb { println("no!"); } else let e = err_of(gb) { println(e); }
