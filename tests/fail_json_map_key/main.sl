// JSON object keys are always strings; a map with a non-str key type
// cannot be json.encode'd.
import "json";
let m: map[int]str = {};
let s: str = json.encode(m);
