/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"
#include "liveness.h"

#include <string.h>

void emit_prelude(CG *cg) {
    for (int i = 0; i < RUNTIME_LEN; i++)
        emit_line(cg, "%s", RUNTIME[i]);
    /* Tier 10: the precise mark-sweep collector, then the containers
     * that allocate through it (chan/bytes/arr/map/strings) -- order
     * matters now: RUNTIME_CONTAINERS references sl_gc_alloc/realloc
     * and sl_rt_gc_blocked, all defined in RUNTIME_GC. */
    for (int i = 0; i < RUNTIME_GC_LEN; i++)
        emit_line(cg, "%s", RUNTIME_GC[i]);
    for (int i = 0; i < RUNTIME_CONTAINERS_LEN; i++)
        emit_line(cg, "%s", RUNTIME_CONTAINERS[i]);
    /* Tier 11 first slice: dead code only, not wired to anything below --
     * see runtime_sched.c's own header comment. */
    for (int i = 0; i < RUNTIME_SCHED_LEN; i++)
        emit_line(cg, "%s", RUNTIME_SCHED[i]);
    /* Tier 11 second slice: also dead code -- see runtime_pool.c's own
     * header comment. Emitted last since it needs sl_ctx_switch/
     * sl_task_stack_init (RUNTIME_SCHED) and sl_gc_register_thread/
     * sl_rt_gc_checkin (RUNTIME_GC) already visible. */
    for (int i = 0; i < RUNTIME_POOL_LEN; i++)
        emit_line(cg, "%s", RUNTIME_POOL[i]);
}


/* Register a raw (not yet canonicalized) function signature. */
void sig_register_raw(CG *cg, Package *p, FuncDecl *f,
                             const char *method_of) {
    if (is_builtin_name(f->name))
        cg_error(f->line, "cannot redefine builtin '%s'", f->name);
    if (sig_find_in(cg, p->name, f->name))
        cg_error(f->line,
                 "redefinition of function '%s' in package '%s'", f->name,
                 p->name);

    FuncSig sig;
    memset(&sig, 0, sizeof(sig));
    sig.name = f->name;
    sig.pkg = p->name;
    sig.is_pub = f->is_pub;
    sig.is_extern = f->is_extern;
    sig.ret_slang = f->ret_type;
    sig.nparams = f->nparams;
    sig.method_of = method_of;
    sig.line = f->line;
    sig.param_slang =
        (const char **)xmalloc(sizeof(char *) *
                               (f->nparams ? f->nparams : 1));
    for (int m = 0; m < f->nparams; m++)
        sig.param_slang[m] = f->param_types[m];

    if (cg->sigs.count == cg->sigs.cap) {
        cg->sigs.cap = cg->sigs.cap ? cg->sigs.cap * 2 : 8;
        cg->sigs.items = (FuncSig *)xrealloc(
            cg->sigs.items, cg->sigs.cap * sizeof(FuncSig));
    }
    cg->sigs.items[cg->sigs.count++] = sig;
}

/* Collect imports, structs, free functions, and methods from every
 * package, then canonicalize all stored type names. */
