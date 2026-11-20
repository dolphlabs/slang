// Run with: npm test   (node --test; no network, no randomness)

import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { describe, it } from 'node:test';
import {
  formatNumber, loadCatalog, localeForUrl, localize, pathFor, plainText, templateKeys, unusedKeys, validateCatalog,
  type Catalog, type Locale, type Strings,
} from './i18n.ts';

function locale(code: string, strings: Strings, defaultCode = 'en'): Locale {
  return { code, name: code.toUpperCase(), og: `${code}_${code.toUpperCase()}`, path: pathFor(code, defaultCode), strings };
}

function catalog(en: Strings, es: Strings): Catalog {
  return { defaultCode: 'en', locales: [locale('en', en), locale('es', es)] };
}

const opts = { siteUrl: 'https://example.test', runner: () => '<div>runner</div>' };

describe('validateCatalog', () => {
  const en = { a: 'Hello <a href="/x/">there</a>', b: 'Use <code>spawn</code>', c: 'Recorded with {tool}' };

  it('accepts a translation that keeps markup, code and placeholders', () => {
    const es = { a: 'Hola <a href="/x/">allí</a>', b: 'Usa <code>spawn</code>', c: 'Grabado con {tool}' };
    assert.deepEqual(validateCatalog(catalog(en, es)), []);
  });

  it('should report a key missing from a translation', () => {
    const problems = validateCatalog(catalog(en, { a: 'Hola <a href="/x/">allí</a>', b: 'Usa <code>spawn</code>' }));
    assert.deepEqual(problems, ['es: missing "c"']);
  });

  it('should report a key the default locale does not have', () => {
    const es = { ...en, z: 'extra' };
    assert.ok(validateCatalog(catalog(en, es)).includes('es: "z" is not in en'));
  });

  it('should report a link whose target was changed', () => {
    const es = { ...en, a: 'Hola <a href="/y/">allí</a>' };
    assert.match(validateCatalog(catalog(en, es)).join('\n'), /"a" changes the markup/);
  });

  it('should report a dropped closing tag', () => {
    const es = { ...en, a: 'Hola <a href="/x/">allí' };
    assert.match(validateCatalog(catalog(en, es)).join('\n'), /"a" changes the markup/);
  });

  it('should report translated text inside <code>', () => {
    const es = { ...en, b: 'Usa <code>engendrar</code>' };
    assert.match(validateCatalog(catalog(en, es)).join('\n'), /"b" changes the text inside <code>/);
  });

  it('should report a lost placeholder', () => {
    const es = { ...en, c: 'Grabado con la herramienta' };
    assert.match(validateCatalog(catalog(en, es)).join('\n'), /"c" changes its \{placeholders\}/);
  });

  it('should report empty strings and template tokens', () => {
    const problems = validateCatalog(catalog(en, { ...en, a: ' ', b: '{{nav.guide}}' })).join('\n');
    assert.match(problems, /"a" is empty/);
    assert.match(problems, /"b" contains a template token/);
  });

  it('should report a default locale that is not listed', () => {
    const c: Catalog = { defaultCode: 'fr', locales: [locale('en', {}, 'fr')] };
    assert.match(validateCatalog(c).join('\n'), /default locale "fr" is not in the list/);
  });
});

describe('formatNumber', () => {
  it('uses the locale separators', () => {
    assert.equal(formatNumber('39857', 'en'), '39,857');
    assert.equal(formatNumber('39857', 'de'), '39.857');
    assert.equal(formatNumber('2.9', 'de'), '2,9');
    assert.equal(formatNumber('2.9', 'en'), '2.9');
  });

  it('keeps the written number of decimals', () => {
    assert.equal(formatNumber('40.0', 'en'), '40.0');
    assert.equal(formatNumber('40.0', 'de'), '40,0');
  });

  it('should throw on something that is not a plain number', () => {
    assert.throws(() => formatNumber('1e3', 'en'), /not a plain number/);
  });
});

