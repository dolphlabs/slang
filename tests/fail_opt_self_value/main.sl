// An opt is held by value, so a plain struct that holds itself through
// one would be infinitely large. Refused, with the fix: a gc struct (a
// pointer) can hold opt[Self], and is how a linked list is written.
struct Node {
    v: int,
    next: opt[Node],
}

let n = Node { v: 1, next: none };
println(n.v);
