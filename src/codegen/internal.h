#ifndef SLANG_CODEGEN_INTERNAL_H
#define SLANG_CODEGEN_INTERNAL_H

/* Shared internal state and declarations for the codegen module,
 * split across the files in this directory. ../codegen.h remains
 * the public, single-function API the rest of the compiler calls
 * into. */

#include "../ast.h"
#include "../common.h"
#include "../codegen.h"
#include "mir.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* Compile-time state (formerly codegen.c:309-465)                     */
/* ------------------------------------------------------------------ */

typedef struct CG CG;


/* ------------------------------------------------------------------ */
/* User-defined structs                                                */
/* ------------------------------------------------------------------ */

typedef struct {
    char *canonical;     /* "pkg.Name" — the slang-level type identity */
    char *pkg;
    char *name;          /* simple name within its package */
    int is_pub;
    int is_gc;
    char **fields;
    const char **ftypes; /* canonical slang field types */
    int nfields;
    char **lts;
    int nlts;
    int line;
} StructDef;

/* Entries are individually allocated and the table holds POINTERS to them.
 * A StructDef * or FuncSig * handed out by struct_find_* / sig_find_* /
 * method_find stays valid however many more entries are added later: a
 * generic instance is appended in the middle of type-checking, while callers
 * up the stack still hold pointers into these tables. With the entries stored
 * by value, that append would xrealloc them out from under those callers. */
typedef struct {
    StructDef **items;
    int count;
    int cap;
} StructTable;

/* ------------------------------------------------------------------ */
/* User-defined enums                                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    char *canonical;   /* "pkg.Name" */
    char *pkg;
    char *name;        /* simple name within its package */
    int is_pub;
    char **variants;   /* variant names, in declared order */
    int32_t *values;   /* resolved ordinal per variant, parallel array */
    int nvariants;
    int line;
} EnumDef;

typedef struct {
    EnumDef *items;
    int count;
    int cap;
} EnumTable;

/* ------------------------------------------------------------------ */
/* Symbol tables                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    char *name;
    const char *slang;
    const char *ctype;
    int drop;
    int stack;
    int moved;
} VarSym;

typedef struct {
    VarSym *items;
    int count;
    int cap;
} VarTable;

/* Tier 10: maps an EX_CALL argument Expr* to the C temp name gen_call
 * assigned it, so a LATER sibling argument's own call-site safepoint
 * bracket can reference an EARLIER sibling's already-materialized
 * value (the liveness pass's "pending" tracking, made concrete).
 * Append-only, scanned backward like VarTable/var_find -- codegen_
 * program runs gen_whole_program twice (dry run then real run), and
 * a backward scan naturally prefers the current pass's registration
 * without needing any per-function or per-pass reset. */
typedef struct {
    Expr *key;
    char *name;
} ExprTmp;

typedef struct {
    ExprTmp *items;
    int count;
    int cap;
} ExprTmpTable;

typedef struct {
    char *name;
    char *pkg;               /* owning package name */
    const char *ret_slang;   /* NULL => void */
    const char **param_slang;
    int nparams;
    int is_pub;
    int is_extern;            /* 'extern fn': calls the bare C symbol */
    const char *method_of;   /* canonical struct name for methods, else NULL */
    char **lts;
    int nlts;
    int line;
} FuncSig;

typedef struct {
    FuncSig **items;   /* pointers, for the same reason as StructTable */
    int count;
    int cap;
} SigTable;

/* One 'import "path"' binding: within the owning package, `alias`
 * refers to the package named `target`. */
typedef struct {
    char *owner;
    char *alias;
    char *target;
} ImportBind;

typedef struct {
    ImportBind *items;
    int count;
    int cap;
} ImportTable;

typedef struct {
    char *name;
    char *pkg;
    const char *slang;
    int is_pub;
} GlobSym;

typedef struct {
    GlobSym *items;
    int count;
    int cap;
} GlobTable;

/* Monomorphized instantiations of the generic option/result types:
 * one C struct per distinct set of type parameters used. */
