#!/usr/bin/env python3
"""
mkimage.py - build disk images for GotekHDD.

Two modes:

  HDD image (the file GOTEKHDD.SYS mounts):
      python3 mkimage.py gotekhdd.img --size 32M

    A standard raw hard-disk image: MBR at LBA 0 with one primary FAT16
    partition starting at LBA 63 (classic 16 heads x 63 sectors/track
    geometry), FAT16 volume inside. Mounts unmodified with
    `hdiutil attach gotekhdd.img` on macOS and
    `imgmount c gotekhdd.img -t hdd` in DOSBox.

  Test SD-card image (for the DASTUB.COM emulator harness):
      python3 mkimage.py card.img --card --image gotekhdd.img --fragments 4

    A FAT16 SD-card-style image (MBR + partition) containing the given
    HDD image as GOTEKHDD.IMG in the root directory, optionally split
    into N cluster extents to exercise the driver's FAT-chain walker.

Everything is deterministic: no timestamps, no randomness.
"""

import argparse
import struct
import sys

SEC = 512
HEADS = 16
SPT = 63
PART_START = 63           # LBA of the partition (= SPT, track-aligned)
DOS_DATE = (2026 - 1980) << 9 | (1 << 5) | 1   # 2026-01-01
DOS_TIME = 12 << 11                             # 12:00:00


def chs(lba):
    """LBA -> MBR-style CHS tuple bytes (head, sec|cyl_hi, cyl_lo)."""
    c, r = divmod(lba, HEADS * SPT)
    h, s = divmod(r, SPT)
    s += 1
    if c > 1023:
        c, h, s = 1023, 254, 63
    return bytes((h, ((c >> 2) & 0xC0) | s, c & 0xFF))


def make_mbr(part_start, part_sectors, ptype):
    mbr = bytearray(SEC)
    e = 0x1BE
    mbr[e] = 0x80                                   # active
    mbr[e+1:e+4] = chs(part_start)
    mbr[e+4] = ptype
    mbr[e+5:e+8] = chs(part_start + part_sectors - 1)
    mbr[e+8:e+12] = struct.pack('<I', part_start)
    mbr[e+12:e+16] = struct.pack('<I', part_sectors)
    mbr[510:512] = b'\x55\xAA'
    return mbr


