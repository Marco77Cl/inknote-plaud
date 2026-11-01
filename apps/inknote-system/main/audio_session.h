#pragma once
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#ifdef __cplusplus
extern "C" {
#endif
extern SemaphoreHandle_t audio_session_mutex;
#ifdef __cplusplus
}
#endif