typedef struct {
    char *inner; /* canonical slang type T of opt[T] */
    char *cname; /* C typedef name, e.g. sl_opt_str */
} OptInst;

typedef struct {
    OptInst *items;
    int count;
    int cap;
} OptTable;

typedef struct {
    char *tv;    /* canonical slang value type T of result[T,E] */
    char *te;    /* canonical slang error type E */
    char *cname; /* C typedef name, e.g. sl_res_int_str */
} ResInst;

typedef struct {
    ResInst *items;
    int count;
    int cap;
} ResTable;

/* One distinct fn(...) -> R instantiation. Unlike opt/result these
 * describe no storage of their own -- the value is a bare C function
 * pointer -- but they still need a typedef, because C function-pointer
 * declarators put the name INSIDE the type ("R (*f)(A)") and every
 * emitter here builds declarations as "<ctype> <name>". */
typedef struct {
    char *slang; /* canonical slang type, e.g. fn(int,str)->bool */
    char *cname; /* C typedef name, e.g. sl_fn_0 */
} FnInst;

typedef struct {
    FnInst *items;
    int count;
    int cap;
} FnTable;

/* One args-struct + pthread trampoline per distinct spawned target
 * function (shared across every 'spawn' call site targeting it). */
typedef struct {
    char *pkg;    /* target function's owning package */
    char *name;   /* target function's simple name */
    char *fntype; /* set instead when spawning a function VALUE: the
                     shape is keyed by fn type, and the target travels
                     in the args struct rather than being a fixed C
                     symbol baked into the trampoline */
    char *sname;  /* C struct type name, e.g. sl_spawn_args_main_handle */
    char *tname;  /* C trampoline function name */
    int has_tracer; /* Tier 10: does sname's args struct have at least
                        one GC-pointer field? decides whether call sites
                        reference sl_gc_trace_<sname> or pass NULL */
} SpawnShape;

typedef struct {
    SpawnShape *items;
    int count;
    int cap;
} SpawnTable;

/* One json.decode/json.encode codec per distinct composite slang type
 * (struct/opt/list/map) reached from a json.decode or json.encode
 * call site. Scalar leaf types go through fixed runtime helpers
 * instead (see json_dec_fn/json_enc_fn in pkg_json/dispatch.c) so
 * they never need an entry here. */
typedef struct {
    char *slang_type; /* canonical slang type this codec is for */
    char *dec_name;   /* C decode function name, or NULL if unneeded */
    char *enc_name;   /* C encode function name, or NULL if unneeded */
} JsonInst;

typedef struct {
    JsonInst *items;
    int count;
    int cap;
} JsonTable;

