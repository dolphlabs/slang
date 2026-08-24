#ifndef SLANG_PARSER_H
#define SLANG_PARSER_H

#include "ast.h"
#include "lexer.h"

/* Parses a token stream into an AST. Exits with a diagnostic on
 * syntax errors. */
Program *parse_program(Token *tokens, int ntokens);

#endif /* SLANG_PARSER_H */