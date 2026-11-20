// B appears only in f's type, and f is itself generic: nothing gives B.
fn ident[T](x: T) -> T { return x; }
fn map_it[A, B](x: A, f: fn(A) -> B) -> B { return f(x); }
println(map_it(1, ident));
