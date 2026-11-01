#include "ui_render.h"
#include <stdio.h>
#include <stdint.h>
int main(void) {
 uint8_t frame[48000];
 for(int s=0;s<5;s++) {
  inknote_ui_render(frame,s,s?4928000:0,"rec_87a39abd.wav");
  char path[80];snprintf(path,sizeof(path),"design/firmware-ui-%d.pbm",s);
  FILE *f=fopen(path,"wb");if(!f)return 1;
  fprintf(f,"P4\n480 800\n");
  for(int y=0;y<800;y++)for(int bx=0;bx<60;bx++) {
   uint8_t b=0;
   for(int bit=0;bit<8;bit++) {int x=bx*8+bit; if(!(frame[(479-x)*100+y/8]&(0x80>>(y%8))))b|=0x80>>bit;}
   fputc(b,f);
  }
  fclose(f);
 }
 return 0;
}
