#ifndef SLANG_LEXER_H
#define SLANG_LEXER_H

#include <stddef.h>

typedef enum {
    T_EOF,
    T_IDENT,
    T_INT,
    T_FLOAT,
    T_STRING,
    T_BYTES,

    /* keywords */
    T_KW_LET,
    T_KW_FN,
    T_KW_IF,
    T_KW_ELSE,
    T_KW_WHILE,
    T_KW_RETURN,
    T_KW_TRUE,
    T_KW_FALSE,
    T_KW_PUB,
    T_KW_IMPORT,
    T_KW_GUARD,
    T_KW_FOR,
    T_KW_IN,
    T_KW_AS,

    /* type names */
    T_TY_INT,
    T_TY_FLOAT,
    T_TY_STR,
    T_TY_BOOL,
    T_TY_BYTES,
    T_TY_I8,
    T_TY_I16,
    T_TY_I32,
    T_TY_I64,
    T_TY_U8,
    T_TY_U16,
    T_TY_U32,
    T_TY_U64,
    T_TY_F32,

    /* operators */
    T_PLUS,
    T_MINUS,
    T_STAR,
    T_SLASH,
    T_PERCENT,
    T_EQEQ,
    T_BANGEQ,
    T_LT,
    T_GT,
    T_LTE,
    T_GTE,
    T_ANDAND,
    T_OROR,
    T_BANG,
    T_ASSIGN,

    /* punctuation */
    T_LPAREN,
    T_RPAREN,
    T_LBRACE,
    T_RBRACE,
    T_COMMA,
    T_SEMI,
    T_COLON,
    T_LBRACKET,
    T_RBRACKET,
    T_DOT,
    T_DOTDOT,
    T_DOTDOTEQ,
    T_ARROW
} TokenType;

typedef struct {
    TokenType type;
    char *text;        /* identifier name or decoded string contents */
    long long int_val; /* T_INT */
    double float_val;  /* T_FLOAT */
    unsigned char *byte_val; /* T_BYTES: raw bytes (may contain NULs) */
    long long byte_len;      /* T_BYTES: byte count */
    int line;
} Token;

typedef struct {
    const char *src;
    size_t pos;
    int line;
} Lexer;

void lexer_init(Lexer *lx, const char *src);
Token lexer_next(Lexer *lx);
const char *token_type_name(TokenType t);

#endif /* SLANG_LEXER_H */