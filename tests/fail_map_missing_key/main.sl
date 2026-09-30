// Indexing a map with a key it does not have names the key and says how
// to avoid the panic. The message used to end "(index 0, length 0)",
// the bounds-check wording, which says nothing about a map.
let ages: map[str]int = {"ada": 36};
println(ages["ada"]);
println(ages["bob"]);
