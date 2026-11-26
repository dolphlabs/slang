import "json";

struct Inner { x: int }
struct Outer {
    inner: Inner `json:"inner,omitempty"`,
}

println(json.encode(Outer { inner: Inner { x: 1 } }));
