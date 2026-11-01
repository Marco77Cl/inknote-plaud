// USB serial transport for the same authenticated HTTP file API.
// Active only on the explicit USB transfer page; no concurrent recording/reading.
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "mbedtls/base64.h"
#include "lwip/sockets.h"
#include <fcntl.h>
static std::atomic_bool usb_bridge_done{true};
static void usb_reply(const char *seq,const char *status,const char *data="") {
    printf("\nINKUSB1 %s %s %s\n",seq,status,data);fflush(stdout);
}
static void usb_bridge_task(void *) {
    int fd=-1;char line[1536];size_t used=0;bool overflow=false;
    uint8_t bytes[1024];char encoded[1370];
    fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK);
    while(!stopping.load()) {
        char c;int got=read(STDIN_FILENO,&c,1);
        if(got<=0){vTaskDelay(pdMS_TO_TICKS(2));continue;}
        if(c=='\r')continue;
        if(c!='\n'){if(used<sizeof(line)-1)line[used++]=c;else overflow=true;continue;}
        line[used]=0;used=0;if(overflow){overflow=false;continue;}
        char *save=nullptr,*magic=strtok_r(line," ",&save),*seq=strtok_r(nullptr," ",&save),*op=strtok_r(nullptr," ",&save),*arg=strtok_r(nullptr," ",&save);
        if(!magic||strcmp(magic,"INKUSB1")||!seq||!op||strlen(seq)>40)continue;
        bool valid=true;for(const char *p=seq;*p;p++)if(!isalnum((unsigned char)*p))valid=false;
        if(!valid)continue;
        if(!strcmp(op,"HELLO")){usb_reply(seq,"OK",token);continue;}
        if(!strcmp(op,"CLOSE")){if(fd>=0)close(fd);fd=-1;usb_reply(seq,"OK");continue;}
        if(!strcmp(op,"OPEN")) {
            if(fd>=0)close(fd);
            fd=socket(AF_INET,SOCK_STREAM,0);
            struct timeval timeout={0,250000};
            if(fd>=0){setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));timeout.tv_sec=2;timeout.tv_usec=0;setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));}
            sockaddr_in address={};address.sin_family=AF_INET;address.sin_port=htons(8081);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
            if(fd<0||connect(fd,(sockaddr*)&address,sizeof(address))!=0){if(fd>=0)close(fd);fd=-1;usb_reply(seq,"ERR","open");}
            else usb_reply(seq,"OK");
            continue;
        }
        if(fd<0){usb_reply(seq,"ERR","closed");continue;}
        if(!strcmp(op,"WRITE")&&arg) {
            size_t length=0;
            if(mbedtls_base64_decode(bytes,sizeof(bytes),&length,(const uint8_t*)arg,strlen(arg))!=0){usb_reply(seq,"ERR","base64");continue;}
            size_t sent=0;while(sent<length&&!stopping.load()){int n=send(fd,bytes+sent,length-sent,0);if(n<=0)break;sent+=n;}
            usb_reply(seq,sent==length?"OK":"ERR",sent==length?"":"write");
        } else if(!strcmp(op,"READ")) {
            int n=recv(fd,bytes,sizeof(bytes),0);
            if(n>0){size_t length=0;mbedtls_base64_encode((uint8_t*)encoded,sizeof(encoded)-1,&length,bytes,n);encoded[length]=0;usb_reply(seq,"DATA",encoded);}
            else if(n==0){usb_reply(seq,"EOF");close(fd);fd=-1;}
            else if(errno==EAGAIN||errno==EWOULDBLOCK)usb_reply(seq,"WAIT");
            else {usb_reply(seq,"ERR","read");close(fd);fd=-1;}
        } else usb_reply(seq,"ERR","command");
    }
    if(fd>=0)close(fd);
    usb_bridge_done.store(true);vTaskDelete(nullptr);
}
static bool usb_bridge_start() {
    if(!usb_serial_jtag_is_driver_installed()) {
        usb_serial_jtag_driver_config_t cfg={};cfg.rx_buffer_size=4096;cfg.tx_buffer_size=4096;
        if(usb_serial_jtag_driver_install(&cfg)!=ESP_OK)return false;
        usb_serial_jtag_vfs_use_driver();
    }
    usb_bridge_done.store(false);
    if(xTaskCreate(usb_bridge_task,"ink_usb",8192,nullptr,4,nullptr)!=pdPASS){usb_bridge_done.store(true);return false;}
    return true;
}
