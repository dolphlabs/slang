/* Tiny C fixture linked into the demo via slang's `link "slangarcade";`
 * + `extern fn` (see main.sl) -- exercises real C interop rather than
 * reimplementing a PRNG in slang. Seeded once, lazily, on first call. */
#include <stdlib.h>
#include <time.h>

static int seeded = 0;

static void ensure_seeded(void) {
    if (!seeded) {
        srand((unsigned int)time(NULL));
        seeded = 1;
    }
}

int sl_demo_roll_die(void) {
    ensure_seeded();
    return (rand() % 6) + 1;
}
