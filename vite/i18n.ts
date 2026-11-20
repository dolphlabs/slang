// Build-time localisation of the homepage.
//
// index.html is a template: every sentence is a {{key}} token, and each
// locale in locales/ is a flat JSON file of key -> HTML fragment. The build
// renders one complete static page per locale (/, /es/, ...), so a localized
// page is as readable with JavaScript off, or to an agent that fetches it,
// as the English one, and no translation code ships to the browser.
//
// Tokens (all resolved here, nothing is left for the client):
//   {{key}}            the locale's string, as HTML
//   {{text:key}}       the same, as plain text safe in an attribute
//   {{json:key}}       the same, escaped for a JSON string (JSON-LD)
//   {{n:1498}}         a number in the locale's own separators: 1,498 / 1.498
//   {{@name}}          a built-in: @lang, @path, @og, @head_links, ...
//   <!-- @translated -->...<!-- @/translated -->
//                      kept on translated pages, dropped on the default one

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export type Strings = Readonly<Record<string, string>>;
export type Translate = (key: string) => string;

export interface LocaleMeta {
  /** BCP 47 tag, used for <html lang>, hreflang and number formatting. */
  code: string;
  /** The language's own name, shown in the switcher. */
  name: string;
  /** Open Graph locale (language_TERRITORY). */
  og: string;
}

export interface Locale extends LocaleMeta {
  /** URL path of the page: "/" for the default locale, "/es/" for es. */
  path: string;
  strings: Strings;
}

export interface Catalog {
  defaultCode: string;
  locales: Locale[];
}

const CODE = /^[a-z]{2,3}(-[A-Z][A-Za-z]{1,3})?$/;

export function pathFor(code: string, defaultCode: string): string {
  return code === defaultCode ? '/' : `/${code.toLowerCase()}/`;
}

// ---- loading and validation ------------------------------------------------

