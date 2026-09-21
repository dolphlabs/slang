## Summary

<!-- What changed and why. Written for someone who has not seen the
     conversation. -->

## Evidence

<!-- For a bug fix: what the new test printed on the code BEFORE this change.
     A regression test that passes on the broken code proves nothing. -->

## Verification

- [ ] `make test` passes on macOS
- [ ] `make test` passes on Linux (CI only runs on `main`, so do this yourself)
- [ ] a memory-safety change is in the `SLANG_GC_THRESHOLD_KB=16` list in `tests/run_tests.sh`
- [ ] `make docs` was run, if the README, a `pub` declaration, a native signature table or `bench/RESULTS.md` changed

## Not done

<!-- Anything you left out, and why. -->
