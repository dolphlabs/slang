#ifndef SLANG_PKG_JSON_H
#define SLANG_PKG_JSON_H

/* The 'json' package's import name, as recognized by loader.c. The
 * rest of json's implementation lives in this directory: dispatch.c
 * (json.decode/json.encode's own codegen, generic over a target type
 * so it doesn't fit native.c's fixed-signature NatSig table), and
 * runtime.c (embedded C runtime: the parser, generic tree, and fixed
 * scalar dec/enc helpers). */
#define PKG_JSON_NAME "json"

#endif /* SLANG_PKG_JSON_H */
