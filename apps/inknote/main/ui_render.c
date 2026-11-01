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
