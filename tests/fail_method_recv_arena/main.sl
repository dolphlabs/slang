// arena, link and trip methods are emitted from a variable's name, so they
// cannot be called on an arbitrary expression. The error says so.
let a = arena_new(256);
a.reset();
arena_new(64).reset();
