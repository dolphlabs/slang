// Liveness fixpoint used to reject any loop assigning a GC-tracked
// local that is also live after it. Both loop kinds, with allocation
// inside (string concat every iteration exercises the backedge roots
// under collection pressure).
let acc = "";
for s in ["a", "b", "c"] {
    acc = acc + s;
}
println(acc);
let w = "";
let i = 0;
while i < 3 {
    w = w + "x";
    i = i + 1;
}
println(w);
println(i);
