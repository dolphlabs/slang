---
name: Bug report
about: The compiler, runtime or a standard package does something wrong
title: ""
labels: bug
---

<!-- Security problem? Do not file it here: see SECURITY.md. -->

**What happened, and what you expected**

**The smallest program that shows it**

```slang

```

**Environment**

- `slangc --version`:
- OS and architecture:
- C compiler (`cc --version`):

**If it is a crash, a wrong result that changes between runs, or a hang**

Does it change with a collection on every few allocations?

```sh
SLANG_GC_THRESHOLD_KB=16 ./slangc your_program.sl --run
```

And with one worker (`SLANG_WORKERS=1`)?
