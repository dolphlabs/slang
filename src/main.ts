// Progressive enhancement only. Every word on the page is in the HTML; this
// adds motion, the runner, copy buttons and the 3D hero, and the page is
// complete without it.

import '@fontsource-variable/geist';
import '@fontsource-variable/geist-mono';
import './styles.css';

const root = document.documentElement;
root.classList.add('js');

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function $(sel: string, scope: ParentNode = document): HTMLElement | null {
  return scope.querySelector<HTMLElement>(sel);
}

function $$(sel: string, scope: ParentNode = document): HTMLElement[] {
  return Array.from(scope.querySelectorAll<HTMLElement>(sel));
}

// ---- nav -------------------------------------------------------------------

function initNav(): void {
  const nav = $('[data-nav]');
  const button = $('[data-menu]');
  const sheet = $('#nav-sheet');
  if (!nav || !button || !sheet) return;

  const onScroll = () => nav.classList.toggle('is-scrolled', window.scrollY > 24);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  const setOpen = (open: boolean) => {
    button.setAttribute('aria-expanded', String(open));
    sheet.hidden = !open;
    nav.classList.toggle('is-open', open);
  };
  button.addEventListener('click', () => setOpen(Boolean(sheet.hidden)));
  sheet.addEventListener('click', (e) => {
    if ((e.target as HTMLElement).closest('a')) setOpen(false);
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !sheet.hidden) {
      setOpen(false);
      button.focus();
    }
  });
  window.matchMedia('(min-width: 1081px)').addEventListener('change', (e) => {
    if (e.matches) setOpen(false);
  });
}

// ---- reveal on scroll ------------------------------------------------------

function initReveal(): void {
  if (reducedMotion || !('IntersectionObserver' in window)) return;
  const els = $$('.section-head, .card, .code-card, .runner, .pkg-grid, .faq-list, .cta > *');
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.add('is-in');
        io.unobserve(e.target);
      }
    },
    { rootMargin: '0px 0px -8% 0px' },
  );
  for (const el of els) {
    // Only hide what is below the fold; anything already on screen stays put.
    if (el.getBoundingClientRect().top > window.innerHeight) {
      el.classList.add('reveal');
      io.observe(el);
    }
  }

  const bars = $('[data-bars]');
  if (bars && bars.getBoundingClientRect().top > window.innerHeight) {
    bars.classList.add('is-armed');
    const bio = new IntersectionObserver(([e]) => {
      if (e?.isIntersecting) {
        bars.classList.add('is-in');
        bio.disconnect();
      }
    }, { threshold: 0.4 });
    bio.observe(bars);
  }
}

// ---- runner ------------------------------------------------------------------

function initRunner(): void {
  const runner = $('[data-runner]');
  if (!runner) return;
  const tabs = $$('[role="tab"]', runner);
  const runBtn = $('[data-run]', runner);
  runner.classList.add('is-js');
  runBtn?.classList.add('is-visible');

  let timer = 0;
  let current = tabs.findIndex((t) => t.getAttribute('aria-selected') === 'true');
  if (current < 0) current = 0;

  const panelOf = (i: number) => {
    const id = tabs[i]?.getAttribute('aria-controls');
    return id ? document.getElementById(id) : null;
  };

  function play(): void {
    window.clearTimeout(timer);
    const panel = panelOf(current);
    if (!panel) return;
    const lines = $$('.out-line', panel);
    for (const l of lines) l.classList.remove('is-shown');
    if (reducedMotion) {
      for (const l of lines) l.classList.add('is-shown');
      return;
    }
    let k = 0;
    const step = () => {
      const l = lines[k++];
      if (!l) return;
      l.classList.add('is-shown');
      timer = window.setTimeout(step, k === 1 ? 420 : 260);
    };
    // A beat for the "compile", then the output.
    timer = window.setTimeout(step, 380);
  }

  function select(i: number, focus: boolean): void {
    tabs.forEach((t, j) => {
      const on = i === j;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      const p = panelOf(j);
      if (p) p.hidden = !on;
    });
    current = i;
    if (focus) tabs[i]?.focus();
    play();
  }

  tabs.forEach((t, i) => {
    t.addEventListener('click', () => select(i, false));
    t.addEventListener('keydown', (e) => {
      const n = tabs.length;
      let next = -1;
      if (e.key === 'ArrowRight') next = (current + 1) % n;
      else if (e.key === 'ArrowLeft') next = (current - 1 + n) % n;
      else if (e.key === 'Home') next = 0;
      else if (e.key === 'End') next = n - 1;
      if (next >= 0) {
        e.preventDefault();
        select(next, true);
      }
    });
  });
  runBtn?.addEventListener('click', play);

  // Output starts hidden (it is "not run yet"); run once it is on screen.
  const io = new IntersectionObserver(([e]) => {
    if (e?.isIntersecting) {
      play();
      io.disconnect();
    }
  }, { threshold: 0.35 });
  io.observe(runner);
}

