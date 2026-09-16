; dastub.asm - INT 13h stub TSR faking a FlashFloppy Direct Access track,
; for testing DAPING.COM and GOTEKHDD.SYS under DOSBox/86Box without
; hardware.
;
;   DASTUB CARD.IMG     load the card image into XMS and hook INT 13h
;
; Any INT 13h read/write to drive 0 at cylinder >= 254 is serviced from
; the image: sector 0 emulates the command/status protocol (SET_LBA,
; SET_CYL, NOP; matching FlashFloppy src/image/da.c behavior including
; cmd_cnt/last_cmd_status/write_cnt), sectors 1..8 window onto image
; LBA lba_base+id-1. Writes below LBA 64 are rejected, mimicking the
; firmware's refusal to write outside the card's FAT volume. Everything
; else chains to the previous handler.
;
; Build: nasm -f bin dastub.asm -o DASTUB.COM

        cpu     8086
        org     0x100

%include "structs.inc"

WRITE_MIN_LBA   equ 64          ; lowest writable LBA (mimics volbase+1)

start:
        jmp     install

; =======================================================================
; Resident part
; =======================================================================
old13:      dd 0
xms_entry:  dd 0
xms_handle: dw 0
use_xms:    db 0                ; 0 = file-backed mode (no XMS/8088)
fhandle:    dw 0                ; file mode: open handle on the image
stub_psp:   dw 0                ; file mode: our PSP for handle access
img_secs:   dd 0                ; image size in sectors
lba_base:   dd 0
stub_nsec:  db 8                ; current window (SET_LBA param[5]; 0 -> 8)
cmd_cnt:    db 0
read_cnt:   db 0
write_cnt:  db 0
last_status: db 0
stub_sig:   db 'HxCFEDA', 0
stub_fw:    db 'DASTUB'
STUB_FW_LEN equ $-stub_fw

; captured caller registers / results
v_ax:       dw 0                ; AL = count, AH = op
v_bx:       dw 0                ; user buffer offset
v_cx:       dw 0                ; CL = sector id
v_es:       dw 0                ; user buffer segment
v_err:      db 0                ; result: 0 = ok, else INT 13h AH code
v_lba:      dd 0

; XMS move descriptor
xmv_len:    dd 0
xmv_shan:   dw 0
xmv_soff:   dd 0
xmv_dhan:   dw 0
xmv_doff:   dd 0

hook13:
        cmp     dl, 0                   ; our unit, DA cylinders,
        jne     .chain                  ; read/write only
        cmp     ch, 254
        jb      .chain
        cmp     ah, 2
        jb      .chain
        cmp     ah, 3
        ja      .chain
        mov     [cs:v_ax], ax
        mov     [cs:v_bx], bx
        mov     [cs:v_cx], cx
        mov     [cs:v_es], es
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        push    cs
        pop     ds
        cld
        mov     byte [v_err], 0
        mov     al, [v_cx]
        or      al, al
        jz      .sector0
        call    data_window
        jmp     .finish
.sector0:
        call    cmd_status
.finish:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        mov     ax, [cs:v_ax]
        mov     ah, [cs:v_err]
        push    bp                      ; set CF in the caller's stacked
        mov     bp, sp                  ; FLAGS and iret, preserving the
        or      ah, ah                  ; caller's IF (a retf 2 would
        jnz     .fail                   ; return with interrupts off!)
        and     word [bp+6], 0xFFFE
        pop     bp
        iret
.fail:
        or      word [bp+6], 1
        pop     bp
        iret
.chain:
        jmp     far [cs:old13]

; -----------------------------------------------------------------------
; data_window: sectors 1..nr_sec <-> image at lba_base+id-1. DS = CS.
data_window:
        mov     cl, [v_cx]              ; first sector id (1..nr_sec)
        cmp     cl, [stub_nsec]
        ja      .badsec
        mov     al, [v_ax]              ; count
        or      al, al
        jz      .badsec
        mov     ah, al
        add     ah, cl
        dec     ah
        cmp     ah, [stub_nsec]         ; last id must be <= nr_sec
        ja      .badsec
        mov     ch, al                  ; CH = count, CL = first id
        ; lba = lba_base + id - 1
        mov     al, cl
        xor     ah, ah
        dec     ax
        add     ax, [lba_base]
        mov     dx, [lba_base+2]
        adc     dx, 0
        mov     [v_lba], ax
        mov     [v_lba+2], dx
        ; bounds: lba + count <= img_secs
        mov     si, ax
        mov     di, dx
        mov     al, ch
        xor     ah, ah
        add     si, ax
        adc     di, 0
        cmp     di, [img_secs+2]
        jb      .bounds_ok
        ja      .badsec
        cmp     si, [img_secs]
        ja      .badsec
