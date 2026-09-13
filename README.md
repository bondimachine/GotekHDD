# GotekHDD

A DOS block device driver that turns a floppy-emulator's SD card into a
hard drive.

If your retro PC has a [FlashFloppy](https://github.com/keirf/flashfloppy)
(or HxC) floppy emulator on the floppy bus, `GOTEKHDD.SYS` mounts a
hard-disk image file stored on the emulator's SD card as a DOS drive
letter — over the same 34-pin floppy cable, with no extra hardware. The
floppy keeps working as a floppy: the driver talks to the emulator
through the HxC **Direct Access** protocol, a virtual track at cylinder
255 that no real diskette ever uses, and restores everything between
transfers.

The disk is a standard raw hard-disk image (MBR + one FAT16 partition),
so the *same file* also mounts on a modern machine:

- macOS: `hdiutil attach gotekhdd.img`
- DOSBox: `imgmount c gotekhdd.img -t hdd`
- Linux: `mount -o loop,offset=32256 gotekhdd.img /mnt`

Copy files onto the image on your Mac, put the card back in the Gotek,
and they're on `C:` (or `D:`...) on the retro machine. Sneakernet, but
the sneaker is an SD card.

## Usage

1. Build an image and copy it to the SD card root (FAT-formatted card,
   the same card your disk images live on):

   ```
   python3 tools/mkimage.py GOTEKHDD.IMG --size 32M
   cp GOTEKHDD.IMG /Volumes/YOUR_SD_CARD/
   ```

2. Copy `GOTEKHDD.SYS` to your DOS boot disk and add to `CONFIG.SYS`:

   ```
   DEVICE=GOTEKHDD.SYS
   ```

   Options: `/F=NAME.IMG` (image file name, default `GOTEKHDD.IMG`),
   `/U=1` (emulator is B:), `/V` (verbose).

3. Reboot. The driver reports the new drive letter.

Before first use on a new machine, run `DAPING.COM` (no arguments) to
check that your BIOS can reach the Direct Access track at all, and
`DAPING /B` for a throughput estimate. `DAPING /M` reports which BIOS
fixups your machine needs if the plain probe fails.

Firmware-side requirements: FlashFloppy in Shugart-target firmware with
a FAT-formatted SD card (Direct Access is unavailable on the pico2's
internal littlefs store), and `MAX-CYL` in `FF.CFG` left at its default
of 255 — the escape mechanism is literally a seek to cylinder 255.

### Hardware bring-up order

1. `DAPING` — status probe. Must show the firmware version.
2. `DAPING /M` — note which fixup rows PASS on your BIOS.
3. `DAPING /L 0` — dumps the card's MBR through the DA window.
4. `DAPING /B` — read throughput (each dot is one 4KB window).
5. `DRVTEST` / `DRVTEST /S 0 /N 2048` — full driver logic without
   mounting (compare the checksum with `test/verify-sum.py`).
6. `DEVICE=GOTEKHDD.SYS` in CONFIG.SYS, reboot, `DIR` the new drive.
7. Interleave: `DIR A:` then the new drive again — both must keep
   working.

## Performance

The floppy bus is the bus: 250 kbit/s MFM, 4KB per disk revolution at
300 RPM. Expect roughly 10–15 KB/s reads and 5–8 KB/s writes. It is a
very patient hard drive. It is, however, a real one: `DIR`, `COPY`,
`CHKDSK`, running programs — everything works.

## How it works

FlashFloppy (and HxC) firmware exposes a "Direct Access" mode: seek to
cylinder 255 and a virtual 9-sector MFM track appears. Sector 0 is a
command/status mailbox (signature `HxCFEDA`); after a `SET_LBA` command,
sectors 1–8 read/write through to any LBA of the SD card. See
`FlashFloppy/src/image/da.c` for the authoritative firmware side.

`GOTEKHDD.SYS` at INIT:

1. probes the DA track through BIOS INT 13h (with diskette parameter
   table and BIOS-data-area fixups around every access, so the 250 kbps
   DD transfer works even when the mounted floppy image is HD),
2. finds the card's FAT volume (MBR or superfloppy, FAT16 or FAT32),
   locates the image file in the root directory, and walks its FAT
   cluster chain into a table of up to 32 contiguous extents,
3. reads the image's MBR and its FAT partition's boot sector, and hands
   that BPB to DOS.

At run time, DOS logical sectors map through the partition offset and
the extent table straight to card LBAs; transfers move up to 8 sectors
per `SET_LBA` window and are verified against the firmware's status
counters. All BIOS floppy state is saved/restored around each request,
so A: floppy access between requests behaves normally.

The card's FAT metadata is never written — the driver only touches the
image file's own data clusters (the firmware enforces this too). If the
image file is fragmented across more than 32 extents, INIT refuses and
tells you to re-copy it to the card.

Resident footprint: about 2.6KB.

## Building (host side)

Needs `nasm` and Python 3. `make` builds `DAPING.COM`, `DASTUB.COM` and
`GOTEKHDD.SYS` into `build/`; `make image card` builds test images.

## Testing without hardware

`DASTUB.COM` is an INT 13h TSR that emulates the DA track against a
card image loaded into XMS — enough to run DAPING and the driver under
DOSBox/DOSBox-X/86Box:

```
make all card
sh test/run-dosbox-test.sh test/t1-daping.bat
```

## Files

| file | what |
|---|---|
| `src/gotekhdd.asm` | the driver: device header, dispatch, READ/WRITE |
| `src/da.asm` | Direct Access transaction layer (shared) |
| `src/extent.asm` | image-sector → card-LBA mapping |
| `src/init.asm` | INIT: card FAT walk, extent table, image BPB |
| `src/daping.asm` | hardware diagnostic |
| `test/dastub.asm` | DA track emulator TSR for DOSBox testing |
| `tools/mkimage.py` | image / test-card builder |

## Credits

Protocol by Jean-François Del Nero (HxC) as implemented by Keir Fraser
in FlashFloppy. HxCMount (Atari ST) proved the concept years ago; this
is the PC/DOS counterpart.
