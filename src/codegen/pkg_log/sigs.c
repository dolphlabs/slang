#include "../internal.h"

const NatSig LOG_SIGS[] = {
    {"log", "debug", 1, {NA_STR}, NULL, 0},
    {"log", "info", 1, {NA_STR}, NULL, 0},
    {"log", "warn", 1, {NA_STR}, NULL, 0},
    {"log", "error", 1, {NA_STR}, NULL, 0},
};

const int LOG_SIGS_LEN = sizeof(LOG_SIGS) / sizeof(LOG_SIGS[0]);