function readJson(file: string): unknown {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch (err) {
    throw new Error(`i18n: cannot read ${file}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

function isStrings(v: unknown): v is Record<string, string> {
  return typeof v === 'object' && v !== null && !Array.isArray(v) &&
    Object.values(v).every((s) => typeof s === 'string');
}

/** Reads locales/index.json and every locale it lists, and validates them. */
export function loadCatalog(dir: string): Catalog {
  const reg = readJson(join(dir, 'index.json')) as { default?: unknown; locales?: unknown };
  if (typeof reg.default !== 'string' || !Array.isArray(reg.locales)) {
    throw new Error('i18n: locales/index.json needs {"default": "<code>", "locales": [...]}');
  }
  const defaultCode = reg.default;
  const locales: Locale[] = (reg.locales as LocaleMeta[]).map((m) => {
    if (!m || typeof m.code !== 'string' || typeof m.name !== 'string' || typeof m.og !== 'string') {
      throw new Error(`i18n: bad entry in locales/index.json: ${JSON.stringify(m)}`);
    }
    const strings = readJson(join(dir, `${m.code}.json`));
    if (!isStrings(strings)) throw new Error(`i18n: locales/${m.code}.json must be a flat object of strings`);
    return { ...m, path: pathFor(m.code, defaultCode), strings };
  });
  const catalog: Catalog = { defaultCode, locales };
  const problems = validateCatalog(catalog);
  if (problems.length) throw new Error(`i18n: the locales are inconsistent:\n  ${problems.join('\n  ')}`);
  return catalog;
}

const TAG = /<\/?[a-zA-Z][^>]*>/g;

/**
 * What a translation is not allowed to change: the markup around it, the
 * links in it, the code in it and its {placeholders}. Word order and the
 * words themselves are the translator's.
 */
function structure(html: string): { tags: string; code: string; params: string } {
  const norm = (list: string[]) => list.map((s) => s.replace(/\s+/g, ' ')).sort().join('\n');
  return {
    tags: norm(html.match(TAG) ?? []),
    code: norm([...html.matchAll(/<code[^>]*>([\s\S]*?)<\/code>/g)].map((m) => m[1] ?? '')),
    params: norm(html.match(/\{[a-z]+\}/g) ?? []),
  };
}

export function validateCatalog(catalog: Catalog): string[] {
  const problems: string[] = [];
  const { defaultCode, locales } = catalog;
  const seen = new Set<string>();
  for (const l of locales) {
    if (!CODE.test(l.code)) problems.push(`${l.code}: not a language tag like "es" or "pt-BR"`);
    if (seen.has(l.code)) problems.push(`${l.code}: listed twice`);
    seen.add(l.code);
  }
  const base = locales.find((l) => l.code === defaultCode);
  if (!base) return [...problems, `the default locale "${defaultCode}" is not in the list`];

  for (const l of locales) {
    for (const [k, v] of Object.entries(l.strings)) {
      if (v.trim() === '') problems.push(`${l.code}: "${k}" is empty`);
      if (v.includes('{{') || v.includes('}}')) problems.push(`${l.code}: "${k}" contains a template token`);
    }
    if (l === base) continue;

    for (const k of Object.keys(base.strings)) {
      const have = l.strings[k];
      if (have === undefined) {
        problems.push(`${l.code}: missing "${k}"`);
        continue;
      }
      const want = structure(base.strings[k] ?? '');
      const got = structure(have);
      if (want.tags !== got.tags) problems.push(`${l.code}: "${k}" changes the markup (tags, classes or links)`);
      if (want.code !== got.code) problems.push(`${l.code}: "${k}" changes the text inside <code>`);
      if (want.params !== got.params) problems.push(`${l.code}: "${k}" changes its {placeholders}`);
    }
    for (const k of Object.keys(l.strings)) {
      if (!(k in base.strings)) problems.push(`${l.code}: "${k}" is not in ${defaultCode}`);
    }
  }
  return problems;
}

// ---- rendering -------------------------------------------------------------

const ENTITIES: Record<string, string> = {
  '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'",
};

export function escapeAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** A fragment as plain text: tags dropped, entities decoded. */
export function plainText(html: string): string {
  return html.replace(TAG, '').replace(/&(nbsp|amp|lt|gt|quot|#39);/g, (e) => ENTITIES[e] ?? e);
}

export function formatNumber(literal: string, code: string): string {
  if (!/^\d+(\.\d+)?$/.test(literal)) throw new Error(`i18n: {{n:${literal}}} is not a plain number`);
  const digits = literal.split('.')[1]?.length ?? 0;
  return new Intl.NumberFormat(code, { minimumFractionDigits: digits, maximumFractionDigits: digits })
    .format(Number(literal));
}

export function translator(locale: Locale, used?: Set<string>): Translate {
  return (key) => {
    const s = locale.strings[key];
    if (s === undefined) throw new Error(`i18n: no "${key}" in locales/${locale.code}.json`);
    used?.add(key);
    return s;
  };
}

/** Which locale a request path belongs to; the default for anything else. */
export function localeForUrl(catalog: Catalog, url: string): Locale {
  const seg = url.split(/[?#]/, 1)[0]?.split('/')[1] ?? '';
  const hit = catalog.locales.find((l) => l.path !== '/' && l.path === `/${seg}/`);
  const fallback = catalog.locales.find((l) => l.code === catalog.defaultCode);
  if (!hit && !fallback) throw new Error('i18n: catalog has no default locale');
  return (hit ?? fallback) as Locale;
}

export interface RenderOptions {
  /** Absolute origin, no trailing slash: hreflang and Open Graph need it. */
  siteUrl: string;
  /** Fills <!-- @runner -->; runs last, so program text is never scanned for tokens. */
  runner: (t: Translate) => string;
  /** Collects every key that was read, to find strings nothing uses. */
  used?: Set<string>;
}

const TOKEN = /\{\{([@a-z][\w.:@-]*)\}\}/g;

// Lazy, so a built-in the template does not use reads no string.
function builtins(locale: Locale, catalog: Catalog, opts: RenderOptions): Record<string, () => string> {
  const isDefault = locale.code === catalog.defaultCode;
  const t = translator(locale, opts.used);

  const link = (l: Locale) => {
    const cur = l.code === locale.code ? ' aria-current="true"' : '';
    return `<a href="${l.path}" hreflang="${l.code}" lang="${l.code}"${cur}>${escapeAttr(l.name)}</a>`;
  };
  const item = (l: Locale) => {
    const cur = l.code === locale.code ? ' aria-current="true"' : '';
    // Only the default page offers to switch (main.ts), so only it carries
    // the other languages' own wording for the offer.
    const offer = isDefault && l.code !== locale.code
      ? ` data-suggest="${escapeAttr(plainText(translator(l, opts.used)('lang.suggest')))}" data-dismiss="${escapeAttr(plainText(translator(l, opts.used)('lang.dismiss')))}"`
      : '';
    return `<li><a href="${l.path}" hreflang="${l.code}" lang="${l.code}" data-lang-link${offer}${cur}>${escapeAttr(l.name)}</a></li>`;
  };

  const headLinks = () => [
    ...catalog.locales.map((l) => `<link rel="alternate" hreflang="${l.code}" href="${opts.siteUrl}${l.path}">`),
    `<link rel="alternate" hreflang="x-default" href="${opts.siteUrl}/">`,
    ...catalog.locales.filter((l) => l.code !== locale.code)
      .map((l) => `<meta property="og:locale:alternate" content="${l.og}">`),
  ].join('\n');

  return {
    '@lang': () => locale.code,
    '@path': () => locale.path,
    '@og': () => locale.og,
    '@lang_short': () => locale.code.split('-')[0]?.toUpperCase() ?? locale.code,
    '@head_links': () => headLinks(),
    '@lang_items': () => catalog.locales.map(item).join(''),
    '@lang_links': () => catalog.locales.map(link).join(''),
    '@lang_label': () => escapeAttr(plainText(t('lang.label'))),
  };
}

/**
 * Every string key the template names, including the ones inside
 * <!-- @translated --> blocks that the default locale never renders.
 */
export function templateKeys(template: string): Set<string> {
  const keys = new Set<string>();
  for (const [, tok] of template.matchAll(TOKEN)) {
    if (!tok || tok.startsWith('@') || tok.startsWith('n:')) continue;
    keys.add(tok.replace(/^(text|json):/, ''));
  }
  return keys;
}

/** Keys of the default locale that neither the template nor the code reads. */
export function unusedKeys(catalog: Catalog, template: string, used: ReadonlySet<string>): string[] {
  const base = catalog.locales.find((l) => l.code === catalog.defaultCode);
  const named = templateKeys(template);
  return Object.keys(base?.strings ?? {}).filter((k) => !used.has(k) && !named.has(k));
}

/** Renders the built template for one locale. */
export function localize(template: string, locale: Locale, catalog: Catalog, opts: RenderOptions): string {
  const isDefault = locale.code === catalog.defaultCode;
  const t = translator(locale, opts.used);
  const built = builtins(locale, catalog, opts);

  const html = template
    .replace(/<!-- @translated -->([\s\S]*?)<!-- @\/translated -->/g, (_, inner: string) => (isDefault ? '' : inner))
    .replace(TOKEN, (_, tok: string) => {
      if (tok.startsWith('@')) {
        const v = built[tok];
        if (v === undefined) throw new Error(`i18n: unknown built-in {{${tok}}}`);
        return v();
      }
      if (tok.startsWith('text:')) return escapeAttr(plainText(t(tok.slice(5))));
      if (tok.startsWith('json:')) return JSON.stringify(plainText(t(tok.slice(5)))).slice(1, -1);
      if (tok.startsWith('n:')) return formatNumber(tok.slice(2), locale.code);
      return t(tok);
    })
    .replace('<!-- @runner -->', () => opts.runner(t));

  // Code and terminal output are the same in every language; keep browser
  // translators away from them. <code> inside <pre> is covered by the <pre>.
  return html.replace(/<pre(?![^>]*\stranslate=)/g, '<pre translate="no"')
    .replace(/(?<!<pre[^>]*>)<code(?![^>]*\stranslate=)/g, '<code translate="no"');
}
