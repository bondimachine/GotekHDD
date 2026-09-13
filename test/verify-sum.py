#!/usr/bin/env python3
"""Compute the expected DRVTEST checksum for a partition slice of the
HDD image: 16-bit additive byte sum of `count` sectors starting at
partition-relative sector `start` (partition begins at image LBA 63).

usage: verify-sum.py gotekhdd.img start count
"""
import sys

PART_START = 63
img, start, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(img, 'rb') as f:
    f.seek((PART_START + start) * 512)
    data = f.read(count * 512)
assert len(data) == count * 512, 'slice extends past image'
print(f'{sum(data) & 0xFFFF:04X}')
