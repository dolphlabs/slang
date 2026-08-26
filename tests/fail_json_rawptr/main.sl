// json.decode's target type must be JSON-representable; rawptr has
// no JSON encoding.
import "json";
let r: result[rawptr, str] = json.decode("null");
