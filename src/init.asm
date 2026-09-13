; init.asm - GOTEKHDD.SYS INIT command (discardable).
;
; Locates the image file on the SD card through the DA protocol, builds
; the extent table, extracts the image partition's BPB, and returns one
; unit to DOS. On any failure returns zero units so the driver unloads.
;
; Entered from the dispatcher with ES:BX -> request packet, DS = CS.
; Returns AX = status word.

; ---------------------------------------------------------------------
init:
        mov     dx, i_banner
        call    iputs

        ; pick the bounce-buffer half that cannot cross a 64KB physical
        ; DMA boundary at this load address
        mov     ax, cs
        mov     cl, 4
        shl     ax, cl
        add     ax, bounce_buf          ; phys & 0xFFFF
        cmp     ax, 0x10000-SEC_SZ
        jbe     .bounce_ok
        mov     word [bounce_off], bounce_buf+SEC_SZ
.bounce_ok:

        mov     al, [es:bx+REQ_DRIVE]   ; drive letter for the summary
        add     al, 'A'
        mov     [i_drive], al

        call    da_autofix              ; XT vs AT BIOS fixup set
                                        ; (overridable with /X and /A)

        ; --- copy and parse the CONFIG.SYS command line ---------------
        push    ds
        lds     si, [es:bx+REQ_CMDLINE]
        push    cs
        pop     es
        mov     di, i_line
        mov     cx, 127
.copy:  lodsb
        stosb
        cmp     al, 0x0D
        je      .copied
        cmp     al, 0x0A
        je      .copied
        or      al, al
        je      .copied
        loop    .copy
.copied:
        mov     byte [es:di-1], 0
        pop     ds
        call    parse_line

        ; --- probe the DA track ---------------------------------------
        call    da_begin
        call    da_read_status
        jnc     .have_da
        mov     dx, i_e_noda
        jmp     init_fail
.have_da:

        ; --- find the card's FAT volume -------------------------------
        xor     ax, ax
        xor     dx, dx
        call    iread_sector            ; card LBA 0 -> i_sec
        jc      init_fail_io
        mov     word [i_volbase], 0
        mov     word [i_volbase+2], 0
        cmp     word [i_sec+510], 0xAA55
        jne     .bad_card
        cmp     word [i_sec+11], SEC_SZ ; looks like a VBR already?
        jne     .scan_mbr
        mov     al, [i_sec+21]          ; media descriptor
        cmp     al, 0xF0
        jae     .have_vol               ; superfloppy card
.scan_mbr:
        mov     si, i_sec+0x1BE
        mov     cx, 4
.part:  mov     al, [si+4]              ; partition type
        cmp     al, 0x01
        je      .fat
        cmp     al, 0x04
        je      .fat
        cmp     al, 0x06
        je      .fat
        cmp     al, 0x0B
        je      .fat
        cmp     al, 0x0C
        je      .fat
        cmp     al, 0x0E
        je      .fat
        add     si, 16
        loop    .part
.bad_card:
        mov     dx, i_e_nofat
        jmp     init_fail
.fat:
        mov     ax, [si+8]
        mov     [i_volbase], ax
        mov     ax, [si+10]
        mov     [i_volbase+2], ax
        mov     ax, [i_volbase]
        mov     dx, [i_volbase+2]
        call    iread_sector            ; card volume VBR
        jc      init_fail_io
.have_vol:

        ; --- parse the card volume's BPB ------------------------------
        cmp     word [i_sec+11], SEC_SZ
        jne     .bad_card
        mov     al, [i_sec+13]          ; sectors per cluster
        mov     [i_spc], al
        xor     cx, cx                  ; log2(spc)
.log2:  shr     al, 1
        jz      .logdone
        inc     cx
        jmp     .log2
.logdone:
        mov     [i_spc_shift], cl
        ; fat_start = volbase + reserved
        mov     ax, [i_sec+14]
        xor     dx, dx
        add     ax, [i_volbase]
        adc     dx, [i_volbase+2]
        mov     [i_fatstart], ax
        mov     [i_fatstart+2], dx
        ; fatsz (16- or 32-bit), fat type flag
        mov     byte [i_fat32], 0
        mov     ax, [i_sec+22]          ; fatsz16
        xor     dx, dx
        or      ax, ax
        jnz     .fatsz_ok
        mov     byte [i_fat32], 1
        mov     ax, [i_sec+0x24]        ; fatsz32
        mov     dx, [i_sec+0x26]