class Fat16Volume:
    """Minimal deterministic FAT16 volume builder."""

    def __init__(self, total_sectors, hidden, label=b'GOTEKHDD   '):
        self.total = total_sectors
        self.hidden = hidden
        self.reserved = 1
        self.nfats = 2
        self.root_entries = 512
        self.root_secs = self.root_entries * 32 // SEC

        # Pick sectors/cluster so the cluster count lands in FAT16
        # territory (4085..65524).
        for spc in (1, 2, 4, 8, 16, 32, 64, 128):
            # Estimate FAT size with this spc, then check cluster count.
            fatsz = 1
            while True:
                data = self.total - self.reserved - self.nfats*fatsz \
                    - self.root_secs
                clusters = data // spc
                need = ((clusters + 2) * 2 + SEC - 1) // SEC
                if need <= fatsz:
                    break
                fatsz = need
            if clusters < 4085:
                continue
            if clusters <= 65524:
                self.spc, self.fatsz, self.clusters = spc, fatsz, clusters
                break
        else:
            raise SystemExit('volume too large for FAT16')
        if self.clusters < 4085:
            raise SystemExit('volume too small for FAT16 (min ~4MB)')

        self.label = label
        self.fat = [0] * (self.clusters + 2)
        self.fat[0] = 0xFFF8
        self.fat[1] = 0xFFFF
        self.rootdir = []          # list of 32-byte entries
        self.data = {}             # cluster -> 512*spc bytes
        self.next_free = 2

    @property
    def data_start(self):
        return self.reserved + self.nfats * self.fatsz + self.root_secs

    def cluster_lba(self, n):
        return self.data_start + (n - 2) * self.spc

    def alloc(self, nclusters, at=None):
        """Allocate a contiguous run; returns list of cluster numbers."""
        start = at if at is not None else self.next_free
        run = list(range(start, start + nclusters))
        if run[-1] >= self.clusters + 2:
            raise SystemExit('image does not fit in the card volume')
        for c in run:
            if self.fat[c] != 0:
                raise SystemExit(f'cluster {c} already allocated')
            self.fat[c] = 1  # placeholder, chained below
        self.next_free = max(self.next_free, run[-1] + 1)
        return run

    def add_file(self, name83, content, runs=1):
        """Add a file, split into `runs` cluster extents separated by
        one-cluster gap files."""
        csize = self.spc * SEC
        nclusters = max(1, (len(content) + csize - 1) // csize)
        per = (nclusters + runs - 1) // runs
        chain = []
        nfrag = 0
        for i in range(0, nclusters, per):
            n = min(per, nclusters - i)
            chain += self.alloc(n)
            if i + n < nclusters:      # gap cluster owned by a filler file
                gap = self.alloc(1)
                nfrag += 1
                self._add_dirent(f'FRAG{nfrag:04d}.TMP', gap[0], csize)
                self.data[gap[0]] = b'\xF6' * csize
                self.fat[gap[0]] = 0xFFFF
        for a, b in zip(chain, chain[1:]):
            self.fat[a] = b
        self.fat[chain[-1]] = 0xFFFF
        for i, c in enumerate(chain):
            self.data[c] = content[i*csize:(i+1)*csize].ljust(csize, b'\0')
        self._add_dirent(name83, chain[0], len(content))
        return chain

    def _add_dirent(self, name11, cluster, size, attr=0x20):
        if '.' in name11:
            base, ext = name11.split('.')
            name11 = base.ljust(8)[:8] + ext.ljust(3)[:3]
        else:
            name11 = name11.ljust(11)[:11]
        ent = struct.pack('<11sB10xHHHI', name11.upper().encode(), attr,
                          DOS_TIME, DOS_DATE, cluster, size)
        assert len(ent) == 32
        self.rootdir.append(ent)

    def vbr(self):
        bpb = struct.pack(
            '<3s8sHBHBHHBHHHII',
            b'\xEB\x3C\x90', b'GOTEKHDD',
            SEC, self.spc, self.reserved, self.nfats, self.root_entries,
            self.total if self.total < 0x10000 else 0,
            0xF8, self.fatsz, SPT, HEADS, self.hidden,
            self.total if self.total >= 0x10000 else 0)
        ext = struct.pack('<BBBI11s8s', 0x80, 0, 0x29, 0x600D0D15,
                          self.label, b'FAT16   ')
        sec = bytearray(SEC)
        sec[:len(bpb)] = bpb
        sec[0x24:0x24+len(ext)] = ext
        sec[510:512] = b'\x55\xAA'
        return bytes(sec)

    def render(self):
        img = bytearray(self.total * SEC)
        img[0:SEC] = self.vbr()
        fat = bytearray(self.fatsz * SEC)
        for i, v in enumerate(self.fat):
            fat[i*2:i*2+2] = struct.pack('<H', v)
        for n in range(self.nfats):
            off = (self.reserved + n * self.fatsz) * SEC
            img[off:off+len(fat)] = fat
        roff = (self.reserved + self.nfats * self.fatsz) * SEC
        img[roff:roff+32*len(self.rootdir)] = b''.join(self.rootdir)
        for c, blob in self.data.items():
            off = self.cluster_lba(c) * SEC
            img[off:off+len(blob)] = blob
        return bytes(img)


def parse_size(s):
    mult = 1
    s = s.upper()
    if s.endswith('M'):
        mult, s = 1024*1024, s[:-1]
    elif s.endswith('K'):
        mult, s = 1024, s[:-1]
    return int(s) * mult


def build_hdd(path, size):
    total = size // SEC
    # Round down to whole cylinders so CHS geometry is consistent.
    cyl_secs = HEADS * SPT
    total = max(total // cyl_secs, 2) * cyl_secs
    part_secs = total - PART_START
    vol = Fat16Volume(part_secs, hidden=PART_START)
    ptype = 0x06 if part_secs >= 65536 else 0x04
    img = make_mbr(PART_START, part_secs, ptype) \
        + b'\0' * ((PART_START - 1) * SEC) + vol.render()
    assert len(img) == total * SEC
    with open(path, 'wb') as f:
        f.write(img)
    print(f'{path}: {total*SEC//1024//1024}MB, partition type '
          f'{ptype:#04x} at LBA {PART_START}, {part_secs} sectors, '
          f'FAT16 {vol.spc} sec/cluster, {vol.clusters} clusters')


def build_card(path, image_path, fragments, size):
    with open(image_path, 'rb') as f:
        content = f.read()
    total = size // SEC
    part_secs = total - PART_START
    vol = Fat16Volume(part_secs, hidden=PART_START)
    vol.add_file('GOTEKHDD.IMG', content, runs=fragments)
    img = make_mbr(PART_START, part_secs, 0x06) \
        + b'\0' * ((PART_START - 1) * SEC) + vol.render()
    with open(path, 'wb') as f:
        f.write(img)
    print(f'{path}: card image {total*SEC//1024//1024}MB containing '
          f'GOTEKHDD.IMG ({len(content)} bytes) in {fragments} extent(s)')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('output')
    ap.add_argument('--size', default='32M',
                    help='image size (default 32M)')
    ap.add_argument('--card', action='store_true',
                    help='build a test SD-card image instead')
    ap.add_argument('--image', default='gotekhdd.img',
                    help='HDD image to embed (card mode)')
    ap.add_argument('--fragments', type=int, default=1,
                    help='split the embedded image into N extents')
    a = ap.parse_args()
    if a.card:
        import os
        need = os.path.getsize(a.image) + (8 << 20)
        build_card(a.output, a.image, a.fragments,
                   max(parse_size(a.size), need))
    else:
        build_hdd(a.output, parse_size(a.size))


if __name__ == '__main__':
    main()
