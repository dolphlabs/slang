// A generic method first called from a TOP-LEVEL statement, whose body
// then needs another instance.
//
// Such a method is instantiated after the body-generation loop has
// finished, so its body is first WALKED by the analysis passes that run
// between the dry and the real run -- and last of those is the borrow
// checker, which re-reads the original expressions long after the cursor
// that installed the type parameters has moved on. A struct literal naming
// its own type (`Item[S] { ... }`) could not be resolved there, so a
// program of this shape did not compile at all. Each MIR function now
// carries the environment its body was lowered under.
//
// This is the `Router[S]` shape a framework needs: a generic holder, a
// method that builds another instance, and app state carried through.

gc struct Item[S] {
    v: S,
    tag: str,
}

gc struct Holder[S] {
    items: [Item[S]],
    name: str,
}

gc struct Ctx[S] {
    state: S,
    note: str,
}

fn churn() -> int {
    let s = "";
    let i = 0;
    while i < 300 {
        s = s + to_str(i);
        i = i + 1;
    }
    return len(s);
}

impl Holder[S] {
    // builds an instance of another generic struct, and borrows a local,
    // so both the earlier failures are exercised
    fn add(self: Holder[S], v: S, tag: str) -> int {
        let made = Item[S] { v: v, tag: self.name + "/" + tag };
        let counted = Count { n: len(made.tag) };
        let r = &counted;          // a borrow, so borrowck must walk this body
        churn();
        push(self.items, made);
        return len(self.items) + r.n;
    }

    fn wrap(self: Holder[S], v: S) -> Ctx[S] {
        return Ctx[S] { state: v, note: self.name };
    }

    fn tag_of(self: Holder[S], i: int) -> str {
        return self.items[i].tag;
    }
}

struct App {
    id: int,
}

struct Count {
    n: int,
}

// every call below is top level: the instance does not exist until here
let h = Holder[int] { items: [], name: "h" };
println(h.add(7, "a"));
println(h.tag_of(0));
println(h.wrap(3).note);

let ha = Holder[App] { items: [], name: "app" };
println(ha.add(App { id: 1 }, "b"));
println(ha.tag_of(0));
println(ha.wrap(App { id: 2 }).state.id);
