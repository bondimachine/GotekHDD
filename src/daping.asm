; daping.asm - GotekHDD stage-1 diagnostic (DOS .COM).
;
; Talks to a FlashFloppy/HxC emulator's Direct Access track from DOS via
; BIOS INT 13h. Run this before trusting GOTEKHDD.SYS on a new machine.
;
;   DAPING            read + print the DA status sector
;   DAPING /M         fixup matrix: which BIOS patches this machine needs
;   DAPING /L nnn     SET_LBA nnn (decimal), dump first 64 bytes of the
;                     card sector (LBA 0 = the card's MBR)
;   DAPING /B         read benchmark (64KB via 16 x 4KB windows)
;   DAPING /C a b     send SET_CYL(a, b)
;   DAPING /U n       use BIOS drive n (default 0); combines with above
;
; Build: nasm -f bin daping.asm -o DAPING.COM

        cpu     8086
        org     0x100

%include "structs.inc"

start:
        cld
        call    parse_args
        mov     al, [mode]
        cmp     al, 'M'
        je      do_matrix
        cmp     al, 'L'
        je      do_lba
        cmp     al, 'B'
        je      do_bench
        cmp     al, 'C'
        je      do_setcyl
        ; fall through: default status mode

; ---------------------------------------------------------------------
do_status:
        mov     dx, msg_probing
        call    puts
        call    da_begin
        call    da_read_status
        pushf
        call    da_end
        popf
        jc      .fail
        mov     dx, msg_ok
        call    puts
        mov     dx, msg_fw
        call    puts
        mov     si, da_buf+DAS_FWVER    ; fw_ver, up to 12 chars
        mov     cx, 12
.fw:    lodsb
        or      al, al
        jz      .fwdone
        call    putc
        loop    .fw
.fwdone:
        call    crlf
        mov     dx, msg_nrsec
        call    puts
        mov     al, [da_buf+DAS_NR_SEC]
        call    put_dec8
        call    crlf
        mov     dx, msg_sd
        call    puts
        mov     al, [da_buf+DAS_SD_STATUS]
        call    put_hex8
        mov     dx, msg_wp
        call    puts
        mov     al, [da_buf+DAS_SD_WP]
        call    put_dec8
        mov     dx, msg_cd
        call    puts
        mov     al, [da_buf+DAS_SD_CD]
        call    put_dec8
        call    crlf
        mov     dx, msg_slot
        call    puts
        mov     ax, [da_buf+DAS_CUR_INDEX]
        call    put_dec16
        call    crlf
        mov     dx, msg_cnts
        call    puts
        mov     al, [da_buf+DAS_CMD_CNT]
        call    put_dec8
        mov     al, '/'
        call    putc
        mov     al, [da_buf+DAS_READ_CNT]
        call    put_dec8
        mov     al, '/'
        call    putc
        mov     al, [da_buf+DAS_WRITE_CNT]
        call    put_dec8
        call    crlf
        xor     al, al
        jmp     exit
.fail:
        call    print_da_err
        mov     al, 1
        jmp     exit

; ---------------------------------------------------------------------
; /M: try the status read under increasing fixup sets.
do_matrix:
        mov     si, matrix
.next:
        lodsb                           ; fixup mask (0xFF = end)
        cmp     al, 0xFF
        je      .done
        mov     [da_fixmask], al
        mov     dx, [si]                ; description string
        add     si, 2
        push    si
        call    puts
        call    da_begin
        call    da_read_status
        pushf
        call    da_end
        popf
        jc      .bad
        mov     dx, msg_pass
        call    puts
        jmp     .cont
.bad:
        push    ax
        mov     dx, msg_fail
        call    puts
        pop     ax
        mov     al, ah                  ; BIOS error code
        call    put_hex8
        call    crlf
.cont:
        pop     si
        jmp     .next
.done:
        mov     byte [da_fixmask], FIX_ALL
        xor     al, al
        jmp     exit

matrix:
        db FIX_ALL
        dw m_all
        db FIX_DPT|FIX_MEDIA
        dw m_dm
        db FIX_DPT
        dw m_dpt
        db 0
        dw m_none
        db 0xFF
m_all:  db 'DPT+media+rate : $'
m_dm:   db 'DPT+media      : $'
m_dpt:  db 'DPT only       : $'
m_none: db 'no fixups      : $'

; ---------------------------------------------------------------------
; /L nnn: SET_LBA, verify acceptance, dump 64 bytes of the sector.
do_lba:
        call    da_begin
        call    da_read_status
        jc      .fail
        mov     al, [da_buf+DAS_CMD_CNT]
        inc     al
        mov     [want_cmdcnt], al
        mov     ax, [arg1]
        mov     dx, [arg1+2]
        call    da_set_lba
        jc      .fail
        call    da_read_status
        jc      .fail
        mov     al, [da_buf+DAS_CMD_CNT]
        cmp     al, [want_cmdcnt]
        jne     .rejected
        cmp     byte [da_buf+DAS_LAST_STATUS], 0
        jne     .rejected
        push    ds
        pop     es
        mov     ax, 0x0201              ; read 1 data sector
        mov     bx, sec_buf
        mov     cl, 1
        call    da_data
        jc      .fail
        call    da_end
        mov     dx, msg_lba_ok
        call    puts
        mov     si, sec_buf             ; dump 4 lines x 16 bytes
        mov     cx, 4
.line:  push    cx
        mov     cx, 16
.byte:  lodsb
        call    put_hex8
        mov     al, ' '
        call    putc
        loop    .byte
        call    crlf
        pop     cx
        loop    .line
        xor     al, al
        jmp     exit
.rejected:
        call    da_end
        mov     dx, msg_cmd_rej
        call    puts
        mov     al, 1
        jmp     exit
.fail:
        call    da_end
        call    print_da_err
        mov     al, 1
        jmp     exit

; ---------------------------------------------------------------------
; /B: read 64KB = 16 windows of 8 sectors, time with the BDA tick count.
do_bench:
        call    da_begin
        call    da_read_status
        jc      bench_fail
        mov     ax, BDA_SEG
        mov     es, ax
        mov     bx, [es:BDA_TICKS]      ; wait for a tick edge (bounded:
        mov     dx, 1024                ; a dead timer must not hang us)
        xor     cx, cx
.sync:  cmp     bx, [es:BDA_TICKS]
        jne     .ticked
        loop    .sync
        dec     dx
        jnz     .sync
        mov     al, 'T'                 ; warn: timer never moved
        call    putc
.ticked:
        mov     ax, [es:BDA_TICKS]
        mov     [t0], ax
        mov     word [cur_lba], 0
        mov     word [cur_lba+2], 0
        mov     cx, 16
.loop:
        push    cx
        mov     ax, [cur_lba]
        mov     dx, [cur_lba+2]
        call    da_set_lba
        jc      bench_fail_pop
        push    ds
        pop     es
        mov     ax, 0x0208              ; read 8 sectors
        mov     bx, sec_buf
        mov     cl, 1
        call    da_data
        jc      bench_fail_pop
        add     word [cur_lba], 8
        adc     word [cur_lba+2], 0
        mov     al, '.'                 ; checkpoint: window done
        call    putc
        pop     cx
        loop    .loop
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS]
        sub     ax, [t0]                ; elapsed ticks (18.2/s)
        jnz     .nonzero
        inc     ax                      ; avoid divide-by-zero under
