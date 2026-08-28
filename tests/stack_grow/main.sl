// Tier 11: forces at least one real task-stack grow through actual
// generated code, not just the standalone spike. tag is a str (a real
// GC pointer) that must stay live ACROSS the recursive call (used again
// after it returns), so wrap_safepoint (core.c) actually brackets every
// level with sl_rt_safepoint_enter/exit -- that's the only place the
// guard-margin check (runtime_core.c) and sl_task_stack_grow
// (runtime_sched.c) get exercised. The default initial task stack is
// 65536 bytes (SL_TASK_INITIAL_STACK_SIZE, runtime_sched.c); this
// recurses far deeper than that could possibly hold unrelocated, so
// growth here is certain, not probabilistic, and deep enough to cross
// several doublings, not just one -- the same "more than once" case the
// standalone spike specifically targeted (a base-anchored translate()
// bug would pass a single grow and only fail on a second).
fn recurse(n: int, tag: str) -> int {
    if n <= 0 {
        return len(tag);
    }
    let sub = recurse(n - 1, tag);
    return sub + len(tag);
}

println(recurse(50000, "grow"));
