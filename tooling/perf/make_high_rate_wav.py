#!/usr/bin/env python3
"""Deterministic 192 kHz / 24-bit stereo throughput fixture (9.216 Mbit/s)."""
import argparse
import random
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output')
parser.add_argument('--seconds', type=int, default=40)
args = parser.parse_args()
rng = random.Random(12345)
# Low-amplitude noise, repeated each second. Keep fixture generation bounded.
second = b''.join(rng.randrange(-32768, 32768).to_bytes(3, 'little', signed=True)
                  for _ in range(192000 * 2))
with wave.open(args.output, 'wb') as output:
    output.setparams((2, 3, 192000, 0, 'NONE', 'not compressed'))
    for _ in range(args.seconds):
        output.writeframesraw(second)
