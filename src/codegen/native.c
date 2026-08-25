/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"

#include <string.h>

const NatSig NATIVE_SIGS[] = {
    {"time", "mono", 0, {0}, "duration", 0},
    {"time", "wall", 0, {0}, "int", 0},
    {"time", "sleep", 1, {NA_INT}, NULL, 0},
    {"net", "listen", 1, {NA_INT}, "result[i32,str]", 0},
    {"net", "port", 1, {NA_INT}, "result[i32,str]", 0},
    {"net", "accept", 1, {NA_INT}, "result[i32,str]", 0},
    {"net", "dial", 2, {NA_STR, NA_INT}, "result[i32,str]", 0},
    {"net", "send", 2, {NA_INT, NA_BYTES}, "result[i32,str]", 0},
    {"net", "recv", 2, {NA_INT, NA_INT}, "result[bytes,str]", 0},
    {"net", "close", 1, {NA_INT}, NULL, 0},
    {"net", "nonblock", 1, {NA_INT}, "result[bool,str]", 0},
    {"net", "tls_server_ctx", 2, {NA_STR, NA_STR}, "result[rawptr,str]", 1},
    {"net", "tls_client_ctx", 1, {NA_STR}, "result[rawptr,str]", 1},
    {"net", "tls_accept", 2, {NA_INT, NA_RAWPTR}, "result[rawptr,str]", 1},
    {"net", "tls_dial", 3, {NA_STR, NA_INT, NA_RAWPTR}, "result[rawptr,str]",
     1},
    {"net", "tls_send", 2, {NA_RAWPTR, NA_BYTES}, "result[i32,str]", 1},
    {"net", "tls_recv", 2, {NA_RAWPTR, NA_INT}, "result[bytes,str]", 1},
    {"net", "tls_close", 1, {NA_RAWPTR}, NULL, 1},
};

/* Validate a call into a native package and return its slang return
 * type. */
const char *native_check(CG *cg, const char *pkg, const char *fname,
                                Expr *e) {
    const NatSig *ns = NULL;
    for (int i = 0;
         i < (int)(sizeof(NATIVE_SIGS) / sizeof(NATIVE_SIGS[0])); i++) {
        if (!strcmp(NATIVE_SIGS[i].pkg, pkg) &&
            !strcmp(NATIVE_SIGS[i].name, fname)) {
            ns = &NATIVE_SIGS[i];
            break;
        }
    }
    if (!ns)
        cg_error(e->line, "package '%s' has no function '%s'", pkg, fname);
    int n = e->as.call.nargs;
    if (n != ns->nargs)
        cg_error(e->line,
                 "function '%s.%s' expects %d argument(s), got %d", pkg,
                 fname, ns->nargs, n);
    if (ns->is_tls)
        cg->want_tls = 1;

    for (int i = 0; i < n; i++) {
        const char *at = infer_type(cg, e->as.call.args[i]);
        int ok;
        const char *want;
        switch (ns->argkinds[i]) {
        case NA_STR:    ok = is_str(at);    want = "a str";    break;
        case NA_BYTES:  ok = is_bytes(at);  want = "bytes";    break;
        case NA_RAWPTR: ok = is_rawptr(at); want = "a rawptr"; break;
        default:        ok = is_int(at);    want = "an integer"; break;
        }
        if (!ok)
            cg_error(e->line, "%s.%s argument %d must be %s (got %s)", pkg,
                     fname, i + 1, want, at);
    }
    return ns->ret;
}

char *native_gen(CG *cg, const char *pkg, const char *fname,
                        Expr *e) {
    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb, xasprintf("sl_%s_%s(", sanitize_pkg(pkg),
                             sanitize_ident(fname)));
    for (int i = 0; i < e->as.call.nargs; i++) {
        if (i)
            sb_append(&sb, ", ");
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        if (!is_str(at) && !is_bytes(at) && !is_rawptr(at))
            a = maybe_cast(cg, !strcmp(pkg, "time") ? "int" : "i32", at, a);
        sb_append(&sb, a);
    }
    sb_append(&sb, ")");
    return sb.data;
}