struct CG {
    StrBuf *out;
    int indent;
    VarTable vars;
    int *var_scopes;
    int var_scope_sp;
    int var_scope_cap;
    ExprTmpTable expr_tmps;
    /* Tier 10: a single global stack (shared across every nesting
     * level, save/restored per gen_call the same way cg->expect is)
     * of C temp names an EARLIER sibling argument of a call currently
     * being generated has already materialized. Closes a gap
     * liveness.c itself doesn't cover: its pending-value tracking
     * (Expr.live_set) deliberately excludes bare-identifier arguments
     * (a named local doesn't need an anonymous "pending" marker, only
     * a stable slot -- see liveness.c's is_bare_ident), which is
     * correct for the pass's own per-statement backward analysis but
     * leaves nothing protecting that local across a *later sibling's*
     * own nested call within the same argument list (`combine(xs,
     * baz())` -- xs must survive baz()'s call, but baz()'s own
     * live_set, seeded from process_children_reverse, doesn't know
     * about xs at all). gen_call pushes every argument's temp name
     * here unconditionally (not just bare idents) as it registers it,
     * so any nested call generated for a later sibling can fold the
     * current contents into its own safepoint bracket alongside its
     * real live_set -- a strict superset, safe even where it's
     * redundant with an already-pending-tracked entry. */
    char **ambient_roots;
    int ambient_count, ambient_cap;
    SigTable sigs;
    GlobTable globs;
    ImportTable imports;
    StructTable structs;
    EnumTable enums;
    OptTable opts;
    ResTable res;
    FnTable fns;
    SpawnTable spawns;
    JsonTable json;
    const char *expect; /* expected type while inferring none/ok/err */
    const char *cur_ret;  /* slang return type of enclosing function */
    const char *cur_pkg;
    const char *cur_func;
    int in_function;
    int tmp_id;
    /* Tier 10: how many loop back-edge safepoint brackets (stmt.c's
     * emit_backedge_enter) are currently open in the C block ST_RETURN
     * is about to emit a "return" from -- see ST_RETURN's own comment.
     * Always balanced within a single function by construction
     * (incremented/decremented symmetrically around each loop body),
     * so no explicit per-function reset is needed, same as
     * ambient_count. */
    int open_backedge_brackets;
    /* break/continue: cur_loop_has_bp tracks the INNERMOST enclosing
     * loop's own bracket only (not the cumulative open_backedge_
     * brackets count above, which return still uses unchanged) --
     * break/continue must close exactly the loop they target, never
     * an outer loop's still-needed bracket. loop_depth is codegen's
     * own "am I inside a loop at all" check (independent of
     * liveness.c's parallel cur_break_live_set/cur_continue_live_set
     * check below -- neither pass is guaranteed to run before the
     * other in every code path, see stmt.c's ST_BREAK/ST_CONTINUE).
     * Both save/restored around each loop's own body processing,
     * exactly like cg->expect/cg->cur_ret already are. */
    int loop_depth;
    int cur_loop_has_bp;
    /* break/continue, liveness.c side: opaque LiveSet* (same idiom as
     * Expr.live_set/Stmt.backedge_live_set) for the innermost
     * enclosing loop's own break/continue target. cur_break_live_set
     * is "whatever's live after the whole loop" (solve_loop_fixpoint's
     * own live_out parameter, constant across its fixpoint
     * iterations); cur_continue_live_set is "whatever's live going
     * into the next iteration" (the fixpoint's own per-iteration
     * cur_out, updated each pass). Save/restored around solve_loop_
     * fixpoint's own processing. */
    void *cur_break_live_set;
    void *cur_continue_live_set;
    char **nat_pkgs; /* names of natively-implemented imported packages */
    int nnat;
    int want_tls; /* set once a net.tls_* function is type-checked */
    int want_json; /* set once a json.decode/json.encode is type-checked */
    int want_link; /* set once link_* / link methods are type-checked */
    int stack_box;
    MirTable mirs;
};

/* C typedef name for a distinct opt[T] instantiation. */

/* ------------------------------------------------------------------ */
/* Native-package function signatures (formerly codegen.c:950-964)      */
/* ------------------------------------------------------------------ */

/* Signatures of the compiler-provided functions in each native
 * package with a fixed call signature (every native package except
 * json -- see pkg_json/dispatch.c). ret == NULL means void. Each
 * argument's expected category drives both the type check below and
 * (indirectly, via is_rawptr/is_bytes/is_str exclusions) native_gen's
 * marshaling -- add a new NA_* kind here rather than special-casing
 * a function name/index pair the way this table used to. Each
 * package owns its own table in its own pkg_<name>/sigs.c; native.c
 * searches across all of them. */
typedef enum {
    NA_INT,       /* marshaled as i32 (time: as int) -- back-compat default */
    NA_STR,
    NA_BYTES,
    NA_RAWPTR,
    NA_STR_FAULT, /* str, or a fault converted to str at the call site */
    NA_I64,       /* full-width int: marshaled as long long, not truncated */
    NA_F64,       /* float: marshaled as double (int widens in) */
    NA_ARR_STR,   /* a [str] list, marshaled as sl_arr *. The only
                     aggregate a native function takes; strings.join
                     needs it to be the inverse of strings.split. */
    NA_UNTIL,     /* an `until` deadline: marshaled as sl_until (int64_t).
                     Deliberately NOT int-compatible -- a deadline is an
                     absolute monotonic instant, and silently accepting a
                     duration would park until 1970 rather than for 5s. */
} NatArgKind;

