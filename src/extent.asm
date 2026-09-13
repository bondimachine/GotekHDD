; extent.asm - map image-file sectors to SD-card LBAs through the extent
; table built at INIT from the file's FAT cluster chain.
;
; extent_lookup:
;   In:  DX:AX = image-relative sector number.
;   Out: CF clear: DX:AX = card LBA, CX = sectors remaining in this run
;        (clamped to 255 so callers can treat it as a small number).
;        CF set: sector is beyond the mapped file.
; Clobbers: SI. Assumes DS = CS.

extent_lookup:
        push    bx
        push    di
        mov     si, ext_table
        mov     di, [ext_count]
        or      di, di
        jz      .notfound
.scan:
        ; sector < ext.start ?
        cmp     dx, [si+2]              ; high words (start is dword at +0)
        jb      .next
        ja      .ge_start
        cmp     ax, [si]
        jb      .next
.ge_start:
        ; off = sector - start
        push    ax
        push    dx
        sub     ax, [si]
        sbb     dx, [si+2]
        ; off < count ?
        cmp     dx, [si+8+2]
        jb      .hit
        ja      .miss
        cmp     ax, [si+8]
        jb      .hit
.miss:
        pop     dx
        pop     ax
.next:
        add     si, EXT_SIZE
        dec     di
        jnz     .scan
.notfound:
        pop     di
        pop     bx
        stc
        ret
.hit:
        ; CX = min(count - off, 255)
        mov     cx, [si+8]
        mov     bx, [si+8+2]
        sub     cx, ax
        sbb     bx, dx
        jnz     .clamp                  ; high word nonzero: huge run
        cmp     cx, 255
        jbe     .cx_ok
.clamp:
        mov     cx, 255
.cx_ok:
        ; card LBA = ext.card + off
        add     ax, [si+4]
        adc     dx, [si+4+2]
        add     sp, 4                   ; drop saved off inputs
        pop     di
        pop     bx
        clc
        ret
