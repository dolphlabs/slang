/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"

#include <string.h>

/* Each native package with fixed-signature functions (i.e. every one
 * except json, which is generic over a target type -- see
 * pkg_json/dispatch.c) keeps its own NatSig table in its own
 * pkg_<name>/sigs.c. Adding a package means adding one line here. */
static const NatSig *find_sig(const NatSig *sigs, int len, const char *pkg,
                              const char *fname) {
    for (int i = 0; i < len; i++)
        if (!strcmp(sigs[i].pkg, pkg) && !strcmp(sigs[i].name, fname))
            return &sigs[i];
    return NULL;
}

static const NatSig *find_any_sig(const char *pkg, const char *fname) {
    const NatSig *ns = find_sig(TIME_SIGS, TIME_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(NET_SIGS, NET_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(PROC_SIGS, PROC_SIGS_LEN, pkg, fname);
    return ns;
}

/* Validate a call into a native package and return its slang return
 * type. */
const char *native_check(CG *cg, const char *pkg, const char *fname,
                                Expr *e) {
    const NatSig *ns = find_any_sig(pkg, fname);
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
