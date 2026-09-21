// Methods of a generic struct declared in another package, instantiated
// over a type only this package knows.
import "stash";

struct Thing {
    id: int,
    name: str,
}

let s = stash.Slot { v: Thing { id: 7, name: "seven" }, set: true };
println(s.value().name);
println(s.filled());
println(s.through().id);

let si = stash.slot_of(4);
println(si.value());

let b = stash.Bag[Thing] { items: [] };
println(b.add(Thing { id: 1, name: "a" }));
println(b.add(Thing { id: 2, name: "b" }));
println(b.size());

let bi = stash.Bag[int] { items: [] };
println(bi.add(9));