.fatsz_ok:
        ; root_start = fat_start + nfats * fatsz
        mov     cl, [i_sec+16]          ; number of FATs (1 or 2)
        mov     si, ax                  ; SI:DI = nfats*fatsz accumulator
        mov     di, dx
        dec     cl
        jz      .one_fat
        add     si, ax
        adc     di, dx                  ; x2 (nfats is 1 or 2)
.one_fat:
        mov     ax, [i_fatstart]
        mov     dx, [i_fatstart+2]
        add     ax, si
        adc     dx, di
        mov     [i_rootstart], ax
        mov     [i_rootstart+2], dx
        ; root_secs = root_entries / 16 (0 on FAT32)
        mov     ax, [i_sec+17]
        mov     cl, 4
        shr     ax, cl
        mov     [i_rootsecs], ax
        ; data_start = root_start + root_secs
        xor     dx, dx
        add     ax, [i_rootstart]
        adc     dx, [i_rootstart+2]
        mov     [i_datastart], ax
        mov     [i_datastart+2], dx
        ; FAT32 root dir start cluster
        mov     ax, [i_sec+0x2C]
        mov     [i_rootclus], ax
        mov     ax, [i_sec+0x2E]
        mov     [i_rootclus+2], ax

        ; reject FAT12 cards: the chain walker reads 16-bit entries.
        ; clusters = (total - (data_start - volbase)) >> spc_shift
        cmp     byte [i_fat32], 0
        jne     .fat_ok
        mov     ax, [i_sec+19]          ; total sectors (16-bit field)
        xor     dx, dx
        or      ax, ax
        jnz     .tot
        mov     ax, [i_sec+0x20]        ; 32-bit total
        mov     dx, [i_sec+0x22]
.tot:
        sub     ax, [i_datastart]
        sbb     dx, [i_datastart+2]
        add     ax, [i_volbase]
        adc     dx, [i_volbase+2]
        mov     cl, [i_spc_shift]
        or      cl, cl
        jz      .noshr2
.shr2:  shr     dx, 1
        rcr     ax, 1
        dec     cl
        jnz     .shr2
.noshr2:
        or      dx, dx
        jnz     .fat_ok
        cmp     ax, 4085
        jae     .fat_ok
        mov     dx, i_e_fat12
        jmp     init_fail
.fat_ok:

        ; --- find the image file in the root directory ----------------
        call    find_file
        jnc     .found
        mov     dx, i_e_noimg
        jmp     init_fail
.found:

        ; --- build the extent table from the FAT chain ----------------
        call    build_extents
        jc      init_fail               ; DX already -> message

        ; --- image MBR: locate the partition --------------------------
        xor     ax, ax
        xor     dx, dx
        call    iread_img_sector
        jc      init_fail_io
        cmp     word [i_sec+510], 0xAA55
        jne     .bad_img
        mov     si, i_sec+0x1BE
        mov     cx, 4
.ipart: mov     al, [si+4]
        cmp     al, 0x01
        je      .ifat
        cmp     al, 0x04
        je      .ifat
        cmp     al, 0x06
        je      .ifat
        cmp     al, 0x0E
        je      .ifat
        add     si, 16
        loop    .ipart
.bad_img:
        mov     dx, i_e_badimg
        jmp     init_fail
.ifat:
        mov     ax, [si+8]
        mov     [part_start], ax
        mov     ax, [si+10]
        mov     [part_start+2], ax
        mov     ax, [si+12]              ; partition sector count
        mov     [i_partsecs], ax
        mov     ax, [si+14]
        mov     [i_partsecs+2], ax

        ; --- image VBR: capture the BPB --------------------------------
        mov     ax, [part_start]
        mov     dx, [part_start+2]
        call    iread_img_sector
        jc      init_fail_io
        cmp     word [i_sec+11], SEC_SZ
        jne     .bad_img
        mov     si, i_sec+11
        mov     di, bpb
        mov     cx, 25
        push    cs
        pop     es
        rep movsb
        ; total_vsecs = BPB total16 or total32, clamped to the partition
        mov     ax, [i_sec+19]
        xor     dx, dx
        or      ax, ax
        jnz     .tot_ok
        mov     ax, [i_sec+0x20]
        mov     dx, [i_sec+0x22]
