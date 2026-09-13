; drvtest.asm - exercises GOTEKHDD.SYS outside CONFIG.SYS.
;
; Loads the driver binary, calls its strategy/interrupt entries with
; hand-built request packets (INIT, MEDIA CHECK, BUILD BPB, READ, WRITE)
; and reports results, so the full driver logic can be tested under
; DOSBox with DASTUB installed, without booting a real DOS.
;
;   DRVTEST             INIT + BUILD BPB + read sector 0 + info
;   DRVTEST /S a /N n   checksum n sectors from logical sector a
;                       (16-bit additive byte sum, printed in hex)
;   DRVTEST /W n        write-invert-readback-restore test on sector n
;
; Build: nasm -f bin drvtest.asm -o DRVTEST.COM

        cpu     8086
        org     0x100

%include "structs.inc"

DTA_SECS equ 32                         ; per-request transfer size

start:
        cld
        call    parse_args

        ; ---- load GOTEKHDD.SYS --------------------------------------
        mov     ax, 0x3D00
        mov     dx, fdrv
        int     0x21
        jnc     .opened
        mov     dx, s_nodrv
        jmp     die
.opened:
        mov     bx, ax
        mov     ah, 0x3F
        mov     cx, 0x3000
        mov     dx, drvbuf
        int     0x21
        jc      .badread
        push    ax
        mov     ah, 0x3E
        int     0x21
        pop     ax
        or      ax, ax
        jnz     .loaded
.badread:
        mov     dx, s_nodrv
        jmp     die
.loaded:
        ; driver segment = CS + drvbuf/16 (drvbuf is paragraph aligned)
        mov     ax, cs
        mov     dx, drvbuf
        mov     cl, 4
        shr     dx, cl
        add     ax, dx
        mov     [drvseg], ax
        mov     dx, [drvbuf+6]          ; header: strategy offset
        mov     [strat], dx
        mov     dx, [drvbuf+8]          ; header: interrupt offset
        mov     [intr], dx

        ; ---- INIT ----------------------------------------------------
        mov     di, packet
        call    clear_packet
        mov     byte [packet+REQ_LEN], 26
        mov     byte [packet+REQ_CMD], 0
        mov     word [packet+REQ_CMDLINE], cmdline
        mov     [packet+REQ_CMDLINE+2], cs
        mov     byte [packet+REQ_DRIVE], 3      ; pretend D:
        call    call_driver
        mov     dx, s_init
        call    puts
        mov     ax, [packet+REQ_STATUS]
        call    put_hex16
        mov     dx, s_units
        call    puts
        mov     al, [packet+REQ_NUNITS]
        call    put_dec8
        call    crlf
        test    word [packet+REQ_STATUS], ST_ERROR
        jnz     near fail
        cmp     byte [packet+REQ_NUNITS], 1
        jne     near fail

        ; ---- BUILD BPB ----------------------------------------------
        mov     di, packet
        call    clear_packet
        mov     byte [packet+REQ_LEN], 22
        mov     byte [packet+REQ_CMD], 2
        call    call_driver
        test    word [packet+REQ_STATUS], ST_ERROR
        jnz     near fail
        mov     dx, s_bpb
        call    puts
        les     si, [packet+REQ_BPB]    ; far ptr to BPB
        mov     ax, [es:si]             ; bytes/sector
        call    put_dec16
        mov     al, '/'
        call    putc
        mov     al, [es:si+2]           ; sectors/cluster
        call    put_dec8
        mov     al, '/'
        call    putc
        mov     ax, [es:si+8]           ; total sectors (16-bit field)
        call    put_dec16
        call    crlf

        ; ---- dispatch mode ------------------------------------------
        cmp     byte [mode], 'W'
        je      near do_write
        cmp     byte [mode], 'S'
        je      near do_sum

        ; default: read logical sector 0, check boot signature
        mov     ax, 1
        xor     dx, dx
        mov     [nsecs], ax
        mov     word [cursec], 0
        call    read_req
        jc      near fail
        mov     dx, s_sec0
        call    puts
        cmp     word [dta+510], 0xAA55
        je      .sig_ok
        mov     dx, s_nosig
        call    puts
        jmp     fail
