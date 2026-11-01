#!/usr/bin/env python3
"""Capture device logs without transmitting commands or deliberately resetting it."""
import argparse
from pathlib import Path
import time
import serial

p = argparse.ArgumentParser()
p.add_argument('--port', default='/dev/cu.usbmodem1101')
p.add_argument('--seconds', type=float, default=30)
p.add_argument('--output', required=True)
a = p.parse_args()
s = serial.Serial(port=None, baudrate=115200, timeout=0.2)
s.port = a.port
s.dtr = False
s.rts = False
s.open()
try:
    with Path(a.output).open('xb') as f:
        end = time.monotonic() + a.seconds
        while time.monotonic() < end:
            data = s.read(4096)
            if data:
                f.write(data)
                f.flush()
                print(data.decode('utf-8', errors='replace'), end='', flush=True)
finally:
    s.close()
