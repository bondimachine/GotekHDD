; da.asm - Direct Access transaction layer (shared by DAPING.COM and
; GOTEKHDD.SYS; %include'd into a flat -f bin program).
;
; Assumes: DS = CS (code and data in one segment), direction flag clear.
; All routines are near, 8086-compatible, and use BIOS INT 13h only.
;
; A transaction is bracketed by da_begin/da_end, which save and patch the
; BIOS floppy state (INT 1Eh diskette parameter table, BDA media-state and
; data-rate bytes) so the BIOS transfers at 250kbps MFM on the DA track at
; cylinder 255 even when the mounted floppy image is HD. Between
; transactions all BIOS state is back to what the previous owner expects;
; the FDC's own cylinder tracking stays consistent because every seek goes
; through it, so normal A: use keeps working (the firmware exits DA mode
; on the next seek below cylinder 254 and remounts the floppy image).

%include "structs.inc"

; ---------------------------------------------------------------------
; da_autofix: choose the default fixup set for this machine. The AT
; diskette-state bytes (40:8B data rate, 40:90 media state) only exist
; on AT-class and later BIOSes; on PC/XT-class machines (BIOS model
; byte FF/FE/FD/FB at F000:FFFE) they are reserved BDA bytes and the
; floppy adapter is 250kbps-only anyway, so only the DPT is patched.
; Clobbers AX, ES.
da_autofix:
        mov     ax, 0xF000
        mov     es, ax
        mov     al, [es:0xFFFE]         ; BIOS model byte
        cmp     al, 0xFF                ; PC
        je      .xt
        cmp     al, 0xFE                ; XT
        je      .xt
        cmp     al, 0xFD                ; PCjr
        je      .xt
        cmp     al, 0xFB                ; XT (later BIOS)
        je      .xt
        cmp     al, 0xF9                ; Convertible (8088)
        je      .xt
        mov     byte [da_fixmask], FIX_ALL
        ret
.xt:
        mov     byte [da_fixmask], FIX_XT
        ret

; ---------------------------------------------------------------------
; da_begin: save BIOS floppy state and apply fixups per [da_fixmask].
; Clobbers AX, ES. Not reentrant.
da_begin:
        push    bx
        xor     ax, ax
        mov     es, ax
        test    byte [da_fixmask], FIX_DPT
        jz      .no_dpt
        cli
        mov     ax, [es:0x1E*4]         ; save INT 1Eh vector
        mov     [da_old_dpt], ax
        mov     ax, [es:0x1E*4+2]
        mov     [da_old_dpt+2], ax
        mov     word [es:0x1E*4], da_dpt
        mov     [es:0x1E*4+2], cs
        sti
.no_dpt:
        mov     ax, BDA_SEG
        mov     es, ax
        mov     bl, [da_unit]
        xor     bh, bh
        test    byte [da_fixmask], FIX_MEDIA
        jz      .no_media
        mov     al, [es:bx+BDA_MEDIA0]  ; save + force media state
        mov     [da_old_media], al
        mov     al, [es:bx+BDA_CYL0]
        mov     [da_old_cyl], al
        mov     byte [es:bx+BDA_MEDIA0], MEDIA_DD_EST
.no_media:
        test    byte [da_fixmask], FIX_RATE
        jz      .no_rate
        mov     al, [es:BDA_RATE]       ; save + force data rate
        mov     [da_old_rate], al
        mov     byte [es:BDA_RATE], RATE_250
.no_rate:
        pop     bx
        ret

; ---------------------------------------------------------------------
; da_end: restore what da_begin saved. Clobbers AX, ES.
da_end:
        push    bx
        xor     ax, ax
        mov     es, ax
        test    byte [da_fixmask], FIX_DPT
        jz      .no_dpt
        cli
        mov     ax, [da_old_dpt]
        mov     [es:0x1E*4], ax
        mov     ax, [da_old_dpt+2]
        mov     [es:0x1E*4+2], ax
        sti
.no_dpt:
        mov     ax, BDA_SEG
        mov     es, ax
        mov     bl, [da_unit]
        xor     bh, bh
        test    byte [da_fixmask], FIX_MEDIA
        jz      .no_media
        mov     al, [da_old_media]
        mov     [es:bx+BDA_MEDIA0], al
.no_media:
        test    byte [da_fixmask], FIX_RATE
        jz      .no_rate
        mov     al, [da_old_rate]
        mov     [es:BDA_RATE], al
.no_rate:
        pop     bx
        ret

; ---------------------------------------------------------------------
; da_int13: one INT 13h floppy op on the DA track with retries.
; In:  AH = 2 (read) / 3 (write), AL = sector count,
;      CL = first sector ID (0 = cmd/status, 1..8 = data window),
;      ES:BX = buffer.
; Out: CF clear on success; CF set and AH = BIOS error code on failure.
; Clobbers AX, CX, DX, DI.
da_int13:
        mov     [da_op], ax
        mov     [da_sector], cl
        mov     byte [da_tries], 4
.retry:
        mov     ax, [da_op]
        mov     cl, [da_sector]
        mov     ch, DA_CYL
        mov     dh, DA_HEAD
        mov     dl, [da_unit]
        int     0x13
        jnc     .done
        mov     [da_err], ah
        inc     word [da_retry_cnt]     ; diagnostics: failed attempts
        dec     byte [da_tries]
        jz      .fail
        ; Reset the controller after the second failed attempt; a reset
        ; forces a recalibrate which may need several passes to step the
        ; head down from cylinder 255 (79 step pulses per recalibrate).
        cmp     byte [da_tries], 2
        ja      .retry
        xor     ax, ax
        mov     dl, [da_unit]
        int     0x13
        jmp     .retry
.fail:
        mov     ah, [da_err]
        stc
        ret
.done:
        clc
        ret

; ---------------------------------------------------------------------
; da_command: send one command sector.
; In:  AL = command code; parameters already stored at da_param (8 bytes;
;      SELECT_NAME may use the bytes beyond da_param too).
; Out: CF as da_int13.
; Clobbers AX, CX, DX, DI, ES.
da_command:
        push    bx
        push    si
        push    ds
        pop     es
        mov     di, da_buf              ; (re)write the signature: the
        mov     si, da_sig              ; buffer doubles as status buffer
        mov     cx, 8
        rep movsb
        mov     [da_buf+DAC_CMD], al
        mov     ax, 0x0301              ; write 1 sector
        mov     bx, da_buf
        xor     cx, cx                  ; CL = 0: command sector
        call    da_int13
        pop     si
        pop     bx
        ret

; ---------------------------------------------------------------------
; da_set_lba: send CMD_SET_LBA for DX:AX (32-bit card LBA).
; Out: CF as da_int13. Clobbers AX, CX, DX, DI, ES.
da_set_lba:
        mov     [da_param], ax
        mov     [da_param+2], dx
        mov     byte [da_param+4], 0
        mov     byte [da_param+5], 0    ; default sector count (8)
        mov     al, DA_CMD_SET_LBA
        jmp     da_command

; ---------------------------------------------------------------------
; da_read_status: read the status sector into da_buf and check the
; "HxCFEDA" signature.
; Out: CF clear = status in da_buf is valid.
; Clobbers AX, CX, DX, SI, DI, ES.
da_read_status:
        push    bx
        push    ds
        pop     es
        mov     ax, 0x0201              ; read 1 sector
        mov     bx, da_buf
        xor     cx, cx                  ; CL = 0: status sector
        call    da_int13
        pop     bx
        jc      .out
        mov     si, da_buf
        mov     di, da_sig
        mov     cx, 8
.cmp:   lodsb
        cmp     al, [di]
        jne     .bad
        inc     di
        loop    .cmp
        clc
.out:   ret
.bad:   mov     ah, 0xFF                ; our own code: bad signature
        stc
        ret

; ---------------------------------------------------------------------
; da_data: transfer data-window sectors.
; In:  AH = 2 (read) / 3 (write), AL = count (1..8),
;      CL = first data sector (1..8), ES:BX = user buffer.
; Out: CF as da_int13. Clobbers AX, CX, DX, DI.
da_data:
        jmp     da_int13

; ---------------------------------------------------------------------
; Data
da_sig:         db 'HxCFEDA', 0
da_unit:        db 0                    ; BIOS drive number
da_fixmask:     db FIX_ALL
da_old_dpt:     dd 0
da_old_media:   db 0
da_old_rate:    db 0
da_old_cyl:     db 0
da_op:          dw 0
da_sector:      db 0
da_tries:       db 0
da_err:         db 0
da_retry_cnt:   dw 0                    ; failed INT 13h attempts (total)

; Diskette parameter table for the DA track: 512-byte sectors, EOT 9
; (IDs 0..8), MFM DD gap. Values otherwise standard 3.5" table.
da_dpt:         db 0xDF, 0x02, 0x25, 0x02, 9, 0x2A, 0xFF, 0x50
                db 0xF6, 0x0F, 0x08

; Command/status sector buffer. da_command relies on the signature being
; pre-filled and da_param following it at DAC_PARAM.
                align 2
da_buf:         db 'HxCFEDA', 0         ; DAC_SIG / DAS_SIG
da_cmd_code:    db 0                    ; DAC_CMD
da_param:       times SEC_SZ-9 db 0     ; DAC_PARAM.. rest of sector