.sig_ok:
        mov     dx, s_pass
        call    puts
        jmp     exit_ok

; ---- checksum mode ---------------------------------------------------
do_sum:
        mov     ax, [arg_s]
        mov     [cursec], ax
        mov     word [sum], 0
        mov     ax, [arg_n]
        mov     [left], ax
.loop:
        mov     ax, [left]
        or      ax, ax
        jz      .done
        cmp     ax, DTA_SECS
        jbe     .n_ok
        mov     ax, DTA_SECS
.n_ok:
        mov     [nsecs], ax
        call    read_req
        jc      near fail
        ; sum bytes
        mov     si, dta
        mov     cx, [nsecs]
        push    dx
        mov     dx, cx
        mov     cl, 9
        shl     dx, cl                  ; bytes this request
        mov     cx, dx
        pop     dx
        xor     ah, ah
.sum:   lodsb
        add     [sum], ax
        loop    .sum
        mov     ax, [nsecs]
        add     [cursec], ax
        sub     [left], ax
        jmp     .loop
.done:
        mov     dx, s_sum
        call    puts
        mov     ax, [sum]
        call    put_hex16
        call    crlf
        mov     dx, s_pass
        call    puts
        jmp     exit_ok

; ---- write test ------------------------------------------------------
do_write:
        mov     ax, [arg_s]
        mov     [cursec], ax
        mov     word [nsecs], 1
        call    read_req                ; original content
        jc      near fail
        mov     si, dta                 ; save + invert
        mov     di, dta+SEC_SZ
        mov     cx, SEC_SZ
.inv:   lodsb
        mov     [di], al
        not     al
        mov     [si-1], al
        inc     di
        loop    .inv
        call    write_req
        jc      near fail
        mov     word [dta], 0x5555      ; spoil the buffer
        call    read_req
        jc      near fail
        mov     si, dta                 ; verify inverted content
        mov     di, dta+SEC_SZ
        mov     cx, SEC_SZ
.chk:   mov     al, [di]
        not     al
        cmp     al, [si]
        jne     .mismatch
        inc     si
        inc     di
        loop    .chk
        ; restore original
        mov     si, dta+SEC_SZ
        mov     di, dta
        mov     cx, SEC_SZ/2
        push    ds
        pop     es
        rep movsw
        call    write_req
        jc      near fail
        mov     dx, s_wr_ok
        call    puts
        mov     dx, s_pass
        call    puts
        jmp     exit_ok
.mismatch:
        mov     dx, s_wr_bad
        call    puts
        jmp     fail

; ---------------------------------------------------------------------
read_req:
        mov     ah, 4
        jmp     rw_req
write_req:
        mov     ah, 8
rw_req:
        push    ax
        mov     di, packet
        call    clear_packet
        pop     ax
        mov     byte [packet+REQ_LEN], 22
        mov     [packet+REQ_CMD], ah
        mov     word [packet+REQ_DTA], dta
        mov     [packet+REQ_DTA+2], cs
        mov     ax, [nsecs]
        mov     [packet+REQ_COUNT], ax
        mov     ax, [cursec]
        mov     [packet+REQ_START], ax
        call    call_driver
        mov     ax, [packet+REQ_STATUS]
        test    ax, ST_ERROR
        jz      .ok
        push    ax
        mov     dx, s_rwerr
        call    puts
        pop     ax
        call    put_hex16
        call    crlf
        stc
        ret
.ok:
        clc
        ret

; call_driver: hand [packet] to the loaded driver.
call_driver:
        push    ds
        push    es
        mov     bx, packet
        push    cs
        pop     es
        mov     ax, [strat]
        mov     [farcall], ax
        mov     ax, [drvseg]
        mov     [farcall+2], ax
        call    far [farcall]
        mov     ax, [intr]
        mov     [farcall], ax
        call    far [farcall]
        pop     es
        pop     ds
        ret

