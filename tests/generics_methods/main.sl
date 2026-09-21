// Methods on a generic struct: `impl Box[T] { ... }`.
//
// A method is instantiated the first time some instance is asked for it,
// and checked with T bound then. So a method that only makes sense for
// some T is fine as long as nobody calls it for the others -- `doubled`
// below multiplies, and `Box[str]` exists in this program without ever
// asking for it.

struct Box[T] {
    v: T,
}

impl Box[T] {
    fn get(self: Box[T]) -> T {
        return self.v;
    }

    fn doubled(self: Box[T]) -> int {
        return self.v * 2;          // only ever instantiated for Box[int]
    }

    fn same(self: Box[T], other: Box[T]) -> bool {
        return self.v == other.v;
    }

    // a method whose return type is a new instance, made while this one
    // is being generated
    fn wrapped(self: Box[T]) -> Box[Box[T]] {
        return Box[Box[T]] { v: self };
    }

    fn apply(self: Box[T], f: fn(T) -> T) -> Box[T] {
        return Box[T] { v: f(self.v) };
    }
}

// the impl block may name its own parameters; they match by position
struct Pair[K, V] {
    k: K,
    v: V,
}

impl Pair[A, B] {
    fn key(self: Pair[A, B]) -> A {
        return self.k;
    }

    fn flip(self: Pair[A, B]) -> Pair[B, A] {
        return Pair[B, A] { k: self.v, v: self.k };
    }
}

// a gc struct: self is a pointer, and its list field outlives the call
gc struct Stack[T] {
    items: [T],
    name: str,
}

impl Stack[T] {
    fn push_one(self: Stack[T], x: T) -> int {
        push(self.items, x);
        return len(self.items);
    }

    fn count(self: Stack[T]) -> int {
        return len(self.items);
    }

    // a method calling another method of the same instance, in a loop:
    // the receiver must stay rooted across every call
    fn grow(self: Stack[T], x: T, n: int) -> int {
        let i = 0;
        while i < n {
            self.push_one(x);
            i = i + 1;
        }
        return self.count();
    }

    fn first(self: Stack[T]) -> opt[T] {
        if len(self.items) == 0 {
            return none;
        }
        return some(self.items[0]);
    }

    // liveness: `made` is a heap value live only inside this body, across
    // an allocating call
    fn labelled(self: Stack[T], tag: str) -> str {
        let made = self.name + "-" + tag;
        self.grow_label();
        return made;
    }

    fn grow_label(self: Stack[T]) -> int {
        let junk = "";
        let i = 0;
        while i < 200 {
            junk = junk + to_str(i);
            i = i + 1;
        }
        return len(junk);
    }
}

// recursion through the instance's own method
gc struct Node[T] {
    val: T,
    next: opt[Node[T]],
}

impl Node[T] {
    fn depth(self: Node[T]) -> int {
        guard let n = self.next else {
            return 1;
        }
        return 1 + n.depth();
    }

    fn last(self: Node[T]) -> T {
        guard let n = self.next else {
            return self.val;
        }
        return n.last();
    }
}

fn inc(x: int) -> int {
    return x + 1;
}

let bi = Box { v: 21 };
println(bi.doubled());
println(bi.get());
println(bi.apply(inc).get());
println(bi.wrapped().get().get());

let bs = Box { v: "text" };
println(bs.get());                       // Box[str] never asks for doubled
println(bs.same(Box { v: "text" }));
println(bs.same(Box { v: "other" }));

let p = Pair { k: "one", v: 1 };
println(p.key());
println(p.flip().key());

let s = Stack[str] { items: [], name: "s" };
println(s.push_one("a"));
println(s.grow("b", 300));
println(s.first() ?? "empty");
println(s.labelled("tag"));
let empty = Stack[int] { items: [], name: "e" };
println(empty.first() ?? -1);
println(empty.grow(7, 3));

let c = Node[str] { val: "c", next: none };
let b = Node[str] { val: "b", next: some(c) };
let a = Node[str] { val: "a", next: some(b) };
println(a.depth());
println(a.last());