void collect_decls(CG *cg, Package *pkgs, int npkgs) {
    int i, j;

    /* imports */
    for (i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (j = 0; j < p->prog->nimports; j++) {
            char *ipath = p->prog->import_paths[j];
            import_push(cg, p->name, path_base(ipath), path_base(ipath));
        }
    }

    /* pass 1: free functions + struct shells */
    for (i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (j = 0; j < p->prog->nfuncs; j++)
            sig_register_raw(cg, p, p->prog->funcs[j], NULL);
        Block *body = p->prog->main_body;
        for (j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_STRUCT)
                continue;
            if (struct_find_in_pkg(cg, p->name, s->as.struct_decl.name))
                cg_error(s->line,
                         "redefinition of struct '%s' in package '%s'",
                         s->as.struct_decl.name, p->name);
            if (cg->structs.count == cg->structs.cap) {
                cg->structs.cap = cg->structs.cap ? cg->structs.cap * 2 : 8;
                cg->structs.items = (StructDef *)xrealloc(
                    cg->structs.items,
                    cg->structs.cap * sizeof(StructDef));
            }
            StructDef *sd = &cg->structs.items[cg->structs.count++];
            sd->canonical =
                xasprintf("%s.%s", p->name, s->as.struct_decl.name);
            sd->pkg = p->name;
            sd->name = s->as.struct_decl.name;
            sd->is_pub = s->as.struct_decl.is_pub;
            sd->fields = s->as.struct_decl.fields;
            sd->ftypes = (const char **)s->as.struct_decl.ftypes;
            sd->nfields = s->as.struct_decl.nfields;
            sd->line = s->line;
        }
    }

    /* pass 2: canonicalize struct field types */
    for (i = 0; i < cg->structs.count; i++) {
        StructDef *sd = &cg->structs.items[i];
        cg->cur_pkg = sd->pkg;
        for (j = 0; j < sd->nfields; j++) {
            for (int q = 0; q < j; q++) {
                if (!strcmp(sd->fields[q], sd->fields[j]))
                    cg_error(sd->line,
                             "duplicate field '%s' in struct '%s'",
                             sd->fields[j], sd->canonical);
            }
            sd->ftypes[j] = canon_type(cg, sd->ftypes[j], sd->line);
        }
    }

    /* pass 3: methods from impl blocks */
    for (i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        Block *body = p->prog->main_body;
        for (j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            StructDef *sd =
                struct_find_in_pkg(cg, p->name, s->as.impl.struct_name);
            if (!sd)
                cg_error(s->line, "impl of unknown struct '%s'",
                         s->as.impl.struct_name);
            for (int q = 0; q < s->as.impl.nfuncs; q++)
                sig_register_raw(cg, p, s->as.impl.funcs[q],
                                 sd->canonical);
        }
    }

    /* pass 4: canonicalize all signatures */
    for (i = 0; i < cg->sigs.count; i++) {
        FuncSig *sig = &cg->sigs.items[i];
        cg->cur_pkg = sig->pkg;
        for (j = 0; j < sig->nparams; j++) {
            ((char **)sig->param_slang)[j] =
                (char *)canon_type(cg, sig->param_slang[j], sig->line);
            if (sig->is_extern)
                check_extern_type(sig->param_slang[j], sig->line,
                                  "parameter");
        }
        if (sig->ret_slang)
            sig->ret_slang = canon_type(cg, sig->ret_slang, sig->line);
        if (sig->is_extern && sig->ret_slang)
            check_extern_type(sig->ret_slang, sig->line, "return");
    }
}

/* Type of a constant-literal initializer, or error. */
const char *literal_type(CG *cg, Expr *e, int line) {
    (void)cg;
    switch (e->kind) {
    case EX_INT:    return "int";
    case EX_FLOAT:  return "float";
    case EX_STRING: return "str";
    case EX_BYTES:  return "bytes";
    case EX_BOOL:   return "bool";
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "-")) {
            Expr *o = e->as.unary.operand;
            if (o->kind == EX_INT) return "int";
            if (o->kind == EX_FLOAT) return "float";
        }
        break;
    default:
        break;
    }
    cg_error(line,
             "package-level variables must be initialized with constant "
             "literals");
    return NULL; /* unreachable */
}

/* C source text for a constant-literal initializer. */
char *gen_const_init(Expr *e) {
    switch (e->kind) {
    case EX_INT:
        return xasprintf("%lld", e->as.int_lit.value);
    case EX_FLOAT:
        return gen_float_literal(e->as.float_lit.value);
    case EX_STRING:
        return c_string_literal(e->as.str_lit.value);
    case EX_BOOL:
        return xstrdup(e->as.bool_lit.value ? "true" : "false");
    case EX_UNARY: {
        char *o = gen_const_init(e->as.unary.operand);
        return xasprintf("(-%s)", o);
    }
    default:
        return NULL; /* unreachable: validated by literal_type */
    }
}

/* Emit package-level variables of all imported packages as C globals
 * and register them in the symbol table. */
void emit_globals(CG *cg, Package *pkgs, int npkgs, int main_index) {
    int any = 0;
    for (int i = 0; i < npkgs; i++) {
        if (i == main_index)
            continue; /* main pkg top-level lets are locals of main() */
        Package *p = &pkgs[i];
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind == ST_STRUCT || s->kind == ST_IMPL)
                continue; /* handled by collect_decls */
            if (s->kind != ST_LET)
                cg_error(s->line,
                         "only 'let' declarations are allowed at top "
                         "level in an imported package");
            const char *t = literal_type(cg, s->as.let.init, s->line);
            if (is_arr(t))
                cg_error(s->line,
                         "package-level lists are not supported yet");
            if (glob_find(cg, p->name, s->as.let.name))
                cg_error(s->line, "duplicate variable '%s' in package '%s'",
                         s->as.let.name, p->name);
            glob_push(cg, s->as.let.name, p->name, t, s->as.let.is_pub);
            if (is_bytes(t)) {
                Expr *init = s->as.let.init;
                char *m = mangle_glob(p->name, s->as.let.name);
                emit_line(cg, "static const unsigned char %s_bdata[] = %s;",
                          m, c_bytes_literal(init->as.bytes_lit.data,
                                             init->as.bytes_lit.len));
                emit_line(cg, "static sl_bytes %s = { %lld, (unsigned char *)%s_bdata };",
                          m, init->as.bytes_lit.len, m);
            } else {
                emit_line(cg, "static %s %s = %s;", map_type(t),
                          mangle_glob(p->name, s->as.let.name),
                          gen_const_init(s->as.let.init));
            }
            any = 1;
        }
    }
    if (any)
        emit_line(cg, "");
}

