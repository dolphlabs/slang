import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import { escapeHtml, highlightShell, highlightSlang, unescapeHtml } from './vite/highlight.ts';

const ROOT = import.meta.dirname;

// Where the site is served. Only absolute URLs need it: canonical, Open
// Graph and Twitter cards. Every link on the page is root-relative.
const SITE_URL = (process.env.SITE_URL ?? 'https://slang.dolphlabs.com').replace(/\/$/, '');

interface Program {
  name: string;
  exit: number;
  note: string;
  recorded?: Record<string, string>;
}

function runnerHtml(): string {
  const { recorded_with: recordedWith, programs } = JSON.parse(
    readFileSync(resolve(ROOT, 'programs/programs.json'), 'utf8'),
  ) as { recorded_with: string; programs: Program[] };

  const tabs = programs
    .map((p, i) => {
      const on = i === 0;
      return `<button type="button" role="tab" id="tab-${p.name}" aria-controls="prog-${p.name}" aria-selected="${on}" tabindex="${on ? 0 : -1}">${p.name}.sl</button>`;
    })
    .join('');

  const panels = programs
    .map((p, i) => {
      const src = readFileSync(resolve(ROOT, `programs/${p.name}/${p.name}.sl`), 'utf8').replace(/\n$/, '');
      let out = readFileSync(resolve(ROOT, `programs/${p.name}/expected.txt`), 'utf8').replace(/\n$/, '');
      for (const [k, v] of Object.entries(p.recorded ?? {})) out = out.replaceAll(`{${k}}`, v);
      if (/\{[a-z]+\}/.test(out)) {
        throw new Error(`programs/${p.name}: expected.txt has a {placeholder} with no "recorded" value`);
      }
      const code = highlightSlang(src)
        .split('\n')
        .map((l) => `<span class="ln">${l || ' '}</span>`)
        .join('');
      const lines = out
        .split('\n')
        .map((l) => `<span class="out-line">${escapeHtml(l)}</span>`)
        .join('');
      const exitCls = p.exit === 0 ? 'sh-ok' : 'sh-err';
      return `<div class="runner-panel" role="tabpanel" id="prog-${p.name}" aria-labelledby="tab-${p.name}"${i === 0 ? '' : ' hidden'}>
  <pre class="runner-code" tabindex="0"><code>${code}</code></pre>
  <div class="runner-term">
    <pre class="runner-out" aria-live="polite"><span class="sh-dir">~/${p.name}</span><span class="sh-p"> $ </span><span class="sh-cmd">slangc ${p.name}.sl --run</span>
${lines}<span class="out-line out-exit ${exitCls}">[exit ${p.exit}]</span></pre>
    <p class="runner-note">${escapeHtml(p.note)}</p>
  </div>
</div>`;
    })
    .join('\n');

  return `<div class="runner" data-runner>
<div class="runner-bar"><span class="dots" aria-hidden="true"><i></i><i></i><i></i></span><div class="runner-tabs" role="tablist" aria-label="Example programs">${tabs}</div></div>
<div class="runner-body">
${panels}
</div>
<div class="runner-foot"><span>Recorded with ${escapeHtml(recordedWith)}. CI compiles each one and checks its output against the real compiler.</span><button type="button" class="btn btn-lime btn-sm" data-run><svg width="11" height="11" viewBox="0 0 12 12" aria-hidden="true"><path d="M2 1 11 6 2 11Z" fill="currentColor"/></svg>Run</button></div>
</div>`;
}

// The concurrency diagram's rabbits: a grid of parked tasks over a row of
// worker threads. Static markup, so the figure is complete without
// JavaScript; main.ts only animates it.
function schedHtml(): { parked: string; queue: string; workers: string } {
  // #mini-head is ~90 x 90 units.
  const cols = 14;
  const rows = 4;
  let parked = '';
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      parked += `<use href="#mini-head" transform="translate(${22 + c * 31} ${46 + r * 36}) scale(0.3)"/>`;
    }
  }
  let queue = '';
  for (let i = 0; i < 7; i++) {
    queue += `<use href="#mini-head" transform="translate(${30 + i * 24} ${219}) scale(0.24)"/>`;
  }
  let workers = '';
  const n = 4;
  const w = 99;
  for (let i = 0; i < n; i++) {
    const x = 24 + i * (w + 12);
    workers += `<g data-worker="${i}"><rect x="${x}" y="294" width="${w}" height="46" rx="8"/>` +
      `<use href="#mini-head" transform="translate(${x + 12} ${300}) scale(0.36)"/>` +
      `<text x="${x + 52}" y="322">cpu ${i}</text></g>`;
  }
  return { parked, queue, workers };
}

// Replaces authoring markers in index.html with generated markup:
//   <code data-lang="slang">…</code>  highlighted slang
//   <code data-lang="shell">…</code>  a terminal transcript
//   <!-- @runner -->                  the example-program runner
//   the empty sched-* groups          the concurrency diagram
//   %SITE_URL%                        the absolute site URL
function slangPage(): Plugin {
  return {
    name: 'slang-page',
    configureServer(server) {
      server.watcher.add(resolve(ROOT, 'programs'));
      server.watcher.on('change', (file) => {
        if (file.includes('/programs/')) server.ws.send({ type: 'full-reload' });
      });
    },
    transformIndexHtml: {
      order: 'pre',
      handler(html) {
        return html
          .replace(/<code data-lang="slang">([\s\S]*?)<\/code>/g, (_, src: string) =>
            `<code>${highlightSlang(unescapeHtml(src.replace(/^\n/, '').replace(/\n\s*$/, '')))}</code>`)
          .replace(/<code data-lang="shell">([\s\S]*?)<\/code>/g, (_, src: string) =>
            `<code>${highlightShell(unescapeHtml(src.replace(/^\n/, '').replace(/\n\s*$/, '')))}</code>`)
          .replace('<!-- @runner -->', runnerHtml)
          .replace('<g class="sched-parked" data-sched-parked></g>', () =>
            `<g class="sched-parked" data-sched-parked>${schedHtml().parked}</g>`)
          .replace('<g data-sched-queue></g>', () => `<g data-sched-queue>${schedHtml().queue}</g>`)
          .replace('<g class="sched-workers" data-sched-workers></g>', () =>
            `<g class="sched-workers" data-sched-workers>${schedHtml().workers}</g>`)
          .replaceAll('%SITE_URL%', SITE_URL);
      },
    },
  };
}

// A strict CSP for the homepage, as a meta tag so it holds on any static
// host. Build only: the dev server's HMR needs a websocket and inline
// styles. 'wasm-unsafe-eval' is for the meshopt decoder (WebAssembly);
// blob: is where GLTFLoader puts the model's textures; the inline style
// attributes are the benchmark bars' values.
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self'",
  "connect-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'none'",
].join('; ');

function csp(): Plugin {
  return {
    name: 'slang-csp',
    apply: 'build',
    transformIndexHtml(html) {
      return html.replace('<meta charset="utf-8">', `<meta charset="utf-8">\n<meta http-equiv="Content-Security-Policy" content="${CSP}">`);
    },
  };
}

export default defineConfig({
  plugins: [slangPage(), csp()],
  build: {
    target: 'es2022',
    // The three.js chunk is loaded on demand by the hero; keep it out of the
    // warning so a real regression in the main bundle still stands out.
    chunkSizeWarningLimit: 700,
    assetsInlineLimit: 0,
  },
});
