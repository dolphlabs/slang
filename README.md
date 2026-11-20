# slang website

The homepage at <https://slang.dolphlabs.com/>, and the build that puts it
in front of the documentation.

This branch shares no history with `main`. It exists so the language
repository stays what it is: a compiler, a runtime and a Python script that
generates the docs, with no Node, no bundler and no 3D models on the path of
someone who only wants to use slang.

## What is here

```
index.html              the page as a template: every word is a {{key}}
locales/                one JSON file of strings per language, and the list
src/main.ts             progressive enhancement: nav, runner, copy, language, motion
src/hero/scene.ts       the 3D field of rabbits (three.js, loaded lazily)
src/styles.css          the one stylesheet
src/assets/models/      the rabbit, optimized (see "The model")
programs/               the runner's programs and their recorded output
vite/highlight.ts       slang highlighting, run at build time
vite/i18n.ts            renders one page per locale; validates the translations
vite/i18n.test.ts       tests for the above (npm test)
vite.config.ts          fills index.html's markers; adds the CSP and the locales
scripts/assemble.sh     docs from the slang repo + this page -> site/
scripts/locale-headers.mjs   _headers rules for /es/, /fr/, ... from the list
scripts/check-programs.mjs   programs vs. the real compiler
scripts/optimize-model.mjs   the model pipeline
deploy/_headers         caching rules appended to the docs' own
```

## Commands

```sh
npm ci
npm run dev                  # the homepage alone, with reload
npm run build                # -> dist/ (/, /es/, /fr/, ...)
npm test                     # the i18n code, and every locale against English
npm run assemble             # -> site/: docs from GitHub main + this page
npm run preview:site         # serve site/ locally
SLANGC=../slang/slangc npm run check   # programs vs. the compiler
```

`assemble` fetches only `docs/` from the slang repository (a sparse,
blob-filtered, depth-1 checkout). `SLANG_DOCS_REF=dev` takes another branch;
`SLANG_DOCS_DIR=../slang/docs` uses a local checkout and needs no network.

## How the page is built

- **The HTML is the content.** Code is highlighted at build time, the
  runner's panels are generated from `programs/`, and the FAQ is `<details>`.
  With JavaScript off, or for an agent fetching the page, nothing is
  missing. The page links its Markdown twin (`/index.md`, from the docs) and
  `/llms-small.txt`.
- **The 3D is decoration and is paid for last.** `main.ts` imports the scene
  on idle, after first paint, and skips it entirely without WebGL 2 or when
  the browser asks to save data. It stops rendering when the hero is off
  screen or the tab is hidden, and holds still under
  `prefers-reduced-motion`. First load without it: about 13 KB of HTML,
  6 KB of CSS and 3 KB of JS, gzipped, plus fonts.
- **Plain three.js**, not `@react-three/fiber` or `<model-viewer>`. The page
  is static apart from one canvas; React would add a runtime and a
  reconciler to drive a few hundred matrices, and `<model-viewer>` shows one
  model per element and cannot instance a field.
- **A strict CSP**, as a meta tag so it holds on any host. It allows
  `'wasm-unsafe-eval'` for the meshopt decoder and nothing inline but style
  attributes.

## Languages

The page is built once per language: `/` is English, and `/es/`, `/fr/`,
`/de/`, `/pt-br/`, `/ja/` and `/zh-cn/` are complete static pages of their
own. Nothing is translated in the browser, so a translated page is as
readable with JavaScript off, or to an agent that fetches it, as the English
one, and it costs no more to load. Each page has its own canonical URL and
`hreflang` links to the others, with `/` as `x-default`.

The documentation (`/guide/`, `/packages/`, ...) comes from the slang
repository and is English only; translated pages say so in the footer and
link to it as it is. The search box on a translated page has its wording
translated (its placeholder, group headings and empty state), but its
results come from the docs' English `search.json`. `404.html` is English too,
since it cannot know which language the missing address was meant in.

**Where the words are.** `index.html` holds markup and `{{tokens}}`;
`locales/<code>.json` holds one HTML fragment per key. `locales/index.json`
lists the languages (the default, `en`, first) and each one's name
in its own language.

| In `index.html` | Becomes |
|---|---|
| `{{key}}` | the string, as HTML |
| `{{text:key}}` | the string as plain text, safe in an attribute |
| `{{json:key}}` | the same, escaped for the JSON-LD block |
| `{{n:1498}}` | a number in the language's separators: `1,498`, `1.498`, `1 498` |
| `{{@lang}}`, `{{@path}}`, ... | per-page values (see `builtins` in `vite/i18n.ts`) |
| `<!-- @translated -->...<!-- @/translated -->` | kept on translated pages only |