.bounds_ok:
        cmp     byte [v_ax+1], 3
        jne     .setup
        ; write: emulate the firmware volume bound
        cmp     word [v_lba+2], 0
        jne     .setup
        cmp     word [v_lba], WRITE_MIN_LBA
        jae     .setup
        mov     byte [v_err], 0x03      ; write protect
        ret
.setup:
        ; length = count * 512
        mov     al, ch
        xor     ah, ah
        push    cx
        mov     cl, 9
        shl     ax, cl
        pop     cx
        mov     [xmv_len], ax
        mov     word [xmv_len+2], 0
        ; image byte offset = lba * 512
        mov     ax, [v_lba]
        mov     dx, [v_lba+2]
        push    cx
        mov     cx, 9
.sh:    shl     ax, 1
        rcl     dx, 1
        loop    .sh
        pop     cx
        cmp     byte [use_xms], 0
        je      .file
        ; direction
        cmp     byte [v_ax+1], 3
        je      .to_xms
        mov     si, [xms_handle]
        mov     [xmv_shan], si
        mov     [xmv_soff], ax
        mov     [xmv_soff+2], dx
        mov     word [xmv_dhan], 0
        mov     si, [v_bx]
        mov     [xmv_doff], si
        mov     si, [v_es]
        mov     [xmv_doff+2], si
        jmp     .go
.to_xms:
        mov     word [xmv_shan], 0
        mov     si, [v_bx]
        mov     [xmv_soff], si
        mov     si, [v_es]
        mov     [xmv_soff+2], si
        mov     si, [xms_handle]
        mov     [xmv_dhan], si
        mov     [xmv_doff], ax
        mov     [xmv_doff+2], dx
.go:
        push    cx
        mov     si, xmv_len
        mov     ah, 0x0B                ; XMS move
        call    far [xms_entry]
        pop     cx
        or      ax, ax
        jz      .moverr
.xfer_ok:
        cmp     byte [v_ax+1], 3
        jne     .done
        add     [write_cnt], ch         ; one bump per written sector
.done:
        ret

        ; ---- file-backed mode (no XMS; 8088-class runs) ----
        ; Only safe when INT 13h is invoked from normal program context
        ; (DAPING/DRVTEST), since it re-enters DOS for file I/O.
.file:
        sti
        mov     si, ax                  ; SI:DI = byte offset
        mov     di, dx
        push    cx                      ; count in CH
        mov     ah, 0x51                ; save caller's PSP, switch to
        int     0x21                    ; ours so the handle resolves
        push    bx
        mov     bx, [stub_psp]
        mov     ah, 0x50
        int     0x21
        mov     bx, [fhandle]           ; seek to the window
        mov     cx, di
        mov     dx, si
        mov     ax, 0x4200
        int     0x21
        jc      .filerr
        mov     ah, [v_ax+1]            ; 2/3 -> 3Fh read / 40h write
        add     ah, 0x3D
        mov     bx, [fhandle]
        mov     cx, [xmv_len]
        mov     dx, [v_bx]
        push    ds
        mov     ds, [cs:v_es]           ; user buffer is DS:DX
        int     0x21
        pop     ds
        jc      .filerr
        cmp     ax, [xmv_len]
        jne     .filerr
        pop     bx                      ; restore caller's PSP
        mov     ah, 0x50
        int     0x21
        pop     cx
        jmp     .xfer_ok
.filerr:
        pop     bx
        mov     ah, 0x50
        int     0x21
        pop     cx
.moverr:
        mov     byte [v_err], 0x20      ; controller failure
        ret
.badsec:
        mov     byte [v_err], 0x04      ; sector not found
        ret