/* Emit forward declarations and definitions for every struct. */
void emit_struct_types(CG *cg) {
    if (!cg->structs.count)
        return;
    for (int i = 0; i < cg->structs.count; i++) {
        char *m = mangle_struct(cg->structs.items[i].canonical);
        emit_line(cg, "typedef struct %s %s;", m, m);
    }
    emit_line(cg, "");
    for (int i = 0; i < cg->structs.count; i++) {
        StructDef *sd = &cg->structs.items[i];
        char *m = mangle_struct(sd->canonical);
        emit_line(cg, "struct %s {", m);
        cg->indent++;
        for (int j = 0; j < sd->nfields; j++)
            emit_line(cg, "%s %s;", ctype_of(cg, sd->ftypes[j]),
                      sanitize_ident(sd->fields[j]));
        cg->indent--;
        emit_line(cg, "};");
        emit_line(cg, "");
    }
}

/* Tier 10: emit a trace function for every struct type that has at
 * least one GC-pointer field, for the mark-sweep collector to call
 * through a heap object's own header. A struct with no GC-pointer
 * fields gets no tracer at all -- its allocation call sites pass NULL
 * directly rather than reference a no-op function (see
 * struct_has_gc_fields, core.c). Must run after emit_struct_types so
 * every struct body (and therefore every field's real name) already
 * exists; field access is emitted directly (o->fieldname), not via
 * offsetof, since the real names are already known here. */
void emit_struct_tracers(CG *cg) {
    for (int i = 0; i < cg->structs.count; i++) {
        StructDef *sd = &cg->structs.items[i];
        if (!struct_has_gc_fields(cg, sd))
            continue;
        char *m = mangle_struct(sd->canonical);
        emit_line(cg, "static void sl_gc_trace_%s(void *p, void (*mark)(void *)) {",
                  m);
        cg->indent++;
        emit_line(cg, "%s *o = (%s *)p;", m, m);
        for (int j = 0; j < sd->nfields; j++)
            if (type_is_gc_ptr(cg, sd->ftypes[j]))
                emit_line(cg, "mark((void *)o->%s);",
                          sanitize_ident(sd->fields[j]));
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "");
    }
}

/* Emit C definitions for every monomorphized opt/result instantiation
 * discovered during generation. Emitted after struct types so inner
 * struct types are complete. */

/* Forward-declares every opt/result instantiation discovered so far
 * (as an incomplete named-struct typedef) so struct bodies emitted
 * afterward can hold an opt[T]/result[T,E]-typed field -- those
 * fields are always pointers (see ctype_of), so an incomplete type
 * is all a struct body needs; the full definition follows later via
 * emit_opt_res_types. Must run before emit_struct_types. */
void emit_opt_res_forward_decls(CG *cg) {
    for (int i = 0; i < cg->opts.count; i++)
        emit_line(cg, "typedef struct %s %s;", cg->opts.items[i].cname,
                  cg->opts.items[i].cname);
    for (int i = 0; i < cg->res.count; i++)
        emit_line(cg, "typedef struct %s %s;", cg->res.items[i].cname,
                  cg->res.items[i].cname);
}

void emit_opt_res_types(CG *cg) {
    for (int i = 0; i < cg->opts.count; i++) {
        OptInst *o = &cg->opts.items[i];
        emit_line(cg, "struct %s {", o->cname);
        cg->indent++;
        emit_line(cg, "bool has;");
        emit_line(cg, "%s v;", ctype_of(cg, o->inner));
        cg->indent--;
        emit_line(cg, "};");
        emit_line(cg, "");
    }
    for (int i = 0; i < cg->res.count; i++) {
        ResInst *r = &cg->res.items[i];
        emit_line(cg, "struct %s {", r->cname);
        cg->indent++;
        emit_line(cg, "bool ok;");
        emit_line(cg, "%s v;", ctype_of(cg, r->tv));
        emit_line(cg, "%s e;", ctype_of(cg, r->te));
        cg->indent--;
        emit_line(cg, "};");
        emit_line(cg, "");
    }
}

/* Tier 10: trace functions for every monomorphized opt/result
 * instantiation, mirroring emit_struct_tracers -- only emitted when the
 * instantiation's own payload type(s) are GC-pointer types (an opt/res
 * of a scalar type needs no tracer at all). has/ok don't need to gate
 * the mark: an unset payload pointer is zero-filled by sl_gc_alloc, and
 * the collector's mark is NULL-safe, so marking unconditionally is
 * simpler and exactly as correct as branching on the flag first. */
