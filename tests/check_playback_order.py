#!/usr/bin/env python3
"""Exercise production ordering/parser, including torn journal and legacy ties."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'apps/inknote-system/main/inknote/playback.cc').read_text()
entry=s[s.index('struct Entry {'):s.index('static std::atomic')]
canonical=s[s.index('static bool canonical('):s.index('static bool validate(')]
order=s[s.index('static void read_order('):s.index('static void show(')]
harness=r'''
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <ctime>
#include <cassert>
FUNCTIONS
int main() {
 Entry e[]={ {"rec_ffffffff.wav",1000,1,0,0}, {"rec_00000000.wav",1000,1,0,1},
             {"rec_11111111.wav",1,1,0,2}, {"rec_22222222.wav",1,1,0,3} };
 FILE *f=tmpfile();assert(f);
 fputs("\nrec_11111111.wav\ninvalid\nrec_22222222.wav\nrec_ffffffff.wavEXTRA\nrec_ffffffff.wav",f);rewind(f);
 read_order(f,e,4);fclose(f);order_entries(e,4,nullptr);
 assert(!strcmp(e[0].name,"rec_22222222.wav"));assert(!strcmp(e[1].name,"rec_11111111.wav"));
 assert(!strcmp(e[2].name,"rec_00000000.wav"));assert(!strcmp(e[3].name,"rec_ffffffff.wav"));
 order_entries(e,4,"/sdcard/recordings/rec_ffffffff.wav");
 assert(!strcmp(e[0].name,"rec_ffffffff.wav"));assert(!strcmp(e[1].name,"rec_22222222.wav"));
 f=tmpfile();assert(f);fputs("torn\nrec_11111111.wav\nrec_22222222.wav\nrec_11111111.wav\n",f);rewind(f);
 read_order(f,e,4);fclose(f);order_entries(e,4,nullptr);
 assert(!strcmp(e[0].name,"rec_11111111.wav"));assert(!strcmp(e[1].name,"rec_22222222.wav"));
 order_entries(nullptr,0,nullptr);
 puts("PASS: journal order over timestamps, legacy directory ties, torn/invalid rows, repeated names, preferred first");
}
'''.replace('FUNCTIONS',entry+canonical+order)
with tempfile.TemporaryDirectory(prefix='inknote-order-test-') as d:
    cpp=Path(d)/'test.cc';out=Path(d)/'test';cpp.write_text(harness)
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(cpp),'-o',str(out)],check=True)
    subprocess.run([str(out)],check=True)
