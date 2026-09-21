# C interop

> Calling C, and the safety rules that come with it.

## C interop

slang already transpiles to C and shells out to `cc`, so calling into
existing C libraries is a thin layer on top of that, not a new
ecosystem: declare the C function's signature, tell the linker which
library to pull in, and call it like any other function.

```slang
link "sqlite3";   // -> '-lsqlite3' on the final cc invocation

extern fn sqlite3_libversion() -> str;
println(sqlite3_libversion());
```

- **`extern fn name(params) -> ret;`** declares a C function with no
  body — it calls the real, unmangled C symbol directly. `int`,
  `i8..u64`, `f32`, `float`, `bool`, and `str` already share their C
  representation, so they marshal for free. `bytes` does not
  auto-decay (it is a boxed struct internally); pass `bytes_ptr(b)`
  and `len(b)` as two separate `rawptr`/`i32` arguments instead of
  inventing implicit multi-argument expansion for one type.
- **`rawptr`** is an opaque foreign pointer (`void *`) for handles a C
  library owns, like `sqlite3*` or `FILE*`. It can be passed around
  and compared against **`nullptr`**, nothing else — no arithmetic,
  no field access, no dereference. A `rawptr` is never GC-owned: if a
  C library allocated it, free it through another `extern fn`, not by
  letting it go out of scope.
- **`link "name";`** is a top-level directive (parsed like `import`)
  that adds `-lname` to the `cc` invocation. Non-default search paths
  go through `LIBRARY_PATH`/`CPATH`, which `cc` already honors — no
  separate slangc flag for that.
- Only types with an unambiguous C representation may cross an
  `extern fn` boundary: numeric types, `bool`, `str`, `bytes`,
  `rawptr`, and `ptr[T]` of those types. GC'd containers (`opt`,
  `result`, `map`, structs, arrays) are rejected at compile time —
  their internal layout isn't something arbitrary C code should ever
  see.

**C++ is out of scope for the compiler itself.** There's no
name-mangling/ABI support planned. Wrap the C++ library in your own
`extern "C"` shim (catching every exception at that boundary — an
uncaught C++ exception unwinding into C is undefined behavior) and
consume the shim exactly like any other C library above.

**Safety notes:**

- The collector is precise for slang values rooted at safepoints. A
  slang value whose *only* remaining reference lives in memory the GC
  cannot scan (possible with some C libraries) can be collected while
  C still holds it. Keep a live slang-side reference for the duration
  of any call that retains a pointer beyond that call.
- Callback function pointers — C calling back into slang — aren't
  supported yet.
- **Deep C libraries and the task stack.** A task's stack starts at
  8KB and grows only at slang checkpoints, which C code has none of.
  A C function that recurses or holds large locals can therefore run
  off the end of the stack buffer and corrupt the heap — a silent
  `abort()` from `malloc`, not a clean crash. The compiler-provided
  packages that wrap deep libraries grow the stack up front
  (`sl_rt_need_stack`, used by `net.tls_*` for OpenSSL and by `sql`
  for SQLite); an `extern fn` into a comparably deep library has no
  such protection, so keep C-side recursion and stack buffers small.

See `tests/ffi/` for a complete example: a small hand-written C
fixture library (`lib.c`) built as a static archive, linked and called
from a slang program exercising `extern fn`, `link`, `rawptr`,
`bytes_ptr`, and `nullptr`.

## Packages (Go/Odin style)

A **package is a directory**: every `.sl` file inside it is compiled
together into one shared namespace, as if concatenated. Import paths
resolve to a directory next to the importer, then a native package,
then `stdlib/<path>`, then a pin in `slang.project`.

```slang
import "geometry";   // binds the name "geometry" in this file's scope
import "a/b/util";   // nested paths bind as "util"
import "geometry" as geo;   // optional alias; call as geo.area(...)

println(geometry.area(3.0, 4.0));   // qualified access
println(util.format(x));
```

**Exports are explicit.** Only declarations marked with `pub` are
visible to importers; everything else is private to its package:

```slang
// geometry/shapes.sl
pub fn area(w: float, h: float) -> float { ... }   // exported
fn scale(v: float) -> float { ... }                // private

// geometry/consts.sl
pub let pi = 3.14159;   // exported package constant
let secret = 42;        // private package global
```

Rules:

- Accessing a non-`pub` member from outside is a compile error.
- Within a package, members are used unqualified: `area(1, 2)`.
- In an imported package, top-level `let` becomes a package global;
  its initializer must be a constant literal.
- The entry point is the file you pass to `slangc`; its directory is
  the main package, and its top-level statements run in order in
  `main()`. Other files of the main package share its namespace.
- Duplicate names within a package, duplicate import bindings, and
  import cycles are all compile errors.
- Symbols are mangled per package (`sl_<pkg>_<name>`), so different
  packages can safely use the same names.

See `examples/pkgdemo/` for a complete multi-package project.

External packages are pinned in `slang.project` (walked up from the
entry file). Imports stay short. `slang.lock` holds content hashes
and is written by `slangc get`, never by hand.

```
name myserver
version 0.1.0

pkg foo git https://github.com/dolphlabs/foo tag v0.1.0
pkg bar git https://github.com/dolphlabs/bar tag v0.2.0 dir src
```

```slang
import "foo";
import "bar";
```

`dir <subdir>` points a pin at the package **inside** the repository,
for a library that also ships examples, docs and its own tests: only
that directory is compiled into your program, and nothing else in the
repository can affect your build. The subdirectory is a relative path
within the clone — `..`, absolute paths and empty segments are refused —
and the lock still hashes the whole clone, so what was verified is what
was fetched.

`slangc get` clones each `pkg` line into `$SLANG_CACHE/pkg/<name>/<hash>`
(`~/.cache/slang` if unset). If a fetched package has its own
`slang.project`, those pins are fetched too and recorded only in
`slang.lock`. Compile does not hit the network. A missing lock, missing
cache, or hash mismatch is an error. Same short name at two git/tag
pairs is an error.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
