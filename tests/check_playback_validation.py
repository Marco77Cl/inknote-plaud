#!/usr/bin/env python3
"""Compile the production canonical/WAV validation functions on the host."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/inknote-system/main/inknote/playback.cc').read_text()
functions = source[source.index('static unsigned u16('):source.index('/* Append order')]
harness = r'''
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cassert>
#include <sys/types.h>
FUNCTIONS
static void le32(unsigned char *p,uint32_t n) {for(int i=0;i<4;i++)p[i]=n>>(i*8);}
static bool check(unsigned char *h, unsigned actual) {
 FILE *f=tmpfile();assert(f);fwrite(h,1,44,f);
 for(unsigned i=44;i<actual;i++)fputc(0,f);rewind(f);
 unsigned seconds=0;bool ok=validate(f,actual,&seconds);if(ok)assert(seconds==1);
 assert(ftell(f)==0);fclose(f);return ok;
}
int main() {
 assert(canonical("rec_0123abcd.wav"));
 assert(!canonical("rec_0123abcd.part"));assert(!canonical("../rec_0123abcd.wav"));
 assert(!canonical("rec_0123abcg.wav"));assert(!canonical("rec_0123abcd.wav.part"));
 unsigned char h[44]={0};memcpy(h,"RIFF",4);le32(h+4,32036);memcpy(h+8,"WAVEfmt ",8);
 le32(h+16,16);h[20]=1;h[22]=1;le32(h+24,16000);le32(h+28,32000);h[32]=2;h[34]=16;
 memcpy(h+36,"data",4);le32(h+40,32000);
 assert(check(h,32044));assert(!check(h,32042));
 h[22]=2;assert(!check(h,32044));h[22]=1;
 le32(h+24,48000);assert(!check(h,32044));le32(h+24,16000);
 le32(h+40,31999);le32(h+4,32035);assert(!check(h,32043));
 le32(h+40,0);le32(h+4,36);assert(!check(h,44));
 puts("PASS: canonical names, valid PCM16 mono, truncated, stereo, wrong rate, odd data, empty, rewind");
}
'''.replace('FUNCTIONS',functions)
with tempfile.TemporaryDirectory(prefix='inknote-playback-test-') as temp:
    cpp=Path(temp)/'test.cc'; binary=Path(temp)/'test';cpp.write_text(harness)
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(cpp),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
