// Points on the Earth: distances, bearings, "everything within 5 km",
// geohash keys for spatial indexes, and geofences.
//
//     import "math/geo";
//
//     let a = geo.point(52.5200, 13.4050);           // Berlin (lat, lon degrees)
//     let b = geo.point(48.8566, 2.3522);            // Paris
//     geo.distance(a, b)                             // 877465 m (haversine)
//     geo.distance_exact(a, b) ?? 0.0                // 879699 m (WGS-84, Vincenty)
//     geo.bearing(a, b)                              // degrees from north
//     let box = geo.bounding_box(a, 5000.0);         // for WHERE lat BETWEEN ..
//     geo.geohash(a, 7)                              // "u33dc0c"
//     geo.contains(fence, p)                         // point in polygon
//
// Latitudes and longitudes are in degrees (WGS-84, as GPS reports them),
// distances in metres, bearings in degrees clockwise from true north.
// distance() treats the Earth as a sphere of mean radius 6371008.8 m,
// within 0.5% of the ellipsoid everywhere; distance_exact() is the
// ellipsoidal distance, to well under a millimetre.

import "math";

// The mean Earth radius (IUGG), metres.
pub let EARTH_RADIUS = 6371008.8;

// WGS-84.
let WGS_A = 6378137.0;
let WGS_F = 0.0033528106647474805;    // 1 / 298.257223563
let WGS_B = 6356752.314245179;

pub struct Point {
    lat: float,
    lon: float,
}

// A point; latitude in [-90, 90], longitude wrapped into [-180, 180).
pub fn point(lat: float, lon: float) -> Point {
    return Point { lat: math.clamp(lat, -90.0, 90.0), lon: wrap_lon(lon) };
}

fn wrap_lon(lon: float) -> float {
    if lon >= -180.0 && lon < 180.0 {
        return lon;
    }
    return math.mod_euclid(lon + 180.0, 360.0) - 180.0;
}

// The great-circle distance in metres (haversine): accurate for any pair
// of points, antipodes included, on the spherical Earth.
pub fn distance(a: Point, b: Point) -> float {
    let p1 = math.to_radians(a.lat);
    let p2 = math.to_radians(b.lat);
    let dp = p2 - p1;
    let dl = math.to_radians(b.lon - a.lon);
    let s1 = math.sin(0.5 * dp);
    let s2 = math.sin(0.5 * dl);
    let h = s1 * s1 + math.cos(p1) * math.cos(p2) * s2 * s2;
    return 2.0 * EARTH_RADIUS * math.asin(math.sqrt(math.min(h, 1.0)));
}

// The distance in metres on the WGS-84 ellipsoid (Vincenty's inverse
// formula, 1975). none for nearly antipodal points, where the iteration
// does not converge; use distance() there.
pub fn distance_exact(a: Point, b: Point) -> opt[float] {
    let l = math.to_radians(b.lon - a.lon);
    let u1 = math.atan((1.0 - WGS_F) * math.tan(math.to_radians(a.lat)));
    let u2 = math.atan((1.0 - WGS_F) * math.tan(math.to_radians(b.lat)));
    let su1 = math.sin(u1);
    let cu1 = math.cos(u1);
    let su2 = math.sin(u2);
    let cu2 = math.cos(u2);
    let lambda = l;
    for iter in 0..200 {
        let sl = math.sin(lambda);
        let cl = math.cos(lambda);
        let ss = math.sqrt((cu2 * sl) * (cu2 * sl) + (cu1 * su2 - su1 * cu2 * cl) * (cu1 * su2 - su1 * cu2 * cl));
        if ss == 0.0 {
            return some(0.0);
        }
        let cs = su1 * su2 + cu1 * cu2 * cl;
        let sigma = math.atan2(ss, cs);
        let sa = cu1 * cu2 * sl / ss;
        let c2a = 1.0 - sa * sa;
        let c2sm = 0.0;
        if c2a != 0.0 {
            c2sm = cs - 2.0 * su1 * su2 / c2a;
        }
        let c = WGS_F / 16.0 * c2a * (4.0 + WGS_F * (4.0 - 3.0 * c2a));
        let prev = lambda;
        lambda = l + (1.0 - c) * WGS_F * sa *
                 (sigma + c * ss * (c2sm + c * cs * (-1.0 + 2.0 * c2sm * c2sm)));
        if math.abs(lambda - prev) < 1e-12 {
            let u2sq = c2a * (WGS_A * WGS_A - WGS_B * WGS_B) / (WGS_B * WGS_B);
            let ka = 1.0 + u2sq / 16384.0 * (4096.0 + u2sq * (-768.0 + u2sq * (320.0 - 175.0 * u2sq)));
            let kb = u2sq / 1024.0 * (256.0 + u2sq * (-128.0 + u2sq * (74.0 - 47.0 * u2sq)));
            let ds = kb * ss * (c2sm + kb / 4.0 * (cs * (-1.0 + 2.0 * c2sm * c2sm) -
                     kb / 6.0 * c2sm * (-3.0 + 4.0 * ss * ss) * (-3.0 + 4.0 * c2sm * c2sm)));
            return some(WGS_B * ka * (sigma - ds));
        }
    }
    return none;
}

