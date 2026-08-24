# slang

A small, statically-typed, garbage-collected programming language that
compiles to native binaries by transpiling to C. The compiler
(`slangc`) is written in C and uses your system C compiler as its
backend — no custom code generator, assembler, or linker required.
Memory is managed by the Boehm-Demers-Weiser conservative GC: slang
strings and allocations are traced and reclaimed automatically,
including cycles.

## Quick start

```sh
brew install libgc   # one-time dependency for compiled programs
make                 # build the slangc compiler
make test            # compile & run the example programs
```

Compile a slang program:

```sh
./slangc examples/hello/main.sl     # produces ./main
./main                              # run it
```

Useful flags:

| Flag        | Effect                                              |
|-------------|-----------------------------------------------------|
| `-o <name>` | Choose the output binary name                       |
| `--emit-c`  | Only write the generated C file (no compilation)    |
| `--keep-c`  | Keep the generated C file after compiling           |
| `--run`     | Compile, then immediately execute the result        |

## Language tour

```slang
// variables with inferred types
let x = 10;              // int  (64-bit)
let pi = 3.14;           // float (double)
let name = "World";      // str
let ok = true;           // bool

// arithmetic: + - * / %   (int/int is integer division)
println(x + y);
println(x / 2.0);        // mixing int and float promotes to float

// strings concatenate with + ; numbers/bools convert automatically
println("Hello, " + name + "! " + x);

// string interpolation with ${expr} (any expression allowed)
println("pi doubled is ${pi * 2}");

// comparisons: == != < <= > >=   logic: && || !
if x > y && ok {
    println("bigger");
} else if x == y {
    println("equal");
} else {
    println("smaller");
}

// loops
let i = 0;
while i < 5 {
    print(i);
    i = i + 1;
}

for j in 0..5 {        // exclusive range: 0,1,2,3,4
    print(j);
}
for k in 1..=3 {       // inclusive range: 1,2,3
    println("tick ${k}");
}

// functions (parameters and return types are annotated)
fn add(a: int, b: int) -> int {
    a + b          // implicit return: last expression is the value
}

fn abs(n: int) -> int {
    guard n >= 0 else {
        return -n; // guard: early exit when the condition fails
    }
    n
}

// void functions just omit the return type
fn shout(msg: str) {
    println(msg + "!!!");
}

// recursion works (functions are forward-declared automatically)
fn fib(n: int) -> int {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}
```

### Built-ins

- `print(expr)` — print a value without a newline
- `println(expr)` — print a value followed by a newline

Both accept any single value of type `int`, `float`, `str`, or `bool`.

### Types

| slang type | C type      | Notes                          |
|------------|-------------|--------------------------------|
| `int`      | `long long` | 64-bit signed integer          |
| `float`    | `double`    | IEEE double                    |
| `str`      | `const char *` | NUL-terminated UTF-8 bytes  |
| `bool`     | `bool`      | `true` / `false`               |

`int` widens to `float` implicitly where needed; all other conversions
are explicit errors.

## Packages (Go/Odin style)

A **package is a directory**: every `.sl` file inside it is compiled
together into one shared namespace, as if concatenated. Import paths
resolve relative to the importing file's directory.

```slang
import "geometry";   // binds the name "geometry" in this file's scope
import "a/b/util";   // nested paths bind as "util"

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

## How it works

```
main.sl ──loader──> packages ──lexer/parser──> ASTs ──codegen──> main.gen.c ──cc──> ./main
```

1. **Loader** (`src/loader.c`) — resolves imports relative to each
   importing file, scans package directories for `.sl` files (in
   deterministic sorted order), merges them per package, and detects
   cycles via canonical paths.
2. **Lexer** (`src/lexer.c`) — tokenizes source into identifiers,
   keywords, literals, and operators.
3. **Parser** (`src/parser.c`) — recursive-descent parser producing an
   AST (`src/ast.h`).
4. **Code generator** (`src/codegen.c`) — walks the ASTs, performs type
   inference and semantic checks (including `pub` enforcement), and
   emits readable C. A tiny runtime (string helpers, printing) is
   embedded directly into every generated file so output is fully
   self-contained.
5. **Driver** (`src/main.c`) — glues it together and shells out to
   `cc`. Because GCC/Clang compile the generated C, you get their full
   optimizer for free.

Inspect what slang generates:

```sh
./slangc examples/hello/main.sl --emit-c && cat main.gen.c
```

## Project layout

```
src/
  common.h     allocation helpers, growable string buffer, file I/O
  loader.h/.c  package discovery, merging, cycle detection
  lexer.h/.c   tokenizer
  ast.h        AST node definitions
  parser.h/.c  recursive-descent parser
  codegen.h/.c type checking + C emission
  main.c       driver: flags, invokes cc
examples/      one directory per example program
Makefile       build/test/clean
```

## Known limitations

- No block scoping: variables declared inside an `if`/`while` body
  remain visible afterwards.
- Strings are immutable; concatenation allocates. The Boehm GC reclaims
  unreachable strings automatically (verified: 2M throwaway
  interpolations hold steady at ~27 MB RSS).
- Package globals require constant-literal initializers.
- Implicit returns only apply to the last statement of a function
  body; `if` and `{}` blocks are statements, not expressions yet.
- No arrays, structs, closures, or error handling yet.

## Memory management

Compiled programs link against [libgc](https://www.hboehm.info/gc/)
(Boehm-Demers-Weiser). All runtime allocations (`sl_strdup`,
`sl_str_concat`, conversions) go through `GC_malloc`; `main()` calls
`GC_INIT()` before user code runs. The driver resolves flags via
`pkg-config bdw-gc` and falls back to plain `-lgc`.

What this means in practice:

- No manual memory management in slang; no leaks from string churn.
- Collection is tracing (mark-and-sweep), so reference cycles are
  collected — unlike refcounting.
- Cost: a small external dependency and occasional short GC pauses.
  For most scripts this is imperceptible.

## Roadmap ideas

- Block scoping and shadowing
- If/block expressions (`let max = if a > b { a } else { b }`)
- Arrays/lists, range `.step(n)`
- Structs with `impl` method blocks
- Option/Result types with `??`
- Import aliases (`import "x" as y`)
- A bytecode VM mode for fast iteration without invoking `cc`
