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
   `/U=1` (emulator is B:), `/V` (verbose), `/N=n` (sectors per DA
   transaction, default 32, max 64 — see Performance).

3. Reboot. The driver reports the new drive letter.

Before first use on a new machine, run `DAPING.COM` (no arguments) to
check that your BIOS can reach the Direct Access track at all, and
`DAPING /B` for a throughput estimate. `DAPING /M` reports which BIOS
fixups your machine needs if the plain probe fails.

Firmware-side requirements: FlashFloppy in Shugart-target firmware with
a FAT16/FAT32 SD card (Direct Access is unavailable on the pico2's
internal littlefs store), and `MAX-CYL` in `FF.CFG` left at its default
of 255 — the escape mechanism is literally a seek to cylinder 255.

### 8088/XT machines

Everything is assembled for the 8086/8088 instruction set (NASM
`cpu 8086`) and the test suite runs on DOSBox-X's emulated 8086. The
driver reads the BIOS model byte at F000:FFFE: on PC/XT-class machines
it applies only the diskette-parameter-table fixup, since the AT
diskette-state bytes (40:8B data rate, 40:90 media state) don't exist
pre-AT and the XT floppy adapter is 250kbps-only anyway. Override with
`/A` (force full AT fixups) or `/X` (force XT set) on the DEVICE line
if the auto-detection guesses wrong on your clone BIOS.

DASTUB (the test-only DA emulator) uses XMS when available and falls
back to DOS file I/O without it, so the test suite also runs on
8088-class configurations — file mode is only safe under DAPING and
DRVTEST, not with a DOS-mounted GotekHDD drive.

### Hardware bring-up order

1. `DAPING` — status probe. Must show the firmware version.
2. `DAPING /M` — note which fixup rows PASS on your BIOS.
3. `DAPING /L 0` — dumps the card's MBR through the DA window.
4. `DAPING /B` — read throughput (each dot is one window). Try
   `/B /N=48` etc. to find the largest window your BIOS transfers
   without erroring, then pass the same `/N` to the driver.
5. `DAPING /T /W` — millisecond timing of every INT 13h step in a DA
   window (command write, status reads, 8-sector read and write), 16
   iterations on one card LBA, plus retry and verification counters.
   `/W` writes back the very bytes just read, so it is safe; without
   it only the read-side steps run. The DA track is window+1 sectors
   of ~22 ms, so a revolution is ~200 ms at `/N=8` and ~700 ms at
   `/N=32`; a step costing a revolution more than its sectors need
   waited a full turn. That is normal for the status-read steps, which
   wait for sector 0 to come round, and for step 1 when it follows one.
   Steps 8 and 10 are the driver's actual read and write transfers and
   the two `driver ... window` lines at the end are what the driver
   would see; the status-read steps are turnaround diagnostics. Add
   `/N=n` to time the window the driver will use, and `/1` to disable
   retries so a failure reports its first error code and duration
   instead of the aftermath of a recalibrate.
6. `DRVTEST` / `DRVTEST /S 0 /N 2048` — full driver logic without
   mounting (compare the checksum with `test/verify-sum.py`).
7. `DEVICE=GOTEKHDD.SYS` in CONFIG.SYS, reboot, `DIR` the new drive.
8. Interleave: `DIR A:` then the new drive again — both must keep
   working.

## Performance

The floppy bus is the bus: 250 kbit/s MFM. The cost of a transfer is
dominated by a fixed per-transaction toll — one `SET_LBA` command plus
the rotational wait for the window to come round — so the driver
amortises it over a large window instead of paying it every 8 sectors.

`SET_LBA` carries the window size, and the firmware sizes the virtual DA
track to match (up to the whole request in one continuous read), so a
32-sector window pays the toll once per 16KB. The window is `/N=n`,
default 32, max 64. Bigger is faster up to a point; the ceiling is the
PC diskette BIOS's own operation timeout on a single multi-sector INT
13h call, which is why the default is conservative. Tune it on your
machine with `DAPING /B /N=48` and `DAPING /T /W /N=48`, then set the
same `/N` on the `DEVICE=` line. For reference, HxCMount (the Atari
equivalent, banging the FDC directly) reaches ~20 KB/s reads and ~13
KB/s writes at large windows; through the PC BIOS expect somewhat less.

There is no status-sector readback per transfer: one command, one
multi-sector transfer, done. INT 13h still reports FDC-level errors and
the driver retries them; `DAPING /T /W` is the write-integrity check to
run during bring-up.

Writes depend on the firmware. Stock FlashFloppy writes each DA sector
to storage as it arrives; on an SD card over SPI the card's busy time
after each single-block write stalls the track and the FDC loses a full
revolution per sector, so writes crawl at ~2 KB/s whatever the window.
The pico2 port buffers the window in RAM and flushes it as one
multi-block write (see its `RP2350.md`), so writes run at the same bus
speed as reads there. It is a real hard drive: `DIR`, `COPY`, `CHKDSK`,
running programs — everything works.

## How it works

FlashFloppy (and HxC) firmware exposes a "Direct Access" mode: seek to
cylinder 255 and a virtual MFM track appears. Sector 0 is a
command/status mailbox (signature `HxCFEDA`); after a `SET_LBA` command,
the data sectors 1..N (N chosen by the command, default 8) read/write
through to consecutive LBAs of the SD card. See
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
the extent table straight to card LBAs; transfers move up to `/N`
sectors per `SET_LBA` window (the command carries the window size and
the firmware sizes the DA track to it, re-establishing the track after
the command write — standard FlashFloppy/HxC behaviour, no firmware
change). All BIOS floppy state is saved/restored around each request,
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
