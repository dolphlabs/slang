// math/geo against published values: great-circle and WGS-84 distances
// (Vincenty's own test line, Flinders Peak to Buninyong), bearings,
// destinations, boxes across the antimeridian and a pole, geohashes, and
// polygons.
import "math/geo";
import "math";

fn near(a: float, b: float, tol: float) -> bool {
    return math.abs(a - b) <= tol;
}

let berlin = geo.point(52.5200, 13.4050);
let paris = geo.point(48.8566, 2.3522);
println(math.round(geo.distance(berlin, paris)));
println(math.round(geo.distance_exact(berlin, paris) ?? 0.0));
println(geo.distance(berlin, berlin));
// Vincenty 1975 / Geoscience Australia: 54972.271 m
let flinders = geo.point(-(37.0 + 57.0 / 60.0 + 3.72030 / 3600.0), 144.0 + 25.0 / 60.0 + 29.52440 / 3600.0);
let buninyong = geo.point(-(37.0 + 39.0 / 60.0 + 10.15610 / 3600.0), 143.0 + 55.0 / 60.0 + 35.38390 / 3600.0);
println(near(geo.distance_exact(flinders, buninyong) ?? 0.0, 54972.271, 0.001));
// antipodes: haversine is exact there
println(near(geo.distance(geo.point(0.0, 0.0), geo.point(0.0, 180.0)), math.pi * geo.EARTH_RADIUS, 1e-6));
println(math.round_to(geo.bearing(berlin, paris), 4));
println(geo.bearing(geo.point(0.0, 0.0), geo.point(1.0, 0.0)));
println(geo.bearing(geo.point(0.0, 0.0), geo.point(0.0, 1.0)));
let dst = geo.destination(berlin, geo.bearing(berlin, paris), geo.distance(berlin, paris));
println(near(dst.lat, paris.lat, 1e-9) && near(dst.lon, paris.lon, 1e-9));
let mid = geo.midpoint(berlin, paris);
println(near(geo.distance(berlin, mid), geo.distance(mid, paris), 1e-6));
println(geo.point(10.0, 190.0).lon);
println(geo.point(95.0, -540.0).lat);

let box = geo.bounding_box(berlin, 5000.0);
println(geo.in_box(box, geo.destination(berlin, 45.0, 4999.0)));
println(geo.in_box(box, geo.destination(berlin, 0.0, 5001.0)));
let wrap = geo.bounding_box(geo.point(0.0, 179.99), 10000.0);
println(wrap.min_lon > wrap.max_lon);
println(geo.in_box(wrap, geo.point(0.0, -179.99)));
let polar = geo.bounding_box(geo.point(89.99, 0.0), 10000.0);
println("${polar.min_lon} ${polar.max_lon} ${polar.max_lat}");

println(geo.geohash(geo.point(57.64911, 10.40744), 11));         // u4pruydqqvj
println(geo.geohash(berlin, 7));
let dec = geo.geohash_decode("u4pruydqqvj") ?? geo.point(0.0, 0.0);
println(near(dec.lat, 57.64911, 1e-5) && near(dec.lon, 10.40744, 1e-5));
let up = geo.geohash_decode("U4PRUYDQQVJ") ?? geo.point(0.0, 0.0);
println(up.lat == dec.lat);
let bad = geo.geohash_decode("u4pa");
if let p = bad { println("no!"); } else let e = err_of(bad) { println(e); }
let nb = geo.geohash_neighbors("u33dc0c") ?? [];
println(inspect(nb));
println(len(geo.geohash_neighbors("u") ?? []));
println(len(geo.geohash_neighbors("zzzzz") ?? []));        // top row: no north

let square = [geo.point(0.0, 0.0), geo.point(0.0, 1.0), geo.point(1.0, 1.0), geo.point(1.0, 0.0)];
println(geo.contains(square, geo.point(0.5, 0.5)));
println(geo.contains(square, geo.point(1.5, 0.5)));
println(geo.contains([geo.point(0.0, 0.0), geo.point(1.0, 1.0)], geo.point(0.5, 0.5)));
// 1 x 1 degree at the equator: about 12,364 km^2
println(math.round(geo.area(square) / 1000000.0));
println(math.round(geo.distance_to_segment(geo.point(0.5, 0.5), geo.point(0.0, 0.0), geo.point(0.0, 1.0))));
println(math.round(geo.distance_to_segment(geo.point(0.0, 2.0), geo.point(0.0, 0.0), geo.point(0.0, 1.0))));
