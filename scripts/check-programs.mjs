// Compiles and runs every program the homepage shows, and fails if one no
// longer builds, prints something else, or exits differently. The page shows
// recorded runs; this is what keeps "recorded" from quietly becoming "made
// up" as the language changes.
//
// Usage: npm run check                       (slangc from PATH)
//        SLANGC=/path/to/slangc npm run check
//
// In expected.txt, `{name}` matches any run of digits: the tasks program
// prints a wall-clock time, which is never the same twice.

import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SLANGC = process.env.SLANGC || 'slangc';
const { recorded_with: recordedWith, programs } = JSON.parse(readFileSync(join(ROOT, 'programs/programs.json'), 'utf8'));

function pattern(line) {
  const escaped = line.replace(/[.*+?^$()|[\]\\]/g, '\\$&');
  return new RegExp('^' + escaped.replace(/\\?\{[a-z]+\\?\}/g, '[0-9]+') + '$');
}

const work = mkdtempSync(join(tmpdir(), 'slang-site-'));
let failed = 0;
try {
  for (const { name, exit } of programs) {
    const src = join(ROOT, 'programs', name, `${name}.sl`);
    const expected = readFileSync(join(ROOT, 'programs', name, 'expected.txt'), 'utf8')
      .replace(/\n$/, '').split('\n');
    // One directory per program: slangc compiles every .sl in a directory
    // into one program.
    const dir = join(work, name);
    mkdirSync(dir);
    copyFileSync(src, join(dir, `${name}.sl`));

    const build = spawnSync(SLANGC, [`${name}.sl`, '-o', name], { cwd: dir, encoding: 'utf8' });
    if (build.error) {
      console.error(`check-programs: cannot run ${SLANGC}: ${build.error.message}`);
      process.exit(2);
    }
    if (build.status !== 0) {
      console.log(`FAIL ${name}: does not compile\n${build.stdout}${build.stderr}`);
      failed++;
      continue;
    }

    const run = spawnSync(join(dir, name), [], { cwd: dir, encoding: 'utf8', timeout: 30_000 });
    const got = run.stdout.replace(/\n$/, '').split('\n');
    const problems = [];
    if (run.status !== exit) problems.push(`exit ${run.status ?? run.signal}, want ${exit}`);
    if (got.length !== expected.length) {
      problems.push(`printed ${got.length} lines, want ${expected.length}`);
    } else {
      expected.forEach((want, i) => {
        if (!pattern(want).test(got[i])) problems.push(`line ${i + 1}: got ${JSON.stringify(got[i])}, want ${JSON.stringify(want)}`);
      });
    }
    if (problems.length) {
      console.log(`FAIL ${name}\n     ${problems.join('\n     ')}`);
      failed++;
    } else {
      console.log(`ok   ${name}`);
    }
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}

// The page says which compiler recorded these runs; say so if it is not the
// one that just checked them.
const version = execFileSync(SLANGC, ['--version'], { encoding: 'utf8' }).trim();
if (version !== recordedWith) {
  console.log(`note: the page says "recorded with ${recordedWith}", this is ${version}; update programs.json`);
}
console.log(failed ? `FAIL: ${failed} of ${programs.length} (${version})` : `ok: ${programs.length} programs (${version})`);
process.exit(failed ? 1 : 0);
