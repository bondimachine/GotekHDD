; structs.inc - shared equates and structure offsets for GotekHDD.
;
; Direct Access (DA) protocol per FlashFloppy src/image/da.c (which is
; HxC-compatible): a virtual MFM DD track at cylinder 255 head 0 with
; 512-byte sectors whose IDs are 0..8. Sector 0 read = status, sector 0
; write = command, sectors 1..8 = card LBA window after CMD_SET_LBA.

%ifndef STRUCTS_INC
%define STRUCTS_INC

DA_CYL          equ 255         ; MFM DD direct-access cylinder
DA_HEAD         equ 0
DA_NSEC         equ 8           ; data sectors per window (IDs 1..8)
SEC_SZ          equ 512

; DA commands (da_cmd_sector.cmd)
DA_CMD_NOP          equ 0
DA_CMD_SET_LBA      equ 1       ; param[0-3] = LBA LE, param[5] = nr_sec (0=default)
DA_CMD_SET_CYL      equ 2       ; param[0] = drive A cyl, param[1] = drive B cyl
DA_CMD_SELECT_IMAGE equ 4       ; param[0-1] = slot number LE
DA_CMD_SELECT_NAME  equ 10      ; param[] = image path, NUL terminated

; struct da_status_sector (read of DA sector 0)
DAS_SIG         equ 0           ; char[8]  "HxCFEDA"
DAS_FWVER       equ 8           ; char[12]
DAS_LBA_BASE    equ 20          ; u32 LE
DAS_CMD_CNT     equ 24          ; u8
DAS_READ_CNT    equ 25          ; u8
DAS_WRITE_CNT   equ 26          ; u8
DAS_LAST_STATUS equ 27          ; u8, 0 = ok
DAS_WRITE_LOCK  equ 28          ; u8
DAS_KEYS        equ 29          ; u8
DAS_SD_STATUS   equ 30          ; u8
DAS_SD_WP       equ 31          ; u8
DAS_SD_CD       equ 32          ; u8
DAS_NR_SEC      equ 33          ; u8
DAS_CUR_INDEX   equ 34          ; u16 LE

; struct da_cmd_sector (write of DA sector 0)
DAC_SIG         equ 0           ; char[8]  "HxCFEDA"
DAC_CMD         equ 8           ; u8
DAC_PARAM       equ 9           ; u8[8] (SELECT_NAME uses more)

; BIOS data area (segment 0x40)
BDA_SEG         equ 0x40
BDA_CALIB       equ 0x3E        ; bit n: drive n calibrated
BDA_MOTOR       equ 0x3F
BDA_RATE        equ 0x8B        ; bits 7-6: last data rate (10 = 250kbps)
BDA_MEDIA0      equ 0x90        ; drive 0 media state
BDA_CYL0        equ 0x94        ; drive 0 current cylinder (per BIOS)
BDA_TICKS       equ 0x6C        ; timer ticks (18.2 Hz)

MEDIA_DD_EST    equ 0x97        ; 250kbps, established, no double-step
RATE_250        equ 0x80        ; 40:8B value for 250kbps last-selected

; Fixup mask bits (which BIOS patches da_begin applies)
FIX_DPT         equ 0x01        ; point INT 1Eh at our DPT
FIX_MEDIA       equ 0x02        ; force 40:90 media state
FIX_RATE        equ 0x04        ; force 40:8B data rate
FIX_ALL         equ 0x07
FIX_XT          equ FIX_DPT     ; 40:8B/40:90 do not exist pre-AT; the
                                ; XT floppy adapter is 250kbps-only, so
                                ; the DPT swap is the only fixup needed

; DOS device driver request packet (offsets from ES:BX)
REQ_LEN         equ 0
REQ_UNIT        equ 1
REQ_CMD         equ 2
REQ_STATUS      equ 3           ; word
REQ_MEDIA       equ 13          ; media descriptor (r/w cmds, media check)
REQ_MC_RET      equ 14          ; MEDIA CHECK: return byte
REQ_DTA         equ 14          ; READ/WRITE/BUILD BPB: transfer address (far)
REQ_COUNT       equ 18          ; READ/WRITE: sector count (word, in/out)
REQ_BPB         equ 18          ; BUILD BPB: returned BPB far ptr
REQ_START       equ 20          ; READ/WRITE: start sector (word)
REQ_NUNITS      equ 13          ; INIT: unit count out
REQ_BRK         equ 14          ; INIT: break address out (far)
REQ_CMDLINE     equ 18          ; INIT: CONFIG.SYS line in / BPB array out
REQ_DRIVE       equ 22          ; INIT: first drive letter (DOS 3.0+)

; Driver status word codes
ST_DONE         equ 0x0100
ST_ERROR        equ 0x8000
ERR_WP          equ 0x00
ERR_NOT_READY   equ 0x02
ERR_CRC         equ 0x04
ERR_SEEK        equ 0x06
ERR_NOT_FOUND   equ 0x08
ERR_WR_FAULT    equ 0x0A
ERR_RD_FAULT    equ 0x0B
ERR_GENERAL     equ 0x0C
ERR_BAD_CMD     equ 0x03

%endif ; STRUCTS_INC
