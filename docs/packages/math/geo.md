# math/geo

> Package math/geo.

Points on the Earth: distances, bearings, "everything within 5 km",
geohash keys for spatial indexes, and geofences.

```slang
import "math/geo";

let berlin = geo.point(52.5200, 13.4050);          // lat, lon in degrees
let paris = geo.point(48.8566, 2.3522);
geo.distance(berlin, paris);                       // 877465 m (haversine)
geo.distance_exact(berlin, paris) ?? 0.0;          // 879699 m (WGS-84)
geo.bearing(berlin, paris);                        // 246.74 degrees
geo.destination(berlin, 90.0, 1000.0);             // 1 km due east
let box = geo.bounding_box(berlin, 5000.0);        // a WHERE clause's lat/lon ranges
geo.geohash(berlin, 7);                            // "u33dc0c"
geo.geohash_neighbors("u33dc0c");                  // the 8 cells around it
geo.contains(fence, p);                            // point in polygon
```

- `distance` is the haversine great-circle distance on a sphere of the
  mean Earth radius (within 0.5% of the ellipsoid); `distance_exact` is
  Vincenty's inverse formula on WGS-84, to well under a millimetre
  (`none` for nearly antipodal points, where it does not converge).
- `bearing`, `destination`, `midpoint`, `distance_to_segment` (how far
  a courier is from the route).
- `bounding_box(center, meters)` and `in_box`: the smallest box holding
  a radius, crossing the antimeridian (`min_lon > max_lon`) or spanning
  every longitude near a pole. Filter an index with the box, then keep
  the rows within `distance`.
- `geohash(p, chars)`, `geohash_decode`, `geohash_box`,
  `geohash_neighbors` (either case accepted).
- `contains` (even-odd rule, for fences small next to a hemisphere) and
  `area` in square metres.

## API

### `let EARTH_RADIUS = 6371008.8;`

The mean Earth radius (IUGG), metres.

### `struct Point`

### `fn point(lat: float, lon: float) -> Point`

A point; latitude in [-90, 90], longitude wrapped into [-180, 180).

### `fn distance(a: Point, b: Point) -> float`

The great-circle distance in metres (haversine): accurate for any pair of points, antipodes included, on the spherical Earth.

### `fn distance_exact(a: Point, b: Point) -> opt[float]`

The distance in metres on the WGS-84 ellipsoid (Vincenty's inverse formula, 1975). none for nearly antipodal points, where the iteration does not converge; use distance() there.

### `fn bearing(a: Point, b: Point) -> float`

The initial bearing from a toward b, degrees clockwise from north in [0, 360). Along a great circle the bearing changes as you go.

### `fn destination(from: Point, bearing_deg: float, meters: float) -> Point`

The point `meters` from `from` along the initial bearing (spherical).

### `fn midpoint(a: Point, b: Point) -> Point`

The midpoint of the great-circle path between a and b.

### `struct Box`

A latitude/longitude rectangle. When it crosses the antimeridian, min_lon > max_lon: a longitude is inside when it is >= min_lon OR <= max_lon.

### `fn bounding_box(center: Point, meters: float) -> Box`

The smallest box holding every point within `meters` of center (spherical; Chan's method). Query an index with the box, then keep the rows whose distance() is within the radius. A box around a pole spans every longitude.

### `fn in_box(b: Box, p: Point) -> bool`

Whether p is inside the box (edges included), across the antimeridian too.

### `fn geohash(p: Point, chars: int) -> str`

The geohash of p with `chars` characters (1 to 12; 7 is about 150 m, 9 about 5 m): nearby points share prefixes, so it indexes well as a string key.

### `fn geohash_box(hash: str) -> result[Box, str]`

The cell a geohash names. An error for an empty hash, one longer than 12 or a character outside the geohash alphabet (either case).

### `fn geohash_decode(hash: str) -> result[Point, str]`

The centre of a geohash's cell.

### `fn geohash_neighbors(hash: str) -> result[[str], str]`

The eight cells around a geohash, at its length: N, NE, E, SE, S, SW, W, NW. A radius search covers the cell and its neighbours. Cells beyond a pole are left out.

### `fn contains(polygon: [Point], p: Point) -> bool`

Whether p lies inside the polygon given by its vertices (in order, either direction, closed or not), by the even-odd rule in plain latitude/longitude: right for geofences that are small next to a hemisphere and do not cross the antimeridian or a pole.

### `fn area(polygon: [Point]) -> float`

The area of a polygon in square metres on the spherical Earth (the spherical-excess formula of Chamberlain and Duquette), for polygons not crossing the antimeridian.

### `fn distance_to_segment(p: Point, a: Point, b: Point) -> float`

The shortest distance in metres from p to the great-circle segment a-b (spherical): the cross-track distance when the foot of the perpendicular falls between a and b, else the nearer endpoint. For "is the courier within 50 m of the route".

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
