#include "common.h"
#include "lexer.h"
#include <errno.h>
#include <string.h>

#include <ctype.h>

void lexer_init(Lexer *lx, const char *src) {
    memset(lx, 0, sizeof(*lx));
    lx->src = src;
    lx->line = 1;
}

static void lex_error(int line, const char *msg) {
    fputs("slang: lex error at line ", stderr);
    fprintf(stderr, "%d", line);
    fputs(": ", stderr);
    fputs(msg, stderr);
    fputc(10, stderr);
    exit(1);
}

static int is_ident_start(char c) {
    return isalpha((unsigned char)c) || c == '_';
}

static int is_ident_char(char c) {
    return isalnum((unsigned char)c) || c == '_';
}

static void buf_push(unsigned char **buf, size_t *cap, size_t *len,
                     unsigned char b) {
    if (*len == *cap) {
        *cap *= 2;
        *buf = (unsigned char *)xrealloc(*buf, *cap);
    }
    (*buf)[(*len)++] = b;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Zero the whole Token, then set what this call cares about.
 *
 * Field-by-field initialisation is how a field gets forgotten: this
 * function never set byte_val/byte_len at all, and when big_u64 was
 * added it had to be remembered here by hand. A memset cannot forget,
 * so adding a field to Token is now safe by construction. */
static Token make_token(TokenType type, int line) {
    Token t;
    memset(&t, 0, sizeof(t));
    t.type = type;
    t.line = line;
    return t;
}

/* Decode a slang string literal body into a fresh buffer. Plain text
 * segments are decoded normally. Interpolations written as backslash
 * brace-expr-brace are stored verbatim between marker bytes (value 1):
 * marker, expression source text, marker. The parser splits on the
 * markers later. */
static char *decode_string(const char *src, size_t start, size_t end, int line) {
    size_t cap = (end - start) * 2 + 4;
    char *out = (char *)xmalloc(cap);
    size_t o = 0, i = start;
    while (i < end) {
        char c = src[i];
        if (c == '$' && i + 1 < end && src[i + 1] == '{') {
            out[o++] = 1;
            i += 2;
            int depth = 1;
            while (i < end && depth > 0) {
                if (src[i] == '{') {
                    depth++;
                } else if (src[i] == '}') {
                    depth--;
                    if (depth == 0)
                        break;
                }
                out[o++] = src[i++];
            }
            if (depth != 0)
                lex_error(line, "unterminated interpolation");
            out[o++] = 1;
            i++; /* past '}' */
            continue;
        }
        if (c == 92 /* backslash */) {
            i++;
            if (i >= end)
                lex_error(line, "unterminated string literal");
            if (src[i] == '{') {
                out[o++] = 1;
                i++;
                int depth = 1;
                while (i < end && depth > 0) {
                    if (src[i] == '{') {
                        depth++;
                    } else if (src[i] == '}') {
                        depth--;
                        if (depth == 0)
                            break;
                    }
                    out[o++] = src[i++];
                }
                if (depth != 0)
                    lex_error(line, "unterminated interpolation");
                out[o++] = 1;
                i++; /* past '}' */
                continue;
            }
            switch (src[i]) {
            case 'n': out[o++] = 10; break;
            case 't': out[o++] = 9; break;
            case 'r': out[o++] = 13; break;
            case '0': out[o++] = 0; break;
            case '"': out[o++] = '"'; break;
            case 92:  out[o++] = 92; break;
            default:
                lex_error(line, "unknown escape sequence in string literal");
            }
            i++;
        } else {
            out[o++] = c;
            i++;
        }
    }
    out[o] = '\0';
    return out;
}

Token lexer_next(Lexer *lx) {
    const char *src = lx->src;

    /* skip whitespace and comments */
    for (;;) {
        char c = src[lx->pos];
        if (c == 10) { /* newline */
            lx->line++;
            lx->pos++;
        } else if (c == ' ' || c == '\t' || c == '\r') {
            lx->pos++;
        } else if (c == '/' && src[lx->pos + 1] == '/') {
            while (src[lx->pos] && src[lx->pos] != 10)
                lx->pos++;
        } else {
            break;
        }
    }

    int line = lx->line;
    char c = src[lx->pos];

    if (c == '\0')
        return make_token(T_EOF, line);

    /* numbers */
    if (isdigit((unsigned char)c)) {
        size_t start = lx->pos;
        /* Hex and binary literals, for the same reason bitwise operators
         * exist: a protocol mask is written 0x7f in every RFC and every
         * reference implementation, and spelling it 127 loses that. An
         * underscore is allowed as a digit separator (0xff_ff, 0b1010_1010)
         * and is simply skipped -- strtoll would stop at it, so the digits
         * are copied into a scratch buffer with separators removed. */
        if (src[lx->pos] == '0' &&
            (src[lx->pos + 1] == 'x' || src[lx->pos + 1] == 'X' ||
             src[lx->pos + 1] == 'b' || src[lx->pos + 1] == 'B')) {
            int base = (src[lx->pos + 1] == 'x' || src[lx->pos + 1] == 'X')
                           ? 16 : 2;
            /* 0b" is a byte-string literal, not a binary number */
            if (!(base == 2 && src[lx->pos + 2] == '"')) {
                lx->pos += 2;
                char digits[80];
                size_t nd = 0;
                for (;;) {
                    char d = src[lx->pos];
                    if (d == '_') { lx->pos++; continue; }
                    int okd = base == 16 ? isxdigit((unsigned char)d)
                                         : (d == '0' || d == '1');
                    if (!okd)
                        break;
                    if (nd + 1 < sizeof(digits))
                        digits[nd++] = d;
                    lx->pos++;
                }
                if (nd == 0)
                    lex_error(line, base == 16
                                  ? "hex literal has no digits"
                                  : "binary literal has no digits");
                digits[nd] = '\0';
                errno = 0;
                unsigned long long uv = strtoull(digits, NULL, base);
                if (errno == ERANGE || nd >= sizeof(digits) - 1)
                    lex_error(line, base == 16
                                  ? "hex literal does not fit in 64 bits"
                                  : "binary literal does not fit in 64 bits");
                Token t = make_token(T_INT, line);
                t.int_val = (long long)uv;
                t.big_u64 = uv > 9223372036854775807ULL;
                return t;
            }
        }
        while (isdigit((unsigned char)src[lx->pos]) || src[lx->pos] == '_')
            lx->pos++;
        if (src[lx->pos] == '.' && isdigit((unsigned char)src[lx->pos + 1])) {
            lx->pos++; /* consume '.' */
            while (isdigit((unsigned char)src[lx->pos]))
                lx->pos++;
            Token t = make_token(T_FLOAT, line);
            t.float_val = strtod(src + start, NULL);
            return t;
        }
        /* strtoULL, not strtoll: strtoll SATURATES at LLONG_MAX on
         * overflow and sets ERANGE, which without this check turned
         * 18446744073709551615, 9223372036854775808 and
         * 99999999999999999999999 into the SAME silently-wrong value.
         * A literal that fits u64 but not i64 keeps its bit pattern and
         * is flagged big_u64, so only a u64 context will accept it;
         * anything larger is a hard error at the point of writing. */
        char digits[96];
        size_t nd = 0;
        int too_long = 0;
        for (size_t i = start; i < lx->pos; i++) {
            if (src[i] == '_')
                continue;
            if (nd + 1 >= sizeof(digits)) { too_long = 1; break; }
            digits[nd++] = src[i];
        }
        digits[nd] = '\0';
        errno = 0;
        unsigned long long uv = strtoull(digits, NULL, 10);
        if (too_long || errno == ERANGE)
            lex_error(line, "integer literal does not fit in 64 bits "
                            "(maximum is 18446744073709551615)");
        Token t = make_token(T_INT, line);
        t.int_val = (long long)uv;
        t.big_u64 = uv > 9223372036854775807ULL;
        return t;
    }

    /* byte-string literals: b"..." (binary-safe, no NUL terminator) */
    if (c == 'b' && src[lx->pos + 1] == '"') {
        lx->pos += 2;
        size_t cap = 16, len = 0;
        unsigned char *buf = (unsigned char *)xmalloc(cap);
        for (;;) {
            char ch = src[lx->pos];
            if (ch == '\0' || ch == 10)
                lex_error(line, "unterminated byte string literal");
            if (ch == '"')
                break;
            if (ch == 92) { /* backslash escape */
                lx->pos++;
                char e = src[lx->pos];
                switch (e) {
                case 'n': buf_push(&buf, &cap, &len, 10); break;
                case 't': buf_push(&buf, &cap, &len, 9); break;
                case 'r': buf_push(&buf, &cap, &len, 13); break;
                case '0': buf_push(&buf, &cap, &len, 0); break;
                case '"': buf_push(&buf, &cap, &len, '"'); break;
                case 92:  buf_push(&buf, &cap, &len, 92); break;
                case 'x': {
                    int hi = hexval(src[lx->pos + 1]);
                    int lo = hexval(src[lx->pos + 2]);
                    if (hi < 0 || lo < 0)
                        lex_error(line,
                                  "invalid \\xHH escape in byte string "
                                  "literal");
                    buf_push(&buf, &cap, &len,
                             (unsigned char)(hi * 16 + lo));
                    lx->pos += 2;
                    break;
                }
                default:
                    lex_error(line,
                              "unknown escape sequence in byte string "
                              "literal");
                }
                lx->pos++;
            } else {
                buf_push(&buf, &cap, &len, (unsigned char)ch);
                lx->pos++;
            }
        }
        lx->pos++; /* closing quote */
        Token t = make_token(T_BYTES, line);
        t.byte_val = buf;
        t.byte_len = (long long)len;
        return t;
    }

    /* identifiers / keywords */
    if (is_ident_start(c)) {
        size_t start = lx->pos;
        while (is_ident_char(src[lx->pos]))
            lx->pos++;
        size_t len = lx->pos - start;
        Token t;

#define KW(s, tt)                                                            \
    if (len == sizeof(s) - 1 && strncmp(src + start, s, len) == 0) {         \
        return make_token(tt, line);                                         \
    }
        KW("let", T_KW_LET)
        KW("fn", T_KW_FN)
        KW("if", T_KW_IF)
        KW("else", T_KW_ELSE)
        KW("while", T_KW_WHILE)
        KW("return", T_KW_RETURN)
        KW("true", T_KW_TRUE)
        KW("false", T_KW_FALSE)
        KW("pub", T_KW_PUB)
        KW("import", T_KW_IMPORT)
        KW("guard", T_KW_GUARD)
        KW("for", T_KW_FOR)
        KW("in", T_KW_IN)
        KW("as", T_KW_AS)
        KW("struct", T_KW_STRUCT)
        KW("gc", T_KW_GC)
        KW("own", T_KW_OWN)
        KW("mut", T_KW_MUT)
        KW("impl", T_KW_IMPL)
        KW("extern", T_KW_EXTERN)
        KW("link", T_KW_LINK)
        KW("spawn", T_KW_SPAWN)
        KW("break", T_KW_BREAK)
        KW("continue", T_KW_CONTINUE)
        KW("unsafe", T_KW_UNSAFE)
        KW("int", T_TY_INT)
        KW("float", T_TY_FLOAT)
        KW("str", T_TY_STR)
        KW("bool", T_TY_BOOL)
        KW("bytes", T_TY_BYTES)
        KW("i8", T_TY_I8)
        KW("i16", T_TY_I16)
        KW("i32", T_TY_I32)
        KW("i64", T_TY_I64)
        KW("u8", T_TY_U8)
        KW("u16", T_TY_U16)
        KW("u32", T_TY_U32)
        KW("u64", T_TY_U64)
        KW("f32", T_TY_F32)
        KW("map", T_TY_MAP)
        KW("opt", T_TY_OPT)
        KW("result", T_TY_RESULT)
        KW("duration", T_TY_DURATION)
        KW("rawptr", T_TY_RAWPTR)
        KW("arena", T_TY_ARENA)
        KW("chan", T_TY_CHAN)
        KW("join", T_TY_JOIN)
#undef KW

        t = make_token(T_IDENT, line);
        t.text = (char *)xmalloc(len + 1);
        memcpy(t.text, src + start, len);
        t.text[len] = '\0';
        return t;
    }

    /* range operators: '..' and '..=' */
    if (c == '.' && src[lx->pos + 1] == '.') {
        if (src[lx->pos + 2] == '=') {
            lx->pos += 3;
            return make_token(T_DOTDOTEQ, line);
        }
        lx->pos += 2;
        return make_token(T_DOTDOT, line);
    }

    if (c == '\'' && is_ident_start(src[lx->pos + 1])) {
        lx->pos++;
        size_t start = lx->pos;
        while (is_ident_char(src[lx->pos]))
            lx->pos++;
        size_t len = lx->pos - start;
        Token t = make_token(T_LIFETIME, line);
        t.text = (char *)xmalloc(len + 1);
        memcpy(t.text, src + start, len);
        t.text[len] = '\0';
        return t;
    }

    /* string literals */
    if (c == '"') {
        lx->pos++;
        size_t start = lx->pos;
        while (src[lx->pos] && src[lx->pos] != '"') {
            if (src[lx->pos] == 10)
                lex_error(line, "unterminated string literal");
            if (src[lx->pos] == 92) /* skip escaped char */
                lx->pos++;
            lx->pos++;
        }
        if (src[lx->pos] != '"')
            lex_error(line, "unterminated string literal");
        Token t = make_token(T_STRING, line);
        t.text = decode_string(src, start, lx->pos, line);
        lx->pos++; /* closing quote */
        return t;
    }

    /* three-char operators -- must precede the two-char table below,
     * or "<<=" would lex as '<<' followed by a stray '=' */
    if (c == '<' && src[lx->pos + 1] == '<' && src[lx->pos + 2] == '=')
        { lx->pos += 3; return make_token(T_SHLEQ, line); }
    if (c == '>' && src[lx->pos + 1] == '>' && src[lx->pos + 2] == '=')
        { lx->pos += 3; return make_token(T_SHREQ, line); }

    /* two-char operators */
    if (c == '+' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_PLUSEQ, line); }
    if (c == '-' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_MINUSEQ, line); }
    if (c == '*' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_STAREQ, line); }
    if (c == '/' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_SLASHEQ, line); }
    if (c == '%' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_PERCENTEQ, line); }
    if (c == '&' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_AMPEQ, line); }
    if (c == '|' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_PIPEEQ, line); }
    if (c == '^' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_CARETEQ, line); }
    if (c == '=' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_EQEQ, line); }
    if (c == '!' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_BANGEQ, line); }
    if (c == '<' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_LTE, line); }
    if (c == '>' && src[lx->pos + 1] == '=') { lx->pos += 2; return make_token(T_GTE, line); }
    if (c == '&' && src[lx->pos + 1] == '&') { lx->pos += 2; return make_token(T_ANDAND, line); }
    if (c == '|' && src[lx->pos + 1] == '|') { lx->pos += 2; return make_token(T_OROR, line); }
    if (c == '?' && src[lx->pos + 1] == '?') { lx->pos += 2; return make_token(T_QQ, line); }
    if (c == '-' && src[lx->pos + 1] == '>') { lx->pos += 2; return make_token(T_ARROW, line); }
    /* Shifts are matched AFTER '<='/'>=' above, so "a >>= b" would lex as
     * '>>' then '='; there is no compound assignment in slang, so that is
     * a parse error either way rather than a silent mis-lex. */
    if (c == '<' && src[lx->pos + 1] == '<') { lx->pos += 2; return make_token(T_SHL, line); }
    if (c == '>' && src[lx->pos + 1] == '>') { lx->pos += 2; return make_token(T_SHR, line); }

    /* single-char tokens */
    lx->pos++;
    switch (c) {
    case '&': return make_token(T_AMP, line);
    case '|': return make_token(T_PIPE, line);
    case '^': return make_token(T_CARET, line);
    case '~': return make_token(T_TILDE, line);
    case '+': return make_token(T_PLUS, line);
    case '-': return make_token(T_MINUS, line);
    case '*': return make_token(T_STAR, line);
    case '/': return make_token(T_SLASH, line);
    case '%': return make_token(T_PERCENT, line);
    case '<': return make_token(T_LT, line);
    case '>': return make_token(T_GT, line);
    case '!': return make_token(T_BANG, line);
    case '=': return make_token(T_ASSIGN, line);
    case '(': return make_token(T_LPAREN, line);
    case ')': return make_token(T_RPAREN, line);
    case '{': return make_token(T_LBRACE, line);
    case '}': return make_token(T_RBRACE, line);
    case ',': return make_token(T_COMMA, line);
    case ';': return make_token(T_SEMI, line);
    case ':': return make_token(T_COLON, line);
    case '[': return make_token(T_LBRACKET, line);
    case ']': return make_token(T_RBRACKET, line);
    case '.': return make_token(T_DOT, line);
    default:
        lex_error(line, "unexpected character");
    }
    return make_token(T_EOF, line); /* unreachable */
}