describe('localize', () => {
  const c = catalog(
    { greet: 'Hello <b>you</b>', note: 'Docs are English', title: 'A "quoted" <i>title</i>', 'lang.suggest': 'EN offer', 'lang.dismiss': 'x', 'lang.label': 'Language' },
    { greet: 'Hola <b>tú</b>', note: 'Docs en inglés', title: 'Un "título" <i>citado</i>', 'lang.suggest': 'Oferta ES', 'lang.dismiss': 'Cerrar', 'lang.label': 'Idioma' },
  );
  const [en, es] = c.locales as [Locale, Locale];

  it('substitutes {{key}} as HTML and {{text:key}} as an escaped attribute', () => {
    const out = localize('<p title="{{text:title}}">{{greet}}</p>', es, c, opts);
    assert.equal(out, '<p title="Un &quot;título&quot; citado">Hola <b>tú</b></p>');
  });

  it('escapes {{json:key}} for a JSON string', () => {
    assert.equal(localize('"{{json:title}}"', en, c, opts), '"A \\"quoted\\" title"');
  });

  it('formats {{n:...}} for the page language', () => {
    assert.equal(localize('{{n:1498}}', locale('de', {}), { ...c, locales: [en, locale('de', {})] }, opts), '1.498');
  });

  it('should throw on a key that does not exist', () => {
    assert.throws(() => localize('{{nope}}', en, c, opts), /no "nope" in locales\/en\.json/);
  });

  it('should throw on an unknown built-in', () => {
    assert.throws(() => localize('{{@nope}}', en, c, opts), /unknown built-in/);
  });

  it('keeps <!-- @translated --> blocks on translated pages only', () => {
    const t = 'a<!-- @translated -->[{{note}}]<!-- @/translated -->b';
    assert.equal(localize(t, en, c, opts), 'ab');
    assert.equal(localize(t, es, c, opts), 'a[Docs en inglés]b');
  });

  it('builds hreflang links with an x-default and the other og locales', () => {
    const out = localize('{{@head_links}}', es, c, opts);
    assert.match(out, /hreflang="en" href="https:\/\/example\.test\/"/);
    assert.match(out, /hreflang="es" href="https:\/\/example\.test\/es\/"/);
    assert.match(out, /hreflang="x-default" href="https:\/\/example\.test\/"/);
    assert.match(out, /og:locale:alternate" content="en_EN"/);
    assert.doesNotMatch(out, /og:locale:alternate" content="es_ES"/);
  });

  it('offers other languages only from the default page', () => {
    const fromEn = localize('{{@lang_items}}', en, c, opts);
    assert.match(fromEn, /data-suggest="Oferta ES" data-dismiss="Cerrar"/);
    assert.equal(localize('{{@lang_items}}', es, c, opts).includes('data-suggest'), false);
    assert.match(localize('{{@lang_items}}', es, c, opts), /hreflang="es"[^>]*aria-current="true"/);
  });

  it('inserts the runner last, so program text is never read as a token', () => {
    const out = localize('<!-- @runner -->', en, c, { ...opts, runner: () => 'let m = {{not_a_token}};' });
    assert.equal(out, 'let m = {{not_a_token}};');
  });

  it('marks code and terminals so browser translators leave them alone', () => {
    const out = localize('<p><code>x</code></p><pre class="a"><code>y</code></pre>', en, c, opts);
    assert.equal(out, '<p><code translate="no">x</code></p><pre translate="no" class="a"><code>y</code></pre>');
  });
});

describe('unused keys', () => {
  it('finds a key nothing reads, and counts keys only named inside a translated block', () => {
    const c = catalog({ a: '1', b: '2', c: '3', d: '4' }, { a: '1', b: '2', c: '3', d: '4' });
    const template = '{{a}}<!-- @translated -->{{b}}<!-- @/translated -->{{text:c}}';
    assert.deepEqual([...templateKeys(template)].sort(), ['a', 'b', 'c']);
    assert.deepEqual(unusedKeys(c, template, new Set()), ['d']);
    assert.deepEqual(unusedKeys(c, template, new Set(['d'])), []);
  });
});

describe('helpers', () => {
  it('maps a request URL to its locale, falling back to the default', () => {
    const c = catalog({}, {});
    assert.equal(localeForUrl(c, '/').code, 'en');
    assert.equal(localeForUrl(c, '/es/').code, 'es');
    assert.equal(localeForUrl(c, '/es/index.html?x=1').code, 'es');
    assert.equal(localeForUrl(c, '/guide/').code, 'en');
  });

  it('lowercases the region in a locale path', () => {
    assert.equal(pathFor('pt-BR', 'en'), '/pt-br/');
    assert.equal(pathFor('en', 'en'), '/');
  });

  it('decodes entities when making plain text', () => {
    assert.equal(plainText('a&nbsp;<b>b</b> &amp; c'), 'a b & c');
  });
});

describe('the real locale files', () => {
  it('load, and agree with the default locale on keys, markup and code', () => {
    const real = loadCatalog(resolve(import.meta.dirname, '../locales'));
    assert.ok(real.locales.length >= 1);
    assert.equal(real.locales.find((l) => l.code === real.defaultCode)?.path, '/');
  });
});
