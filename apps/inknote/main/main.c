#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/stream_buffer.h"
#include "driver/gpio.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_random.h"
#include "esp_heap_caps.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"
#include "i2c_bsp.h"
#include "es8311_bsp.h"
#include "epaper_port.h"
#include "power.h"
#include "ui_render.h"

#define RATE 16000
#define RING_BYTES (128 * 1024)
#define MAX_DATA_BYTES (32000U * 60U * 60U) /* split manually after one hour */
#define MIC_GAIN_DB 30.0f
static const char *TAG = "InkNote";
typedef enum { READY, RECORDING, SAVING, COMPLETE, ERROR_STATE } state_t;
static const char *names[] = {"READY", "RECORDING", "SAVING", "COMPLETE", "ERROR"};
typedef struct { state_t state; uint32_t bytes; uint32_t peak; char file[80]; char message[80]; } view_t;
static view_t view;
static portMUX_TYPE view_lock = portMUX_INITIALIZER_UNLOCKED;
static QueueHandle_t display_queue;
static TaskHandle_t recorder_handle;
static StreamBufferHandle_t audio_ring;
static atomic_bool stop_requested, capture_done, capture_failed;
static atomic_uint dma_overflows;
static sdmmc_card_t *card;

static view_t snapshot(void) {
    view_t v;
    portENTER_CRITICAL(&view_lock); v = view; portEXIT_CRITICAL(&view_lock);
    return v;
}
static void publish(state_t state, const char *message) {
    portENTER_CRITICAL(&view_lock);
    view.state = state;
    snprintf(view.message, sizeof(view.message), "%s", message ? message : "");
    view_t v = view;
    portEXIT_CRITICAL(&view_lock);
    ESP_LOGI(TAG, "STATE=%s file=%s bytes=%lu %s", names[state], v.file, (unsigned long)v.bytes, v.message);
    /* State changes are retained in order; progress frames may be skipped. */
    xQueueSend(display_queue, &v, portMAX_DELAY);
}
static void fail(const char *message) { publish(ERROR_STATE, message); }

