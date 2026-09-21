# next steps

Work top to bottom, one item at a time; tick items as they land.

Everything finished is cleared from this file to keep it short. The full
write-ups — why each design was chosen, what was measured, which controls
caught what — are in git history and the PR descriptions:

- before v0.2.0: `git show eeefce1:next-steps.md`
- Linux CI (x86_64 and arm64), OpenSSL discovery, `slangc test`, chunked
  request bodies, methods sharing a name with a package function, and the
  Postgres driver: `git show f9680d1:next-steps.md`

Runtime bugs and their investigations live in `todo.md`.

Landed since that clear-out (PRs #157, #159–#162, #164, #165): `io` (stdin,
then terminal control: size, no-echo, raw mode, keys), `flags`, method calls
on any expression, the callee of an indirect call made visible to every
compiler pass, a use-after-free in the DNS resolver, and a Linux-only test
timing assumption.

## 1. CI on `dev`, not only `main`

- [ ] `.github/workflows/ci.yml` runs on a push to `main`, on manual
  dispatch and on a published release. **Nothing runs on a pull request to
  `dev` or a push to `dev`**, so a change reaches `dev` verified only by
  whoever opened it.

  That has been true of every PR since the last clear-out. Each of #157,
  #159–#162, #164 and #165 was checked by hand, on macOS and in an Ubuntu
  24.04 container, never on arm64 and never on GitHub's runners. The tree of
  `dev` at `f9680d1` did pass the full suite that way (243 on macOS and on
  Ubuntu); what has not run is the workflow itself, so the arm64 legs, the
  live Postgres job and the docs build have not seen any of this.

  The first time CI sees these changes will be the next `dev` → `main` merge,
  which is a late place to learn that arm64 disagrees.

  **First step, cheap:** dispatch the workflow on `dev`
  (`gh workflow run ci.yml --ref dev`) and read all three legs.

  **Then:** decide what should run on a PR. Linux x86_64 and macOS are the
  fast legs; the arm64 legs and the live Postgres job are slower, and the
  file's own constraint stands (nothing in it may reach the internet).

## 2. Audit: values a compiler pass cannot see

- [ ] Two memory-safety bugs of one shape, found in a row (#164, #165): a
  compiler pass walks an expression's children by hand, and a child it never
  visits is invisible to it. Liveness then thinks the value died at its last
  *visible* use and does not root it, so a collection frees it; the move pass
  leaves a drop flag set, so something is freed twice.

  #165 was the worse one: a list of functions used only as a callee
  (`handlers[name](req)`) crashed at the **default** GC threshold, 3 runs in
  3, and `spawn handlers[i](job);`, which the README documents, did too.

  **The `-Wswitch-enum` audit run for #164 does not cover this.** It finds
  expression *kinds* a switch lacks a case for. #165 was a missing *child* of
  a kind that was handled: `EX_CALL` had a case, and the case ignored
  `call.callee`. Every pass has a `default:` that ignores an unhandled kind
  silently, so neither failure is a compile error.

  **Approach:** for every pass that walks the tree by hand (liveness, move,
  borrow, escape, mir, the enum rewrite), list every child of every `Expr`
  and `Stmt` kind (`select` arms, `guard let`, `for … in` iterables, struct
  and map literals, `spawn`, slices, `??`) and, for each, write a program
  whose value is used *only* there, with an allocating call before it, run
  under `SLANG_GC_THRESHOLD_KB=16`. A crash or a wrong result is the finding.
  A test that passes on the broken compiler proves nothing, so each new test
  must be shown to fail on the code before its fix.

  **A lead, not a finding:** a local used only inside a callee that also
  contains a call taking a GC argument is protected today by the *outer*
  call's safepoint bracket. No failure was found, but it was not proved that
  the entry checkin cannot collect it under several workers.

  **Adjacent, low priority, no failure found — do not fix without one:** the
  runtime does not save or restore `errno` across a task switch, and about 64
  reads of it (`sl_net.c` 33, `sl_os.c` 11, `sl_fs.c` 9, `sl_tls.c` 7) sit
  between a syscall and the check of its result. The `Bad file descriptor`
  flake that first pointed here was not this (#159): async preemptions were
  zero in that test.

## 3. The ~5% SIGBUS under amplified preemption

- [ ] Find and fix it.

  Open the longest. `todo.md` records the signature, three explanations
  already tested and eliminated (do not re-chase them), and a concrete next
  step: poison the trampoline's resume-target slot on entry and validate
  it before the final `jmp`, turning corruption into a detection at the
  moment it happens.

## 4. Remote benchmarks

- [ ] Run the cross-language suite on a Linux host and record it in
  `bench/RESULTS.md` as its own run.

  `bench/run_remote.sh` is built, with a preflight that inspects the host
  before anything runs. It needs a host chosen deliberately: the suite
  saturates every core for minutes and binds ports, so it must not run on
  a machine serving anything.

  **Waiting on a full run.** PR #150 holds interim results from a scaled-down
  run. When the full suite has run:
  - update `bench/RESULTS.md` and the website with the heavy-tier numbers;
  - the site shows only C#, Java, Go, Rust, Bun, Node and slang (Python and C
    are left out of it);
  - the Java `api` heavy tier should now build (a `.gitignore` pattern had
    been hiding its `Main.java`); check that it does.

## 5. Language gaps found and left alone

- [ ] **`spawn fns[i](x)` as an expression** (`let t = spawn fns[i](x);`) is a
  parse error: `spawn` in expression position takes only a named call. The
  statement form parses, and is the one the README documents.
- [ ] **A method that returns a reference cannot be called on a temporary or a
  field/element path** (`make().get()` where `get` returns `&int`). #164 refuses
  it with a message saying to bind the receiver to a variable first. Supporting
  it means the borrow checker tracking a loan against something with no name.
- [ ] **`arena`, `link` and `trip` methods only work on a variable**
  (`a.alloc(..)`, `conn.send(..)`, `t.pull()`). Their emission is keyed on a
  variable's name; on any other receiver #164 gives a clear error.
- [ ] **Raw mode and Ctrl-Z.** The process stops with the terminal still raw.
  Restoring on stop and re-applying on continue is what a full-screen program
  would need. `SIGKILL` and a crash cannot be handled at all, and are
  documented as such.
- [ ] **Terminal resize events and mouse input** for `io`. `term_width` /
  `term_height` are polled; there is no event, and a mouse report decodes to
  `"unknown"`.

## 6. Command-line programs: what is still missing

- [ ] A line-editing helper built on `io.read_key`: cursor movement, history,
  a prompt that redraws. Not scoped. Candidate only; worth deciding whether
  it belongs in `stdlib` or in a program that wants it before writing it.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
