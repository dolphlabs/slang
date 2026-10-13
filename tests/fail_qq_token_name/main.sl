// A stray ?? names itself in the error: the token name once held the C
// trigraph ??', which the C compiler turned into ^.
let x = ?? 1;
println(x);
