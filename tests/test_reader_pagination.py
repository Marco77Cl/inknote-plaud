#!/usr/bin/env python3
"""Compile the firmware's actual text pagination with tiny host display stubs."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/inknote-system/main/page_fiction/page_fiction.cc').read_text()
start = source.index('bool read_page_from_file(')
end = source.index('// Render canvas', start)
function = source[start:end]
harness = r'''
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <cassert>
#include <string>
#define SCREEN_WIDTH 480
#define ESP_LOGE(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGI(...) ((void)0)
struct Font { int Width_EN = 9, Width_CH = 18; } font;
struct Context { const char *filepath; const char *encoding = "UTF-8"; int lines_per_page = 38; Font *current_font = &font; } g_display_ctx;
char lines_char[48][256];
'''
harness += function
harness += r'''
int main(int argc, char **argv) {
 g_display_ctx.filepath = argv[1];
 std::string original;
 for (int i=0;i<1800;i++) original += "甲乙丙丁 mixed text。";
 original += "\n尾行";
 FILE *f=fopen(argv[1],"wb"); fwrite(original.data(),1,original.size(),f); fclose(f);
 std::string rebuilt; size_t position=0, end=0; char unused[1]; int pages=0;
 while(read_page_from_file(position,unused,1,&end)) {
   assert(end>position && end<=original.size());
   assert(end==original.size() || ((unsigned char)original[end]&0xc0)!=0x80);
   for (auto& line : lines_char) rebuilt += line;
   position=end; pages++;
 }
 std::string expected=original; expected.erase(std::remove(expected.begin(),expected.end(),'\n'),expected.end());
 assert(rebuilt==expected && pages>5 && position==original.size());
 // A shorter final page must clear all lines left over from the previous page.
 for(auto& line:lines_char) assert(line[0]==0);
 // Font changes restart at the saved byte anchor and never consume an unseen page.
 size_t anchor=300; while(((unsigned char)original[anchor]&0xc0)==0x80) --anchor;
 g_display_ctx.lines_per_page=12; font.Width_CH=36; font.Width_EN=18;
 assert(read_page_from_file(anchor,unused,1,&end));
 assert(std::string(lines_char[0])==original.substr(anchor,strlen(lines_char[0])));
 puts("reader paginator: UTF-8 continuity, small-font bounds, EOF clearing and font anchor PASS");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    cpp = Path(tmp) / 'reader.cc'
    cpp.write_text(harness)
    binary = Path(tmp) / 'reader'
    subprocess.run(['c++', '-std=c++17', '-fsanitize=address,undefined', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(Path(tmp)/'book.txt')], check=True)
