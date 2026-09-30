// Build-time syntax highlighting for slang. The page ships highlighted HTML,
// so there is no highlighter in the browser bundle and the code reads the
// same with JavaScript off.

const KEYWORDS = new Set([
  'as', 'break', 'case', 'continue', 'default', 'else', 'extern', 'fn', 'for',
  'gc', 'guard', 'if', 'impl', 'import', 'in', 'let', 'link', 'mut', 'pub',
  'return', 'select', 'spawn', 'struct', 'switch', 'while', 'enum',
]);

const LITERALS = new Set(['true', 'false', 'none', 'nullptr', 'self']);

const TYPES = new Set([
  'int', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'f32', 'float',
  'bool', 'str', 'bytes', 'rawptr', 'opt', 'result', 'chan', 'duration',
  'join', 'map', 'ptr', 'fault',
]);

const TOKEN = new RegExp(
  [
    String.raw`(?<comment>//[^\n]*)`,
    String.raw`(?<string>b?"(?:\\.|[^"\\\n])*")`,
    String.raw`(?<number>\b\d[\d_]*(?:\.\d+)?\b)`,
    String.raw`(?<word>[A-Za-z_][A-Za-z0-9_]*)`,
    String.raw`(?<punct>[-+*/%=<>!&|^?:;.,(){}\[\]]+)`,
  ].join('|'),
  'g',
);

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

export function unescapeHtml(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
}

function span(cls: string, text: string): string {
  return `<span class="${cls}">${escapeHtml(text)}</span>`;
}

export function highlightSlang(code: string): string {
  let out = '';
  let last = 0;
  for (const m of code.matchAll(TOKEN)) {
    const at = m.index ?? 0;
    out += escapeHtml(code.slice(last, at));
    last = at + m[0].length;
    const g = m.groups ?? {};
    if (g.comment) out += span('tc', g.comment);
    else if (g.string) out += span('ts', g.string);
    else if (g.number) out += span('tn', g.number);
    else if (g.punct) out += span('tp', g.punct);
    else if (g.word) {
      const w = g.word;
      const next = code.slice(last).match(/^\s*(.)/)?.[1];
      if (KEYWORDS.has(w)) out += span('tk', w);
      else if (LITERALS.has(w)) out += span('tl', w);
      else if (TYPES.has(w) || /^[A-Z]/.test(w)) out += span('tt', w);
      else if (next === '(') out += span('tf', w);
      else out += escapeHtml(w);
    }
  }
  return out + escapeHtml(code.slice(last));
}

// A terminal transcript: `$ ` lines are commands, the rest is output. Lines
// starting with `!` are shown as errors (the `!` is dropped), `+` as success.
export function highlightShell(text: string): string {
  return text
    .split('\n')
    .map((line) => {
      const cmd = line.match(/^(\S*)\$ (.*)$/);
      if (cmd) {
        const [, dir = '', command = ''] = cmd;
        return `<span class="sh-dir">${escapeHtml(dir)}</span><span class="sh-p">$ </span><span class="sh-cmd">${escapeHtml(command)}</span>`;
      }
      if (line.startsWith('!')) return `<span class="sh-err">${escapeHtml(line.slice(1))}</span>`;
      if (line.startsWith('+')) return `<span class="sh-ok">${escapeHtml(line.slice(1))}</span>`;
      return `<span class="sh-out">${escapeHtml(line)}</span>`;
    })
    .join('\n');
}
