"""Compile the firmware's actual header writer on macOS and parse its output."""
from pathlib import Path
import subprocess
import tempfile
import wave
import argparse
parser=argparse.ArgumentParser()
parser.add_argument("--source",default="apps/inknote/main/main.c")
a=parser.parse_args()
root = Path(__file__).resolve().parents[1]
s = (root/a.source).read_text()
body = s[s.index('static void le16'):s.index('static esp_err_t mount_card')]
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    src = '#include <stdio.h>\n#include <stdint.h>\n#include <stdbool.h>\n#include <string.h>\n#define RATE 16000\n'+body
    src += '\nint main(int argc,char**argv){FILE*f=fopen(argv[1],"wb"); if(!f||!wav_header(f,32000))return 1; for(int i=0;i<32000;i++)fputc(0,f);return fclose(f);}\n'
    (p/'test.c').write_text(src)
    subprocess.run(['clang',str(p/'test.c'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test'),str(p/'test.wav')],check=True)
    with wave.open(str(p/'test.wav'),'rb') as w:
        assert w.getparams()[:4] == (1,2,16000,16000)
        assert len(w.readframes(16000)) == 32000
print('PASS: actual C firmware header produces mono PCM16 16000 Hz, 16000 frames, 32000 data bytes')
