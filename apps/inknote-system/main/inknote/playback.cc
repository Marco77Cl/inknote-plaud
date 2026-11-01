#include "playback.h"
#include "input.h"
#include "ui_render.h"
#include "audio_player.h"
#include "es8311_bsp.h"
#include "epaper_port.h"
#include "driver/gpio.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/task.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *TAG="InkNotePlayback";
struct Entry { char name[17]; time_t modified; unsigned seconds; uint64_t saved_order; unsigned directory_order; };
static std::atomic<bool> completed{false}, unsupported{false};
static void ignore_player_event(audio_player_cb_ctx_t *) {}
static void player_event(audio_player_cb_ctx_t *ctx) {
    if(ctx->audio_event==AUDIO_PLAYER_CALLBACK_EVENT_IDLE) completed.store(true);
    if(ctx->audio_event==AUDIO_PLAYER_CALLBACK_EVENT_UNKNOWN_FILE_TYPE) unsupported.store(true);
}
static unsigned u16(const unsigned char *p) { return p[0]|(unsigned(p[1])<<8); }
static uint32_t u32(const unsigned char *p) { return p[0]|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24); }
static bool canonical(const char *n) {
    if(strlen(n)!=16 || strncmp(n,"rec_",4) || strcmp(n+12,".wav")) return false;
    for(int i=4;i<12;i++) if(!((n[i]>='0'&&n[i]<='9')||(n[i]>='a'&&n[i]<='f'))) return false;
    return true;
}
static bool validate(FILE *f, off_t size, unsigned *seconds) {
    unsigned char h[44];
    bool ok=fread(h,1,sizeof(h),f)==sizeof(h) && !memcmp(h,"RIFF",4) && !memcmp(h+8,"WAVEfmt ",8)
        && u32(h+16)==16 && u16(h+20)==1 && u16(h+22)==1 && u32(h+24)==16000
        && u32(h+28)==32000 && u16(h+32)==2 && u16(h+34)==16 && !memcmp(h+36,"data",4)
        && u32(h+40)>0 && !(u32(h+40)&1) && uint64_t(u32(h+40))+44==uint64_t(size)
        && uint64_t(u32(h+4))+8==uint64_t(size);
    if(ok) *seconds=(u32(h+40)+31999)/32000;
    rewind(f); return ok;
}
/* Append order survives invalid RTC dates and FAT timestamp ties. Blank prefix
 * separates a torn previous append without rewriting any existing records. */
