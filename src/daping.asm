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
;   DAPING /T [lba]   phase timing: ms per INT 13h step of a DA window
;                     (cmd write, status reads, 8-sector data ops), 16
;                     iterations on one card LBA (default: 64 sectors into
;                     the card FAT volume's data area). Add /W to time the
;                     write path too: it writes back the bytes it just read.
;   DAPING /C a b     send SET_CYL(a, b)
;   DAPING /U n       use BIOS drive n (default 0); combines with above
;
; Build: nasm -f bin daping.asm -o DAPING.COM

        cpu     8086
        org     0x100

%include "structs.inc"

start:
        cld
        call    da_autofix
        call    parse_args
        mov     al, [mode]
        cmp     al, 'M'
        je      do_matrix
        cmp     al, 'L'
        je      do_lba
        cmp     al, 'B'
        je      do_bench
        cmp     al, 'T'
        je      do_timing
        cmp     al, 'C'
        je      do_setcyl
        ; fall through: default status mode

; ---------------------------------------------------------------------
do_status:
        mov     dx, msg_probing
        call    puts
        mov     dx, msg_fixups
        call    puts
        mov     al, [da_fixmask]
        call    put_hex8
        call    crlf
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
; /T [lba] [/W]: time every INT 13h step of a DA window transaction.
;
; Each iteration runs the steps below back-to-back and accumulates the
; elapsed time of each (PIT-based clock, see timer_read), so a step that
; sits near one revolution (~200 ms) above its raw data time tells us the
; BIOS missed the sector it wanted and waited a full turn:
;   1 SET_LBA cmd write   (random rotational phase: wait for sector 0)
;   2 status read         right after the cmd write (sector 0 again)
;   3 read 8 data sectors right after a status read (tiny gap: sector 1)
;   4 status read         right after the data read (pre-index gap)
;   5 write 8 sectors     right after a status read      (/W only)
;   6 status read         right after the data write     (/W only)
;   7 SET_LBA cmd write   right after a status read
;   8 read 8 data sectors right after the cmd write
; The driver's read window is 1+8+4; its write window is 1+2+5+6.
; All steps use the same card LBA, so a lost command can never redirect
; the write-back (step 5 rewrites exactly the bytes step 3 read).
T_ITER          equ 16
PIT_PER_MS      equ 1193                ; 1.19318 MHz PIT clock

do_timing:
        call    da_begin
        call    da_read_status
        jc      tfail0
        mov     ax, [arg1]
        or      ax, [arg1+2]
        jnz     .have_lba
        call    find_data_lba           ; -> DX:AX
        jc      tfail0
        mov     [arg1], ax
        mov     [arg1+2], dx
.have_lba:
        mov     dx, msg_t_head
        call    puts
        mov     ax, [arg1]
        mov     dx, [arg1+2]
        call    put_dec32
        mov     dx, msg_t_head2
        call    puts
        mov     word [da_retry_cnt], 0
        call    timer_init
        mov     word [t_iter], T_ITER
.iter:
        ; 1: SET_LBA at a random rotational phase
        call    tm_start
        call    t_setlba
        mov     si, ph1
        call    tm_end
        jc      tfail
        ; 2: status read straight after the command write
        call    tm_start
        call    da_read_status
        mov     si, ph2
        call    tm_end
        jc      tfail
        mov     byte [t_lbaok], 1
        mov     ax, [da_buf+DAS_LBA_BASE]
        cmp     ax, [arg1]
        jne     .badlba
        mov     ax, [da_buf+DAS_LBA_BASE+2]
        cmp     ax, [arg1+2]
        je      .p3
.badlba:
        inc     word [t_badlba]
        mov     byte [t_lbaok], 0
.p3:    ; 3: data read straight after a status read
        call    tm_start
        call    t_read8
        mov     si, ph3
        call    tm_end
        jc      tfail
        ; 4: status read straight after the data read
        call    tm_start
        call    da_read_status
        mov     si, ph4
        call    tm_end
        jc      tfail
        cmp     byte [opt_w], 0
        je      .p7
        cmp     byte [t_lbaok], 0       ; never write on an unverified LBA
        je      .p7
        mov     al, [da_buf+DAS_WRITE_CNT]
        add     al, DA_NSEC
        mov     [want_wrcnt], al
        ; 5: data write-back straight after a status read
        call    tm_start
        call    t_write8
        mov     si, ph5
        call    tm_end
        jc      tfail
        ; 6: status read straight after the data write
        call    tm_start
        call    da_read_status
        mov     si, ph6
        call    tm_end
        jc      tfail
        mov     al, [da_buf+DAS_WRITE_CNT]
        cmp     al, [want_wrcnt]
        je      .p7
        inc     word [t_badwr]
.p7:    ; 7: command write straight after a status read
        call    tm_start
        call    t_setlba
        mov     si, ph7
        call    tm_end
        jc      tfail
        ; 8: data read straight after the command write (driver read path)
        call    tm_start
        call    t_read8
        mov     si, ph8
        call    tm_end
        jc      tfail
        mov     al, '.'
        call    putc
        dec     word [t_iter]
        jnz     .iter
        call    timer_restore
        call    da_end
        call    crlf
        ; per-step table
        mov     si, ph_table
        mov     cx, 8
.row:   push    cx
        mov     dx, [si]
        call    puts
        mov     bx, [si+2]
        cmp     byte [opt_w], 0
        jne     .have
        cmp     bx, ph5
        je      .skip
        cmp     bx, ph6
        je      .skip
.have:  call    print_rec
        jmp     .next
.skip:  mov     dx, msg_skipped
        call    puts
.next:  add     si, 4
        pop     cx
        loop    .row
        ; counters
        mov     dx, msg_t_retry
        call    puts
        mov     ax, [da_retry_cnt]
        call    put_dec16
        mov     dx, msg_t_badlba
        call    puts
        mov     ax, [t_badlba]
        call    put_dec16
        mov     dx, msg_t_badwr
        call    puts
        mov     ax, [t_badwr]
        call    put_dec16
        call    crlf
        ; derived driver windows
        mov     dx, msg_t_rdwin
        call    puts
        mov     ax, [ph1]
        mov     dx, [ph1+2]
        add     ax, [ph8]
        adc     dx, [ph8+2]
        add     ax, [ph4]
        adc     dx, [ph4+2]
        call    avg_ms
        call    print_window
        cmp     byte [opt_w], 0
        je      .hint
        mov     dx, msg_t_wrwin
        call    puts
        mov     ax, [ph1]
        mov     dx, [ph1+2]
        add     ax, [ph2]
        adc     dx, [ph2+2]
        add     ax, [ph5]
        adc     dx, [ph5+2]
        add     ax, [ph6]
        adc     dx, [ph6+2]
        call    avg_ms
        call    print_window
.hint:
        mov     dx, msg_t_hint
        call    puts
        xor     al, al
        jmp     exit

tfail:                                  ; AH = error, SI -> failed step
        push    ax
        call    timer_restore
        call    da_end
        call    crlf
        mov     dx, msg_t_step
        call    puts
        mov     ax, si
        sub     ax, ph1
        mov     cl, 3
        shr     ax, cl
        inc     ax
        call    put_dec16
        call    crlf
        pop     ax
        call    print_da_err
        mov     al, 1
        jmp     exit
tfail0:                                 ; failure during setup
        push    ax
        call    da_end
        pop     ax
        call    print_da_err
        mov     al, 1
        jmp     exit

t_setlba:
        mov     ax, [arg1]
        mov     dx, [arg1+2]
        jmp     da_set_lba
t_read8:
        push    ds
        pop     es
        mov     ax, 0x0200|DA_NSEC
        mov     bx, sec_buf
        mov     cl, 1
        jmp     da_data
t_write8:
        push    ds
        pop     es
        mov     ax, 0x0300|DA_NSEC
        mov     bx, sec_buf
        mov     cl, 1
        jmp     da_data

; find_data_lba: locate the card's FAT volume (MBR or superfloppy) and
; return DX:AX = first sector of its data area + 64: a sector that is
; either free space or ordinary file data, so writing back identical
; bytes there is harmless. CF set on failure (AH = code).
find_data_lba:
        xor     ax, ax
        xor     dx, dx
        call    da_set_lba
        jc      .out
        call    .rd1
        jc      .out
        xor     ax, ax                  ; assume superfloppy: volume at 0
        xor     dx, dx
        cmp     word [sec_buf+0x0B], SEC_SZ
        jne     .mbr
        cmp     byte [sec_buf+0x15], 0xF0
        jae     .vol
.mbr:   mov     si, sec_buf+0x1BE
        mov     cx, 4
.part:  mov     al, [si+4]
        cmp     al, 0x01
        je      .found
        cmp     al, 0x04
        je      .found
        cmp     al, 0x06
        je      .found
        cmp     al, 0x0B
        je      .found
        cmp     al, 0x0C
        je      .found
        cmp     al, 0x0E
        je      .found
        add     si, 16
        loop    .part
        mov     ah, 0xFD                ; no FAT volume on the card
        stc
        ret
.found: mov     ax, [si+8]
        mov     dx, [si+10]
        push    ax
        push    dx
        call    da_set_lba
        pop     dx
        pop     ax
        jc      .out
        push    ax
        push    dx
        call    .rd1
        pop     dx
        pop     ax
        jc      .out
.vol:   cmp     word [sec_buf+0x0B], SEC_SZ
        jne     .badvbr
        add     ax, [sec_buf+0x0E]      ; reserved sectors
        adc     dx, 0
        push    ax
        mov     ax, [sec_buf+0x11]      ; root entries * 32 / 512
        mov     cl, 4
        shr     ax, cl
        mov     bx, ax
        pop     ax
        add     ax, bx
        adc     dx, 0
        mov     bx, [sec_buf+0x16]      ; FAT size (FAT12/16)
        xor     cx, cx
        or      bx, bx
        jnz     .fats
        mov     bx, [sec_buf+0x24]      ; FAT32 size
        mov     cx, [sec_buf+0x26]
.fats:  push    cx
        mov     cl, [sec_buf+0x10]      ; number of FATs
        xor     ch, ch
        pop     si                      ; SI = fatsz hi
        jcxz    .badvbr
.fat:   add     ax, bx
        adc     dx, si
        loop    .fat
        add     ax, 64
        adc     dx, 0
        clc
.out:   ret
.badvbr:
        mov     ah, 0xFC                ; unreadable volume boot record
        stc
        ret
.rd1:   push    ds                      ; read 1 data sector into sec_buf
        pop     es
        mov     ax, 0x0201
        mov     bx, sec_buf
        mov     cl, 1
        jmp     da_data

; --- timing helpers -------------------------------------------------
; The BIOS runs PIT channel 0 in mode 3 (square wave), whose count is
; ambiguous within the 55 ms tick. Mode 2 keeps the 18.2 Hz interrupt
; rate but counts 65536..1 once per tick, so ticks*65536 + (65536-count)
; is a monotonic 1.19 MHz clock (Abrash's long-period Zen timer).
timer_init:
        mov     al, 0x34                ; ch0, lo/hi, mode 2, binary
        out     0x43, al
        xor     al, al
        out     0x40, al
        out     0x40, al
        ret
timer_restore:
        mov     al, 0x36                ; back to mode 3
        out     0x43, al
        xor     al, al
        out     0x40, al
        out     0x40, al
        ret

; timer_read: DX:AX = current clock (ticks : 65536-count). Preserves all
; other registers.
timer_read:
        push    bx
        push    es
        mov     ax, BDA_SEG
        mov     es, ax
        cli
        xor     al, al                  ; latch channel 0
        out     0x43, al
        in      al, 0x40
        mov     bl, al
        in      al, 0x40
        mov     bh, al                  ; BX = count
        mov     al, 0x0A                ; OCW3: read IRR
        out     0x20, al
        in      al, 0x20
        mov     dx, [es:BDA_TICKS]
        sti
        neg     bx                      ; 65536 - count
        test    al, 1                   ; IRQ0 pending = tick wrapped but
        jz      .ok                     ; the counter not yet bumped
        cmp     bx, 0x8000
        jae     .ok
        inc     dx
.ok:    mov     ax, bx
        pop     es
        pop     bx
        ret

tm_start:
        push    ax
        push    dx
        call    timer_read
        mov     [ts], ax
        mov     [ts+2], dx
        pop     dx
        pop     ax
        ret

; tm_end: SI -> record {sum dd, max dd}. Preserves AX and the flags.
tm_end:
        pushf
        push    ax
        push    dx
        call    timer_read
        sub     ax, [ts]
        sbb     dx, [ts+2]
        add     [si], ax
        adc     [si+2], dx
        cmp     dx, [si+6]
        jb      .done
        ja      .max
        cmp     ax, [si+4]
        jbe     .done
.max:   mov     [si+4], ax
        mov     [si+6], dx
.done:  pop     dx
        pop     ax
        popf
        ret

; div32: DX:AX / CX -> DX:AX quotient, BX remainder.
div32:
        push    si
        mov     si, ax
        mov     ax, dx
        xor     dx, dx
        div     cx                      ; AX = hi quotient
        mov     bx, ax
        mov     ax, si
        div     cx                      ; AX = lo quotient, DX = remainder
        xchg    bx, dx                  ; DX = hi quotient, BX = remainder
        pop     si
        ret

; avg_ms: DX:AX = sum of T_ITER samples in PIT units -> DX:AX in ms.
avg_ms:
        mov     cx, 4                   ; / T_ITER (16)
.s:     shr     dx, 1
        rcr     ax, 1
        loop    .s
        mov     cx, PIT_PER_MS
        jmp     div32

; print_rec: BX -> record; prints "avg / max ms".
print_rec:
        push    bx
        mov     ax, [bx]
        mov     dx, [bx+2]
        call    avg_ms                  ; (div32 clobbers BX)
        call    put_dec32
        mov     dx, msg_slash
        call    puts
        pop     bx
        mov     ax, [bx+4]
        mov     dx, [bx+6]
        mov     cx, PIT_PER_MS
        call    div32
        call    put_dec32
        mov     dx, msg_ms
        call    puts
        ret

; print_window: DX:AX = ms per 4KB window -> "nnn ms = nn.n KB/s".
print_window:
        push    ax
        call    put_dec32
        mov     dx, msg_ms_eq
        call    puts
        pop     cx
        or      cx, cx
        jz      .inst
        mov     ax, 40000               ; 4KB in ms -> KB/s x10
        xor     dx, dx
        div     cx
        mov     cx, 10
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
        ret
.inst:  mov     dx, msg_inst
        call    puts
        ret

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
        cmp     al, 'W'
        je      .write_ok
        mov     [mode], al
        cmp     al, 'L'
        je      .one_arg
        cmp     al, 'T'
        je      .one_arg
        cmp     al, 'C'
        je      .two_args
        jmp     .scan
.write_ok:
        mov     byte [opt_w], 1
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
; SI advances past the number. Stops (leaving 0) at the next switch, so
; an optional argument may be omitted: "/T /W".
parse_dec32:
        xor     ax, ax
        mov     [num], ax
        mov     [num+2], ax
.skip:
        lodsb
        cmp     al, 0x0D
        je      .end
        cmp     al, '/'
        je      .stop
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

put_dec32:                              ; DX:AX = dword
        push    ax
        push    bx
        push    cx
        push    dx
        mov     word [dcount], 0
.div:   mov     cx, 10
        call    div32                   ; DX:AX /= 10, BX = digit
        push    bx
        inc     word [dcount]
        mov     cx, ax
        or      cx, dx
        jnz     .div
.emit:  pop     ax
        add     al, '0'
        call    putc
        dec     word [dcount]
        jnz     .emit
        pop     dx
        pop     cx
        pop     bx
        pop     ax
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

; /T state
opt_w:      db 0                        ; /W: include the write-back steps
ts:         dd 0                        ; step start time
t_iter:     dw 0
t_lbaok:    db 0
t_badlba:   dw 0                        ; status showed a different lba_base
t_badwr:    dw 0                        ; write_cnt did not advance by 8
want_wrcnt: db 0
dcount:     dw 0
ph1:        dd 0, 0                     ; {sum, max} in PIT units
ph2:        dd 0, 0
ph3:        dd 0, 0
ph4:        dd 0, 0
ph5:        dd 0, 0
ph6:        dd 0, 0
ph7:        dd 0, 0
ph8:        dd 0, 0
ph_table:   dw msg_p1, ph1, msg_p2, ph2, msg_p3, ph3, msg_p4, ph4
            dw msg_p5, ph5, msg_p6, ph6, msg_p7, ph7, msg_p8, ph8

msg_probing: db 'GotekHDD DAPING 0.1 - probing Direct Access track...', 13, 10, '$'
msg_fixups: db 'BIOS fixups   : $'
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

msg_t_head: db 'DA step timing, 16 iterations at card LBA $'
msg_t_head2: db ' (avg / max ms)', 13, 10, '$'
msg_p1:     db ' 1 SET_LBA cmd write, random phase : $'
msg_p2:     db ' 2 status read after cmd write     : $'
msg_p3:     db ' 3 read 8 after status read        : $'
msg_p4:     db ' 4 status read after read 8        : $'
msg_p5:     db ' 5 write 8 after status read       : $'
msg_p6:     db ' 6 status read after write 8       : $'
msg_p7:     db ' 7 SET_LBA cmd write after status  : $'
msg_p8:     db ' 8 read 8 after cmd write          : $'
msg_slash:  db ' / $'
msg_ms:     db ' ms', 13, 10, '$'
msg_ms_eq:  db ' ms = $'
msg_inst:   db 'instant (emulator?)', 13, 10, '$'
msg_skipped: db 'skipped (add /W to write back the bytes read)', 13, 10, '$'
msg_t_retry: db 'INT 13h retries: $'
msg_t_badlba: db '   lba_base mismatches: $'
msg_t_badwr: db '   write_cnt mismatches: $'
msg_t_rdwin: db 'driver READ window  (1+8+4)   : $'
msg_t_wrwin: db 'driver WRITE window (1+2+5+6) : $'
msg_t_hint: db 'One revolution is ~200 ms (9 sectors of ~22 ms). A step that costs'
            db 13, 10, '~200 ms more than its sector count needs missed its sector and'
            db 13, 10, 'waited a full turn.', 13, 10, '$'
msg_t_step: db 'failed at step $'

sec_buf:    times SEC_SZ*DA_NSEC db 0
