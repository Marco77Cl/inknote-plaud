#pragma once
#include "button_bsp.h"

/* Only consume actions used by InkNote. During E-Ink refresh, press/release
 * bits can accumulate alongside clicks; the factory reader clears them all
 * and returns the first bit, losing a later double-click. Back takes priority. */
static inline int inknote_wait_key(TickType_t timeout) {
    const EventBits_t mask = set_bit_button(0) | set_bit_button(7) |
                            set_bit_button(8) | set_bit_button(14) | set_bit_button(22);
    EventBits_t bits = xEventGroupWaitBits(key_groups, mask, pdTRUE, pdFALSE, timeout);
    if (bits & set_bit_button(22)) return 22;
    if (bits & set_bit_button(8)) return 8;
    if (bits & set_bit_button(7)) return 7;
    if (bits & set_bit_button(0)) return 0;
    if (bits & set_bit_button(14)) return 14;
    return -1;
}