// The initial bearing from a toward b, degrees clockwise from north in
// [0, 360). Along a great circle the bearing changes as you go.
pub fn bearing(a: Point, b: Point) -> float {
    let p1 = math.to_radians(a.lat);
    let p2 = math.to_radians(b.lat);
    let dl = math.to_radians(b.lon - a.lon);
    let y = math.sin(dl) * math.cos(p2);
    let x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return math.mod_euclid(math.to_degrees(math.atan2(y, x)), 360.0);
}

// The point `meters` from `from` along the initial bearing (spherical).
pub fn destination(from: Point, bearing_deg: float, meters: float) -> Point {
    let d = meters / EARTH_RADIUS;
    let th = math.to_radians(bearing_deg);
    let p1 = math.to_radians(from.lat);
    let l1 = math.to_radians(from.lon);
    let sp2 = math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(th);
    let p2 = math.asin(math.clamp(sp2, -1.0, 1.0));
    let l2 = l1 + math.atan2(math.sin(th) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * sp2);
    return point(math.to_degrees(p2), math.to_degrees(l2));
}

// The midpoint of the great-circle path between a and b.
pub fn midpoint(a: Point, b: Point) -> Point {
    let p1 = math.to_radians(a.lat);
    let p2 = math.to_radians(b.lat);
    let l1 = math.to_radians(a.lon);
    let dl = math.to_radians(b.lon - a.lon);
    let bx = math.cos(p2) * math.cos(dl);
    let by = math.cos(p2) * math.sin(dl);
    let p3 = math.atan2(math.sin(p1) + math.sin(p2), math.sqrt((math.cos(p1) + bx) * (math.cos(p1) + bx) + by * by));
    let l3 = l1 + math.atan2(by, math.cos(p1) + bx);
    return point(math.to_degrees(p3), math.to_degrees(l3));
}

// A latitude/longitude rectangle. When it crosses the antimeridian,
// min_lon > max_lon: a longitude is inside when it is >= min_lon OR
// <= max_lon.
pub struct Box {
    min_lat: float,
    min_lon: float,
    max_lat: float,
    max_lon: float,
}

// The smallest box holding every point within `meters` of center
// (spherical; Chan's method). Query an index with the box, then keep the
// rows whose distance() is within the radius. A box around a pole spans
// every longitude.
pub fn bounding_box(center: Point, meters: float) -> Box {
    let r = math.max(meters, 0.0) / EARTH_RADIUS;
    let lat = math.to_radians(center.lat);
    let lon = math.to_radians(center.lon);
    let min_lat = lat - r;
    let max_lat = lat + r;
    let half_pi = 0.5 * math.pi;
    if min_lat <= -half_pi || max_lat >= half_pi {
        return Box {
            min_lat: math.to_degrees(math.max(min_lat, -half_pi)), min_lon: -180.0,
            max_lat: math.to_degrees(math.min(max_lat, half_pi)), max_lon: 180.0
        };
    }
    let dl = math.asin(math.min(math.sin(r) / math.cos(lat), 1.0));
    return Box {
        min_lat: math.to_degrees(min_lat), min_lon: wrap_lon(math.to_degrees(lon - dl)),
        max_lat: math.to_degrees(max_lat), max_lon: wrap_lon(math.to_degrees(lon + dl))
    };
}

