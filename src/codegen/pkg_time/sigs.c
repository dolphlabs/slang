/* Signatures for the 'time' package's native functions -- see
 * native.c's native_check/native_gen for the table-driven dispatch
 * these plug into, and internal.h for the NatSig/NatArgKind types. */

#include "../internal.h"

const NatSig TIME_SIGS[] = {
    {"time", "mono", 0, {0}, "duration", 0},
    {"time", "wall", 0, {0}, "int", 0},
    {"time", "sleep", 1, {NA_INT}, NULL, 0},
};

const int TIME_SIGS_LEN = sizeof(TIME_SIGS) / sizeof(TIME_SIGS[0]);