void emit_opt_res_tracers(CG *cg) {
    for (int i = 0; i < cg->opts.count; i++) {
        OptInst *o = &cg->opts.items[i];
        if (!type_is_gc_ptr(cg, o->inner))
            continue;
        emit_line(cg, "static void sl_gc_trace_%s(void *p, void (*mark)(void *)) {",
                  o->cname);
        cg->indent++;
        emit_line(cg, "%s *o = (%s *)p;", o->cname, o->cname);
        emit_line(cg, "mark((void *)o->v);");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "");
    }
    for (int i = 0; i < cg->res.count; i++) {
        ResInst *r = &cg->res.items[i];
        int vptr = type_is_gc_ptr(cg, r->tv);
        int eptr = type_is_gc_ptr(cg, r->te);
        if (!vptr && !eptr)
            continue;
        emit_line(cg, "static void sl_gc_trace_%s(void *p, void (*mark)(void *)) {",
                  r->cname);
        cg->indent++;
        emit_line(cg, "%s *o = (%s *)p;", r->cname, r->cname);
        if (vptr)
            emit_line(cg, "mark((void *)o->v);");
        if (eptr)
            emit_line(cg, "mark((void *)o->e);");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "");
    }
}

/* Some native runtimes unconditionally reference a fixed set of
 * opt/result instantiations regardless of which of their functions
 * the slang program actually calls or how it uses their return
 * values (net: i32/str, bytes/str, bool/str for its handles/recv/
 * nonblock; proc: opt[str] for getenv); register them whenever the
 * owning package is imported so their typedefs always exist
 * alongside the runtime code that references them. */
void force_native_result_types(CG *cg) {
    if (want_pkg(cg, "net")) {
        res_cname(cg, "i32", "str");
        res_cname(cg, "bytes", "str");
        res_cname(cg, "bool", "str");
        /* cg->want_tls is only known for certain after the dry run
         * has walked every statement (same "populate now, read back
         * on the real run" pattern as opts/res/spawns above) */
        if (cg->want_tls)
            res_cname(cg, "rawptr", "str");
    }
    if (want_pkg(cg, "proc"))
        opt_cname(cg, "str");
}

/* Emit the native-package runtime sections that this program needs,
 * based on which native packages were imported. Must run after
 * emit_opt_res_types so the fixed result/opt instantiations exist. */
void emit_native_runtime(CG *cg) {
    int want_time = want_pkg(cg, "time");
    int want_net = want_pkg(cg, "net");
    int want_proc = want_pkg(cg, "proc");
    if (!want_time && !want_net && !want_proc)
        return;
    if (want_time)
        for (int i = 0; i < TIME_RUNTIME_LEN; i++)
            emit_line(cg, "%s", TIME_RUNTIME[i]);
    if (want_net)
        for (int i = 0; i < NET_RUNTIME_LEN; i++)
            emit_line(cg, "%s", NET_RUNTIME[i]);
    if (cg->want_tls)
        for (int i = 0; i < TLS_RUNTIME_LEN; i++)
            emit_line(cg, "%s", TLS_RUNTIME[i]);
    if (want_proc)
        for (int i = 0; i < PROC_RUNTIME_LEN; i++)
            emit_line(cg, "%s", PROC_RUNTIME[i]);
}

/* Emit the args-struct + task entry function for every distinct
 * 'spawn' target discovered while generating. Must run before any
 * function body that spawns one references it by name.
 *
 * Tier 11 third slice: this used to also emit an outer pthread entry
 * point (%s(void *_sl_raw)) that registered the OS thread with the
 * collector, ran %s_entry to completion via sl_ctx_switch, and
 * unregistered on the way out -- one real OS thread per spawned task,
 * created fresh by ST_SPAWN's own pthread_create call (stmt.c). Under
 * the worker pool, a task's entry function is submitted to
 * sl_task_submit (runtime_pool.c) instead, which already owns exactly
 * that registration/switch/unregistration lifecycle for whichever
 * pooled OS thread ends up running it -- the outer trampoline became
 * genuinely dead code, not merely unused, and was deleted along with
 * it rather than left as an inert leftover. Only %s_entry remains. */
