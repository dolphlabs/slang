/* Signatures for the 'proc' package's native functions -- see
 * native.c's native_check/native_gen for the table-driven dispatch
 * these plug into, and internal.h for the NatSig/NatArgKind types. */

#include "../internal.h"

const NatSig PROC_SIGS[] = {
    {"proc", "shutdown_requested", 0, {0}, "bool", 0},
    {"proc", "active_tasks", 0, {0}, "int", 0},
    {"proc", "wait_idle", 0, {0}, NULL, 0},
    /* wait_idle bounded by a deadline: true once idle, false if the
       deadline passed first */
    {"proc", "wait_idle_until", 1, {NA_UNTIL}, "bool", 0},
    {"proc", "getenv", 1, {NA_STR}, "opt[str]", 0},
    {"proc", "args", 0, {0}, "[str]", 0},
    {"proc", "cwd", 0, {0}, "result[str,str]", 0},
    {"proc", "spawn", 4, {NA_ARR_STR, NA_ARR_STR, NA_STR, NA_INT}, "result[int,str]", 0},
    /* spawn, passing fds as 3, 4, ... with LISTEN_FDS set (the systemd
       convention net.inherited reads): hand listeners to a new version */
    {"proc", "spawn_fds", 5, {NA_ARR_STR, NA_ARR_STR, NA_STR, NA_INT, NA_ARR_I32},
     "result[int,str]", 0},
    /* the runtime's counters in a fixed order; the `runtime` package
       (stdlib/runtime) names them */
    {"proc", "runtime_stats", 0, {0}, "[int]", 0},
    {"proc", "kill", 2, {NA_INT, NA_INT}, "result[bool,str]", 0},
    {"proc", "wait", 2, {NA_INT, NA_UNTIL}, "result[int,str]", 0},
};

const int PROC_SIGS_LEN = sizeof(PROC_SIGS) / sizeof(PROC_SIGS[0]);

