// Import resolution for names that are also built-in packages. A
// directory next to the importer comes first, then the built-in -- but
// only the exact path "json" is the built-in json, and a directory only
// shadows a built-in if it holds .sl files.
import "json";              // built-in: ./json/ holds only data
import "lib/json" as mine;  // a local package that merely ends in "json"
import "time";              // ./time/ holds .sl files, so it shadows

gc struct P { a: int }

println(json.encode(P { a: 1 }));
println(mine.tag());
println(time.label());