void emit_spawn_trampolines(CG *cg) {
    for (int i = 0; i < cg->spawns.count; i++) {
        SpawnShape *s = &cg->spawns.items[i];
        FuncSig *sig = sig_find_in(cg, s->pkg, s->name);
        char *callee = sig->is_extern ? xstrdup(sig->name)
                                      : mangle_func(sig->pkg, sig->name);

        emit_line(cg, "typedef struct {");
        cg->indent++;
        if (sig->nparams == 0) {
            emit_line(cg, "char _unused;");
        } else {
            for (int j = 0; j < sig->nparams; j++)
                emit_line(cg, "%s a%d;", ctype_of(cg, sig->param_slang[j]),
                          j);
        }
        cg->indent--;
        emit_line(cg, "} %s;", s->sname);
        emit_line(cg, "");

        /* Tier 10: trace the spawn args struct the same way a
         * slang-declared struct's fields are traced -- it's the same
         * shape (fixed, named fields, a0..an-1 here instead of the
         * user's own field names), just generated from a FuncSig
         * instead of a StructDef. s->has_tracer was computed once in
         * spawn_shape_for (core.c), where param_slang was already at
         * hand; reused here and by every ST_SPAWN call site later. */
        if (s->has_tracer) {
            emit_line(cg, "static void sl_gc_trace_%s(void *p, void (*mark)(void *)) {",
                      s->sname);
            cg->indent++;
            emit_line(cg, "%s *o = (%s *)p;", s->sname, s->sname);
            for (int j = 0; j < sig->nparams; j++)
                if (type_is_gc_ptr(cg, sig->param_slang[j]))
                    emit_line(cg, "mark((void *)o->a%d);", j);
            cg->indent--;
            emit_line(cg, "}");
            emit_line(cg, "");
        }

        /* Tier 11: the spawned function's own body runs on a task-owned
         * buffer (sl_task_stack_init) instead of directly on a pthread's
         * OS-provided stack -- %s_entry is the sl_ctx_make entry point,
         * switched into by whichever pooled worker (runtime_pool.c)
         * dequeues this task, and switched back out of once the user
         * function returns, mirroring main()/sl_main_task_entry
         * exactly. */
        emit_line(cg, "static void %s_entry(void *_sl_raw) {", s->tname);
        cg->indent++;
        if (sig->nparams == 0) {
            emit_line(cg, "(void)_sl_raw;");
            emit_line(cg, "%s();", callee);
        } else {
            emit_line(cg, "%s *_sl_a = (%s *)_sl_raw;", s->sname, s->sname);
            StrBuf args;
            sb_init(&args);
            for (int j = 0; j < sig->nparams; j++) {
                if (j)
                    sb_append(&args, ", ");
                sb_append(&args, xasprintf("_sl_a->a%d", j));
            }
            emit_line(cg, "%s(%s);", callee, args.data);
        }
        /* Also decremented inside sl_rt_error's non-main-thread path,
         * since a task that panics never reaches this line -- both
         * paths must decrement exactly once. */
        emit_line(cg, "sl_rt_active_spawns_dec();");
        /* Tier 11 eighth slice: bracketed -- see sl_rt_error's own
         * identical bracket and comment (runtime_core.c) for the exact
         * hazard this closes, sharpened for this specific call site: an
         * async signal landing mid-sl_ctx_switch, AFTER some but not all
         * of its own callee-saved-register pushes but BEFORE its
         * `mov %rsi,%rsp` has executed, diverts this task through the
         * async trampoline instead. sl_rt_native_rsp -- %rsi's argument
         * value here -- is _Thread_local: read ONCE, into a register,
         * when this call's arguments are evaluated, on WHICHEVER worker
         * thread first ran this task. The trampoline's own full-register
         * save/restore faithfully preserves that already-loaded %rsi
         * value across the suspension, so if this task is later resumed
         * on a DIFFERENT worker (routine here -- any idle worker may
         * dequeue any queued task), the resumed code finishes THIS SAME,
         * now-stale sl_ctx_switch call and switches the NEW thread onto
         * the ORIGINAL thread's own native scheduler stack -- two OS
         * threads on one stack. Every spawned task hits this exact call
         * exactly once, on completion, making it the single most-executed
         * unbracketed switch in a task-heavy workload -- root-caused via
         * concurrent_compute's own crashes (map/chan/array corruption in
         * completely unrelated code, the signature of a hijacked native
         * stack, not a clean fault at the bug's own site). */
        emit_line(cg, "sl_rt_preempt_disable();");
        emit_line(cg, "sl_ctx_switch(&sl_rt_current_task->rsp, sl_rt_native_rsp);");
        emit_line(cg, "fprintf(stderr, \"slang: internal error: spawn task entry \"");
        emit_line(cg, "                \"resumed after switching back -- unreachable\\n\");");
        emit_line(cg, "abort(); /* genuinely unreachable -- a can't-happen guard, never");
        emit_line(cg, "            routed through sl_rt_error's panic-recovery machinery */");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "");
    }
}

