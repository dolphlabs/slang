// `&mut xs[i]` on elements that hold GC pointers used to compile, into a
// pointer a push through `qs`, an alias of `ps`, could leave dangling.
struct Q { n: str }
fn rename(q: &mut Q) { q.n = "z"; }
let ps: [Q] = [Q { n: "a" }];
let qs = ps;
rename(&mut ps[0]);
push(qs, Q { n: "b" });
println(ps[0].n);
