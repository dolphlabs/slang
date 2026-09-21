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

Landed since that clear-out (PRs #157, #159–#162, #164, #165, #168, #169,
#171): `io` (stdin, then terminal control: size, no-echo, raw mode, keys),
`flags`, method calls on any expression, the callee of an indirect call made
visible to every compiler pass, a use-after-free in the DNS resolver, a
Linux-only test timing assumption, the licence and community files, stable
table storage and one iterator over function bodies (generics PR 0), and an
entry guard for functions with a large C frame (a 700-call function died with
SIGBUS on clang).

## 1. User-defined generics, then zokor

- [ ] **Why.** zokor, the backend framework (`dolphlabs/zokor`, empty), has to
  carry the application's own state through a router, middleware and handlers:
  `Router[S]`, `Ctx[S]`, `fn(Ctx[S]) -> Response`. slang has no generics,
  interfaces, closures or `any`, so a library cannot name a type the app
  defines. `tyto`'s 12-parameter `dispatch` is the symptom, and `tyto` and
  `slang-lipo` already copy the same infrastructure between them (`dotenv.sl`
  is byte-identical). Decided: generics come first, all of structs, methods and
  functions, before any zokor code.

  **Model.** Monomorphized, type parameters unbounded, bodies checked per
  instance (the C++ template model) with an "in instantiation of" note on
  errors. `Box[T]` bracket syntax, matching `opt[T]` and `chan[T]`. Type
  arguments are inferred, never written at a call site. Each instance is
  produced by re-parsing the generic's tokens, so an instance cannot inherit
  another's annotations and a new AST field cannot escape it.

  **Sequence**, one PR each, merged and verified on macOS and Linux before the
  next, none stacked:
  - [x] **0.** Stable table storage; one iterator over function bodies (#169).
    Generated C byte-identical for 115 programs.
  - [ ] **1.** Generic structs: `struct Box[T]`, `Name[args]` in types,
    struct-literal inference, templates and instances, mangling. Needs an
    explicit call to the enum rewrite on each fresh instance, since
    `resolve_enum_refs` runs before any instance exists.
  - [ ] **2.** Methods on generic structs (`impl Box[T]`), instantiated lazily.
  - [ ] **3.** Generic functions, with unification and expected-type inference.
  - [ ] **4.** Hardening: cross-package generics, the refusals for `spawn` and
    for a generic used as a value, error notes, `slangc test`, docs. **Warn
    when a program's instance count passes a threshold**, so a framework
    cannot silently bloat a binary.
  - [ ] **5.** A mini `Router[S]` with `Ctx[S]` over an app-defined `S`, as the
    proof; then zokor.

  **Acceptance test for PR 1:** `Box[int]` must generate the same C as a
  hand-written `IntBox`, apart from names. That shows the "no runtime cost"
  claim directly instead of arguing it.

  **Cost model** (measured on one Mac; treat as an order of magnitude): about
  97% of a build is `cc -O3 -flto`, every program carries a ~6,300-line
  runtime, and one representative 12-line function adds ~33 lines of C, ~1.1 KB
  and 25 to 38 ms. Instances multiply that by instances *used* times methods
  *used*; a typical app has one `S`.

  **zokor v0.1**, as agreed: config and dotenv, the error-code registry, the
  rate limiter, a router with `:params` and before/after middleware, the serve
  loop with graceful shutdown; WebSocket, **rewritten from RFC 6455** (not
  ported from `slang-lipo`); a `zokor check` layout checker; Postgres helpers
  and a testing kit. Needs `crypto.sha1` in slang first. The layer rules to
  enforce are already written down in `tyto`'s `AGENTS.md`: import direction,
  only the DB adapter imports `pg`, every package has tests, routes private by
  default, tenant id an explicit parameter.

## 2. CI on `dev`, not only `main`

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

## 3. Audit: values a compiler pass cannot see

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

## 4. The ~5% SIGBUS under amplified preemption

- [ ] Find and fix it.

  Open the longest. `todo.md` records the signature, three explanations
  already tested and eliminated (do not re-chase them), and a concrete next
  step: poison the trampoline's resume-target slot on entry and validate
  it before the final `jmp`, turning corruption into a detection at the
  moment it happens.

## 5. Remote benchmarks

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

## 6. Language gaps found and left alone

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
- [ ] **The frame guard's edges** (#171). A program that needs a guard is
  compiled twice, so its build time roughly doubles; none of the real programs
  measured needs one. `--emit-c` output has no guards, since it does not
  compile. Frames under 1536 bytes are still trusted to fit the 2 KB safepoint
  margin, which was not re-derived. The real cause of the growth on clang (one
  spill slot per call result, and callees inlined into their caller) is not
  something slang can change; only the guard contains it.
- [ ] **Terminal resize events and mouse input** for `io`. `term_width` /
  `term_height` are polled; there is no event, and a mouse report decodes to
  `"unknown"`.

## 7. Command-line programs: what is still missing

- [ ] A line-editing helper built on `io.read_key`: cursor movement, history,
  a prompt that redraws. Not scoped. Candidate only; worth deciding whether
  it belongs in `stdlib` or in a program that wants it before writing it.

## Notes

- Do not change `bench/http/main.sl` for perf experiments. Raw-best slang is `bench/http_opt/main.sl`; remasure with `./bench/run_http_opt.sh`.
- Do not start LLVM.
- Phase E claim requires p99 **and** RSS vs Go; RPS alone is not a win.