.tot_ok:
        cmp     dx, [i_partsecs+2]
        jb      .tot_fits
        ja      .tot_clamp
        cmp     ax, [i_partsecs]
        jbe     .tot_fits
.tot_clamp:
        mov     ax, [i_partsecs]
        mov     dx, [i_partsecs+2]
.tot_fits:
        mov     [total_vsecs], ax
        mov     [total_vsecs+2], dx

        call    da_end

        ; --- summary + INIT return ------------------------------------
        mov     dx, i_ok1
        call    iputs
        mov     ax, [total_vsecs]       ; sectors -> MB (>>11)
        mov     dx, [total_vsecs+2]
        mov     cx, 11
.mb:    shr     dx, 1
        rcr     ax, 1
        loop    .mb
        call    iputdec
        mov     dx, i_ok2
        call    iputs
        mov     ax, [ext_count]
        call    iputdec
        mov     dx, i_ok3
        call    iputs
        mov     dl, [i_drive]
        mov     ah, 0x02
        int     0x21
        mov     dx, i_ok4
        call    iputs

        les     bx, [req_ptr]
        mov     byte [es:bx+REQ_NUNITS], 1
        mov     word [es:bx+REQ_BRK], init_start
        mov     [es:bx+REQ_BRK+2], cs
        mov     word [es:bx+REQ_CMDLINE], bpb_array
        mov     [es:bx+REQ_CMDLINE+2], cs
        mov     ax, ST_DONE
        ret

init_fail_io:
        mov     dx, i_e_io
init_fail:
        push    dx
        call    da_end
        pop     dx
        call    iputs
        les     bx, [req_ptr]
        mov     byte [es:bx+REQ_NUNITS], 0
        mov     word [es:bx+REQ_BRK], 0
        mov     [es:bx+REQ_BRK+2], cs
        mov     ax, ST_DONE
        ret

; ---------------------------------------------------------------------
; iread_sector: read card sector DX:AX into i_sec via the resident
; window machinery. CF on failure.
iread_sector:
        mov     [io_lba], ax
        mov     [io_lba+2], dx
        mov     byte [rw_op], 2
        mov     byte [rw_n], 1
        mov     byte [rw_bounce], 0
        mov     word [rw_buf], i_sec
        mov     [rw_buf+2], cs
        jmp     card_io

; iread_img_sector: read image-relative sector DX:AX into i_sec.
iread_img_sector:
        call    extent_lookup
        jc      .bad
        jmp     iread_sector
.bad:   ret

; ---------------------------------------------------------------------
; parse_line: scan i_line for /F=..., /U=n, /V. Fills i_name (11 chars).
parse_line:
        mov     si, i_line
.scan:  lodsb
        or      al, al
        jz      .done
        cmp     al, '/'
        jne     .scan
        lodsb
        and     al, 0xDF
        cmp     al, 'V'
        jne     .not_v
        mov     byte [verbose], 1
        jmp     .scan
.not_v:
        cmp     al, 'A'                 ; force full (AT) BIOS fixups
        jne     .not_a
        mov     byte [da_fixmask], FIX_ALL
        jmp     .scan
.not_a:
        cmp     al, 'X'                 ; force XT fixups (DPT only)
        jne     .not_x
        mov     byte [da_fixmask], FIX_XT
        jmp     .scan
.not_x:
        cmp     al, 'U'
        jne     .not_u
        lodsb                           ; expect '=' or ':'
        lodsb
        sub     al, '0'
        cmp     al, 1
        ja      .scan
        mov     [da_unit], al
        jmp     .scan
.not_u:
        cmp     al, 'F'
        jne     .scan
        lodsb                           ; '=' or ':'
        ; parse 8.3 name into i_name
        mov     di, i_name
        push    cx
        mov     cx, 11
        mov     al, ' '
.blank: mov     [di], al
        inc     di
        loop    .blank
        pop     cx
        mov     di, i_name
        mov     bx, i_name+8            ; base-name limit
.nm:    lodsb
        or      al, al
        jz      .nm_done
        cmp     al, ' '
        je      .nm_done
        cmp     al, '.'
        jne     .nm_ch
        mov     di, i_name+8            ; jump to extension
        mov     bx, i_name+11
        jmp     .nm
.nm_ch: cmp     di, bx
        jae     .nm                     ; overflow: ignore extra chars
        cmp     al, 'a'
        jb      .nm_st
        cmp     al, 'z'
        ja      .nm_st
        and     al, 0xDF