static void le16(uint8_t *p, uint16_t n) { p[0]=n; p[1]=n>>8; }
static void le32(uint8_t *p, uint32_t n) { p[0]=n; p[1]=n>>8; p[2]=n>>16; p[3]=n>>24; }
static bool wav_header(FILE *f, uint32_t n) {
    uint8_t h[44] = {0};
    memcpy(h,"RIFF",4); le32(h+4,n+36); memcpy(h+8,"WAVEfmt ",8);
    le32(h+16,16); le16(h+20,1); le16(h+22,1); le32(h+24,RATE);
    le32(h+28,RATE*2); le16(h+32,2); le16(h+34,16);
    memcpy(h+36,"data",4); le32(h+40,n);
    return fseek(f,0,SEEK_SET)==0 && fwrite(h,1,sizeof(h),f)==sizeof(h);
}
static esp_err_t mount_card(void) {
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_DEFAULT; /* 20 MHz for first bring-up */
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width=4; slot.clk=16; slot.cmd=17; slot.d0=15; slot.d1=7; slot.d2=8; slot.d3=18;
    slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;
    esp_vfs_fat_sdmmc_mount_config_t cfg = {.format_if_mount_failed=false,.max_files=5,.allocation_unit_size=32768};
    esp_err_t err = esp_vfs_fat_sdmmc_mount("/sdcard", &host, &slot, &cfg, &card);
    if (err != ESP_OK) return err;
    sdmmc_card_print_info(stdout,card);
    if (mkdir("/sdcard/recordings",0755)!=0 && errno!=EEXIST) return ESP_FAIL;
    struct stat st;
    if (stat("/sdcard/recordings",&st)!=0 || !S_ISDIR(st.st_mode)) return ESP_FAIL;
    return ESP_OK;
}
static bool rx_overflow(i2s_chan_handle_t handle, i2s_event_data_t *event, void *ctx) {
    (void)handle; (void)event; (void)ctx;
    atomic_fetch_add(&dma_overflows, 1);
    return false;
}
static esp_err_t configure_audio(void) {
    ESP_ERROR_CHECK(i2s_driver_init());
    esp_err_t err = es8311_codec_init();
    if (err != ESP_OK) return err;
    err = esp_codec_dev_set_in_gain(record_dev_handle, MIC_GAIN_DB);
    if (err != ESP_OK) return err;
    /* Reproduce the verified official recorder's mono LEFT-slot configuration. */
    i2s_std_clk_config_t clk = I2S_STD_CLK_DEFAULT_CONFIG(RATE);
    i2s_std_slot_config_t slot = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,I2S_SLOT_MODE_MONO);
    slot.slot_mask = I2S_STD_SLOT_LEFT;
    ESP_ERROR_CHECK(i2s_channel_disable(rx_handle));
    ESP_ERROR_CHECK(i2s_channel_reconfig_std_clock(rx_handle,&clk));
    ESP_ERROR_CHECK(i2s_channel_reconfig_std_slot(rx_handle,&slot));
    i2s_event_callbacks_t cb = {.on_recv_q_ovf=rx_overflow};
    ESP_ERROR_CHECK(i2s_channel_register_event_callback(rx_handle,&cb,NULL));
    /* RX stays disabled until a recording begins. */
    gpio_set_level(I2S_PA_PIN,0);
    ESP_LOGI(TAG,"Audio configured: 16000 Hz PCM16 mono LEFT, gain=%.0f dB",MIC_GAIN_DB);
    return ESP_OK;
}
static void capture_task(void *arg) {
    (void)arg;
    int16_t samples[1024];
    while (!atomic_load(&stop_requested)) {
        size_t n=0;
        esp_err_t err=i2s_channel_read(rx_handle,samples,sizeof(samples),&n,200);
        if (err!=ESP_OK || !n || (n&1) || atomic_load(&dma_overflows)) {
            ESP_LOGE(TAG,"Capture error=%s n=%u dma_overflow=%u",esp_err_to_name(err),(unsigned)n,atomic_load(&dma_overflows));
            atomic_store(&capture_failed,true); break;
        }
        if (xStreamBufferSend(audio_ring,samples,n,0)!=n) {
            ESP_LOGE(TAG,"Audio ring overflow; recording will not report COMPLETE");
            atomic_store(&capture_failed,true); break;
        }
    }
    i2s_channel_disable(rx_handle);
    atomic_store(&capture_done,true);
    vTaskDelete(NULL);
}
static FILE *create_recording(char *temp, size_t temp_size, char *final, size_t final_size) {
    for (int i=0;i<32;i++) {
        uint32_t id=esp_random();
        snprintf(final,final_size,"/sdcard/recordings/rec_%08lx.wav",(unsigned long)id);
        snprintf(temp,temp_size,"/sdcard/recordings/rec_%08lx.part",(unsigned long)id);
        struct stat st;
        if (stat(final,&st)==0) continue;
        int fd=open(temp,O_CREAT|O_EXCL|O_WRONLY,0644);
        if (fd<0) { if (errno==EEXIST) continue; return NULL; }
        FILE *f=fdopen(fd,"wb");
        if (!f) close(fd);
        return f;
    }
    return NULL;
}
static void recorder_task(void *arg) {
    (void)arg;
    uint8_t buffer[8192];
    for (;;) {
        ulTaskNotifyTake(pdTRUE,portMAX_DELAY);
        char temp[128],final[128];
        FILE *f=create_recording(temp,sizeof(temp),final,sizeof(final));
        if (!f) { fail("Cannot create file / card full?"); continue; }
        portENTER_CRITICAL(&view_lock);
        snprintf(view.file,sizeof(view.file),"%s",strrchr(final,'/')+1);
        view.bytes=0; view.peak=0;
        portEXIT_CRITICAL(&view_lock);
        if (!wav_header(f,0)) { fclose(f); fail("Header write failed; .part kept"); continue; }
        xStreamBufferReset(audio_ring);
        atomic_store(&capture_done,false); atomic_store(&capture_failed,false);
        atomic_store(&dma_overflows,0);
        if (i2s_channel_enable(rx_handle)!=ESP_OK) { fclose(f); fail("Cannot start audio"); continue; }
        if (xTaskCreatePinnedToCore(capture_task,"capture",6144,NULL,8,NULL,1)!=pdPASS) {
            i2s_channel_disable(rx_handle); fclose(f); fail("Capture task allocation failed"); continue;
        }
        publish(RECORDING,"Press dial or BOOT to stop");
        uint32_t bytes=0,peak=0,clipped=0;
        uint64_t sumsq=0;
        bool write_ok=true;
        int64_t last_frame=esp_timer_get_time();
        for (;;) {
            size_t n=xStreamBufferReceive(audio_ring,buffer,sizeof(buffer),pdMS_TO_TICKS(100));
            if (n) {
                if (write_ok) {
                    size_t written=fwrite(buffer,1,n,f);
                    if (written!=n) { write_ok=false; atomic_store(&stop_requested,true); }
                    bytes+=written;
                    for (size_t j=0;j+1<written;j+=2) {
                        int32_t x=(int16_t)((uint16_t)buffer[j]|((uint16_t)buffer[j+1]<<8));
                        uint32_t a=x<0?-x:x;
                        if (a>peak) peak=a;
                        if (a>=32760) clipped++;
                        sumsq+=(int64_t)x*x;
                    }
                    portENTER_CRITICAL(&view_lock); view.bytes=bytes; view.peak=peak; portEXIT_CRITICAL(&view_lock);
                    if (bytes>=MAX_DATA_BYTES) atomic_store(&stop_requested,true);
                }
            }
            if (esp_timer_get_time()-last_frame>10000000) {
                last_frame=esp_timer_get_time();
                ESP_LOGI(TAG,"RECORDING bytes=%lu peak=%lu",(unsigned long)bytes,(unsigned long)peak);
            }
            if (atomic_load(&capture_done) && xStreamBufferBytesAvailable(audio_ring)==0) break;
        }
        publish(SAVING,"Finalizing WAV; keep power on");
        bool header_ok=wav_header(f,bytes);
        bool flush_ok=fflush(f)==0;
        bool sync_ok=fsync(fileno(f))==0;
        bool close_ok=fclose(f)==0;
        bool ok=write_ok && !atomic_load(&capture_failed) && !atomic_load(&dma_overflows) && bytes>0 && !(bytes&1) && header_ok && flush_ok && sync_ok && close_ok;
        if (ok && rename(temp,final)!=0) ok=false;
        if (ok) {
            struct stat st;
            ok=stat(final,&st)==0 && st.st_size==(off_t)(bytes+44);
        }
        double rms=bytes?sqrt((double)sumsq/(bytes/2)):0;
        ESP_LOGI(TAG,"RESULT ok=%d bytes=%lu seconds=%.3f peak=%lu rms=%.2f clipped=%lu gain=%.0f",ok,(unsigned long)bytes,bytes/32000.0,(unsigned long)peak,rms,(unsigned long)clipped,MIC_GAIN_DB);
        if (ok) publish(COMPLETE,clipped?"Saved; clipping detected":"Saved. Press dial for next note");
        else fail("Recording failed; inspect .part/WAV");
    }
}
static void display_task(void *arg) {
    (void)arg;
    uint8_t *frame=heap_caps_malloc(EPD_SIZE_MONO,MALLOC_CAP_SPIRAM);
    if (!frame) { ESP_LOGE(TAG,"Display allocation failed"); vTaskDelete(NULL); return; }
    epaper_port_init();
    /* Progress is sampled here, never queued behind slow panel refreshes. */
    uint8_t *region=heap_caps_malloc(34*416,MALLOC_CAP_SPIRAM);
    if (!region) { free(frame); ESP_LOGE(TAG,"Partial buffer allocation failed"); vTaskDelete(NULL); return; }
    view_t v;
    int shown=-1;
    uint32_t shown_second=UINT32_MAX;
    for (;;) {
        bool transition=xQueueReceive(display_queue,&v,pdMS_TO_TICKS(100))==pdTRUE;
        if (!transition) {
            v=snapshot();
            if (v.state!=RECORDING || shown!=RECORDING || v.bytes/32000==shown_second) continue;
        }
        inknote_ui_render(frame,v.state,v.bytes,v.file);
        int64_t started=esp_timer_get_time();
        bool quick_start=transition && v.state==RECORDING && (shown==READY || shown==COMPLETE);
        if (quick_start) {
            /* Cross-page changes require a full waveform to establish the base. */
            EPD_Init_Fast(); EPD_Display_Fast_Base(frame);
        } else if (!transition) {
            /* Portrait x32..448,y288..560 -> controller x288..560,y32..448. */
            for(int row=0;row<416;row++) memcpy(region+row*34,frame+(row+32)*100+36,34);
            EPD_Display_Partial(region,288,32,560,448);
        } else {
            EPD_Init_Fast(); EPD_Display_Base(frame);
            /* READY/COMPLETE retain the base image for the next quick start. */
            if(v.state==SAVING || v.state==ERROR_STATE) EPD_Sleep();
        }
        shown=v.state; shown_second=v.bytes/32000;
        ESP_LOGI(TAG,"DISPLAY=%s seconds=%lu refresh=%s ms=%lld",names[v.state],(unsigned long)shown_second,
                 quick_start?"start-fast-base":transition?"full":"partial",(long long)((esp_timer_get_time()-started)/1000));
    }
}
static void command(const char *cmd) {
    state_t s=snapshot().state;
    if (!strcmp(cmd,"status")) { view_t v=snapshot(); ESP_LOGI(TAG,"STATUS=%s file=%s bytes=%lu",names[v.state],v.file,(unsigned long)v.bytes); }
    else if (!strcmp(cmd,"stop") || (!strcmp(cmd,"toggle") && s==RECORDING)) atomic_store(&stop_requested,true);
    else if ((!strcmp(cmd,"start") || !strcmp(cmd,"toggle")) && (s==READY || s==COMPLETE)) {
        atomic_store(&stop_requested,false);
        portENTER_CRITICAL(&view_lock); view.state=RECORDING; portEXIT_CRITICAL(&view_lock);
        xTaskNotifyGive(recorder_handle);
    }
}
static void controls_task(void *arg) {
    (void)arg;
    int pins[]={5,0}; int stable[]={1,1},last[]={1,1},count[]={0,0};
    gpio_config_t cfg={.pin_bit_mask=(1ULL<<5)|(1ULL<<0),.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE};
    gpio_config(&cfg);
    char line[32]; unsigned len=0;
    for (;;) {
        for (int i=0;i<2;i++) {
            int v=gpio_get_level(pins[i]);
            if (v==last[i]) count[i]++; else count[i]=0;
            last[i]=v;
            if (count[i]>=3) { count[i]=3; if (v!=stable[i]) { stable[i]=v; if (!v) command(i==0?"toggle":"stop"); } }
        }
        uint8_t c;
        while (usb_serial_jtag_read_bytes(&c,1,0)>0) {
            if (c=='\r'||c=='\n') { line[len]=0; if(len) command(line); len=0; }
            else if(len<sizeof(line)-1) line[len++]=c;
            else len=0;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
void app_main(void) {
    ESP_LOGI(TAG,"InkNote bring-up v0.1; no AI; no card formatting");
    i2c_master_init();
    if (inknote_screen_power_init()!=ESP_OK) { ESP_LOGE(TAG,"Screen supply initialization failed"); return; }
    display_queue=xQueueCreate(8,sizeof(view_t));
    audio_ring=xStreamBufferCreate(RING_BYTES,1);
    if (!display_queue || !audio_ring) { ESP_LOGE(TAG,"Memory allocation failed"); return; }
    if(xTaskCreatePinnedToCore(display_task,"display",8192,NULL,2,NULL,0)!=pdPASS) { ESP_LOGE(TAG,"Display task failed"); return; }
    esp_err_t err=mount_card();
    if(err!=ESP_OK) { fail("TF mount failed; no format attempted"); return; }
    err=configure_audio();
    if(err!=ESP_OK) { fail("Audio initialization failed"); return; }
    usb_serial_jtag_driver_config_t usb=USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    if(usb_serial_jtag_driver_install(&usb)!=ESP_OK) { fail("USB console init failed"); return; }
    if(xTaskCreatePinnedToCore(recorder_task,"recorder",16384,NULL,5,&recorder_handle,1)!=pdPASS) { fail("Recorder task failed"); return; }
    publish(READY,"Press dial to record");
    if(xTaskCreate(controls_task,"controls",4096,NULL,4,NULL)!=pdPASS) fail("Controls task failed");
}
