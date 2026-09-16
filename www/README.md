# The slang documentation standard

This directory builds <https://dolphlabs.github.io/slang/>. It is also
the convention every slang package is expected to follow, so that a
package gets documentation the same way everywhere — the way `godoc`
made one format the norm for Go.

```sh
make docs          # or: python3 www/build.py
python3 -m http.server -d docs 8000
```

Output goes to `docs/`, which GitHub Pages serves directly. There is no
CI step, no bundler, no lockfile, and no network access required: the
generator is one file of dependency-free Python 3.

## The rule that matters

**Nothing on the site is written twice.**

| What | Comes from |
|---|---|
| Guide prose | `README.md` sections, pulled by heading |
| Native package APIs | `NatSig` tables in `src/codegen/pkg_*/sigs.c` |
| Which native packages exist | `NATIVE_PKGS[]` in `src/loader.c` |
| Source package APIs | `pub` declarations in `stdlib/**/*.sl` |
| Item documentation | the comment block above each `pub` declaration |

A docs site that keeps its own copy of the reference drifts from the
code within a month, and a confidently wrong document is worse than a
missing one. So the build reads the repository instead. Add a package to
`NATIVE_PKGS[]` and it appears here; add a `pub fn` to a stdlib package
and it appears here, with whatever comment sits above it.

## Documenting a package

Write a comment block directly above a `pub` declaration. That block
becomes the item's documentation — no tags, no directives, no separate
file:

```slang
// Index of the first `target` byte in `b` at or after `from`, or -1
// if it does not occur. `target` is a byte value, not a substring:
// 44 is a comma.
pub fn find(b: bytes, from: int, target: int) -> int {
```

Conventions worth keeping to:

- **Lead with what it returns**, not with "This function…".
- **Say what happens at the edges.** A reader is usually here because
  something was empty, absent, or too long.
- Backticks render as inline code.
- A row of dashes (`// ----`) is treated as a section divider, not
  documentation, so banner comments do not leak into the API listing.

## Agents are first-class readers

Anything a person can read here, a program can read more cheaply:

| Path | What it is |
|---|---|
| `/llms.txt` | Site index in the [llmstxt.org](https://llmstxt.org) shape |
| `/llms-full.txt` | The entire site as one plain-text document |
| `/api.json` | Every package and every function, machine-readable |
| `/<any-page>.md` | Markdown twin of that exact page |
| `/search.json` | The search index |

Each HTML page declares its own twin in the head:

```html
<link rel="alternate" type="text/markdown" href="./index.md">
```

The HTML carries the full content, including syntax highlighting, which
is applied at build time. JavaScript adds only the theme toggle, search,
the table of contents, copy buttons and motion — a fetch with no JS
engine loses none of the text.

## Files

```
www/
  build.py          the whole generator
  theme/base.html   page template
  theme/style.css   theme (light/dark, honours prefers-reduced-motion)
  theme/app.js      progressive enhancement only
docs/               generated output, committed, served by Pages
```

## Deploying

The output is plain files with relative links and no server-side
requirements, so any static host works. `docs/` is committed, which
means **no host has to run a build at all** — the directory is already
what gets served.

### Cloudflare Pages

Connect the repository, then:

| Setting | Value |
|---|---|
| Framework preset | **None** |
| Build command | *(leave empty)* — or `python3 www/build.py` |
| Build output directory | **`docs`** |
| Root directory | *(leave empty — the repo root)* |
| Production branch | `main` (or whichever you publish from) |

Leaving the build command empty is the recommended setup: `docs/` is
committed, so Cloudflare just uploads it. Set it to `python3
www/build.py` only if you would rather the site be rebuilt on every
push than remember to run `make docs` before committing — Cloudflare's
build image has Python 3, and the generator needs nothing else.

`docs/_headers` is generated for Cloudflare and does two things that
matter here:

- serves the `.md` twins and `.txt` files as `text/plain`, so a browser
  displays them instead of downloading them;
- sends `Access-Control-Allow-Origin: *` on `.md`, `.txt` and `.json`,
  which is what lets a tool on another origin fetch `api.json`,
  `llms.txt` or any page's Markdown twin. Without it the agent-facing
  half of this site is unreachable from a browser-based client.

GitHub Pages ignores `_headers`, so shipping it costs nothing there.

### GitHub Pages

Settings → Pages → Source: *Deploy from a branch* → your branch,
folder **`/docs`**. The generated `.nojekyll` stops Jekyll from
touching the output.

### Anywhere else

Copy `docs/` to the host. If it lets you set response headers, mirror
`docs/_headers`; if not, the site still works — only the cross-origin
fetches and the in-browser Markdown rendering are affected.

## Attribution

slang is built and maintained by **[Dolphlabs](https://dolphlabs.com)**
(Dolph Tech Limited). The generator threads that through every surface
it produces — the footer of each page, the hero byline, the `author`
and `og:site_name` metadata, the end of every Markdown twin, the header
of `llms.txt`, and a `maintainer` object in `api.json` — from the single
`ORG` definition at the top of `build.py`. Change it in one place.