; -----------------------------------------------------------------------
; cmd_status: sector 0 read (status) or write (command). DS = CS.
cmd_status:
        cmp     byte [v_ax], 1          ; single sector only
        jne     .badsec
        cmp     byte [v_ax+1], 3
        je      .command
        ; ---- status read: synthesize into the caller's buffer ----
        mov     es, [v_es]
        mov     di, [v_bx]
        push    di
        xor     ax, ax
        mov     cx, SEC_SZ/2
        rep stosw
        pop     di
        mov     si, stub_sig
        mov     cx, 8
        rep movsb
        mov     si, stub_fw             ; fw_ver at DAS_FWVER
        mov     cx, STUB_FW_LEN
        rep movsb
        mov     di, [v_bx]
        mov     ax, [lba_base]
        mov     [es:di+DAS_LBA_BASE], ax
        mov     ax, [lba_base+2]
        mov     [es:di+DAS_LBA_BASE+2], ax
        inc     byte [read_cnt]
        mov     al, [cmd_cnt]
        mov     [es:di+DAS_CMD_CNT], al
        mov     al, [read_cnt]
        mov     [es:di+DAS_READ_CNT], al
        mov     al, [write_cnt]
        mov     [es:di+DAS_WRITE_CNT], al
        mov     al, [last_status]
        mov     [es:di+DAS_LAST_STATUS], al
        mov     byte [es:di+DAS_SD_CD], 1
        mov     al, [stub_nsec]
        mov     [es:di+DAS_NR_SEC], al
        ret
.command:
        ; ---- command write: parse the caller's buffer ----
        inc     byte [cmd_cnt]
        mov     byte [last_status], 1   ; guilty until proven ok
        mov     es, [v_es]
        mov     si, [v_bx]
        mov     di, stub_sig
        mov     cx, 8
.sig:   mov     al, [es:si]
        cmp     al, [di]
        jne     .done                   ; bad sig: ignored, status = err
        inc     si
        inc     di
        loop    .sig
        mov     al, [es:si+DAC_CMD-8]   ; SI already past the signature
        cmp     al, DA_CMD_NOP
        je      .ok
        cmp     al, DA_CMD_SET_CYL
        je      .ok
        cmp     al, DA_CMD_SET_LBA
        jne     .done                   ; unknown command: status stays 1
        mov     ax, [es:si+DAC_PARAM-8]
        mov     [lba_base], ax
        mov     ax, [es:si+DAC_PARAM-8+2]
        mov     [lba_base+2], ax
        mov     al, [es:si+DAC_PARAM-8+5]   ; param[5] = nr_sec (0 -> 8),
        or      al, al                      ; matching da.c; clamp to the
        jnz     .haven                      ; window ceiling we model
        mov     al, 8
.haven: cmp     al, DA_WIN_MAX
        jbe     .setn
        mov     al, DA_WIN_MAX
.setn:  mov     [stub_nsec], al
.ok:
        mov     byte [last_status], 0
.done:
        ret
.badsec:
        mov     byte [v_err], 0x04
        ret

resident_end:

; =======================================================================
; Installer (transient)
; =======================================================================
install:
        cld
        mov     dx, s_banner
        call    puts
        ; filename from the PSP command line
        mov     si, 0x81
.sk:    lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 0x0D
        jne     .have
        mov     dx, s_usage
        jmp     die
.have:
        mov     di, fname
.cp:    stosb
        lodsb
        cmp     al, 0x0D
        je      .cp_done
        cmp     al, ' '
        jne     .cp
.cp_done:
        mov     byte [di], 0

        ; open the card image read-write (read-only as a fallback)
        mov     ax, 0x3D02
        mov     dx, fname
        int     0x21
        jnc     .opened
        mov     ax, 0x3D00
        int     0x21
        jnc     .opened
        mov     dx, s_nofile
        jmp     die
.opened:
        mov     [fhandle], ax
        mov     bx, ax                  ; size = seek to end
        mov     ax, 0x4202
        xor     cx, cx
        xor     dx, dx
        int     0x21
        mov     [fsize], ax
        mov     [fsize+2], dx
        mov     cx, 9                   ; sectors = size >> 9
