# Errors

> opt, result and fault -- and the rule for choosing.

## Option / Result

```slang
fn div10(n: int) -> opt[int] {
    if n % 10 == 0 { return some(n / 10); }
    return none;
}

fn parse_small(s: str) -> result[i32, str] {
    if s == "big" { return err("value too large"); }
    return ok(7);
}

// guard let unwraps the happy path and binds it for the rest of the
// block; the else branch must exit (return, or exit()) since the
// bound name has no value to fall back to. `else let e = err_of(r)`
// binds the error value for `result[T, E]` so failures stay visible.
fn safe_div(n: int) -> int {
    guard let v = div10(n) else {
        return -1;
    }
    return v;
}

fn load_config(path: str) -> str {
    let r: result[str, str] = read_file(path);
    guard let body = r else let e = err_of(r) {
        log.warn("config load failed: " + e);
        return "";
    }
    return body;
}

// ?? recovers from none / err with a fallback value
println(div10(41) ?? -1);              // -1 (none)
println(parse_small("big") ?? -1);     // -1 (err)

// `fault` is the closed 5-kind network/runtime failure enum:
// fault_timeout / fault_reset / fault_closed / fault_io / fault_refused.
// `==` and `fault_kind` only see the kind. `fault_op` and `fault_code`
// carry context: the op name ("recv", "connect", "dial", ...) and the
// errno value (0 when none applies). `to_str` / `+` / `println` render
// the full "op detail (code N)" form, so failures stay debuggable.
let f = fault_io();
println(fault_kind(f));                // 4
println(fault_op(f));                  // "" (hand-built, no op)
println(fault_code(f));                // 0

// bare 'none' / 'err(...)' need an annotated binding to infer their
// other type parameter
let nothing: opt[str] = none;
let bad: result[str, str] = err("boom");
```

Panics (out-of-bounds index, division by zero, `err_of` on ok, missing
map key) carry `pkg.func:line`: `list index out of bounds at
main.foo:12`. A panicking `spawn`ed task reports through stderr and its
`join_wait` surfaces the same string as `err`, so failures stay visible
across task boundaries.

`opt[T]` and `result[T, E]` are monomorphized per distinct type
argument (one C struct per instantiation actually used). Constructing
`none`/`err(...)` without enough context to infer the missing type
parameter is a compile error.

## Error model: opt vs result vs fault

- `opt[T]` — the value may legitimately be absent (`none`). Lookup
  misses, optional config, end of a drained channel. Absence is not
  failure; `??` supplies the default.
- `result[T, E]` — the operation can fail with a *descriptive* error
  (`err(e)`). Parsing, validation, anything where the caller needs to
  know *why*. `E` is usually `str`; `guard let x = r else let e =
  err_of(r)` keeps the reason visible.
- `fault` — the operation hit the *environment*: timeout, reset,
  closed connection, refused dial, IO error. A closed 5-kind enum
  (`fault_timeout` / `fault_reset` / `fault_closed` / `fault_io` /
  `fault_refused`), comparable with `==` and convertible with
  `to_str` / `+`. Use it when the failure is about the world, not
  the data.

Rule of thumb: absent data is `opt`, bad data is `result[_, str]`,
bad world is `result[_, fault]`. Never collapse a descriptive `str`
error into a bare `fault_io()` at a boundary — that is where
debuggability goes to die (see `http.read` below).