.nonzero:                               ; emulators (instant transfers)
        mov     [t0], ax                ; da_end clobbers AX
        call    da_end
        mov     dx, msg_ticks
        call    puts
        mov     ax, [t0]
        call    put_dec16
        call    crlf
        mov     dx, msg_rate
        call    puts
        mov     cx, [t0]                ; ticks
        mov     ax, 11651               ; 64KB*18.2t/s -> KB/s x10
        xor     dx, dx
        div     cx
        mov     cx, 10                  ; print as nn.n
        xor     dx, dx
        div     cx
        push    dx
        call    put_dec16
        mov     al, '.'
        call    putc
        pop     ax
        call    put_dec16
        mov     dx, msg_kbs
        call    puts
        xor     al, al
        jmp     exit
bench_fail_pop:
        pop     cx
bench_fail:
        call    da_end
        call    print_da_err
        mov     al, 1
        jmp     exit

; ---------------------------------------------------------------------
; /C a b: SET_CYL(a, b) with acceptance check.
do_setcyl:
        call    da_begin
        call    da_read_status
        jc      .fail
        mov     al, [da_buf+DAS_CMD_CNT]
        inc     al
        mov     [want_cmdcnt], al
        mov     al, [arg1]
        mov     [da_param], al
        mov     al, [arg2]
        mov     [da_param+1], al
        mov     al, DA_CMD_SET_CYL
        call    da_command
        jc      .fail
        call    da_read_status
        jc      .fail
        mov     al, [da_buf+DAS_CMD_CNT]
        cmp     al, [want_cmdcnt]
        jne     .rej
        cmp     byte [da_buf+DAS_LAST_STATUS], 0
        jne     .rej
        call    da_end
        mov     dx, msg_cyl_ok
        call    puts
        xor     al, al
        jmp     exit
.rej:
        call    da_end
        mov     dx, msg_cmd_rej
        call    puts
        mov     al, 1
        jmp     exit
.fail:
        call    da_end
        call    print_da_err
        mov     al, 1
        jmp     exit

; ---------------------------------------------------------------------
exit:
        mov     ah, 0x4C
        int     0x21

print_da_err:
        push    ax
        mov     dx, msg_err
        call    puts
        pop     ax
        cmp     ah, 0xFF
        je      .sig
        mov     al, ah
        call    put_hex8
        call    crlf
        ret
.sig:
        mov     dx, msg_badsig
        call    puts
        ret

; ---------------------------------------------------------------------
; Command line: [ /U n ] [ /M | /B | /L nnn | /C a b ]
parse_args:
        mov     si, 0x81