void gen_prototypes(CG *cg, Package *pkgs, int npkgs) {
    int any = 0;
    for (int i = 0; i < npkgs; i++) {
        Program *prog = pkgs[i].prog;

        /* free functions */
        for (int j = 0; j < prog->nfuncs; j++) {
            FuncDecl *f = prog->funcs[j];
            FuncSig *sig = sig_find_in(cg, pkgs[i].name, f->name);
            StrBuf params;
            sb_init(&params);
            if (f->is_extern) {
                /* no body defined here, so the real symbol just needs
                 * a matching prototype for the C compiler + linker;
                 * parameter names are irrelevant in a prototype */
                if (sig->nparams == 0) {
                    sb_append(&params, "void");
                } else {
                    for (int m = 0; m < sig->nparams; m++) {
                        if (m)
                            sb_append(&params, ", ");
                        sb_append(&params, ctype_of(cg, sig->param_slang[m]));
                    }
                }
                emit_line(cg, "extern %s %s(%s);",
                          sig->ret_slang ? ctype_of(cg, sig->ret_slang)
                                         : "void",
                          f->name, params.data);
                any = 1;
                continue;
            }
            if (f->nparams == 0) {
                sb_append(&params, "void");
            } else {
                for (int m = 0; m < f->nparams; m++) {
                    if (m)
                        sb_append(&params, ", ");
                    sb_append(&params, ctype_of(cg, sig->param_slang[m]));
                    sb_putc(&params, ' ');
                    sb_append(&params, sanitize_ident(f->params[m]));
                }
            }
            emit_line(cg, "static %s %s(%s);",
                      sig->ret_slang ? ctype_of(cg, sig->ret_slang)
                                     : "void",
                      mangle_func(pkgs[i].name, f->name), params.data);
            any = 1;
        }

        /* methods from impl blocks */
        Block *body = prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++) {
                FuncDecl *f = s->as.impl.funcs[q];
                FuncSig *sig = sig_find_in(cg, pkgs[i].name, f->name);
                StrBuf params;
                sb_init(&params);
                if (f->nparams == 0) {
                    sb_append(&params, "void");
                } else {
                    for (int m = 0; m < f->nparams; m++) {
                        if (m)
                            sb_append(&params, ", ");
                        sb_append(&params,
                                  ctype_of(cg, sig->param_slang[m]));
                        sb_putc(&params, ' ');
                        sb_append(&params, sanitize_ident(f->params[m]));
                    }
                }
                emit_line(cg, "static %s %s(%s);",
                          sig->ret_slang ? ctype_of(cg, sig->ret_slang)
                                         : "void",
                          mangle_func(pkgs[i].name, f->name), params.data);
                any = 1;
            }
        }
    }
    if (any)
        emit_line(cg, "");
}

void gen_function(CG *cg, Package *p, FuncDecl *f) {
    FuncSig *sig = sig_find_in(cg, p->name, f->name);

    cg->vars.count = 0; /* fresh scope per function */
    cg->in_function = 1;
    cg->cur_ret = sig->ret_slang;
    cg->cur_pkg = p->name;

    for (int j = 0; j < f->nparams; j++)
        var_push(cg, f->params[j], sig->param_slang[j]);

    StrBuf params;
    sb_init(&params);
    if (f->nparams == 0) {
        sb_append(&params, "void");
    } else {
        for (int j = 0; j < f->nparams; j++) {
            if (j)
                sb_append(&params, ", ");
            sb_append(&params, ctype_of(cg, sig->param_slang[j]));
            sb_putc(&params, ' ');
            sb_append(&params, sanitize_ident(f->params[j]));
        }
    }

    emit_line(cg, "static %s %s(%s) {",
              sig->ret_slang ? ctype_of(cg, sig->ret_slang) : "void",
              mangle_func(p->name, f->name), params.data);
    gen_block(cg, f->body);
    emit_line(cg, "}");
    emit_line(cg, "");

    cg->in_function = 0;
    cg->cur_ret = NULL;
}