extern "C" void inknote_recording_saved(const char *file) {
    const char *name=strrchr(file,'/'); name=name?name+1:file;
    if(!canonical(name)) return;
    FILE *journal=fopen("/sdcard/recordings/.inknote-order","ab");
    if(!journal) { ESP_LOGW(TAG,"Saved recording, but cannot open order journal"); return; }
    bool ok=fprintf(journal,"\n%s\n",name)>0;
    if(fflush(journal)!=0) ok=false;
    if(fsync(fileno(journal))!=0) ok=false;
    if(fclose(journal)!=0) ok=false;
    if(!ok) ESP_LOGW(TAG,"Saved recording, but order journal sync failed");
}
static void read_order(FILE *journal,Entry *entries,unsigned count) {
    char name[17]; unsigned used=0; bool invalid=false; uint64_t rank=0;
    int ch;
    while((ch=fgetc(journal))!=EOF) {
        if(ch=='\n') {
            name[used]='\0';
            if(!invalid && canonical(name)) {
                ++rank;
                for(unsigned i=0;i<count;i++) if(!strcmp(entries[i].name,name)) entries[i].saved_order=rank;
            }
            used=0; invalid=false;
        } else if(used<16 && ch!=0) name[used++]=(char)ch;
        else invalid=true;
    }
    // An unterminated tail is ignored until the next append separates it.
}
static int compare(const void *a,const void *b) {
    const Entry *x=(const Entry*)a,*y=(const Entry*)b;
    if(x->saved_order!=y->saved_order) return x->saved_order>y->saved_order?-1:1;
    if(x->modified!=y->modified) return x->modified>y->modified?-1:1;
    // Legacy files have no reliable save order. Directory order is only a
    // deterministic fallback; random filenames must not imply chronology.
    if(x->directory_order!=y->directory_order) return x->directory_order>y->directory_order?-1:1;
    return 0;
}
static void order_entries(Entry *entries,unsigned count,const char *preferred_file) {
    if(count) qsort(entries,count,sizeof(Entry),compare);
    if(preferred_file) {
        const char *base=strrchr(preferred_file,'/'); base=base?base+1:preferred_file;
        for(unsigned i=0;i<count;i++) if(!strcmp(entries[i].name,base)) {
            Entry recent=entries[i];
            memmove(entries+1,entries,i*sizeof(Entry)); entries[0]=recent; break;
        }
    }
}
static void show(uint8_t *frame,Entry *entries,unsigned selected,unsigned count,int mode,int volume,int &shown_mode,unsigned &shown_page) {
    unsigned first=(selected/5)*5;
    if(mode==0 && count) {
        const char *files[5]={}; unsigned seconds[5]={};
        for(unsigned row=0;row<5 && first+row<count;row++) {
            files[row]=entries[first+row].name;seconds[row]=entries[first+row].seconds;
        }
        if(shown_mode!=0 || shown_page!=first) {
            // Establish a white cursor baseline, so partial moves cannot reveal
            // a cursor from a previous selection or previous page.
            inknote_list_render(frame,files,seconds,first,UINT32_MAX,count);
            EPD_Init_Fast(); EPD_Display_Fast_Base(frame);
        }
        inknote_list_render(frame,files,seconds,first,selected,count);
        uint8_t cursor[56*16];
        for(int row=0;row<16;row++)memcpy(cursor+row*56,frame+(448+row)*100+27,56);
        EPD_Display_Partial(cursor,216,448,664,464);
    } else {
        inknote_library_render(frame,count?entries[selected].name:"",count?selected+1:0,count,
                              count?entries[selected].seconds:0,mode,volume);
        EPD_Init_Fast(); EPD_Display_Base(frame);
    }
    shown_mode=mode;shown_page=first;
}
/* The vendor player leaves PAUSE unchanged when stopped directly from pause.
 * Resume first so its outer loop reaches IDLE after closing the owned FILE. */
