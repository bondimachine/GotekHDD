; gotekhdd.asm - GOTEKHDD.SYS: DOS block device driver exposing the first
; FAT partition of a hard-disk image file (default GOTEKHDD.IMG) stored on
; a FlashFloppy/HxC emulator's SD card, transported over the floppy bus
; via the HxC Direct Access protocol (BIOS INT 13h, cylinder 255).
;
;   CONFIG.SYS:  DEVICE=GOTEKHDD.SYS [/F=NAME.IMG] [/U=n] [/V]
;
; Layout: device header, resident data, resident code (dispatch, READ,
; WRITE, card window I/O, DA layer, extent lookup), then the discardable
; INIT section whose start address is returned as the driver break.
;
; Build: nasm -f bin gotekhdd.asm -o GOTEKHDD.SYS

        cpu     8086
        org     0

%include "structs.inc"

; ---------------------------------------------------------------------
; Device header
header:
        dd      -1                      ; next driver
        dw      0x0000                  ; attributes: block device
        dw      strategy
        dw      interrupt
        db      1                       ; number of units
        times 7 db 0

; ---------------------------------------------------------------------
; Resident data
req_ptr:        dd 0                    ; saved request packet address

; BPB copied from the image partition's VBR (DOS 3.31 layout, 25 bytes),
; plus the pointer array INIT hands back to DOS.
bpb:            times 25 db 0
bpb_array:      dw bpb

part_start:     dd 0                    ; partition start (image sectors)
total_vsecs:    dd 0                    ; partition size in sectors
verbose:        db 0
max_win:        db DA_WIN_DEFAULT       ; sectors per DA transaction (/N=n)

; Extent table: image file location on the card as up to MAX_EXTENTS
; contiguous runs. Each entry: file-relative start sector (4), card LBA
; (4), sector count (4).
MAX_EXTENTS     equ 32
EXT_SIZE        equ 12
ext_count:      dw 0
ext_table:      times MAX_EXTENTS*EXT_SIZE db 0

; card window I/O state
io_lba:         dd 0                    ; current window's card LBA
io_tries:       db 0

; ---------------------------------------------------------------------
; Strategy: remember the request packet.
strategy:
        mov     [cs:req_ptr], bx
        mov     [cs:req_ptr+2], es
        retf

; ---------------------------------------------------------------------
; Interrupt: dispatch the saved request.
interrupt:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        cld
        mov     ax, cs
        mov     ds, ax
        les     bx, [req_ptr]
        mov     al, [es:bx+REQ_CMD]
        cmp     al, 0
        je      .init
        cmp     al, 1
        je      .media_check
        cmp     al, 2
        je      .build_bpb
        cmp     al, 4
        je      .read
        cmp     al, 8
        je      .write
        cmp     al, 9
        je      .write                  ; write w/verify: same path
        cmp     al, 11
        jbe     .noop                   ; other legacy commands: succeed
        mov     ax, ST_ERROR|ST_DONE|ERR_BAD_CMD
        jmp     .out
.init:
        call    init                    ; in the discardable section
        jmp     .out
.media_check:
        mov     byte [es:bx+REQ_MC_RET], 1   ; media not changed
        jmp     .noop
.build_bpb:
        mov     word [es:bx+REQ_BPB], bpb
        mov     [es:bx+REQ_BPB+2], cs
        jmp     .noop
.read:
        mov     ah, 2
        call    read_write
        jmp     .out
.write:
        mov     ah, 3
        call    read_write
        jmp     .out
.noop:
        mov     ax, ST_DONE
.out:
        les     bx, [req_ptr]
        mov     [es:bx+REQ_STATUS], ax
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        retf