const char *token_type_name(TokenType t) {
    switch (t) {
    case T_EOF:      return "end of file";
    case T_IDENT:    return "identifier";
    case T_INT:      return "integer";
    case T_FLOAT:    return "float";
    case T_STRING:   return "string";
    case T_BYTES:    return "byte string";
    case T_KW_LET:   return "'let'";
    case T_KW_FN:    return "'fn'";
    case T_KW_IF:    return "'if'";
    case T_KW_ELSE:  return "'else'";
    case T_KW_WHILE: return "'while'";
    case T_KW_RETURN:return "'return'";
    case T_KW_TRUE:  return "'true'";
    case T_KW_FALSE: return "'false'";
    case T_KW_PUB:   return "'pub'";
    case T_KW_IMPORT:return "'import'";
    case T_KW_GUARD: return "'guard'";
    case T_KW_FOR:   return "'for'";
    case T_KW_IN:    return "'in'";
    case T_KW_AS:    return "'as'";
    case T_KW_STRUCT:return "'struct'";
    case T_KW_GC:    return "'gc'";
    case T_KW_OWN:   return "'own'";
    case T_KW_MUT:   return "'mut'";
    case T_AMP:      return "'&'";
    case T_PIPE:     return "'|'";
    case T_CARET:    return "'^'";
    case T_TILDE:    return "'~'";
    case T_SHL:      return "'<<'";
    case T_SHR:      return "'>>'";
    case T_PLUSEQ:   return "'+='";
    case T_MINUSEQ:  return "'-='";
    case T_STAREQ:   return "'*='";
    case T_SLASHEQ:  return "'/='";
    case T_PERCENTEQ:return "'%='";
    case T_AMPEQ:    return "'&='";
    case T_PIPEEQ:   return "'|='";
    case T_CARETEQ:  return "'^='";
    case T_SHLEQ:    return "'<<='";
    case T_SHREQ:    return "'>>='";
    case T_KW_IMPL:  return "'impl'";
    case T_KW_EXTERN:return "'extern'";
    case T_KW_LINK:  return "'link'";
    case T_KW_SPAWN: return "'spawn'";
    case T_KW_BREAK: return "'break'";
    case T_KW_CONTINUE: return "'continue'";
    case T_KW_UNSAFE: return "'unsafe'";
    case T_TY_INT:   return "'int'";
    case T_TY_FLOAT: return "'float'";
    case T_TY_STR:   return "'str'";
    case T_TY_BOOL:  return "'bool'";
    case T_TY_BYTES: return "'bytes'";
    case T_TY_I8:    return "'i8'";
    case T_TY_I16:   return "'i16'";
    case T_TY_I32:   return "'i32'";
    case T_TY_I64:   return "'i64'";
    case T_TY_U8:    return "'u8'";
    case T_TY_U16:   return "'u16'";
    case T_TY_U32:   return "'u32'";
    case T_TY_U64:   return "'u64'";
    case T_TY_F32:   return "'f32'";
    case T_TY_MAP:   return "'map'";
    case T_TY_OPT:   return "'opt'";
    case T_TY_RESULT:return "'result'";
    case T_TY_DURATION: return "'duration'";
    case T_TY_RAWPTR: return "'rawptr'";
    case T_TY_ARENA: return "'arena'";
    case T_TY_WIRE:  return "'wire'";
    case T_TY_UNTIL: return "'until'";
    case T_TY_FAULT: return "'fault'";
    case T_TY_PEER:  return "'peer'";
    case T_TY_TRIP:  return "'trip'";
    case T_TY_LINK:  return "'link'";
    case T_TY_CHAN:  return "'chan'";
    case T_TY_JOIN:  return "'join'";
    case T_PLUS:     return "'+'";
    case T_MINUS:    return "'-'";
    case T_STAR:     return "'*'";
    case T_SLASH:    return "'/'";
    case T_PERCENT:  return "'%'";
    case T_EQEQ:     return "'=='";
    case T_BANGEQ:   return "'!='";
    case T_LT:       return "'<'";
    case T_GT:       return "'>'";
    case T_LTE:      return "'<='";
    case T_GTE:      return "'>='";
    case T_ANDAND:   return "'&&'";
    case T_OROR:     return "'||'";
    case T_QQ:       return "'??'";
    case T_BANG:     return "'!'";
    case T_ASSIGN:   return "'='";
    case T_LPAREN:   return "'('";
    case T_RPAREN:   return "')'";
    case T_LBRACE:   return "'{'";
    case T_RBRACE:   return "'}'";
    case T_COMMA:    return "','";
    case T_SEMI:     return "';'";
    case T_COLON:    return "':'";
    case T_LBRACKET: return "'['";
    case T_RBRACKET: return "']'";
    case T_DOT:      return "'.'";
    case T_DOTDOT:   return "'..'";
    case T_DOTDOTEQ: return "'..='";
    case T_ARROW:    return "'->'";
    case T_LIFETIME: return "lifetime";
    }
    return "?";
}