// ---- copy buttons ------------------------------------------------------------

// Copies the commands from a transcript: `dir$ cmd` lines, prompt dropped,
// output left out.
function commandsOf(text: string): string {
  return text
    .split('\n')
    .map((l) => l.match(/^\S*\$ (.*)$/)?.[1])
    .filter((l): l is string => l !== undefined)
    .join('\n');
}

function initCopy(): void {
  for (const btn of $$('[data-copy]')) {
    btn.addEventListener('click', async () => {
      const target = document.getElementById(btn.dataset.copy ?? '');
      if (!target) return;
      const label = btn.textContent;
      try {
        await navigator.clipboard.writeText(commandsOf(target.textContent ?? ''));
        btn.textContent = 'Copied';
      } catch (err) {
        // Clipboard access is refused on insecure origins and in some
        // embedded browsers; say so rather than pretend it worked.
        console.warn('copy failed', err);
        btn.textContent = 'Select to copy';
      }
      window.setTimeout(() => { btn.textContent = label; }, 1600);
    });
  }
}

// ---- scheduler diagram --------------------------------------------------------

function initSched(): void {
  const parked = $$('[data-sched-parked] use');
  const workers = $$('[data-sched-workers] [data-worker]');
  if (!parked.length || !workers.length || reducedMotion) return;
  const fig = $('.sched');
  if (!fig) return;

  let timer = 0;
  let w = 0;
  const tick = () => {
    // A parked task wakes, lights up, and a worker takes it.
    const p = parked[Math.floor(Math.random() * parked.length)];
    p?.classList.add('is-awake');
    window.setTimeout(() => p?.classList.remove('is-awake'), 900);
    const worker = workers[w++ % workers.length];
    const use = worker?.querySelector('use');
    if (use) {
      use.animate(
        [{ transform: 'translateY(0)' }, { transform: 'translateY(-4px)' }, { transform: 'translateY(0)' }],
        { duration: 360, easing: 'ease-out', composite: 'add' },
      );
    }
    timer = window.setTimeout(tick, 240 + Math.random() * 260);
  };
  new IntersectionObserver(([e]) => {
    window.clearTimeout(timer);
    if (e?.isIntersecting) tick();
  }).observe(fig);
}

// ---- hero ------------------------------------------------------------------------

function webglOk(): boolean {
  try {
    const c = document.createElement('canvas');
    return !!c.getContext('webgl2');
  } catch (err) {
    console.warn('WebGL check failed', err);
    return false;
  }
}

function initHero(): void {
  const canvas = $('[data-hero-canvas]') as HTMLCanvasElement | null;
  if (!canvas) return;
  const conn = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection;
  // The hero is decoration: skip ~400 KB of JS and models when the visitor
  // asked to save data or the browser cannot draw it.
  if (conn?.saveData || !webglOk()) return;

  const card = $('[data-spawn]');
  const countEl = $('[data-spawn-count]');
  const button = $('[data-spawn-run]') as HTMLButtonElement | null;

  const start = () => {
    import('./hero/scene')
      .then(({ createHero }) =>
        createHero({
          canvas,
          reducedMotion,
          horizon: () => {
            const ctas = $('.hero .hero-ctas');
            const r = canvas.getBoundingClientRect();
            if (!ctas || !r.height) return 0.66;
            return (ctas.getBoundingClientRect().bottom - r.top + 16) / r.height;
          },
          onCount: (n) => { if (countEl) countEl.textContent = n.toLocaleString('en'); },
        }),
      )
      .then((hero) => {
        if (card) card.hidden = false;
        button?.addEventListener('click', () => hero.spawn(100));
      })
      .catch((err: unknown) => {
        // The static hero is already on screen; log and leave it be.
        console.warn('hero scene failed to start', err);
      });
  };

  // After first paint and the page's own work, so the 3D never delays the
  // text a visitor came to read.
  const idle = (window as Window & { requestIdleCallback?: (cb: () => void, o?: { timeout: number }) => number }).requestIdleCallback;
  if (idle) idle(start, { timeout: 1200 });
  else window.setTimeout(start, 200);
}

initNav();
initReveal();
initRunner();
initCopy();
initSched();
initHero();