// Whether p is inside the box (edges included), across the antimeridian
// too.
pub fn in_box(b: Box, p: Point) -> bool {
    if p.lat < b.min_lat || p.lat > b.max_lat {
        return false;
    }
    if b.min_lon <= b.max_lon {
        return p.lon >= b.min_lon && p.lon <= b.max_lon;
    }
    return p.lon >= b.min_lon || p.lon <= b.max_lon;
}

// ---- geohash ---------------------------------------------------------

// The geohash of p with `chars` characters (1 to 12; 7 is about 150 m,
// 9 about 5 m): nearby points share prefixes, so it indexes well as a
// string key.
pub fn geohash(p: Point, chars: int) -> str {
    let n = math.clamp(chars, 1, 12);
    let lat_lo = -90.0;
    let lat_hi = 90.0;
    let lon_lo = -180.0;
    let lon_hi = 180.0;
    let out: [str] = [];
    let even = true;
    let bits = 0;
    let ch = 0;
    while len(out) < n {
        if even {
            let mid = 0.5 * (lon_lo + lon_hi);
            if p.lon >= mid {
                ch = ch * 2 + 1;
                lon_lo = mid;
            } else {
                ch = ch * 2;
                lon_hi = mid;
            }
        } else {
            let mid = 0.5 * (lat_lo + lat_hi);
            if p.lat >= mid {
                ch = ch * 2 + 1;
                lat_lo = mid;
            } else {
                ch = ch * 2;
                lat_hi = mid;
            }
        }
        even = !even;
        bits += 1;
        if bits == 5 {
            push(out, b32(ch));
            bits = 0;
            ch = 0;
        }
    }
    let s = "";
    for c in out {
        s = s + c;
    }
    return s;
}

// The cell a geohash names. An error for an empty hash, one longer than
// 12 or a character outside the geohash alphabet (either case).
pub fn geohash_box(hash: str) -> result[Box, str] {
    let raw = to_bytes(hash);
    if len(raw) == 0 || len(raw) > 12 {
        return err("geo: a geohash has 1 to 12 characters");
    }
    let lat_lo = -90.0;
    let lat_hi = 90.0;
    let lon_lo = -180.0;
    let lon_hi = 180.0;
    let even = true;
    for i in 0..len(raw) {
        let v = b32_value(raw[i]);
        if v < 0 {
            return err("geo: '" + hash + "' is not a geohash");
        }
        let bit = 16;
        while bit > 0 {
            let on = (v & bit) != 0;
            if even {
                let mid = 0.5 * (lon_lo + lon_hi);
                if on { lon_lo = mid; } else { lon_hi = mid; }
            } else {
                let mid = 0.5 * (lat_lo + lat_hi);
                if on { lat_lo = mid; } else { lat_hi = mid; }
            }
            even = !even;
            bit = bit / 2;
        }
    }
    return ok(Box { min_lat: lat_lo, min_lon: lon_lo, max_lat: lat_hi, max_lon: lon_hi });
}

// The centre of a geohash's cell.
pub fn geohash_decode(hash: str) -> result[Point, str] {
    let r = geohash_box(hash);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    return ok(Point { lat: 0.5 * (b.min_lat + b.max_lat), lon: 0.5 * (b.min_lon + b.max_lon) });
}

// The eight cells around a geohash, at its length: N, NE, E, SE, S, SW, W,
// NW. A radius search covers the cell and its neighbours. Cells beyond a
// pole are left out.
pub fn geohash_neighbors(hash: str) -> result[[str], str] {
    let r = geohash_box(hash);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    let n = len(hash);
    let dlat = b.max_lat - b.min_lat;
    let dlon = b.max_lon - b.min_lon;
    let clat = 0.5 * (b.min_lat + b.max_lat);
    let clon = 0.5 * (b.min_lon + b.max_lon);
    let out: [str] = [];
    let dys = [1.0, 1.0, 0.0, -1.0, -1.0, -1.0, 0.0, 1.0];
    let dxs = [0.0, 1.0, 1.0, 1.0, 0.0, -1.0, -1.0, -1.0];
    for i in 0..8 {
        let lat = clat + dys[i] * dlat;
        if lat > 90.0 || lat < -90.0 {
            continue;
        }
        push(out, geohash(point(lat, clon + dxs[i] * dlon), n));
    }
    return ok(out);
}

