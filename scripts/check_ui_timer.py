"""Short device UI acceptance: command recording, capture all timing logs."""
import time
import argparse
from pathlib import Path
import serial
parser=argparse.ArgumentParser()
parser.add_argument('--output',required=True)
parser.add_argument('--repeat',action='store_true')
a=parser.parse_args()
s=serial.Serial(port=None,baudrate=115200,timeout=.1)
s.port='/dev/cu.usbmodem1101';s.dtr=False;s.rts=False;s.open()
t=time.monotonic();started=stopped=False
second_started=second_stopped=False
with Path(a.output).open('xb') as f:
 while time.monotonic()-t<(55 if a.repeat else 45):
  elapsed=time.monotonic()-t
  if elapsed>=8 and not started:s.write(b'start\n');started=True
  if elapsed>=23 and not stopped:s.write(b'stop\n');stopped=True
  if a.repeat and elapsed>=34 and not second_started:s.write(b'start\n');second_started=True
  if a.repeat and elapsed>=40 and not second_stopped:s.write(b'stop\n');second_stopped=True
  b=s.read(4096)
  if b:f.write(b);f.flush();print(b.decode(errors='replace'),end='',flush=True)
s.close()