static void stop_owned_playback() {
    if(audio_player_get_state()==AUDIO_PLAYER_STATE_PAUSE) {
        while(audio_player_resume()!=ESP_OK) vTaskDelay(pdMS_TO_TICKS(20));
        while(audio_player_get_state()==AUDIO_PLAYER_STATE_PAUSE) vTaskDelay(pdMS_TO_TICKS(10));
    }
    if(!completed.load()) {
        while(audio_player_stop()!=ESP_OK) vTaskDelay(pdMS_TO_TICKS(20));
        while(!completed.load() && audio_player_get_state()!=AUDIO_PLAYER_STATE_SHUTDOWN)
            vTaskDelay(pdMS_TO_TICKS(10));
    }
}
extern "C" void inknote_playback_page(uint8_t *frame,const char *preferred_file) {
    Entry *entries=nullptr; unsigned count=0,capacity=0,selected=0; int mode=0,volume=90;
    bool failed=false,active=false,dirty=true;
    int shown_mode=-1; unsigned shown_page=UINT32_MAX;
    DIR *directory=opendir("/sdcard/recordings");
    if(!directory) failed=true;
    else {
        struct dirent *de;
        while((de=readdir(directory))) {
            if(!canonical(de->d_name)) continue;
            char path[64]; snprintf(path,sizeof(path),"/sdcard/recordings/%.16s",de->d_name);
            struct stat st; unsigned seconds=0;
            if(stat(path,&st)||!S_ISREG(st.st_mode)) continue;
            FILE *f=fopen(path,"rb"); if(!f) continue;
            bool valid=validate(f,st.st_size,&seconds); fclose(f); if(!valid) continue;
            if(count==capacity) {
                // Fail visibly rather than silently truncate a large library.
                unsigned next=capacity?capacity*2:32;
                if(next>4096) { failed=true; break; }
                void *p=heap_caps_realloc(entries,next*sizeof(Entry),MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
                if(!p) { failed=true; break; } entries=(Entry*)p; capacity=next;
            }
            memcpy(entries[count].name,de->d_name,17);
            entries[count].modified=st.st_mtime; entries[count].seconds=seconds;
            entries[count].saved_order=0; entries[count].directory_order=count; count++;
        }
        closedir(directory);
    }
    FILE *journal=fopen("/sdcard/recordings/.inknote-order","rb");
    if(journal) { read_order(journal,entries,count); fclose(journal); }
    order_entries(entries,count,preferred_file);
    ESP_LOGI(TAG,"ORDER preferred=%s count=%u",preferred_file?preferred_file:"",count);
    for(unsigned i=0;i<count;i++) ESP_LOGI(TAG,"ORDER row=%u file=%s rank=%llu mtime=%lld",i+1,entries[i].name,(unsigned long long)entries[i].saved_order,(long long)entries[i].modified);
    if(audio_player_get_state()!=AUDIO_PLAYER_STATE_IDLE) failed=true;
    if(failed) mode=5; else if(!count) mode=4;
    audio_player_callback_register(player_event,nullptr);
    i2s_channel_disable(rx_handle);
    ESP_LOGI(TAG,"Library opened: %u recordings, mode=%d",count,mode);
    for(;;) {
        if(active && completed.load()) {
            active=false; mode=unsupported.load()?5:3; dirty=true;
            ESP_LOGI(TAG,"Playback ended: %s",entries[selected].name);
        }
        if(dirty) { show(frame,entries,selected,count,mode,volume,shown_mode,shown_page);dirty=false; }
        int key=inknote_wait_key(pdMS_TO_TICKS(50));
        if(key==22||key==8) {
            if(!failed && count && mode!=0) {
                if(active)stop_owned_playback();
                active=false;mode=0;dirty=true;
                esp_codec_dev_set_out_mute(play_dev_handle,true);gpio_set_level(I2S_PA_PIN,0);
                continue;
            }
            break;
        }
        if(failed||!count) continue;
        if(key==0||key==14) {
            if(active) {
                volume+=(key==0?10:-10); if(volume>100)volume=100;if(volume<0)volume=0;
                esp_codec_dev_set_out_vol(play_dev_handle,volume);
            } else { selected=(selected+count+(key==0?-1:1))%count; mode=0; }
            dirty=true;
        } else if(key==7) {
            if(active) {
                esp_err_t err=mode==2?audio_player_resume():audio_player_pause();
                if(err==ESP_OK) {
                    audio_player_state_t wanted=mode==2?AUDIO_PLAYER_STATE_PLAYING:AUDIO_PLAYER_STATE_PAUSE;
                    // Acknowledge the queued transition before accepting Back, so
                    // STOP can never overtake an unprocessed PAUSE request.
                    while(!completed.load() && audio_player_get_state()!=wanted)
                        vTaskDelay(pdMS_TO_TICKS(10));
                    mode=mode==2?1:2;dirty=true;
                }
            } else {
                char path[64];snprintf(path,sizeof(path),"/sdcard/recordings/%s",entries[selected].name);
                FILE *f=fopen(path,"rb"); struct stat st;
                if(!f||stat(path,&st)||!validate(f,st.st_size,&entries[selected].seconds)) {
                    if(f) fclose(f);
                    mode=5;dirty=true;continue;
                }
                completed.store(false);unsupported.store(false);
                esp_codec_dev_set_out_vol(play_dev_handle,volume);gpio_set_level(I2S_PA_PIN,1);
                if(audio_player_play(f)!=ESP_OK) { fclose(f);mode=5; }
                else { active=true;mode=1;ESP_LOGI(TAG,"Playback started: %s",entries[selected].name); }
                dirty=true;
            }
        }
    }
    if(active) stop_owned_playback();
    esp_codec_dev_set_out_mute(play_dev_handle,true);gpio_set_level(I2S_PA_PIN,0);
    // Vendor API rejects nullptr; detach to a no-op with no owned context.
    audio_player_callback_register(ignore_player_event,nullptr);
    heap_caps_free(entries);
    ESP_LOGI(TAG,"Library closed; audio player idle");
}
