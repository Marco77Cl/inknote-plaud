#pragma once
#include <stdint.h>
/* 800x480 packed controller frame, portrait logical coordinates 480x800. */
void inknote_ui_render(uint8_t *frame, int state, uint32_t bytes, const char *file);