.nm_st: mov     [di], al
        inc     di
        jmp     .nm
.nm_done:
        dec     si
        jmp     .scan
.done:  ret

; ---------------------------------------------------------------------
; find_file: locate i_name in the card volume's root directory.
; Out: CF clear, [i_filecl] = first cluster, [i_filesz] = size in bytes.
find_file:
        cmp     byte [i_fat32], 0
        jne     .fat32

        ; FAT12/16 fixed root directory
        mov     ax, [i_rootstart]
        mov     dx, [i_rootstart+2]
        mov     cx, [i_rootsecs]
.sec16: push    cx
        push    ax
        push    dx
        call    iread_sector
        jc      .pop_fail
        call    scan_dir_sector
        jnc     .pop_found
        pop     dx
        pop     ax
        pop     cx
        add     ax, 1
        adc     dx, 0
        loop    .sec16
        stc
        ret

.fat32:
        mov     ax, [i_rootclus]
        mov     dx, [i_rootclus+2]
.clus:  ; sector range of this cluster
        call    clus_to_lba             ; DX:AX -> DX:AX first sector
        jc      .fail
        mov     cl, [i_spc]
        xor     ch, ch
.csec:  push    cx
        push    ax
        push    dx
        call    iread_sector
        jc      .pop_fail
        call    scan_dir_sector
        jnc     .pop_found
        pop     dx
        pop     ax
        pop     cx
        add     ax, 1
        adc     dx, 0
        loop    .csec
        ; next cluster in the root chain
        mov     ax, [i_curclus]
        mov     dx, [i_curclus+2]
        call    fat_next
        jc      .fail
        cmp     dx, 0x0FFF
        jne     .not_end
        cmp     ax, 0xFFF8
        jae     .fail
.not_end:
        jmp     .clus

.pop_found:
        pop     dx
        pop     ax
        pop     cx
        clc
        ret
.pop_fail:
        pop     dx
        pop     ax
        pop     cx
.fail:  stc
        ret

; clus_to_lba: DX:AX = cluster -> DX:AX = card sector of its first
; sector; also remembers the cluster in i_curclus. CF on bad cluster.
clus_to_lba:
        mov     [i_curclus], ax
        mov     [i_curclus+2], dx
        sub     ax, 2
        sbb     dx, 0
        jc      .bad
        mov     cl, [i_spc_shift]
        or      cl, cl
        jz      .noshift
.sh:    shl     ax, 1
        rcl     dx, 1
        dec     cl
        jnz     .sh
.noshift:
        add     ax, [i_datastart]
        adc     dx, [i_datastart+2]
        clc
        ret
.bad:   stc
        ret

; scan_dir_sector: look for i_name among the 16 entries in i_sec.
; Out: CF clear + i_filecl/i_filesz filled if found. Also CF set with
; ZF... (end-of-dir is treated as plain not-found; harmless extra scan).
scan_dir_sector:
        mov     si, i_sec
        mov     cx, 16
.ent:   cmp     byte [si], 0            ; end of directory
        je      .no
        cmp     byte [si], 0xE5         ; deleted
        je      .next
        test    byte [si+11], 0x18      ; dir or volume label
        jnz     .next
        push    cx
        push    si
        mov     di, i_name
        mov     cx, 11
.cmp:   mov     al, [si]
        cmp     al, [di]
        jne     .nomatch
        inc     si
        inc     di
        loop    .cmp
        pop     si
        pop     cx
        ; matched: first cluster (FAT32 high word at +20), size at +28
        mov     ax, [si+26]
        mov     [i_filecl], ax
        xor     ax, ax
        cmp     byte [i_fat32], 0
        je      .lo
        mov     ax, [si+20]
.lo:    mov     [i_filecl+2], ax
        mov     ax, [si+28]
        mov     [i_filesz], ax
        mov     ax, [si+30]
        mov     [i_filesz+2], ax
        clc
        ret
.nomatch:
        pop     si
        pop     cx
.next:  add     si, 32
        loop    .ent
.no:    stc
        ret