typedef struct {
    const char *pkg, *name;
    int nargs;
    NatArgKind argkinds[4];
    const char *ret;
    int is_tls; /* needs OpenSSL: gates TLS_RUNTIME + -lssl -lcrypto */
} NatSig;

/* ------------------------------------------------------------------ */
/* Per-package signatures and embedded runtime C source. Each native
 * package lives entirely under src/codegen/pkg_<name>/: its NatSig
 * table (if any) in sigs.c, its embedded runtime in runtime*.c. */
/* ------------------------------------------------------------------ */

extern const NatSig TIME_SIGS[]; /* src/codegen/pkg_time/ */
extern const int TIME_SIGS_LEN;

extern const NatSig NET_SIGS[]; /* src/codegen/pkg_net/ */
extern const int NET_SIGS_LEN;

extern const NatSig PROC_SIGS[]; /* src/codegen/pkg_proc/ */
extern const int PROC_SIGS_LEN;

extern const NatSig FS_SIGS[]; /* src/codegen/pkg_fs/ */
extern const int FS_SIGS_LEN;

extern const NatSig LOG_SIGS[]; /* src/codegen/pkg_log/ */
extern const int LOG_SIGS_LEN;

extern const NatSig CRYPTO_SIGS[]; /* src/codegen/pkg_crypto/ */
extern const int CRYPTO_SIGS_LEN;

extern const NatSig SQL_SIGS[]; /* src/codegen/pkg_sql/ */
extern const int SQL_SIGS_LEN;

extern const NatSig OS_SIGS[];
extern const NatSig STRINGS_SIGS[]; /* src/codegen/pkg_os/ */
extern const int OS_SIGS_LEN;
extern const int STRINGS_SIGS_LEN;

extern const NatSig IO_SIGS[]; /* src/codegen/pkg_io/ */
extern const int IO_SIGS_LEN;

extern const NatSig REGEX_SIGS[]; /* src/codegen/pkg_regex/ */
extern const int REGEX_SIGS_LEN;

extern const NatSig ENCODING_SIGS[]; /* src/codegen/pkg_encoding/ */
extern const int ENCODING_SIGS_LEN;

extern const NatSig COMPRESS_SIGS[]; /* src/codegen/pkg_compress/ */
extern const int COMPRESS_SIGS_LEN;

/* ------------------------------------------------------------------ */
/* Functions (declarations generated from every former 'static' def)   */
/* ------------------------------------------------------------------ */

void cg_error(int line, const char *fmt, ...);
void sb_putc(StrBuf *sb, char c);
void sb_nl(StrBuf *sb);
char *c_string_literal(const char *s);
char *c_bytes_literal(const unsigned char *p, long long len);
char *sanitize_ident(const char *name);
const char *map_type(const char *t);
int is_int(const char *t);
int is_signed_int(const char *t);
int int_rank(const char *t);
int is_flt(const char *t);
int is_num(const char *t);
int is_str(const char *t);
int is_bytes(const char *t);
int is_rawptr(const char *t);
int is_wire(const char *t);
int is_until(const char *t);
int is_fault(const char *t);
int is_peer(const char *t);
int is_trip(const char *t);
int is_link(const char *t);
int type_is_arena(const char *t);
int type_is_link(const char *t);
int type_is_trip(const char *t);
int type_is_raw_ptr(const char *t);
int is_arr(const char *t);
int is_map(const char *t);
void check_extern_type(const char *t, int line, const char *what);
void map_kv(const char *t, char **k, char **v);
int is_map_key(CG *cg, const char *t);
int is_opt(const char *t);
int is_result(const char *t);
int is_chan(const char *t);
int is_mutex(const char *t);
int is_fn(const char *t);
char *fn_type_of_sig(CG *cg, FuncSig *sig);
const char *fn_var_type(CG *cg, const char *name);
FuncSig *fn_sig_of_type(CG *cg, const char *t, const char *name, int line);
void emit_fn_types(CG *cg);
int fn_parts(const char *t, char ***out, char **ret);
const char *fn_cname(CG *cg, const char *t);
int is_join(const char *t);
const char *res_access(CG *cg, const char *t);

