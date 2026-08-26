// json.decode()'s target type is inferred from the binding's
// annotation (same mechanism as ok()/err()); without one it can't be
// inferred.
import "json";
let x = json.decode("5");