; ---------------------------------------------------------------------
; read_write: service a READ (AH=2) or WRITE (AH=3) request.
; ES:BX -> request packet. Returns driver status word in AX.
;
; Per-request state kept in registers/locals:
;   [rw_op]     2/3
;   [rw_vsec]   next partition-relative sector (dword)
;   [rw_left]   sectors still to do
;   [rw_done]   sectors completed
;   [rw_buf]    current user transfer address (far)
read_write:
        mov     [rw_op], ah
        mov     ax, [es:bx+REQ_START]
        mov     [rw_vsec], ax
        mov     word [rw_vsec+2], 0
        mov     ax, [es:bx+REQ_COUNT]
        mov     [rw_left], ax
        mov     word [rw_done], 0
        mov     ax, [es:bx+REQ_DTA]
        mov     [rw_buf], ax
        mov     ax, [es:bx+REQ_DTA+2]
        mov     [rw_buf+2], ax

        ; bounds: start + count <= total_vsecs
        mov     ax, [rw_vsec]
        add     ax, [rw_left]
        mov     dx, 0
        adc     dx, 0
        cmp     dx, [total_vsecs+2]
        jb      .bounds_ok
        ja      .bounds_bad
        cmp     ax, [total_vsecs]
        jbe     .bounds_ok
.bounds_bad:
        mov     ax, ST_ERROR|ST_DONE|ERR_NOT_FOUND
        ret
.bounds_ok:
        call    da_begin
.loop:
        cmp     word [rw_left], 0
        je      .success
        ; image sector = part_start + vsec
        mov     ax, [rw_vsec]
        mov     dx, [rw_vsec+2]
        add     ax, [part_start]
        adc     dx, [part_start+2]
        call    extent_lookup           ; -> DX:AX card LBA, CX run left
        jc      .fail_notfound
        mov     [io_lba], ax
        mov     [io_lba+2], dx
        ; n = min(rw_left, max_win, run, sectors-to-64KB-boundary)
        mov     ax, [rw_left]
        mov     bl, [max_win]
        xor     bh, bh
        cmp     ax, bx
        jbe     .n1
        mov     ax, bx
.n1:    cmp     ax, cx
        jbe     .n2
        mov     ax, cx
.n2:    call    dma_clamp               ; AL = final n (>=1), may switch
                                        ; to the bounce buffer for 1 sec
        mov     [rw_n], al
        call    card_io                 ; window transfer w/ verify+retry
        jc      .fail_io
        mov     al, [rw_n]
        xor     ah, ah
        add     [rw_vsec], ax
        adc     word [rw_vsec+2], 0
        add     [rw_done], ax
        sub     [rw_left], ax
        ; advance user pointer by n*512 (bump segment, keep offset)
        mov     cl, 5
        shl     ax, cl                  ; n * 32 paragraphs
        add     [rw_buf+2], ax
        jmp     .loop
.success:
        call    da_end
        les     bx, [req_ptr]
        mov     ax, [rw_done]
        mov     [es:bx+REQ_COUNT], ax
        mov     ax, ST_DONE
        ret
.fail_notfound:
        mov     al, ERR_NOT_FOUND
        jmp     .fail
.fail_io:
        call    map_error               ; AH (BIOS/da code) -> AL DOS code
.fail:
        push    ax
        call    da_end
        les     bx, [req_ptr]
        mov     ax, [rw_done]
        mov     [es:bx+REQ_COUNT], ax
        pop     ax
        xor     ah, ah
        or      ax, ST_ERROR|ST_DONE
        ret

rw_op:      db 0
rw_n:       db 0
rw_bounce:  db 0                        ; this window uses the bounce buffer
rw_vsec:    dd 0
rw_left:    dw 0
rw_done:    dw 0
rw_buf:     dd 0

; ---------------------------------------------------------------------
; dma_clamp: limit AX (window sector count) so the INT 13h transfer from
; [rw_buf] does not cross a 64KB physical boundary. If not even one
; sector fits, route this window through the resident bounce buffer.
; In: AX = proposed n. Out: AL = final n, [rw_bounce] set/cleared.
dma_clamp:
        mov     byte [rw_bounce], 0
        push    bx
        push    cx
        mov     bx, [rw_buf+2]          ; phys = seg*16 + off (low 16 bits
        mov     cl, 4                   ; are all that matter mod 64KB)
        shl     bx, cl
        add     bx, [rw_buf]
        ; sectors until boundary = (0x10000 - (phys & 0xFFFF)) / 512
        mov     cx, bx
        neg     cx                      ; 0x10000 - phys16 (mod 64KB)
        jz      .fits                   ; phys aligned: full 64KB ahead
        push    ax
        mov     ax, cx
        mov     cl, 9
        shr     ax, cl
        mov     cx, ax
        pop     ax
        or      cx, cx
        jz      .bounce
        cmp     ax, cx
        jbe     .fits
        mov     ax, cx