typedef enum {
    TW_NONE = 0,
    TW_REF,
    TW_REFMUT,
    TW_OWN,
    TW_GC,
    TW_PTR,
    TW_RAW,
    TW_RAWMUT
} TypeWrap;

TypeWrap type_wrap(const char *t, char **inner);
char *type_lifetime(const char *t);
int type_is_boxable(CG *cg, const char *t);
int expr_addressable(Expr *e);
int type_is_gc_ptr(CG *cg, const char *t);
int type_has_gc_roots(CG *cg, const char *t);
int struct_has_gc_fields(CG *cg, StructDef *sd);
int count_gc_root_exprs(CG *cg, const char *slang_t);
int count_named_gc_roots(CG *cg, const char *name);
void append_named_gc_roots(CG *cg, StrBuf *sb, const char *name, int *wrote);
int struct_type_is_gc(CG *cg, const char *t);
const char *struct_access(CG *cg, const char *t);
StructDef *struct_of_type(CG *cg, const char *t);
char *opt_inner(const char *t);
char *chan_elem(const char *t);
char *join_elem(const char *t);
FuncSig *spawn_target(CG *cg, Expr *call, int line);
void result_te(const char *t, char **tv, char **ev);
char *arr_elem(const char *t);
int can_assign(const char *dst, const char *src);
int int_literal_value(Expr *e, long long *out);
int fits_in(const char *t, long long v);
int value_assignable(const char *dst, Expr *src, const char *srct);
const char *promote(const char *lt, const char *rt);
char *maybe_cast(CG *cg, const char *dst, const char *src,
                        char *expr);
const char *opt_cname(CG *cg, const char *inner);
const char *res_cname(CG *cg, const char *tv, const char *te);
SpawnShape *spawn_shape_for(CG *cg, FuncSig *sig);
SpawnShape *spawn_shape_for_fn(CG *cg, const char *fntype);
const char *spawn_fn_type(CG *cg, Expr *call);
void var_push(CG *cg, const char *name, const char *slang);
void var_scope_reset(CG *cg);
void var_scope_push(CG *cg);
void var_scope_pop(CG *cg);
void var_redecl_check(CG *cg, const char *name, int line);
VarSym *var_find(CG *cg, const char *name);
void expr_tmp_register(CG *cg, Expr *e, const char *name);
const char *expr_tmp_find(CG *cg, Expr *e);
void ambient_root_push(CG *cg, const char *name);
char *sequence_one(CG *cg, int seq_id, int idx, const char *ctype,
                   const char *slang_type, char *text, Expr *expr_node,
                   StrBuf *prelude);
int safepoint_elidable(CG *cg, Expr *e);
char *wrap_safepoint(CG *cg, Expr *e, const char *result_ctype,
                     const char *prelude, char *inner);
FuncSig *sig_find_in(CG *cg, const char *pkg, const char *name);
void glob_push(CG *cg, const char *name, const char *pkg,
                      const char *slang, int is_pub);
GlobSym *glob_find(CG *cg, const char *pkg, const char *name);
void import_push(CG *cg, const char *owner, const char *alias,
                        const char *target);
const char *import_try(CG *cg, const char *alias);
const char *import_target(CG *cg, const char *alias, int line);
int is_native_pkg(CG *cg, const char *name);
int want_pkg(CG *cg, const char *name);
const char *expect_push(CG *cg, const char *t);
int split_dotted(const char *name, char **left, char **right);
char *sanitize_pkg(const char *name);
char *mangle_func(const char *pkg, const char *name);
char *mangle_sig(FuncSig *sig);
FuncSig *sig_of_decl(CG *cg, FuncDecl *f);
char *mangle_glob(const char *pkg, const char *name);
char *path_base(const char *path);
StructDef *struct_find_canon(CG *cg, const char *canon);
StructDef *struct_find_in_pkg(CG *cg, const char *pkg,
                                     const char *name);
