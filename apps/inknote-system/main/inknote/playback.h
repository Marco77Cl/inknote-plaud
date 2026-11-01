#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void inknote_recording_saved(const char *file);
void inknote_playback_page(uint8_t *frame, const char *preferred_file);
#ifdef __cplusplus
}
#endif