fn b32(v: int) -> str {
    return switch v {
        case 0 { "0" } case 1 { "1" } case 2 { "2" } case 3 { "3" }
        case 4 { "4" } case 5 { "5" } case 6 { "6" } case 7 { "7" }
        case 8 { "8" } case 9 { "9" } case 10 { "b" } case 11 { "c" }
        case 12 { "d" } case 13 { "e" } case 14 { "f" } case 15 { "g" }
        case 16 { "h" } case 17 { "j" } case 18 { "k" } case 19 { "m" }
        case 20 { "n" } case 21 { "p" } case 22 { "q" } case 23 { "r" }
        case 24 { "s" } case 25 { "t" } case 26 { "u" } case 27 { "v" }
        case 28 { "w" } case 29 { "x" } case 30 { "y" }
        default { "z" }
    };
}

// The value of a geohash character, -1 for one outside the alphabet
// (which leaves out a, i, l and o).
fn b32_value(c: int) -> int {
    let ch = c;
    if ch >= 65 && ch <= 90 {
        ch += 32;
    }
    if ch >= 48 && ch <= 57 {
        return ch - 48;
    }
    return switch ch {
        case 98 { 10 } case 99 { 11 } case 100 { 12 } case 101 { 13 }
        case 102 { 14 } case 103 { 15 } case 104 { 16 } case 106 { 17 }
        case 107 { 18 } case 109 { 19 } case 110 { 20 } case 112 { 21 }
        case 113 { 22 } case 114 { 23 } case 115 { 24 } case 116 { 25 }
        case 117 { 26 } case 118 { 27 } case 119 { 28 } case 120 { 29 }
        case 121 { 30 } case 122 { 31 }
        default { -1 }
    };
}

// ---- polygons --------------------------------------------------------

// Whether p lies inside the polygon given by its vertices (in order,
// either direction, closed or not), by the even-odd rule in plain
// latitude/longitude: right for geofences that are small next to a
// hemisphere and do not cross the antimeridian or a pole.
pub fn contains(polygon: [Point], p: Point) -> bool {
    let n = len(polygon);
    if n < 3 {
        return false;
    }
    let inside = false;
    let j = n - 1;
    for i in 0..n {
        let a = polygon[i];
        let b = polygon[j];
        if (a.lat > p.lat) != (b.lat > p.lat) {
            let x = (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon;
            if p.lon < x {
                inside = !inside;
            }
        }
        j = i;
    }
    return inside;
}

// The area of a polygon in square metres on the spherical Earth (the
// spherical-excess formula of Chamberlain and Duquette), for polygons not
// crossing the antimeridian.
pub fn area(polygon: [Point]) -> float {
    let n = len(polygon);
    if n < 3 {
        return 0.0;
    }
    let total = 0.0;
    for i in 0..n {
        let a = polygon[i];
        let b = polygon[(i + 1) % n];
        total += math.to_radians(b.lon - a.lon) *
                 (2.0 + math.sin(math.to_radians(a.lat)) + math.sin(math.to_radians(b.lat)));
    }
    return math.abs(total * EARTH_RADIUS * EARTH_RADIUS / 2.0);
}

// The shortest distance in metres from p to the great-circle segment a-b
// (spherical): the cross-track distance when the foot of the
// perpendicular falls between a and b, else the nearer endpoint. For
// "is the courier within 50 m of the route".
pub fn distance_to_segment(p: Point, a: Point, b: Point) -> float {
    let dap = distance(a, p) / EARTH_RADIUS;
    let tap = math.to_radians(bearing(a, p));
    let tab = math.to_radians(bearing(a, b));
    let xt = math.asin(math.clamp(math.sin(dap) * math.sin(tap - tab), -1.0, 1.0));
    let at = math.acos(math.clamp(math.cos(dap) / math.cos(xt), -1.0, 1.0));
    let dab = distance(a, b) / EARTH_RADIUS;
    if math.cos(tap - tab) < 0.0 {
        return distance(a, p);
    }
    if at > dab {
        return distance(b, p);
    }
    return math.abs(xt) * EARTH_RADIUS;
}