char *mangle_struct(const char *canon);
EnumDef *enum_find_canon(CG *cg, const char *canon);
EnumDef *enum_find_in_pkg(CG *cg, const char *pkg, const char *name);
int is_enum(CG *cg, const char *t);
char *mangle_enum(const char *canon);
void collect_enum_decls(CG *cg, Package *pkgs, int npkgs);
void resolve_enum_refs(CG *cg, Package *pkgs, int npkgs);
void emit_enum_tables(CG *cg);
const char *ctype_of(CG *cg, const char *t);
const char *canon_type(CG *cg, const char *t, int line);
/* funcs.c: the one iterator over every function body a pass must visit. */
typedef struct {
    Package *pkg;            /* the package declaring `fn` */
    FuncDecl *fn;
    FuncSig *sig;
    const char *impl_struct; /* the impl block's struct as written; NULL for a plain function */
    int i_pkg, phase, i_fn, i_stmt, i_impl; /* position: private to funcs.c */
} FuncCursor;
void func_cursor_init(FuncCursor *c);
int func_cursor_next(CG *cg, Package *pkgs, int npkgs, FuncCursor *c,
                     int with_extern);
void func_cursor_enter(CG *cg, const FuncCursor *c);
void compute_escape(CG *cg, Package *pkgs, int npkgs, int main_index);
int type_is_copy(CG *cg, const char *t);
int type_needs_drop(CG *cg, const char *t);
void compute_moves(CG *cg, Package *pkgs, int npkgs, int main_index);
void compute_borrowck(CG *cg, Package *pkgs, int npkgs, int main_index);
void move_consume(CG *cg, Expr *e);
void move_reinit(CG *cg, const char *name);
void emit_drop_flag(CG *cg, const char *name);
void emit_drop_overwrite(CG *cg, const char *name);
void emit_scope_drops(CG *cg, int from);
void emit_line(CG *cg, const char *fmt, ...);
int is_builtin_name(const char *name);
FuncSig *method_find(CG *cg, StructDef *sd, const char *name);
const char *infer_ident_name(CG *cg, const char *name, int line);
const char *ctor_infer(CG *cg, Expr *e);
const char *native_check(CG *cg, const char *pkg, const char *fname,
                                Expr *e);
const char *infer_call(CG *cg, Expr *e);
const char *infer_method(CG *cg, Expr *e);
/* What `recv.name(...)` names for a receiver of type `recv_t`: the method's
 * FuncSig (self is param 0), or -- when the struct has a fn-typed FIELD of
 * that name, which wins -- the signature of the function it holds, with
 * *fld set to the field's index and no implicit self. *fld is -1 for a
 * method. Shared by infer_method and gen_method so they cannot disagree. */
FuncSig *method_target(CG *cg, const char *recv_t, const char *name,
                       int line, StructDef **sd_out, int *fld);
const char *infer_binary(CG *cg, Expr *e);
const char *infer_type(CG *cg, Expr *e);
char *gen_ident_name(CG *cg, const char *name, int line);
char *gen_float_literal(double v);
char *panic_at(CG *cg, int line);
char *conv_to_str(CG *cg, const char *t, char *expr);

/* Drop one redundant outer parenthesis pair from a generated expression
 * so `if ((a == b))` comes out as `if (a == b)` -- see core.c. */
const char *strip_outer_parens(const char *s);
char *gen_string_concat(CG *cg, Expr *e, const char *lt,
                               const char *rt);
char *gen_numeric_binary(CG *cg, Expr *e, const char *result_t);
char *gen_comparison(CG *cg, Expr *e, const char *lt, const char *rt);
char *gen_builtin_call(CG *cg, Expr *e, int *handled);
char *gen_ctor(CG *cg, Expr *e);
char *native_gen(CG *cg, const char *pkg, const char *fname,
                        Expr *e);
char *gen_call(CG *cg, Expr *e);
char *gen_method(CG *cg, Expr *e);
char *gen_maplit(CG *cg, Expr *e, const char *expect_k,
                        const char *expect_v);
