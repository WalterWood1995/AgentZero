; gfx.asm - shared 32-bit framebuffer / frame-timing / text helpers for the
; ARCADE (arcade.asm) and WORM (worm.asm) kernels. Extracted from arcade.asm.
;   fill_rect/rect        : clipped solid rectangles on the VBE LFB
;   arc_text/arc_glyph    : ROM 8x8 font text at [t_x],[t_y], colour [t_col], scale [t_scale]
;   arc_wait_frame        : PIT ch0 60 fps frame sync (drains keyboard + serial debug)
;   arc_rand              : xorshift32 PRNG
;   arc_diag              : bottom-left 'K:<8042 status><scancode><count>' keyboard HUD
;   ser_*                 : COM1 debug output helpers (QEMU)
; The including file must define arc_serial_poll (called while waiting for the frame).

; ---------------------------------------------------------------------
; arc_wait_frame: block until ARC_FRAME PIT counts have elapsed since the
; previous frame boundary (remainder carried over -> 60 fps average). Keeps
; draining the keyboard and the serial debug line while waiting.
arc_wait_frame:
    pushad
.l:
    call kbd_drain
    call arc_serial_poll
    call pit_read
    movzx ebx, ax
    mov eax, [arc_prev]
    sub eax, ebx                   ; prev - cur (ch0 counts down)
    jns .nw
    add eax, 65536
.nw:
    add [arc_acc], eax
    mov [arc_prev], ebx
    cmp dword [arc_acc], ARC_FRAME
    jb  .l
    sub dword [arc_acc], ARC_FRAME
    cmp dword [arc_acc], ARC_FRAME ; way behind (slow frame)? drop the debt
    jb  .ok
    mov dword [arc_acc], 0
.ok:
    popad
    ret

; arc_rand: -> EAX = xorshift32
arc_rand:
    mov eax, [arc_rng]
    mov edx, eax
    shl eax, 13
    xor eax, edx
    mov edx, eax
    shr eax, 17
    xor eax, edx
    mov edx, eax
    shl eax, 5
    xor eax, edx
    mov [arc_rng], eax
    ret

; ---------------------------------------------------------------------
; fill_rect: [r_x],[r_y],[r_w],[r_h] (signed px) colour [r_col]; clipped to the
; screen. Preserves all registers.
fill_rect:
    pushad
    mov eax, [r_x]
    mov ebx, [r_w]
    cmp eax, 0
    jge .l1
    add ebx, eax
    xor eax, eax
.l1:
    mov ecx, [lfb_w]
    sub ecx, eax
    cmp ebx, ecx
    jle .l2
    mov ebx, ecx
.l2:
    cmp ebx, 0
    jle .q
    mov edx, [r_y]
    mov esi, [r_h]
    cmp edx, 0
    jge .t1
    add esi, edx
    xor edx, edx
.t1:
    mov ecx, [lfb_h]
    sub ecx, edx
    cmp esi, ecx
    jle .t2
    mov esi, ecx
.t2:
    cmp esi, 0
    jle .q
    mov edi, edx
    imul edi, dword [lfb_pitch]
    add edi, [lfb_phys]
    lea edi, [edi + eax*4]
    mov eax, [r_col]
.row:
    push edi
    mov ecx, ebx
    rep stosd
    pop edi
    add edi, [lfb_pitch]
    dec esi
    jnz .row
.q:
    popad
    ret

; rect helper: EAX=x EBX=y ECX=w EDX=h ESI=colour -> fill_rect
rect:
    mov [r_x], eax
    mov [r_y], ebx
    mov [r_w], ecx
    mov [r_h], edx
    mov [r_col], esi
    call fill_rect
    ret

; arc_text: ESI = asciiz, drawn at [t_x],[t_y] with [t_col], pixel scale
; [t_scale] using the ROM 8x8 font in font_buf. Advances t_x. Preserves regs.
arc_text:
    pushad
.c:
    lodsb
    test al, al
    jz  .d
    call arc_glyph
    mov eax, [t_scale]
    shl eax, 3
    add [t_x], eax
    jmp .c
.d:
    popad
    ret

; arc_glyph: AL = char at [t_x],[t_y]. Preserves regs.
arc_glyph:
    pushad
    movzx ebx, al
    shl ebx, 3
    add ebx, font_buf              ; glyph rows
    mov eax, [t_scale]
    mov [r_w], eax
    mov [r_h], eax
    mov eax, [t_col]
    mov [r_col], eax
    xor ecx, ecx                   ; gy