.fits:
        pop     cx
        pop     bx
        ret
.bounce:
        mov     ax, 1
        mov     byte [rw_bounce], 1
        pop     cx
        pop     bx
        ret

; ---------------------------------------------------------------------
; card_io: one DA window transfer of [rw_n] sectors.
; In: [rw_op] 2/3, [rw_n] count, [io_lba] card LBA, [rw_buf] user buffer
;     ([rw_bounce]: use the resident bounce buffer for a single sector).
; Out: CF clear on success; CF set + AH = error code on failure.
;
; One SET_LBA (which sizes the firmware's DA track to exactly [rw_n]
; sectors) followed by one multi-sector INT 13h op, no status readbacks:
; the toll of a SET_LBA and the rotational wait for the window is paid
; once per window rather than once per sector, and nothing waits an
; extra revolution to re-read the status sector. INT 13h still reports
; FDC-level errors (CRC/DMA) and da_int13 retries them; DAPING /T /W is
; the integrity check for firmware bring-up. Whole-transaction retry
; wraps it for robustness on a marginal seek.
card_io:
        mov     byte [io_tries], 3
.attempt:
        mov     al, [rw_n]              ; size the DA track to this window
        mov     [da_nsec], al
        mov     ax, [io_lba]
        mov     dx, [io_lba+2]
        call    da_set_lba
        jc      .retry
        ; bounce-buffered write: stage the user sector into the bounce buf
        cmp     byte [rw_op], 3
        jne     .xfer
        cmp     byte [rw_bounce], 0
        je      .xfer
        push    ds
        pop     es
        mov     di, [bounce_off]
        lds     si, [rw_buf]
        mov     cx, SEC_SZ/2
        rep movsw
        push    cs
        pop     ds
.xfer:
        mov     ah, [rw_op]
        mov     al, [rw_n]
        mov     cl, 1                   ; first data sector ID
        cmp     byte [rw_bounce], 0
        je      .user_buf
        push    ds
        pop     es
        mov     bx, [bounce_off]
        jmp     .go
.user_buf:
        les     bx, [rw_buf]
.go:
        call    da_data
        jc      .retry
        ; bounce-buffered read: copy the sector out to the user buffer
        cmp     byte [rw_op], 3
        je      .ok
        cmp     byte [rw_bounce], 0
        je      .ok
        mov     si, [bounce_off]
        les     di, [rw_buf]
        mov     cx, SEC_SZ/2
        rep movsw
.ok:
        clc
        ret
.retry:
        mov     [da_err], ah
        dec     byte [io_tries]
        jz      .fail
        xor     ax, ax                  ; reset the FDC between attempts
        mov     dl, [da_unit]
        int     0x13
        jmp     .attempt
.fail:
        mov     ah, [da_err]
        stc
        ret

; ---------------------------------------------------------------------
; map_error: AH = BIOS INT 13h error (or 0xFF bad sig / 0xFE verify
; mismatch) -> AL = DOS device error code.
map_error:
        mov     al, ERR_NOT_READY
        cmp     ah, 0x80                ; timeout / not ready
        je      .done
        mov     al, ERR_WP
        cmp     ah, 0x03
        je      .done
        mov     al, ERR_CRC
        cmp     ah, 0x10
        je      .done
        mov     al, ERR_SEEK
        cmp     ah, 0x40
        je      .done
        mov     al, ERR_NOT_FOUND
        cmp     ah, 0x04
        je      .done
        mov     al, ERR_WR_FAULT
        cmp     ah, 0xFE                ; verify mismatch
        jne     .general
        cmp     byte [rw_op], 3
        je      .done
        mov     al, ERR_RD_FAULT
        jmp     .done
.general:
        mov     al, ERR_GENERAL
.done:
        ret

; ---------------------------------------------------------------------
%include "da.asm"
%include "extent.asm"

; 1KB bounce area: INIT points bounce_off at whichever 512-byte half
; does not cross a physical 64KB DMA boundary (depends on load address).
bounce_off: dw bounce_buf
bounce_buf: times SEC_SZ*2 db 0

; ---------------------------------------------------------------------
; Everything below this point is discarded after INIT.
init_start:
%include "init.asm"
