#pragma once
#include <stdint.h>
/* 800x480 packed controller frame, portrait logical coordinates 480x800. */
void inknote_ui_render(uint8_t *frame, int state, uint32_t bytes, const char *file);

#ifdef __cplusplus
extern "C" {
#endif
void inknote_transfer_render(uint8_t *frame, const char *address, const char *code, int status, const char *ssid, const char *password);
void inknote_library_render(uint8_t *frame,const char *file,unsigned index,unsigned count,unsigned seconds,int mode,int volume);
void inknote_list_render(uint8_t *frame,const char *const *files,const unsigned *seconds,unsigned first,unsigned selected,unsigned count);
#ifdef __cplusplus
}
#endif