char *gen_structlit(CG *cg, Expr *e);
char *gen_index(CG *cg, Expr *e);
char *gen_slice(CG *cg, Expr *e);
char *gen_list(CG *cg, Expr *e, const char *expect_elem);
char *gen_expr(CG *cg, Expr *e);
void gen_print(CG *cg, Expr *call, int newline);
void gen_stmt(CG *cg, Stmt *s);
void gen_stmts(CG *cg, Stmt **stmts, int count);
void gen_block(CG *cg, Block *b);
void emit_runtime_file(CG *cg, const char *name);
void emit_prelude(CG *cg);
void sig_register_raw(CG *cg, Package *p, FuncDecl *f,
                             const char *method_of);
void collect_decls(CG *cg, Package *pkgs, int npkgs);
const char *literal_type(CG *cg, Expr *e, int line);
char *gen_const_init(Expr *e);
void emit_globals(CG *cg, Package *pkgs, int npkgs, int main_index);
void emit_struct_fwd_decls(CG *cg);
void emit_struct_types(CG *cg);
void emit_struct_tracers(CG *cg);
void emit_opt_res_forward_decls(CG *cg);
void emit_opt_res_types(CG *cg);
void emit_opt_res_tracers(CG *cg);
void force_native_result_types(CG *cg);
void emit_native_runtime(CG *cg);
void emit_spawn_trampolines(CG *cg);
void gen_prototypes(CG *cg, Package *pkgs, int npkgs);
void gen_function(CG *cg, Package *p, FuncDecl *f);
void gen_whole_program(CG *cg, Package *pkgs, int npkgs,
                              int main_index);

/* ------------------------------------------------------------------ */
/* json.decode / json.encode (src/codegen/pkg_json/dispatch.c)         */
/* ------------------------------------------------------------------ */

/* Returns the C function name that decodes a JSON value into slang
 * type `t` (a canonical type, e.g. from cg->expect). For scalar
 * types this is one of the fixed JSON_RUNTIME helpers; for composite
 * types (struct/opt/list/map[str,_]) it registers (and recursively
 * discovers) a monomorphized codec, to be emitted later by
 * emit_json_codecs. Every function has signature
 * 'bool NAME(sl_json_val *v, <ctype_of t> *out, char **err)'.
 * cg_error()s if `t` cannot be represented in JSON (rawptr, chan[T],
 * result[T,E], or a map with a non-str key). */
const char *json_dec_fn(CG *cg, const char *t, int line);

/* Same as json_dec_fn but for encoding: 'void NAME(<ctype_of t> v,
 * sl_json_sb *out)'. */
const char *json_enc_fn(CG *cg, const char *t, int line);

/* Wraps `val` (a C expression of slang type `t`) with whatever cast
 * its encode function's fixed-width parameter needs (e.g. i32 -> a
 * '(long long)' cast for sl_json_enc_i64); composite/bool/str values
 * pass through unchanged. Used at json.encode's own call site. */
char *json_enc_call_arg(const char *t, const char *val);

/* Emits JSON_RUNTIME (the parser, generic tree, and fixed scalar
 * dec/enc helpers) if cg->want_json. */
void emit_json_runtime(CG *cg);

/* Emits every composite codec registered in cg->json (prototypes
 * first, then bodies, so mutually-recursive struct codecs don't need
 * emission-order tracking). Must run after emit_struct_types and
 * emit_opt_res_types, since codec signatures reference both. */
void emit_json_codecs(CG *cg);

/* Type-checks a 'json.decode'/'json.encode' call (fname is the part
 * after the dot) and returns its slang return type, exactly like
 * native_check does for the fixed-signature native packages -- but
 * json's functions are generic over T, so they get their own entry
 * point instead of a NatSig row in some pkg_json/sigs.c. */
const char *json_call_infer(CG *cg, const char *fname, Expr *e);

/* Codegens a 'json.decode'/'json.encode' call site; mirrors
 * native_gen. Must run after json_call_infer has been called on the
 * same Expr (via infer_type), same convention as native_gen. */
char *json_call_gen(CG *cg, const char *fname, Expr *e);

#endif /* SLANG_CODEGEN_INTERNAL_H */
