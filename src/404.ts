// The not-found page. Without JavaScript it is complete: a generic error
// pointing at the guide. With it, the error names the address that was
// asked for and suggests the closest real page, the way slangc suggests
// the closest name ("did you mean 'x'?").

import '@fontsource-variable/geist';
import '@fontsource-variable/geist-mono';
import './styles.css';

interface SearchEntry {
  title: string;
  url: string;
}

// Paths longer than this are shown truncated: the address bar is input.
const MAX_SHOWN = 64;

function normalise(path: string): string {
  return path
    .toLowerCase()
    .replace(/^\/+|\/+$/g, '')
    .replace(/(^|\/)index(\.html|\.md)?$/, '')
    .replace(/\.(html|md)$/, '');
}

function levenshtein(a: string, b: string): number {
  // One row of the edit-distance table at a time; `diag` is the cell
  // above-left, `row[j]` the cell above until it is overwritten.
  const row = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let diag = i - 1;
    let left = i;
    for (let j = 1; j <= b.length; j++) {
      const up = row[j] ?? 0;
      const cell = Math.min(up + 1, left + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = up;
      row[j] = cell;
      left = cell;
    }
    row[0] = i;
  }
  return row[b.length] ?? 0;
}

// The closest page, judged on the whole path and on its last segment, so
// /http and /pakages/http both find packages/http. Too far from anything
// and there is no suggestion: a wrong guess is worse than none.
function closest(path: string, urls: string[]): string | null {
  const want = normalise(path);
  if (!want) return null;
  const wantLast = want.split('/').pop() ?? want;
  let best: string | null = null;
  let bestScore = Infinity;
  for (const url of urls) {
    const have = url.replace(/\/$/, '');
    if (!have) continue;
    const last = have.split('/').pop() ?? have;
    const score = Math.min(levenshtein(want, have), levenshtein(wantLast, last) + 0.5);
    if (score < bestScore) {
      bestScore = score;
      best = url;
    }
  }
  const limit = Math.max(2, Math.floor(wantLast.length / 3));
  return best !== null && bestScore <= limit ? best : null;
}

function showPath(): string {
  let path = window.location.pathname;
  try {
    path = decodeURIComponent(path);
  } catch {
    // A malformed escape: show it as it arrived rather than not at all.
  }
  return path.length > MAX_SHOWN ? `${path.slice(0, MAX_SHOWN - 1)}…` : path;
}

async function suggest(): Promise<void> {
  // textContent only: the path comes from the address bar.
  for (const el of document.querySelectorAll<HTMLElement>('[data-nf-path]')) {
    el.textContent = showPath();
  }

  const hint = document.querySelector<HTMLElement>('[data-nf-hint]');
  if (!hint) return;

  let urls: string[];
  try {
    const res = await fetch('/search.json', { headers: { Accept: 'application/json' } });
    if (!res.ok) throw new Error(`search.json: HTTP ${res.status}`);
    urls = ((await res.json()) as SearchEntry[]).map((e) => e.url);
  } catch (err) {
    // The static hint (the guide) is already on the page; say why there
    // is no better one, for whoever is debugging the site.
    console.warn('404: no suggestion, search index unavailable:', err);
    return;
  }

  const match = closest(window.location.pathname, urls);
  if (match === null) return;

  const href = `/${match}`;
  const link = document.createElement('a');
  link.className = 'nf-fix';
  link.href = href;
  link.textContent = `'${href}'`;
  hint.replaceChildren('did you mean ', link, '?');
}

void suggest();
