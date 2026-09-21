#ifndef SLANG_PARSER_H
#define SLANG_PARSER_H

#include "ast.h"
#include "lexer.h"

/* Parses a token stream into an AST. Exits with a diagnostic on
 * syntax errors. */
Program *parse_program(Token *tokens, int ntokens);

/* Re-parse one `fn`/`pub fn` declaration from where it was first parsed.
 * Each instance of a generic method needs its own AST; see FuncDecl. */
FuncDecl *parse_fn_decl_again(const FuncDecl *from);

#endif /* SLANG_PARSER_H */