.gy:
    movzx edx, byte [ebx + ecx]
    mov eax, ecx
    imul eax, [t_scale]
    add eax, [t_y]
    mov [r_y], eax
    xor edi, edi                   ; gx
    mov ebp, 0x80                  ; bit mask (ebp survives fill_rect's pushad)
.gx:
    test edx, ebp
    jz  .skip
    mov eax, edi
    imul eax, [t_scale]
    add eax, [t_x]
    mov [r_x], eax
    call fill_rect
.skip:
    shr ebp, 1
    inc edi
    cmp edi, 8
    jb  .gx
    inc ecx
    cmp ecx, 8
    jb  .gy
    popad
    ret

; arc_num2: EAX = 0..99 -> two chars (leading space) drawn with arc_text
arc_num2:
    pushad
    xor edx, edx
    mov ecx, 10
    div ecx                        ; eax = tens, edx = ones
    add al, '0'
    test eax, 0x0F
    jnz .t
    mov al, ' '
.t:
    mov [numbuf], al
    add dl, '0'
    mov [numbuf+1], dl
    mov byte [numbuf+2], 0
    mov esi, numbuf
    call arc_text
    popad
    ret

; arc_text_centered: ESI = str, [t_y], [t_col], [t_scale]; centres on screen
arc_text_centered:
    pushad
    push esi
    xor ecx, ecx
.len:
    lodsb
    test al, al
    jz  .l
    inc ecx
    jmp .len
.l:
    pop esi
    mov eax, [t_scale]
    shl eax, 3
    imul eax, ecx                  ; text width
    mov ebx, [lfb_w]
    sub ebx, eax
    sar ebx, 1
    mov [t_x], ebx
    call arc_text
    popad
    ret


; ---------------------------------------------------------------------
; on-screen diagnostics (bottom-left): "K:<status><scancode><bytes>"
arc_diag:
    mov al, [kbd_last_status]
    mov ah, [kbd_last_sc]
    mov edx, [kbd_byte_count]
    shl edx, 16
    movzx eax, ax
    or  eax, edx
    cmp eax, [diag_last]
    je  .q
    mov [diag_last], eax
    ; build the string
    mov edi, diag_buf
    mov byte [edi], 'K'
    mov byte [edi+1], ':'
    add edi, 2
    mov al, [kbd_last_status]
    call hex2_to_edi
    mov byte [edi], ' '
    inc edi
    mov al, [kbd_last_sc]
    call hex2_to_edi
    mov byte [edi], ' '
    inc edi
    mov al, [kbd_byte_count+1]
    call hex2_to_edi
    mov al, [kbd_byte_count]
    call hex2_to_edi
    mov byte [edi], 0
    ; erase + draw
    mov eax, 8
    mov ebx, [lfb_h]
    sub ebx, 24
    mov ecx, 14 * 16
    mov edx, 16
    mov esi, C_BLACK
    call rect
    mov dword [t_x], 8
    mov eax, [lfb_h]
    sub eax, 24
    mov [t_y], eax
    mov dword [t_scale], 2
    mov dword [t_col], C_DIM
    mov esi, diag_buf
    call arc_text
.q:
    ret

; hex2_to_edi: AL -> two hex chars at [EDI], EDI += 2
hex2_to_edi:
    push eax
    push eax
    shr al, 4
    call .n
    pop eax
    call .n
    pop eax
    ret
.n:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .e
    add al, 7
.e:
    mov [edi], al
    inc edi
    ret


ser_puts:
    push eax
    push esi
.l:
    lodsb
    test al, al
    jz  .d
    call putc
    jmp .l
.d:
    pop esi
    pop eax
    ret
ser_nl:
    push eax
    mov al, 13
    call putc
    mov al, 10
    call putc
    pop eax
    ret
ser_hex8:
    push eax
    push eax
    shr al, 4
    call .n
    pop eax
    call .n
    pop eax
    ret
.n:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .e
    add al, 7
.e:
    call putc
    ret
ser_hex32:
    push eax
    push ecx
    mov ecx, 4
.l:
    rol eax, 8
    call ser_hex8
    dec ecx
    jnz .l
    pop ecx
    pop eax
    ret

; ---- shared data ----
numbuf      db 0, 0, 0, 0
diag_buf    times 24 db 0
arc_rng     dd 0x12345678
arc_prev    dd 0
arc_acc     dd 0
diag_last   dd 0xFFFFFFFF
r_x         dd 0
r_y         dd 0
r_w         dd 0
r_h         dd 0
r_col       dd 0
t_x         dd 0
t_y         dd 0
t_col       dd 0
t_scale     dd 1
