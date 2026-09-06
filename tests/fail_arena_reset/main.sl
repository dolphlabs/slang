let a = arena_new(64);
let p = a.alloc(1);
a.reset();
println(*p);