.ssz:   shr     dx, 1
        rcr     ax, 1
        loop    .ssz
        mov     [img_secs], ax
        mov     [img_secs+2], dx
        mov     ax, 0x4200              ; rewind
        xor     cx, cx
        xor     dx, dx
        int     0x21

        ; XMS present? If not (e.g. an 8088-class CPU), stay file-backed.
        mov     ax, 0x4300
        int     0x2F
        cmp     al, 0x80
        je      .have_xms
        mov     ah, 0x51                ; remember our PSP so the hook
        int     0x21                    ; can reach the open handle
        mov     [stub_psp], bx
        mov     dx, s_filemode
        call    puts
        jmp     .hook
.have_xms:
        mov     byte [use_xms], 1
        mov     ax, 0x4310
        int     0x2F
        mov     [xms_entry], bx
        mov     [xms_entry+2], es

        ; allocate XMS: KB = (size >> 10) + 1; 16-bit KB count caps the
        ; image at just under 64MB
        mov     ax, [fsize]
        mov     dx, [fsize+2]
        mov     cx, 10
.kb:    shr     dx, 1
        rcr     ax, 1
        loop    .kb
        or      dx, dx
        jz      .size_ok
        mov     dx, s_toobig
        jmp     die
.size_ok:
        inc     ax
        mov     dx, ax
        mov     ah, 0x09
        call    far [xms_entry]
        or      ax, ax
        jnz     .alloced
        mov     dx, s_noalloc
        jmp     die
.alloced:
        mov     [xms_handle], dx

        ; copy file -> XMS in 16KB chunks
        mov     word [xoff], 0
        mov     word [xoff+2], 0
.chunk:
        mov     bx, [fhandle]
        mov     ah, 0x3F
        mov     cx, 16384
        mov     dx, iobuf
        int     0x21
        jc      .rderr
        or      ax, ax
        jz      .loaded
        inc     ax                      ; round length up to even
        and     ax, 0xFFFE
        mov     [xmv_len], ax
        mov     word [xmv_len+2], 0
        mov     word [xmv_shan], 0
        mov     word [xmv_soff], iobuf
        mov     [xmv_soff+2], cs
        mov     bx, [xms_handle]
        mov     [xmv_dhan], bx
        mov     bx, [xoff]
        mov     [xmv_doff], bx
        mov     bx, [xoff+2]
        mov     [xmv_doff+2], bx
        push    ax
        mov     si, xmv_len
        mov     ah, 0x0B
        call    far [xms_entry]
        or      ax, ax
        pop     ax
        jz      .rderr
        add     [xoff], ax
        adc     word [xoff+2], 0
        jmp     .chunk
.rderr:
        mov     dx, s_rderr
        jmp     die
.loaded:
        mov     bx, [fhandle]
        mov     ah, 0x3E
        int     0x21

.hook:
        ; hook INT 13h
        mov     ax, 0x3513
        int     0x21
        mov     [old13], bx
        mov     [old13+2], es
        mov     dx, hook13
        mov     ax, 0x2513
        int     0x21

        mov     dx, s_done
        call    puts

        ; TSR: keep PSP + resident part
        mov     dx, (resident_end - start + 0x10F) >> 4
        mov     ax, 0x3100
        int     0x21

die:
        call    puts
        mov     ax, 0x4C01
        int     0x21

puts:
        mov     ah, 0x09
        int     0x21
        ret

s_banner:  db 'DASTUB - Direct Access track emulator', 13, 10, '$'
s_usage:   db 'usage: DASTUB CARD.IMG', 13, 10, '$'
s_filemode: db 'no XMS: file-backed mode (DAPING/DRVTEST only)', 13, 10, '$'
s_nofile:  db 'error: cannot open card image', 13, 10, '$'
s_noalloc: db 'error: XMS allocation failed', 13, 10, '$'
s_rderr:   db 'error: reading card image', 13, 10, '$'
s_toobig:  db 'error: card image too large (max 63MB)', 13, 10, '$'
s_done:    db 'installed: INT 13h drive 0 cyl>=254 now emulated', 13, 10, '$'

fname:     times 80 db 0
fsize:     dd 0
xoff:      dd 0
iobuf:
