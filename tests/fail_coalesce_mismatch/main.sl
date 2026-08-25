// the ?? fallback must match the option's inner type
let o: opt[int] = some(1);
let y: str = o ?? "x";