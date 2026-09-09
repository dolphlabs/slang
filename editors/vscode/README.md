# Slang VS Code extension

TextMate syntax highlighting for `.sl` files, generated from the
compiler's own lexer (`src/lexer.h`, `src/lexer.c`).

## Install for local use

1. Open this folder (`editors/vscode`) in VS Code.
2. Run `Developer: Install Extension from Location...` from the command
   palette and pick this folder. Or symlink it into
   `~/.vscode/extensions/slang-0.1.0` and restart.
3. Open any `.sl` file: keywords, types, builtins, strings (incl.
   `b"..."`), numbers, and `//` comments highlight.

## Regenerating

Keyword/type/builtin lists mirror `KW(...)` in `src/lexer.c`,
`is_builtin_name` in `src/codegen/core.c`, and the `fault_*` builtins
in `src/codegen/expr.c` + `infer.c`. When the language gains tokens,
update `syntaxes/slang.tmLanguage.json` to match.