; ---------------------------------------------------------------------
; fat_next: DX:AX = cluster -> DX:AX = next cluster (FAT32 masked to 28
; bits). CF on I/O error. Caches one FAT sector in i_fatbuf.
fat_next:
        push    bx
        push    cx
        cmp     byte [i_fat32], 0
        jne     .f32
        ; FAT16: sector = fatstart + cl>>8, entry = word[(cl&FF)*2]
        mov     bx, ax
        mov     al, ah
        xor     ah, ah                  ; cl >> 8
        xor     dx, dx
        call    fat_load
        jc      .out
        mov     al, bl
        xor     ah, ah
        shl     ax, 1
        mov     bx, ax
        mov     ax, [i_fatbuf+bx]
        xor     dx, dx
        clc
        jmp     .out
.f32:
        ; FAT32: sector = fatstart + cl>>7, entry = dword[(cl&7F)*4]
        mov     bx, ax                  ; keep low word
        mov     cx, 7
.shr:   shr     dx, 1
        rcr     ax, 1
        loop    .shr
        call    fat_load
        jc      .out
        mov     ax, bx
        and     ax, 0x7F
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     ax, [i_fatbuf+bx]
        mov     dx, [i_fatbuf+bx+2]
        and     dx, 0x0FFF              ; 28-bit cluster numbers
        clc
.out:
        pop     cx
        pop     bx
        ret

; fat_load: ensure FAT sector index DX:AX (relative to fatstart) is in
; i_fatbuf. Preserves BX, CX. CF on error.
fat_load:
        add     ax, [i_fatstart]
        adc     dx, [i_fatstart+2]
        cmp     ax, [i_fatcur]
        jne     .load
        cmp     dx, [i_fatcur+2]
        jne     .load
        clc
        ret
.load:
        push    bx
        push    cx
        mov     [i_fatcur], ax
        mov     [i_fatcur+2], dx
        mov     [io_lba], ax
        mov     [io_lba+2], dx
        mov     byte [rw_op], 2
        mov     byte [rw_n], 1
        mov     byte [rw_bounce], 0
        mov     word [rw_buf], i_fatbuf
        mov     [rw_buf+2], cs
        call    card_io
        pop     cx
        pop     bx
        jnc     .ok
        mov     word [i_fatcur], 0xFFFF ; invalidate
        mov     word [i_fatcur+2], 0xFFFF
        stc
.ok:    ret

; ---------------------------------------------------------------------
; build_extents: walk the file's cluster chain, coalescing runs.
; Out: CF set with DX -> error message on failure.
build_extents:
        ; iterations = ceil(file sectors / spc); file sectors =
        ; ceil(size/512)
        mov     ax, [i_filesz]
        mov     dx, [i_filesz+2]
        add     ax, 511
        adc     dx, 0
        mov     cx, 9
.s9:    shr     dx, 1
        rcr     ax, 1
        loop    .s9
        or      ax, ax
        jnz     .nz
        or      dx, dx
        jz      .empty
.nz:
        mov     cl, [i_spc_shift]
        or      cl, cl
        jz      .noshr
.shp:   shr     dx, 1
        rcr     ax, 1
        adc     ax, 0                   ; round up on carry-out
        adc     dx, 0
        dec     cl
        jnz     .shp
.noshr:
        mov     [i_clusleft], ax
        mov     [i_clusleft+2], dx
        mov     word [ext_count], 0
        mov     word [i_filesec], 0
        mov     word [i_filesec+2], 0
        mov     ax, [i_filecl]
        mov     dx, [i_filecl+2]
.walk:
        ; sanity: cluster >= 2
        or      dx, dx
        jnz     .cl_ok
        cmp     ax, 2
        jb      .badchain
.cl_ok:
        push    ax
        push    dx
        call    clus_to_lba             ; DX:AX = card lba of cluster
        jc      .badchain_pop
        call    ext_add
        jc      .toofrag_pop
        pop     dx
        pop     ax
        ; done all clusters?
        push    ax
        push    dx
        mov     ax, [i_clusleft]
        mov     dx, [i_clusleft+2]
        sub     ax, 1
        sbb     dx, 0
        mov     [i_clusleft], ax
        mov     [i_clusleft+2], dx
        or      ax, dx
        pop     dx
        pop     ax
        jz      .done
        call    fat_next
        jnc     .walk
        mov     dx, i_e_io
        stc
        ret
.done:
        clc
        ret
.empty:
        mov     dx, i_e_badimg
        stc
        ret
.badchain_pop:
        pop     dx
        pop     ax
.badchain:
        mov     dx, i_e_chain
        stc
        ret
.toofrag_pop:
        pop     dx
        pop     ax
        mov     dx, i_e_frag
        stc
        ret