/* Generate the complete translation unit into cg->out. */
void gen_whole_program(CG *cg, Package *pkgs, int npkgs,
                              int main_index) {
    emit_prelude(cg);

    emit_opt_res_forward_decls(cg);
    emit_struct_types(cg);
    emit_struct_tracers(cg);

    force_native_result_types(cg);
    emit_opt_res_types(cg);
    emit_opt_res_tracers(cg);

    emit_native_runtime(cg);

    emit_json_runtime(cg);
    emit_json_codecs(cg);

    emit_globals(cg, pkgs, npkgs, main_index);

    gen_prototypes(cg, pkgs, npkgs);

    emit_spawn_trampolines(cg);

    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (int j = 0; j < p->prog->nfuncs; j++) {
            if (p->prog->funcs[j]->is_extern)
                continue; /* declared only; no body to emit */
            gen_function(cg, p, p->prog->funcs[j]);
        }
        /* methods from impl blocks */
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++)
                gen_function(cg, p, s->as.impl.funcs[q]);
        }
    }

    /* top-level statements of the main package become sl_main_task_entry,
     * run on its own task-owned stack (sl_task_stack_init,
     * runtime_sched.c) instead of directly on main()'s OS-provided one --
     * this is what gives sl_rt_safepoint_enter's growth check something
     * safe to relocate. cg->in_function is deliberately left at 0 here,
     * not set to 1 the way a real gen_function call would: top-level
     * `return` must stay a hard compile error (ST_RETURN's own check,
     * stmt.c), exactly as before this wrapper existed. */
    cg->vars.count = 0;
    cg->cur_pkg = pkgs[main_index].name;
    emit_line(cg, "static void sl_main_task_entry(void *_sl_unused_arg) {");
    emit_line(cg, "    (void)_sl_unused_arg;");
    gen_block(cg, pkgs[main_index].prog->main_body);
    emit_line(cg, "    exit(0); /* main()'s own sl_ctx_switch never returns */");
    emit_line(cg, "}");
    emit_line(cg, "");
    emit_line(cg, "int main(void) {");
    if (want_pkg(cg, "proc")) {
        /* Tier 11 sixth slice: block SIGTERM/SIGINT exactly ONCE, here,
         * before any other thread is ever created -- every subsequently-
         * created thread (pool workers, the timer thread, the reactor
         * thread, the dedicated signal thread itself) inherits the
         * blocked mask automatically via normal pthread_create
         * semantics. Replaces the old per-subsystem block_signals
         * parameter dance entirely: that design deliberately left
         * exactly one OS thread (this one, main's original) unblocked
         * and relied on a blocking net.accept() call getting EINTR on
         * that specific thread -- correct only as long as main's own
         * task could never migrate to a different OS thread, which
         * stopped being true once chan/time.sleep parking made that
         * migration possible. Now every thread blocks these signals,
         * including this one, and exactly one dedicated thread
         * (sl_proc_install_signal_handlers below) owns delivery via
         * sigwait(), decoupled from which thread happens to be running
         * which task at any given moment. */
        emit_line(cg, "    sigset_t sl_rt_sigmask;");
        emit_line(cg, "    sigemptyset(&sl_rt_sigmask);");
        emit_line(cg, "    sigaddset(&sl_rt_sigmask, SIGTERM);");
        emit_line(cg, "    sigaddset(&sl_rt_sigmask, SIGINT);");
        emit_line(cg, "    pthread_sigmask(SIG_BLOCK, &sl_rt_sigmask, NULL);");
    }
    emit_line(cg, "    sl_gc_register_thread();");
    /* Pool must exist before anything can be submitted to it, and
     * nothing is submitted before user code (which might 'spawn')
     * starts running below. */
    emit_line(cg, "    sl_pool_start();");
    /* Tier 11 fifth slice: the timer thread, gated on 'time' being
     * imported at all -- sl_time_start (pkg_time/runtime.c, TIME_RUNTIME)
     * is only ever DEFINED when want_pkg(cg,"time") is true
     * (emit_native_runtime); this needs its own fresh gate here, not
     * emit_native_runtime's own local, which has no scope reaching this
     * function. */
    if (want_pkg(cg, "time"))
        emit_line(cg, "    sl_time_start();");
    /* Tier 11 sixth slice: the reactor, same gating reasoning as the
     * timer thread just above -- must start BEFORE
     * sl_proc_install_signal_handlers() below, so sl_rt_shutdown_hook
     * (runtime_core.c) is guaranteed set before the signal thread could
     * ever consume a signal and try to call through it. */
    if (want_pkg(cg, "net"))
        emit_line(cg, "    sl_reactor_start();");
    if (want_pkg(cg, "proc"))
        emit_line(cg, "    sl_proc_install_signal_handlers();");
    /* Tier 11 fourth slice: main's own task is heap-allocated exactly
     * the way sl_task_submit already allocates every spawned task's
     * struct, instead of repurposing sl_rt_task_storage (the per-thread
     * idle placeholder sl_gc_register_thread just pointed
     * sl_rt_current_task at) in place. Once chan_send/chan_recv can
     * park, main's own task can become a real, externally-linked
     * object (reachable from a channel's own wait list and the global
     * parked-task registry) -- reusing sl_rt_task_storage for that
     * would let it alias the SAME memory this (or any other) thread's
     * idle-between-tasks placeholder also uses, once main's task is
     * resumed on a different worker while this thread falls back to
     * being idle. Heap-allocating keeps sl_rt_task_storage a uniformly
     * private, never-externally-referenced idle placeholder for every
     * thread, main's included -- no special case. */
    emit_line(cg, "    sl_task *sl_rt_main_task = (sl_task *)malloc(sizeof(sl_task));");
    emit_line(cg, "    if (!sl_rt_main_task) {");
    emit_line(cg, "        fprintf(stderr, \"slang: out of memory allocating main task\\n\");");
    emit_line(cg, "        exit(1);");
    emit_line(cg, "    }");
    emit_line(cg, "    memset(sl_rt_main_task, 0, sizeof(*sl_rt_main_task));");
    emit_line(cg, "    sl_rt_main_task->is_main = 1;");
    emit_line(cg, "    sl_rt_current_task = sl_rt_main_task;");
    emit_line(cg, "    sl_task_stack_init(sl_rt_current_task, sl_main_task_entry, NULL);");
    /* Tier 11 seventh slice: same run_start_ns reset sl_worker_run_loop
     * gives every OTHER dispatch (runtime_pool.c) -- this is the one
     * switch-in that bypasses that loop, so it needs its own copy.
     * Without it, main's very first loop back-edge would compare
     * against 0 (the memset'd default) instead of a real timestamp. */
    emit_line(cg, "    sl_rt_main_task->run_start_ns = sl_rt_monotonic_ns();");
    emit_line(cg, "    sl_ctx_switch(&sl_rt_native_rsp, sl_rt_current_task->rsp);");
    /* Only reached if main's own task PARKED -- a normal finish calls
     * exit(0) directly from sl_main_task_entry and never switches back
     * at all. Falls into the SAME shared post-switch dispatch the real
     * pool workers use (sl_worker_after_switch/sl_worker_run_loop,
     * runtime_pool.c): from here on this OS thread simply joins the
     * pool, indistinguishable from any other worker -- safe because the
     * only way the process ever legitimately exits is a direct exit()
     * call from somewhere, regardless of which thread is inside
     * sl_worker_run_loop at that moment. */
    emit_line(cg, "    sl_worker_after_switch(sl_rt_main_task);");
    /* Tier 11 eighth slice: -1, not a real sl_pool_slots index -- this
     * is main's own original OS thread, not one of sl_pool_workers[],
     * and the async-preemption ticker's own scope note excludes it
     * (only real pool workers are ever preemption targets in v1). See
     * sl_worker_run_loop's own comment (runtime_pool.c). */
    emit_line(cg, "    sl_worker_run_loop(-1);");
    emit_line(cg, "    return 0; /* unreachable: sl_worker_run_loop only returns on shutdown */");
    emit_line(cg, "}");
}

