# Testing

> slangc test, with assert and panic.

## Testing

Tests live next to the code they test, Go-style: files named `*_test.sl`
hold functions named `test_*`, taking nothing and returning nothing, which
fail through `assert` or `panic`.

```slang
// calc_test.sl
fn test_add() {
    assert(add(2, 3) == 5);
}

fn test_clamp() {
    let got = clamp(15, 0, 10);       // private functions are reachable:
    assert(got == 10, "got " + to_str(got));   // tests are in the package
}
```

```sh
slangc test                 # the package in the current directory
slangc test path/to/pkg     # another one
slangc test --run clamp     # only tests whose name contains "clamp"
```

```
ok   test_add (52us)
FAIL test_clamp (30us)
     got 15 at calc.test_clamp:7
FAIL: 1 of 2 failed (190us)
```

- **Each test runs in its own task**, so a failing test is reported with
  its message and location and the run carries on. Tests run one at a
  time, so output stays in order.
- **`*_test.sl` files never reach a normal build.** Test helpers can't leak
  into a program, and a test file's imports can't add link flags to one.
- **Programs are testable too.** When the package is a program rather than
  a library, `slangc test` does not run its top-level statements: the test
  runner is `main`. Functions, structs and methods are all there.
- Exit status is 0 when every test passes, 1 when any fails, and 2 when the
  tests cannot be run (a `test_` function with parameters, say). A package
  with no test files exits 0 and says so.
- `--keep` keeps the generated runner and prints where it is.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
