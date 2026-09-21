// A generic struct declared in one package, instantiated from another --
// including with a type that only the importing package knows.
import "stash";

struct Thing {
    id: int,
    name: str,
}

// stash.Stack[Thing] is an instance whose argument is main.Thing
let stack = stash.Stack[Thing] { items: [Thing { id: 1, name: "a" }] };
push(stack.items, Thing { id: 2, name: "b" });
println(len(stack.items));
println(stack.items[1].name);

// inferred, through a dotted name
let slot = stash.Slot { v: Thing { id: 7, name: "seven" }, set: true };
println(slot.v.id);

// a generic in stash naming another generic in stash, over main's type
let w = stash.Wrapped[Thing] {
    inner: stash.Slot[Thing] { v: Thing { id: 3, name: "c" }, set: true },
    note: "wrapped"
};
println(w.inner.v.name + " " + w.note);

// the same template over a builtin, through stash's own functions
let ints = stash.Stack[int] { items: [1, 2, 3] };
println(stash.size(ints));
let e = stash.empty_slot(5);
println(e.v);
println(e.set);