Numbers are written as plain literals so the page cannot show a German
reader "1,498 ms" for what the benchmark measured as 1498. Code, compiler
output and the runner's programs are the same in every language and are
marked `translate="no"`.

**The build refuses an inconsistent translation.** Every locale must have
exactly the keys of `en`, and each string must keep the markup, link targets,
`<code>` text and `{placeholders}` of the English one. Words and word order
are the translator's. A string in `en.json` that nothing reads also fails the
build, so a deleted sentence cannot leave a stale key behind.

**Adding a language**

1. Add it to `locales/index.json` (`code` is a BCP 47 tag such as `it` or
   `pt-BR`; its page is `/<code lowercased>/`).
2. Copy `locales/en.json` to `locales/<code>.json` and translate the values.
   `lang.suggest` and `lang.dismiss` are shown on the English page, in the
   new language, when the visitor's browser asks for it.
3. `npm run build`. The error names every key that is missing or broken.
4. Have a native speaker read it. The shipped translations were written
   without one and should be reviewed before they are announced.

Things to check for a new language: the SVG diagram labels (`conc.sched_*`)
must stay short, because SVG text does not wrap and the figure is a fixed
480 units wide; and a right-to-left language needs the stylesheet's
physical `left`/`right` properties converted to logical ones first, which
this change did not do.

**Choosing a language.** Every language link is a plain link, so the switcher
works without JavaScript. `main.ts` adds two things: it closes the menu on an
outside click or Escape, and on the English page only it offers the
visitor's own language once, as a dismissible notice, when
`navigator.languages` matches an available one (same language and script, so
`zh-TW` is not offered Simplified Chinese). It never redirects. The choice is
kept in `localStorage` under `slang.lang`; where storage is blocked the offer
just repeats.

**Fonts.** Geist covers Latin, Cyrillic and Vietnamese. Japanese and Chinese
use the system's own CJK font rather than a web font of several megabytes,
and the stylesheet resets the Latin letter-spacing and headline size for them.

## Claims need numbers

Every number on the page comes from somewhere you can check:

| On the page | Source |
|---|---|
| 2.9 MB, 39,857 req/s, the memory bars, the CPU table | `bench/RESULTS.md` in the slang repo, light tier, run `20260917T203432Z` |
| 1.5x Go | the same table: 2,637 ms / 1,757 ms |
| ~3k tokens | `docs/llms-small.txt`: 12,419 bytes, about 4 bytes a token |
| 3M rows under 20 MB, ~0.8 ms minors | README, *Memory management* |
| 0.53 s over HTTP/2 | README, `http2` |
| 10,000 tasks in ~0.6 s | `programs/tasks`, measured on an i5-8279U |
| Compiler errors, test output | real `slangc` output, copied |
| The runner's output | `programs/*/expected.txt`, checked in CI |

When the benchmarks are rerun, update the page from the new
`bench/RESULTS.md`, including where slang loses. The agent-token
benchmark has not run yet, and the page says so; when it has, its table
replaces the "first run pending" card.

## The runner's programs

Each program is `programs/<name>/<name>.sl` with `expected.txt` beside it,
listed in `programs/programs.json` with its exit code. Its caption is the
`runner.note.<name>` string in each locale.
`{name}` in `expected.txt` matches any number (for timings), and the value
shown on the page comes from `"recorded"`. CI builds `slangc` from `main`
and runs `npm run check` on every push; run it yourself before changing a
program.

## The model

The source is the Tripo export `s-shaped bunny3d.glb`: 400k triangles,
16 MB, three 4K textures. It is not committed; `git clone` fetches every
branch, so it would land on every machine that clones the compiler.

```sh
npm run model -- "/path/to/s-shaped bunny3d.glb"
```

produces `rabbit.glb` (24k triangles, 1K WebP textures, meshopt, ~305 KB)
for the near rabbits and `rabbit-lo.glb` (3k triangles, geometry and UVs
only, ~42 KB) for the field, which reuses the first file's material.

## Deploying (Cloudflare Pages)

| Setting | Value |
|---|---|
| Production branch | `website` |
| Build command | `npm ci && npm run assemble` |
| Build output directory | `site` |
| Environment | `NODE_VERSION=22` |

`assemble` also appends `_headers` rules for each localized homepage
(`scripts/locale-headers.mjs`), the same ones `deploy/_headers` gives `/`.

The docs change on `main`, not here, so a push to `main` should rebuild
the site too: create a deploy hook in the Pages project and call it from a
workflow on `main`. Until then, a docs change goes live on the next push to
this branch or a manual redeploy.

## Brand

Colours and type come from the HomeV2 design: ground `#07080A`, ink
`#F4F1EA`, lime `#D6F531`; Geist and Geist Mono, self-hosted. The logo,
icons and Open Graph image are the files from `slang-brand/`, unchanged.
