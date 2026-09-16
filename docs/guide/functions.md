# Function values

> Functions as values, deliberately without closures.

## Function values

A `fn` type holds a function. `fn(A, B) -> R` for one that returns a
value, `fn(A)` for one that returns nothing:

```slang
fn double(x: int) -> int { return x * 2; }
fn triple(x: int) -> int { return x * 3; }

let f: fn(int) -> int = double;   // annotated
let g = triple;                   // or inferred from the function
println(f(21));                   // 42
```

They work as parameters, return values, struct fields, list and map
elements — which is what makes a dispatch table possible instead of a
chain of string comparisons (`demo/samplex/server.sl` routes this way):

```slang
gc struct Route {
    method: str,
    path: str,
    handler: fn(State, http.Request, int) -> http.Response,
}

let routes: [Route] = [
    Route { method: "GET",  path: "/api/tasks", handler: list_tasks },
    Route { method: "POST", path: "/api/tasks", handler: create_task }
];

for i in 0..len(routes) {
    if routes[i].method == req.method && routes[i].path == req.path {
        return routes[i].handler(st, req, -1);
    }
}
```

Anything holding a function value is callable directly —
`routes[i].handler(...)`, `by_name["parse"](...)`, `pick(true)(4)`.

**These are not closures, and that is the point.** A function value
always names a top-level function; nothing is captured. There is no
environment to allocate, trace, or reason about, so a `fn` value is
exactly a C function pointer — it names code, never the heap, and the
collector ignores it entirely. Anything a handler needs is passed to
it, which is the same rule `spawn` already follows.

Two consequences worth knowing:

- **Methods cannot be used as function values.** A method takes a
  receiver the type does not name, so `fn(Counter) -> int` would be a
  lie about its arity. Wrap it in a plain function.
- **A binding shadows a function of the same name.** `let scale = ...`
  in scope means `scale` refers to the binding, never to `fn scale`.

`spawn` takes a function value too — `spawn handlers[i](job);` — see
Concurrency below.