.scan:
        lodsb
        cmp     al, 0x0D
        je      .done
        cmp     al, '/'
        jne     .scan
        lodsb
        and     al, 0xDF                ; upcase
        cmp     al, 'U'
        je      .unit
        mov     [mode], al
        cmp     al, 'L'
        je      .one_arg
        cmp     al, 'C'
        je      .two_args
        jmp     .scan
.unit:
        call    parse_dec32
        mov     al, [num]
        mov     [da_unit], al
        jmp     .scan
.one_arg:
        call    parse_dec32
        mov     ax, [num]
        mov     [arg1], ax
        mov     ax, [num+2]
        mov     [arg1+2], ax
        jmp     .scan
.two_args:
        call    parse_dec32
        mov     ax, [num]
        mov     [arg1], ax
        call    parse_dec32
        mov     ax, [num]
        mov     [arg2], ax
        jmp     .scan
.done:
        ret

; parse_dec32: skip non-digits then parse a 32-bit decimal into [num].
; SI advances past the number.
parse_dec32:
        xor     ax, ax
        mov     [num], ax
        mov     [num+2], ax
.skip:
        lodsb
        cmp     al, 0x0D
        je      .end
        cmp     al, '0'
        jb      .skip
        cmp     al, '9'
        ja      .skip
.digit:
        sub     al, '0'
        xor     ah, ah
        push    ax                      ; num = num*10 + digit
        mov     ax, [num]
        mov     dx, [num+2]
        shl     ax, 1
        rcl     dx, 1                   ; x2
        mov     bx, ax
        mov     cx, dx
        shl     ax, 1
        rcl     dx, 1
        shl     ax, 1
        rcl     dx, 1                   ; x8
        add     ax, bx
        adc     dx, cx                  ; x10
        pop     bx
        add     ax, bx
        adc     dx, 0
        mov     [num], ax
        mov     [num+2], dx
        lodsb
        cmp     al, '0'
        jb      .stop
        cmp     al, '9'
        jbe     .digit
.stop:
        dec     si                      ; unread terminator
.end:
        ret

; ---------------------------------------------------------------------
; Output helpers
puts:                                   ; DX -> '$'-terminated string
        mov     ah, 0x09
        int     0x21
        ret

putc:                                   ; AL = char
        push    ax
        push    bx
        push    dx
        mov     dl, al
        mov     ah, 0x02
        int     0x21
        mov     ah, 0x68                ; commit stdout so redirected
        mov     bx, 1                   ; output survives a later hang
        int     0x21
        pop     dx
        pop     bx
        pop     ax
        ret

crlf:
        mov     dx, msg_crlf
        jmp     puts

put_hex8:                               ; AL = byte
        push    ax
        push    cx
        push    ax
        mov     cl, 4
        shr     al, cl
        call    .nib
        pop     ax
        and     al, 0x0F
        call    .nib
        pop     cx
        pop     ax
        ret
.nib:
        add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:     jmp     putc

put_dec8:                               ; AL = byte
        xor     ah, ah
put_dec16:                              ; AX = word
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .div
.emit:  pop     ax
        add     al, '0'
        call    putc
        loop    .emit
        pop     dx
        pop     cx
        pop     bx
        ret

; ---------------------------------------------------------------------
%include "da.asm"

; ---------------------------------------------------------------------
mode:       db 0
num:        dd 0
arg1:       dd 0
arg2:       dw 0
t0:         dw 0
cur_lba:    dd 0
want_cmdcnt: db 0

msg_probing: db 'GotekHDD DAPING 0.1 - probing Direct Access track...', 13, 10, '$'
msg_ok:     db 'Direct Access OK (HxCFEDA signature found)', 13, 10, '$'
msg_fw:     db 'Firmware      : $'
msg_nrsec:  db 'Window sectors: $'
msg_sd:     db 'SD status     : $'
msg_wp:     db '  WP: $'
msg_cd:     db '  CD: $'
msg_slot:   db 'Current slot  : $'
msg_cnts:   db 'cmd/rd/wr cnts: $'
msg_pass:   db 'PASS', 13, 10, '$'
msg_fail:   db 'FAIL, BIOS err $'
msg_err:    db 'ERROR: INT 13h failed, code $'
msg_badsig: db 'ERROR: no HxCFEDA signature (not a DA track?)', 13, 10, '$'
msg_lba_ok: db 'SET_LBA accepted; sector dump:', 13, 10, '$'
msg_cmd_rej: db 'ERROR: command not accepted by firmware', 13, 10, '$'
msg_cyl_ok: db 'SET_CYL accepted', 13, 10, '$'
msg_ticks:  db 'Elapsed ticks : $'
msg_rate:   db 'Read rate     : $'
msg_kbs:    db ' KB/s', 13, 10, '$'
msg_crlf:   db 13, 10, '$'

sec_buf:    times SEC_SZ*DA_NSEC db 0