; ext_add: append cluster at card LBA DX:AX (spc sectors starting at
; file sector i_filesec) to the extent table, coalescing with the
; previous run when contiguous. CF when the table is full.
ext_add:
        push    si
        mov     si, [ext_count]
        or      si, si
        jz      .new
        ; last extent end = card + count
        push    ax
        push    dx
        mov     ax, si
        dec     ax
        mov     dx, EXT_SIZE
        push    dx
        mul     dl                      ; AX = (count-1)*12 (fits: 31*12)
        pop     dx
        mov     si, ax
        add     si, ext_table
        mov     ax, [si+4]
        mov     dx, [si+4+2]
        add     ax, [si+8]
        adc     dx, [si+8+2]
        pop     cx                      ; original DX (lba high)
        cmp     dx, cx
        pop     dx                      ; original AX (lba low) -> DX tmp
        jne     .newkeep
        cmp     ax, dx
        jne     .newkeep
        ; contiguous: count += spc
        mov     al, [i_spc]
        xor     ah, ah
        add     [si+8], ax
        adc     word [si+8+2], 0
        jmp     .advance
.newkeep:
        mov     ax, dx                  ; restore lba low
        mov     dx, cx                  ; restore lba high
.new:
        cmp     word [ext_count], MAX_EXTENTS
        jae     .full
        push    ax
        mov     ax, [ext_count]
        push    dx
        mov     dx, EXT_SIZE
        mul     dl
        pop     dx
        mov     si, ax
        add     si, ext_table
        pop     ax
        mov     [si+4], ax              ; card lba
        mov     [si+4+2], dx
        mov     ax, [i_filesec]
        mov     [si], ax
        mov     ax, [i_filesec+2]
        mov     [si+2], ax
        mov     al, [i_spc]
        xor     ah, ah
        mov     [si+8], ax
        mov     word [si+8+2], 0
        inc     word [ext_count]
.advance:
        mov     al, [i_spc]
        xor     ah, ah
        add     [i_filesec], ax
        adc     word [i_filesec+2], 0
        clc
        pop     si
        ret
.full:
        stc
        pop     si
        ret

; ---------------------------------------------------------------------
; init-time output helpers
iputs:
        mov     ah, 0x09
        int     0x21
        ret

iputdec:                                ; AX decimal
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
.e:     pop     dx
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        loop    .e
        pop     dx
        pop     cx
        pop     bx
        ret

; ---------------------------------------------------------------------
; INIT data (all discarded)
i_banner:   db 13, 10, 'GotekHDD 0.1 - FlashFloppy Direct Access disk', 13, 10, '$'
i_e_noda:   db 'GotekHDD: no Direct Access track (FlashFloppy with SD card required)', 13, 10, '$'
i_e_io:     db 'GotekHDD: card I/O error', 13, 10, '$'
i_e_nofat:  db 'GotekHDD: no FAT volume on the card', 13, 10, '$'
i_e_fat12:  db 'GotekHDD: FAT12 card not supported - use FAT16/FAT32', 13, 10, '$'
i_e_noimg:  db 'GotekHDD: image file not found in card root directory', 13, 10, '$'
i_e_frag:   db 'GotekHDD: image too fragmented - re-copy it to the card', 13, 10, '$'
i_e_chain:  db 'GotekHDD: bad FAT chain for image file', 13, 10, '$'
i_e_badimg: db 'GotekHDD: image has no FAT12/16 MBR partition', 13, 10, '$'
i_ok1:      db 'GotekHDD: mounted $'
i_ok2:      db 'MB image ($'
i_ok3:      db ' extents) as $'
i_ok4:      db ':', 13, 10, '$'

i_drive:    db '?'
i_name:     db 'GOTEKHDD', 'IMG'        ; 11-char 8.3, default
i_volbase:  dd 0
i_spc:      db 1
i_spc_shift: db 0
i_fat32:    db 0
i_fatstart: dd 0
i_rootstart: dd 0
i_rootsecs: dw 0
i_datastart: dd 0
i_rootclus: dd 0
i_curclus:  dd 0
i_filecl:   dd 0
i_filesz:   dd 0
i_filesec:  dd 0
i_clusleft: dd 0
i_partsecs: dd 0
i_fatcur:   dd 0xFFFFFFFF
i_line:     times 128 db 0
i_fatbuf:   times SEC_SZ db 0
i_sec:      times SEC_SZ db 0
