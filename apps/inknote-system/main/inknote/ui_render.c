#include "ui_render.h"
#include "ui_assets/ui_assets.h"
#include <stdio.h>
#include <string.h>
static void pixel(uint8_t *frame, int x, int y, int black) {
    if (x<0 || x>=480 || y<0 || y>=800) return;
    unsigned offset=(479-x)*100+y/8, mask=0x80>>(y%8);
    if (black) frame[offset]&=~mask; else frame[offset]|=mask;
}
static void label(uint8_t *frame, const char *s, int x, int y, int timer) {
    const unsigned char *atlas=timer?ui_timer:ui_small;
    int w=timer?64:16,h=timer?96:28,stride=timer?88:190;
    for (; *s; s++,x+=w) {
        int g=timer?(*s==':'?10:*s-'0'):(unsigned char)*s-32;
        if(g<0 || g>=(timer?11:95)) continue;
        for(int j=0;j<h;j++) for(int i=0;i<w;i++) {
            int sx=g*w+i;
            pixel(frame,x+i,y+j,atlas[j*stride+sx/8]&(0x80>>(sx%8)));
        }
    }
}
void inknote_ui_render(uint8_t *frame, int state, uint32_t bytes, const char *file) {
    if(state<0 || state>4) state=4;
    memset(frame,255,48000);
    const unsigned char *bg=ui_backgrounds[state];
    for(int y=0;y<800;y++) for(int x=0;x<480;x++)
        if(bg[y*60+x/8]&(0x80>>(x%8))) pixel(frame,x,y,1);
    char line[48];
    if(state!=4) {
        unsigned seconds=bytes/32000;
        if(seconds>3600) seconds=3600;
        snprintf(line,sizeof(line),"%02u:%02u",seconds/60,seconds%60);
        label(frame,line,80,291,1);
    }
    if(state>=1 && state<=3) {
        snprintf(line,sizeof(line),"%.26s",file?file:"");
        label(frame,line,32,480,0);
        snprintf(line,sizeof(line),"%.1f %s",bytes>=1048576?bytes/1048576.0:bytes/1024.0,bytes>=1048576?"MB":"KB");
        label(frame,line,32,527,0);
    }
}

void inknote_transfer_render(uint8_t *frame,const char *address,const char *code,int status,const char *ssid,const char *password) {
    memset(frame,255,48000);
    const unsigned char *bg=status==0?ui_sync_0:status==1?ui_sync_1:ui_sync_2;
    for(int y=0;y<800;y++)for(int x=0;x<480;x++)if(bg[y*60+x/8]&(0x80>>(x%8)))pixel(frame,x,y,1);
    if(status==0) { label(frame,ssid,32,267,0);label(frame,password,32,341,0);label(frame,code,48,425,1);label(frame,address,32,589,0); }
}

void inknote_library_render(uint8_t *frame,const char *file,unsigned index,unsigned count,unsigned seconds,int mode,int volume) {
    if(mode<0 || mode>5)mode=5;
    memset(frame,255,48000);
    const unsigned char *bg=ui_playbacks[mode];
    for(int y=0;y<800;y++)for(int x=0;x<480;x++)
        if(bg[y*60+x/8]&(0x80>>(x%8)))pixel(frame,x,y,1);
    if(mode<4) {
        char line[48];
        snprintf(line,sizeof(line),"%02u:%02u",seconds/60,seconds%60);
        label(frame,line,80,291,1);
        label(frame,file?file:"",32,482,0);
        snprintf(line,sizeof(line),"%u / %u",index,count);
        label(frame,line,32,218,0);
        snprintf(line,sizeof(line),"%d%%",volume);
        label(frame,line,100,536,0);
    }
}

void inknote_list_render(uint8_t *frame,const char *const *files,const unsigned *seconds,unsigned first,unsigned selected,unsigned count) {
    memset(frame,255,48000);
    for(int y=0;y<800;y++)for(int x=0;x<480;x++)
        if(ui_library[y*60+x/8]&(0x80>>(x%8)))pixel(frame,x,y,1);
    char line[48];
    snprintf(line,sizeof(line),"%u / %u",first/5+1,(count+4)/5);
    label(frame,line,288,172,0);
    for(unsigned row=0;row<5 && first+row<count;row++) {
        int y=232+row*80;
        label(frame,files[row],48,y,0);
        snprintf(line,sizeof(line),"%02u:%02u",seconds[row]/60,seconds[row]%60);
        label(frame,line,48,y+32,0);
        if(first+row==selected)
            for(int dx=0;dx<12;dx++)for(int dy=dx/2;dy<16-dx/2;dy++)pixel(frame,18+dx,y+dy,1);
    }
}