clear_packet:
        push    es
        push    cs
        pop     es
        mov     di, packet
        xor     ax, ax
        mov     cx, 16
        rep stosw
        pop     es
        ret

fail:
        mov     dx, s_fail
        call    puts
        mov     ax, 0x4C01
        int     0x21
exit_ok:
        mov     ax, 0x4C00
        int     0x21
die:
        call    puts
        mov     ax, 0x4C02
        int     0x21

; ---------------------------------------------------------------------
; /S n, /N n, /W n parsing (decimal)
parse_args:
        mov     si, 0x81
.scan:  lodsb
        cmp     al, 0x0D
        je      .done
        cmp     al, '/'
        jne     .scan
        lodsb
        and     al, 0xDF
        cmp     al, 'S'
        je      .s
        cmp     al, 'N'
        je      .n
        cmp     al, 'W'
        jne     .scan
        mov     byte [mode], 'W'
        call    pdec
        mov     [arg_s], ax
        jmp     .scan
.s:     mov     byte [mode], 'S'
        call    pdec
        mov     [arg_s], ax
        jmp     .scan
.n:     call    pdec
        mov     [arg_n], ax
        jmp     .scan
.done:  ret

pdec:                                   ; parse decimal at SI -> AX
        xor     bx, bx
.skip:  lodsb
        cmp     al, 0x0D
        je      .end
        cmp     al, '0'
        jb      .skip
        cmp     al, '9'
        ja      .skip
.dig:   sub     al, '0'
        xor     ah, ah
        push    ax
        mov     ax, bx
        mov     bx, 10
        mul     bx
        mov     bx, ax
        pop     ax
        add     bx, ax
        lodsb
        cmp     al, '0'
        jb      .stop
        cmp     al, '9'
        jbe     .dig
.stop:  dec     si
.end:   mov     ax, bx
        ret

; ---------------------------------------------------------------------
puts:
        mov     ah, 0x09
        int     0x21
        ret
putc:
        push    dx
        mov     dl, al
        mov     ah, 0x02
        int     0x21
        pop     dx
        ret
crlf:
        mov     dx, s_crlf
        jmp     puts
put_hex16:
        push    ax
        mov     al, ah
        call    put_hex8
        pop     ax
        jmp     put_hex8
put_hex8:
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
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     .p
        add     al, 7
.p:     jmp     putc
put_dec8:
        xor     ah, ah
put_dec16:
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d:     xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d
.e:     pop     ax
        add     al, '0'
        call    putc
        loop    .e
        pop     dx
        pop     cx
        pop     bx
        ret

; ---------------------------------------------------------------------
mode:    db 0
arg_s:   dw 0
arg_n:   dw 1
drvseg:  dw 0
strat:   dw 0
intr:    dw 0
farcall: dd 0
cursec:  dw 0
nsecs:   dw 0
left:    dw 0
sum:     dw 0

fdrv:    db 'GOTEKHDD.SYS', 0
cmdline: db 'DEVICE=GOTEKHDD.SYS /V', 0x0D

s_nodrv: db 'cannot load GOTEKHDD.SYS', 13, 10, '$'
s_init:  db 'INIT status  : $'
s_units: db '  units: $'
s_bpb:   db 'BPB b/spc/tot: $'
s_sec0:  db 'sector 0 read: $'
s_nosig: db 'no 55AA boot signature!', 13, 10, '$'
s_sum:   db 'checksum     : $'
s_rwerr: db 'request FAILED, status $'
s_wr_ok: db 'write/readback/restore OK', 13, 10, '$'
s_wr_bad: db 'readback MISMATCH', 13, 10, '$'
s_pass:  db 'DRVTEST PASS', 13, 10, '$'
s_fail:  db 'DRVTEST FAIL', 13, 10, '$'
s_crlf:  db 13, 10, '$'

packet:  times 32 db 0

        align 16
drvbuf:  times 0x3000 db 0
dta:     times SEC_SZ*DTA_SECS db 0
