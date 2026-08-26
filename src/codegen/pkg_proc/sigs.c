/* Signatures for the 'proc' package's native functions -- see
 * native.c's native_check/native_gen for the table-driven dispatch
 * these plug into, and internal.h for the NatSig/NatArgKind types. */

#include "../internal.h"

const NatSig PROC_SIGS[] = {
    {"proc", "shutdown_requested", 0, {0}, "bool", 0},
    {"proc", "active_tasks", 0, {0}, "int", 0},
    {"proc", "getenv", 1, {NA_STR}, "opt[str]", 0},
};

const int PROC_SIGS_LEN = sizeof(PROC_SIGS) / sizeof(PROC_SIGS[0]);
