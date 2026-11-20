// Prints the _headers rules for the localized homepages (/es/, /fr/, ...):
// exactly the rules deploy/_headers gives "/", so a header added for the
// homepage (caching, framing, the discovery Link) reaches every translation
// without being written twice. assemble.sh appends the output.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { default: defaultCode, locales } = JSON.parse(readFileSync(resolve(ROOT, 'locales/index.json'), 'utf8'));

if (!Array.isArray(locales) || typeof defaultCode !== 'string') {
  console.error('locale-headers: locales/index.json needs a "default" and a "locales" list');
  process.exit(1);
}

// The block under a line that is exactly "/": its indented lines, up to the
// first line that is not indented.
const lines = readFileSync(resolve(ROOT, 'deploy/_headers'), 'utf8').split('\n');
const start = lines.indexOf('/');
if (start < 0) {
  console.error('locale-headers: deploy/_headers has no rule for "/"');
  process.exit(1);
}
const rules = [];
for (let i = start + 1; i < lines.length && /^\s+\S/.test(lines[i] ?? ''); i++) rules.push(lines[i]);
if (rules.length === 0) {
  console.error('locale-headers: the "/" rule in deploy/_headers has no headers');
  process.exit(1);
}

// Keep in step with pathFor() in vite/i18n.ts.
const paths = locales.filter((l) => l.code !== defaultCode).map((l) => `/${l.code.toLowerCase()}/`);

process.stdout.write(paths.map((p) => `\n${p}\n${rules.join('\n')}\n`).join(''));
