#include "sync_transfer.h"
#include "ui_render.h"
#include "esp_http_server.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "esp_random.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "mdns.h"
#include "cJSON.h"
#include "mbedtls/sha256.h"
#include "button_bsp.h"
#include "input.h"
#include "epaper_port.h"
#include <dirent.h>
#include <sys/stat.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cctype>
#include <atomic>
extern uint8_t *Image_Mono;
extern bool wifi_enable;
static const char *TAG="InkSync";
static char pairing[7],token[33];
static unsigned failures;
static int64_t blocked_until;
static uint8_t *io_buffer;
static std::atomic_bool stopping{false};
static esp_err_t error(httpd_req_t *r,const char *status,const char *message) {
    httpd_resp_set_status(r,status);return httpd_resp_send(r,message,HTTPD_RESP_USE_STRLEN);
}
static bool authorized(httpd_req_t *r) {
    char actual[64],expected[64];snprintf(expected,sizeof(expected),"Bearer %s",token);
    return httpd_req_get_hdr_value_str(r,"Authorization",actual,sizeof(actual))==ESP_OK && strcmp(actual,expected)==0;
}
static bool valid_name(const char *s) {
    if(strlen(s)!=16 || strncmp(s,"rec_",4) || strcmp(s+12,".wav")) return false;
    for(int i=4;i<12;i++) if(!isxdigit((unsigned char)s[i])) return false;
    return true;
}
static uint32_t u32(const uint8_t *p) {return p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static bool metadata(const char *name,uint32_t *size) {
    if(!valid_name(name))return false;
    char path[80];snprintf(path,sizeof(path),"/sdcard/recordings/%s",name);
    struct stat st;if(stat(path,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<44 || st.st_size>UINT32_MAX)return false;
    FILE *f=fopen(path,"rb");if(!f)return false;
    uint8_t h[44];bool ok=fread(h,1,44,f)==44;fclose(f);
    ok=ok && !memcmp(h,"RIFF",4) && !memcmp(h+8,"WAVEfmt ",8) && !memcmp(h+36,"data",4)
        && h[20]==1 && h[21]==0 && h[22]==1 && h[23]==0 && u32(h+24)==16000 && h[34]==16 && h[35]==0
        && u32(h+40)==st.st_size-44;
    if(ok) *size=st.st_size;
    return ok;
}
static esp_err_t pair_handler(httpd_req_t *r) {
    if(esp_timer_get_time()<blocked_until)return error(r,"429 Too Many Requests","Wait one minute");
    if(r->content_len<=0 || r->content_len>64)return error(r,"400 Bad Request","Invalid pair request");
    char body[65]={0};int used=0;
    while(used<r->content_len){int n=httpd_req_recv(r,body+used,r->content_len-used);if(n<=0)return ESP_FAIL;used+=n;}
    cJSON *j=cJSON_Parse(body);const cJSON *code=j?cJSON_GetObjectItemCaseSensitive(j,"code"):nullptr;
    bool ok=cJSON_IsString(code) && !strcmp(code->valuestring,pairing);cJSON_Delete(j);
    if(!ok){if(++failures>=5){blocked_until=esp_timer_get_time()+60000000;failures=0;}return error(r,"403 Forbidden","Pairing code incorrect");}
    failures=0;char out[96];snprintf(out,sizeof(out),"{\"token\":\"%s\",\"device\":\"InkNote\",\"api\":1}",token);
    httpd_resp_set_type(r,"application/json");return httpd_resp_send(r,out,HTTPD_RESP_USE_STRLEN);
}
static esp_err_t list_handler(httpd_req_t *r) {
    if(!authorized(r))return error(r,"401 Unauthorized","Pair device first");
    char query[80]={0},value[16]={0};unsigned offset=0;
    if(httpd_req_get_url_query_str(r,query,sizeof(query))==ESP_OK && httpd_query_key_value(query,"offset",value,sizeof(value))==ESP_OK)offset=strtoul(value,nullptr,10);
    DIR *d=opendir("/sdcard/recordings");if(!d)return error(r,"503 Service Unavailable","TF recordings unavailable");
    cJSON *root=cJSON_CreateObject(),*files=cJSON_AddArrayToObject(root,"files");unsigned seen=0,count=0;bool more=false;dirent *e;
    while((e=readdir(d))){uint32_t size;if(!metadata(e->d_name,&size))continue;if(seen++<offset)continue;if(count==64){more=true;break;}
        cJSON *f=cJSON_CreateObject();cJSON_AddStringToObject(f,"name",e->d_name);cJSON_AddNumberToObject(f,"size",size);
        cJSON_AddNumberToObject(f,"duration",(size-44)/32000.0);cJSON_AddItemToArray(files,f);count++;
    }closedir(d);
    if(more)cJSON_AddNumberToObject(root,"next",offset+count);else cJSON_AddNullToObject(root,"next");
    char *out=cJSON_PrintUnformatted(root);cJSON_Delete(root);if(!out)return error(r,"500 Internal Server Error","Memory unavailable");
    httpd_resp_set_type(r,"application/json");esp_err_t result=httpd_resp_send(r,out,HTTPD_RESP_USE_STRLEN);free(out);return result;
}
static esp_err_t file_handler(httpd_req_t *r) {
    if(!authorized(r))return error(r,"401 Unauthorized","Pair device first");
    char query[80],name[24],path[80];uint32_t size;
    if(httpd_req_get_url_query_str(r,query,sizeof(query))!=ESP_OK || httpd_query_key_value(query,"name",name,sizeof(name))!=ESP_OK || !metadata(name,&size))return error(r,"404 Not Found","Completed recording not found");
    snprintf(path,sizeof(path),"/sdcard/recordings/%s",name);FILE *f=fopen(path,"rb");if(!f)return error(r,"503 Service Unavailable","TF read failed");
    mbedtls_sha256_context sha;mbedtls_sha256_init(&sha);mbedtls_sha256_starts(&sha,0);size_t n;unsigned chunks=0;
    while(!stopping.load() && (n=fread(io_buffer,1,4096,f))>0){mbedtls_sha256_update(&sha,io_buffer,n);if(++chunks%16==0)vTaskDelay(1);}
    if(stopping.load()){mbedtls_sha256_free(&sha);fclose(f);return ESP_FAIL;}
    if(ferror(f)){mbedtls_sha256_free(&sha);fclose(f);return error(r,"500 Internal Server Error","TF read failed");}
    uint8_t digest[32];mbedtls_sha256_finish(&sha,digest);mbedtls_sha256_free(&sha);
    char hex[65];for(int i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    uint32_t start=0;char range[64],cr[80];
    if(httpd_req_get_hdr_value_str(r,"Range",range,sizeof(range))==ESP_OK){unsigned parsed;int consumed=0;
        if(sscanf(range,"bytes=%u-%n",&parsed,&consumed)!=1 || consumed==0 || range[consumed] || parsed>=size){fclose(f);return error(r,"416 Range Not Satisfiable","Invalid range");}
        start=parsed;snprintf(cr,sizeof(cr),"bytes %lu-%lu/%lu",(unsigned long)start,(unsigned long)size-1,(unsigned long)size);
        httpd_resp_set_status(r,"206 Partial Content");httpd_resp_set_hdr(r,"Content-Range",cr);
    }
    httpd_resp_set_type(r,"audio/wav");httpd_resp_set_hdr(r,"X-SHA256",hex);httpd_resp_set_hdr(r,"Accept-Ranges","bytes");httpd_resp_set_hdr(r,"Cache-Control","no-store");
    fseek(f,start,SEEK_SET);esp_err_t result=ESP_OK;
    while(!stopping.load() && (n=fread(io_buffer,1,4096,f))>0){if((result=httpd_resp_send_chunk(r,(const char*)io_buffer,n))!=ESP_OK)break;if(++chunks%16==0)vTaskDelay(1);}
    if(stopping.load())result=ESP_FAIL;
    if(ferror(f)) result=ESP_FAIL;
    fclose(f);
    if(result==ESP_OK)result=httpd_resp_send_chunk(r,nullptr,0);
    ESP_LOGI(TAG,"TRANSFER file=%s offset=%lu status=%s",name,(unsigned long)start,esp_err_to_name(result));return result;
}
#include "book_upload.inc"
#include "usb_bridge.inc"

static void transfer_page(bool usb_only) {
    stopping.store(false);
    int screen_status=2;char address[64]={0};
    httpd_handle_t server=nullptr;bool discovery=false;
    wifi_mode_t previous_mode=WIFI_MODE_NULL;
    esp_netif_t *ap=esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    bool created_ap=false,mode_changed=false,owned_wifi=false;
    char ssid[32]={0},password[13]={0};
    uint8_t mac[6],secret[6];esp_read_mac(mac,ESP_MAC_WIFI_STA);esp_fill_random(secret,sizeof(secret));
    snprintf(ssid,sizeof(ssid),"InkNote-%02X%02X",mac[4],mac[5]);
    for(int i=0;i<6;i++)snprintf(password+i*2,3,"%02x",secret[i]);
    esp_err_t network_error=ESP_OK;
    if(!usb_only) {
    network_error=esp_wifi_get_mode(&previous_mode);
    // A disabled network setting deinitializes Wi-Fi at boot. Transfer owns a
    // temporary AP in that case, without enabling or changing saved home Wi-Fi.
    if(network_error==ESP_ERR_WIFI_NOT_INIT) {
        network_error=esp_netif_init();
        if(network_error==ESP_OK) {
            network_error=esp_event_loop_create_default();
            if(network_error==ESP_ERR_INVALID_STATE)network_error=ESP_OK;
        }
        if(network_error==ESP_OK) {
            wifi_init_config_t init=WIFI_INIT_CONFIG_DEFAULT();
            network_error=esp_wifi_init(&init);owned_wifi=network_error==ESP_OK;
        }
        if(network_error==ESP_OK)network_error=esp_wifi_set_storage(WIFI_STORAGE_RAM);
    }
    if(network_error==ESP_OK && (owned_wifi || previous_mode==WIFI_MODE_STA || previous_mode==WIFI_MODE_NULL)) {
        if(!ap){ap=esp_netif_create_default_wifi_ap();created_ap=ap!=nullptr;}
        if(!ap)network_error=ESP_ERR_NO_MEM;
        if(network_error==ESP_OK){network_error=esp_wifi_set_mode(owned_wifi || previous_mode==WIFI_MODE_NULL ? WIFI_MODE_AP : WIFI_MODE_APSTA);mode_changed=network_error==ESP_OK;}
        wifi_config_t cfg={};
        memcpy(cfg.ap.ssid,ssid,strlen(ssid));cfg.ap.ssid_len=strlen(ssid);
        memcpy(cfg.ap.password,password,strlen(password));cfg.ap.authmode=WIFI_AUTH_WPA2_PSK;
        cfg.ap.max_connection=1;cfg.ap.channel=1;
        if(network_error==ESP_OK)network_error=esp_wifi_set_config(WIFI_IF_AP,&cfg);
        if(network_error==ESP_OK)network_error=esp_wifi_start();
    } else if(network_error==ESP_OK)network_error=ESP_ERR_INVALID_STATE;
    } else {
        network_error=esp_netif_init();
        if(network_error==ESP_OK){network_error=esp_event_loop_create_default();if(network_error==ESP_ERR_INVALID_STATE)network_error=ESP_OK;}
    }
    esp_netif_ip_info_t ip={};
    if(!usb_only && network_error==ESP_OK)network_error=esp_netif_get_ip_info(ap,&ip);
    if(network_error!=ESP_OK || (!usb_only && !ip.ip.addr)){
        ESP_LOGE(TAG,"Direct Wi-Fi failed: %s",esp_err_to_name(network_error));
    } else {
        io_buffer=(uint8_t*)heap_caps_malloc(4096,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
        snprintf(pairing,sizeof(pairing),"%06lu",(unsigned long)(esp_random()%1000000));
        uint8_t raw[16];esp_fill_random(raw,16);for(int i=0;i<16;i++)snprintf(token+i*2,3,"%02x",raw[i]);failures=0;blocked_until=0;
        httpd_config_t cfg=HTTPD_DEFAULT_CONFIG();cfg.server_port=8081;cfg.ctrl_port=32769;cfg.stack_size=8192;cfg.max_open_sockets=2;cfg.recv_wait_timeout=5;cfg.send_wait_timeout=5;
        if(io_buffer && httpd_start(&server,&cfg)==ESP_OK){
            httpd_uri_t pair={};pair.uri="/api/pair";pair.method=HTTP_POST;pair.handler=pair_handler;
            httpd_uri_t list={};list.uri="/api/recordings";list.method=HTTP_GET;list.handler=list_handler;
            httpd_uri_t file={};file.uri="/api/file";file.method=HTTP_GET;file.handler=file_handler;
            httpd_uri_t book={};book.uri="/api/books";book.method=HTTP_POST;book.handler=book_upload_handler;
            httpd_register_uri_handler(server,&book);
            httpd_register_uri_handler(server,&pair);httpd_register_uri_handler(server,&list);httpd_register_uri_handler(server,&file);
            if(!usb_only && mdns_init()==ESP_OK){discovery=true;uint8_t mac[6];esp_read_mac(mac,ESP_MAC_WIFI_STA);char host[32];snprintf(host,sizeof(host),"inknote-%02x%02x%02x",mac[3],mac[4],mac[5]);mdns_hostname_set(host);mdns_instance_name_set("InkNote recorder");mdns_service_add(nullptr,"_inknote","_tcp",8081,nullptr,0);}
            snprintf(address,sizeof(address),IPSTR ":8081",IP2STR(&ip.ip));
            screen_status=0;
            if(usb_only && !usb_bridge_start())screen_status=2;
            ESP_LOGI(TAG,"READY address=%s",address);
        }
    }
    if(usb_only) {
        Paint_NewImage(Image_Mono,EPD_WIDTH,EPD_HEIGHT,270,WHITE);Paint_SelectImage(Image_Mono);Paint_Clear(WHITE);
        Paint_DrawString_CN(20,70,"USB 数据线传输",&Font24_UTF8,WHITE,BLACK);
        Paint_DrawString_CN(20,150,screen_status==0?"已就绪，请在 Mac 选择 USB 连接":"USB 启动失败，请返回重试",&Font18_UTF8,WHITE,BLACK);
        Paint_DrawString_CN(20,210,"支持书籍导入、录音下载",&Font18_UTF8,WHITE,BLACK);
        Paint_DrawString_CN(20,270,"无需连接 Wi-Fi 或输入配对码",&Font18_UTF8,WHITE,BLACK);
        Paint_DrawString_CN(20,720,"双击 BOOT / 拨轮退出传输",&Font16_UTF8,WHITE,BLACK);
    } else inknote_transfer_render(Image_Mono,address,pairing,screen_status,ssid,password);
    EPD_Init();EPD_Display_Base(Image_Mono);
    int key;do{key=inknote_wait_key(pdMS_TO_TICKS(100));}while(key!=22 && key!=8);
    ESP_LOGI(TAG,"BACK requested");
    stopping.store(true);
    while(!usb_bridge_done.load())vTaskDelay(pdMS_TO_TICKS(10));
    if(server) httpd_stop(server);
    if(discovery) mdns_free();
    if(owned_wifi) {
        esp_wifi_stop();esp_wifi_deinit();
    } else if(mode_changed) {
        esp_err_t restored=esp_wifi_set_mode(previous_mode);
        if(restored!=ESP_OK)ESP_LOGE(TAG,"Wi-Fi mode restore: %s",esp_err_to_name(restored));
    }
    if(!usb_only && !owned_wifi && mode_changed && !wifi_enable)esp_wifi_stop();
    if(created_ap)esp_netif_destroy_default_wifi(ap);
    free(io_buffer);io_buffer=nullptr;memset(token,0,sizeof(token));
    memset(pairing,0,sizeof(pairing));memset(password,0,sizeof(password));
    xEventGroupClearBits(key_groups,set_bit_all);
    ESP_LOGI(TAG,"STOPPED");
}

void inknote_transfer_page(void){transfer_page(false);}
void inknote_usb_transfer_page(void){transfer_page(true);}