void codegen_program(Package *pkgs, int npkgs, int main_index,
                     StrBuf *out, int *out_want_tls) {
    CG cg;
    memset(&cg, 0, sizeof(CG));
    cg.out = out;
    cg.cur_pkg = pkgs[main_index].name;

    /* record which packages are compiler-provided natives */
    for (int i = 0; i < npkgs; i++) {
        if (!pkgs[i].native)
            continue;
        cg.nat_pkgs = (char **)xrealloc(
            cg.nat_pkgs, (size_t)(cg.nnat + 1) * sizeof(char *));
        cg.nat_pkgs[cg.nnat++] = pkgs[i].name;
    }

    collect_decls(&cg, pkgs, npkgs);

    /* Dry run: generation populates the opt/result monomorphization
     * tables as it goes, but typedefs must be emitted before any use.
     * Generate once into a scratch buffer to discover every
     * instantiation, then generate for real with complete tables. */
    StrBuf scratch;
    sb_init(&scratch);
    cg.out = &scratch;
    gen_whole_program(&cg, pkgs, npkgs, main_index);
    free(scratch.data);

    /* Tier 10: populate Expr.live_set (used by gen_call's call-site
     * safepoint brackets) once, before the real gen_whole_program pass
     * below reads it -- codegen never mutates live_set, so computing
     * it once and letting the real run read the same already-computed
     * data is safe. Must run here, after the dry run and before the
     * glob-bookkeeping reset just below: package-level (non-main)
     * globals only exist in cg.globs once emit_globals (called from
     * gen_whole_program) has registered them via glob_push, and a
     * function body referencing one of its own package's globals
     * (e.g. httpkit's find_blank_line reading the package-level `CR`)
     * needs that to already be resolvable, exactly like the real
     * gen_function pass just below will. Running it any earlier
     * (before the dry run ever populates cg.globs at all) makes
     * compute_liveness reject any such program with a spurious
     * "undefined variable" -- caught by demo/main.sl specifically,
     * which is exactly this shape (httpkit.sl's CR/LF/SPACE). */
    compute_liveness(&cg, pkgs, npkgs, main_index);

    /* emit_globals (called from gen_whole_program) registers package
     * globals as it emits them; undo that bookkeeping before the real
     * run re-emits and re-registers the same globals, or it trips its
     * own duplicate-declaration check. opts/res are deliberately left
     * to accumulate across both passes (that's the point of the dry
     * run); globs has no such purpose here. */
    cg.globs.count = 0;

    out->len = 0;
    out->data[0] = '\0';
    cg.out = out;
    gen_whole_program(&cg, pkgs, npkgs, main_index);
    *out_want_tls = cg.want_tls;
}
