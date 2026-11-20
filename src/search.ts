// The docs' search palette, on the homepage: the same /search.json (pages
// and every API item, written by the slang repo's www/build.py), the same
// keys (/ and Cmd/Ctrl-K), the same ranking, so search works the same
// wherever you start. The index loads on first open, never with the page.

interface Entry {
  kind: 'page' | 'api';
  title: string;
  url: string;
  tagline?: string;
  name?: string;
  sig?: string;
  text?: string;
  _t: string;
  _n: string;
  _s: string;
  _x: string;
}

const ESC: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
const esc = (s: string) => String(s).replace(/[&<>"]/g, (c) => ESC[c] ?? c);

function mark(text: string, words: string[]): string {
  let out = esc(text);
  for (const w of words) {
    if (!w) continue;
    const re = new RegExp(`(${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'ig');
    out = out.replace(re, '<mark>$1</mark>');
  }
  return out;
}

// Every word must match somewhere; a word scores by where it matched,
// strongest first. Kept identical to the docs' app.js.
function scoreOf(it: Entry, words: string[]): number {
  let total = 0;
  for (const w of words) {
    let s = 0;
    if (it._t === w || it._n === w) s = 100;
    else if (it._t.startsWith(w) || it._n.startsWith(w)) s = 70;
    else if (it._t.includes('.' + w) || it._t.includes('_' + w)) s = 55;
    else if (it._t.includes(w)) s = 45;
    else if (it._s.includes(w)) s = 20;
    else if (it._x.includes(w)) s = 8;
    if (!s) return 0;
    total += s;
  }
  if (it.kind === 'page') total += 6;
  return total - Math.min(it._t.length, 40) / 40;
}

export function initSearch(): void {
  const palette = document.getElementById('palette');
  const input = document.getElementById('palette-input') as HTMLInputElement | null;
  const list = document.getElementById('palette-list');
  if (!palette || !input || !list) return;

  let index: Entry[] | null = null;
  let sel = 0;
  let lastFocus: Element | null = null;

  // The words around the results are the page's, in its language; the
  // results themselves come from the English docs index.
  const ui = {
    empty: palette.dataset.empty ?? 'Nothing matches “{query}”.',
    unavailable: palette.dataset.unavailable ?? '',
    pages: palette.dataset.pages ?? 'Pages',
  };

  const load = (): Promise<Entry[]> => {
    if (index) return Promise.resolve(index);
    return fetch('/search.json')
      .then((r) => (r.ok ? r.json() : []))
      .then((j: Entry[]) => {
        index = j.map((it) => ({
          ...it,
          _t: (it.title || '').toLowerCase(),
          _n: (it.name || '').toLowerCase(),
          _s: (it.sig || it.tagline || '').toLowerCase(),
          _x: (it.text || '').toLowerCase(),
        }));
        return index;
      })
      .catch(() => (index = []));
  };

  const items = (): HTMLElement[] => Array.from(list.querySelectorAll<HTMLElement>('.palette-item'));

  const draw = (rows: Entry[], words: string[], onlyGroup?: string) => {
    sel = 0;
    if (!rows.length) {
      list.innerHTML = input.value.trim()
        ? `<p class="palette-empty">${esc(ui.empty).replace('{query}', () => esc(input.value.trim()))}</p>`
        : `<p class="palette-empty">${esc(ui.unavailable)}</p>`;
      return;
    }
    let group = '';
    list.innerHTML = rows
      .map((it, i) => {
        const g = onlyGroup || (it.kind === 'page' ? ui.pages : 'API');
        const head = g !== group ? `<p class="palette-group">${g}</p>` : '';
        group = g;
        const api = it.kind === 'api';
        return `${head}<a class="palette-item" role="option" id="pi-${i}" href="/${esc(it.url)}"${i === 0 ? ' aria-selected="true"' : ''}>` +
          `<span class="pi-title${api ? ' is-code' : ''}">${mark(it.title, words)}</span>` +
          `<span class="pi-sub${api ? ' is-code' : ''}">${esc((api ? it.sig : it.tagline) || '')}</span></a>`;
      })
      .join('');
    input.setAttribute('aria-activedescendant', 'pi-0');
  };

  const render = (q: string) => {
    if (!index) return;
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) {
      draw(index.filter((it) => it.kind === 'page').slice(0, 12), [], ui.pages);
      return;
    }
    const scored = index
      .map((it) => ({ it, s: scoreOf(it, words) }))
      .filter((x) => x.s > 0)
      .sort((a, b) => b.s - a.s);
    const pages: Entry[] = [];
    const api: Entry[] = [];
    let bestPage = 0;
    let bestApi = 0;
    for (const { it, s } of scored) {
      if (it.kind === 'page') {
        if (!bestPage) bestPage = s;
        if (pages.length < 6) pages.push(it);
      } else {
        if (!bestApi) bestApi = s;
        if (api.length < 40) api.push(it);
      }
    }
    draw(bestApi > bestPage ? api.concat(pages) : pages.concat(api), words);
  };

  const move = (d: number) => {
    const els = items();
    if (!els.length) return;
    els[sel]?.removeAttribute('aria-selected');
    sel = (sel + d + els.length) % els.length;
    const cur = els[sel];
    if (!cur) return;
    cur.setAttribute('aria-selected', 'true');
    cur.scrollIntoView({ block: 'nearest' });
    input.setAttribute('aria-activedescendant', cur.id);
  };

  const open = () => {
    lastFocus = document.activeElement;
    palette.hidden = false;
    document.body.style.overflow = 'hidden';
    input.value = '';
    input.focus();
    load().then(() => render(''));
  };
  const close = () => {
    if (palette.hidden) return;
    palette.hidden = true;
    document.body.style.overflow = '';
    if (lastFocus instanceof HTMLElement) lastFocus.focus();
  };

  document.querySelectorAll('[data-search]').forEach((b) => b.addEventListener('click', open));
  input.addEventListener('input', () => load().then(() => render(input.value)));
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'Enter') {
      const cur = items()[sel] as HTMLAnchorElement | undefined;
      if (cur) { e.preventDefault(); close(); window.location.href = cur.href; }
    }
  });
  palette.addEventListener('click', (e) => {
    const t = e.target as HTMLElement;
    if (t === palette || t.closest('.palette-item')) close();
  });
  list.addEventListener('mousemove', (e) => {
    const it = (e.target as HTMLElement).closest('.palette-item') as HTMLElement | null;
    if (!it) return;
    const els = items();
    const i = els.indexOf(it);
    if (i < 0 || i === sel) return;
    els[sel]?.removeAttribute('aria-selected');
    sel = i;
    it.setAttribute('aria-selected', 'true');
  });
  document.addEventListener('keydown', (e) => {
    const a = document.activeElement as HTMLElement | null;
    const typing = !!a && (/^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) || a.isContentEditable);
    if ((e.key === 'k' || e.key === 'K') && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      if (palette.hidden) open(); else close();
    } else if (e.key === '/' && !typing && palette.hidden) {
      e.preventDefault();
      open();
    } else if (e.key === 'Escape' && !palette.hidden) {
      close();
    }
  });
}
