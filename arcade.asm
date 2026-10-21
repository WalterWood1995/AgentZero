; arcade.asm - AgentZero game console (included by stage2.asm when built with
; ARCADE=1). 32-bit protected mode, ring 0, no OS, no interrupts.
;
;   input  : PS/2 keyboard polled through the 8042 (kbd_drain -> key_state[])
;   tick   : PIT channel 0 free-running counter, fixed 60 fps frame sync
;   output : VBE linear framebuffer (32 bpp BGRX), rectangles + the ROM 8x8 font
;
; Games (all original, no third-party assets):
;   PONG  - P1 W/S, P2 Up/Down. First to 7.
;   FIGHT - P1 A/D move, W jump, F punch. P2 Left/Right, Up jump, Enter punch.
;           Health bars, knockback, stun, KO.
; Menu: '1' = Pong, '2' = Fight, Esc = back to the menu, Space = again (after a win).
;
; Debug: with a serial port (QEMU) 'H' on COM1 lists the held scancodes and 'G'
; dumps the game state as hex. Without one (the real Asus) a small HUD in the
; bottom-left corner shows 8042 status / last scancode / byte count.

ARC_FRAME   equ 19886              ; PIT ch0 counts per frame (1193182 / 60)
C_BLACK     equ 0x00000000
C_WHITE     equ 0x00FFFFFF
C_GREY      equ 0x00606060
C_DIM       equ 0x00303030
C_GREEN     equ 0x0000FF00
C_RED       equ 0x00FF3030
C_BLUE      equ 0x004090FF
C_YELLOW    equ 0x00FFE040
C_SKIN      equ 0x00FFD0A0

; scancodes (set 1; 0x80|code = E0-prefixed)
K_ESC   equ 0x01
K_1     equ 0x02
K_2     equ 0x03
K_W     equ 0x11
K_S     equ 0x1F
K_A     equ 0x1E
K_D     equ 0x20
K_F     equ 0x21
K_SPACE equ 0x39
K_ENTER equ 0x1C
K_KP0   equ 0x52
K_UP    equ 0xC8
K_DOWN  equ 0xD0
K_LEFT  equ 0xCB
K_RIGHT equ 0xCD

; pong geometry
P_W     equ 16
P_H     equ 96
B_S     equ 16
P1X     equ 40
PADDLE_SPEED equ 8
WIN_SCORE equ 7

; fight geometry
FLOOR   equ 620
F_W     equ 48                     ; body width
F_H     equ 100                    ; body height (head + torso)
ARM_L   equ 44
ARM_H   equ 14
F_SPEED equ 6
JUMP_V  equ 18
PUNCH_T equ 8
PUNCH_CD equ 24
STUN_T  equ 12
KNOCK   equ 30
DMG     equ 8

; fighter struct offsets
FX   equ 0
FY   equ 4                         ; height above the floor
VY   equ 8
FACE equ 12                        ; 1 = faces right, -1 = faces left
HP   equ 16
ATK  equ 20                        ; frames of active punch left
CD   equ 24                        ; punch cooldown
STUN equ 28
HIT  equ 32                        ; this punch already landed
PX   equ 36                        ; last drawn x/y (for erase)
PY   equ 40
COL  equ 44
KL   equ 48                        ; key codes: left / right / jump / punch / punch alt
KR   equ 52
KJ   equ 56
KP   equ 60
KP2  equ 64
F_SIZE equ 68

; =====================================================================
arcade_pm:
    call pit_init
    call uart_detect
    call kbd_init
    cmp byte [vbe_ok], 0
    je  .novbe
    mov eax, [lfb_pitch]
    mul dword [lfb_h]
    mov [fb_size], eax
    rdtsc
    or  eax, 1
    mov [arc_rng], eax
    call pit_read
    movzx eax, ax
    mov [arc_prev], eax
    mov dword [arc_acc], 0
    call arc_menu_enter
.loop:
    call kbd_drain
    mov eax, [arc_mode]
    cmp eax, 1
    je  .pong
    cmp eax, 2
    je  .fight
    cmp eax, 3
    je  .pover
    cmp eax, 4
    je  .fover
    call arc_menu_step
    jmp .frame
.pong:
    call pong_step
    jmp .frame
.fight:
    call fight_step
    jmp .frame
.pover:
    call pong_over_step
    jmp .frame
.fover:
    call fight_over_step
.frame:
    call arc_diag
    call arc_wait_frame
    jmp .loop
.novbe:
    ; no linear framebuffer: say so in the legacy text buffer and park
    mov esi, s_arc_novbe
    mov edi, 0xB8000
.nv:
    lodsb
    test al, al
    jz  .nvh
    mov [edi], al
    mov byte [edi+1], 0x0C
    add edi, 2
    jmp .nv
.nvh:
    hlt
    jmp .nvh

%include "gfx.asm"               ; shared framebuffer / text / frame helpers
; key: EBX = code -> ZF clear if held
%macro KEYHELD 1
    cmp byte [key_state + %1], 0
%endmacro

; ---------------------------------------------------------------------
; MENU
arc_menu_enter:
    mov dword [arc_mode], 0
    call clear_lfb
    mov dword [t_y], 170
    mov dword [t_col], C_GREEN
    mov dword [t_scale], 6
    mov esi, s_arc_title
    call arc_text_centered
    mov dword [t_y], 240
    mov dword [t_scale], 2
    mov dword [t_col], C_GREY
    mov esi, s_arc_sub
    call arc_text_centered
    mov dword [t_y], 340
    mov dword [t_scale], 4
    mov dword [t_col], C_WHITE
    mov esi, s_arc_m1
    call arc_text_centered
    mov dword [t_y], 400
    mov esi, s_arc_m2
    call arc_text_centered
    mov dword [t_y], 500
    mov dword [t_scale], 2
    mov dword [t_col], C_YELLOW
    mov esi, s_arc_h1
    call arc_text_centered
    mov dword [t_y], 530
    mov esi, s_arc_h2
    call arc_text_centered
    mov dword [t_y], 560
    mov esi, s_arc_h3
    call arc_text_centered
    ret

arc_menu_step:
    KEYHELD K_1
    jne .p
    KEYHELD K_2
    jne .f
    ret
.p:
    call pong_enter
    ret
.f:
    call fight_enter
    ret

; ---------------------------------------------------------------------
; PONG
pong_enter:
    mov dword [arc_mode], 1
    call clear_lfb
    mov eax, [lfb_w]
    sub eax, P1X + P_W
    mov [p2x], eax
    mov eax, [lfb_h]
    sub eax, P_H
    sar eax, 1
    mov [p1y], eax
    mov [p2y], eax
    mov [p1y_prev], eax
    mov [p2y_prev], eax
    mov dword [score1], 0
    mov dword [score2], 0
    mov dword [score_dirty], 1
    mov dword [serve_dir], 1
    call pong_reset_ball
    ret

pong_reset_ball:
    mov eax, [lfb_w]
    sub eax, B_S
    sar eax, 1
    mov [ballx], eax               ; (keep *_prev: the next render erases the old spot,
    mov eax, [lfb_h]               ;  including a ball clipped at the screen edge)
    sub eax, B_S
    sar eax, 1
    mov [bally], eax
    mov dword [ballvx], 0
    mov dword [ballvy], 0
    mov dword [serve_t], 60
    ret

pong_step:
    KEYHELD K_ESC
    je  .in1
    call arc_menu_enter
    ret
.in1:
    ; --- input ---
    KEYHELD K_W
    je  .n1
    sub dword [p1y], PADDLE_SPEED
.n1:
    KEYHELD K_S
    je  .n2
    add dword [p1y], PADDLE_SPEED
.n2:
    KEYHELD K_UP
    je  .n3
    sub dword [p2y], PADDLE_SPEED
.n3:
    KEYHELD K_DOWN
    je  .n4
    add dword [p2y], PADDLE_SPEED
.n4:
    mov eax, [p1y]
    call pong_clamp_y
    mov [p1y], eax
    mov eax, [p2y]
    call pong_clamp_y
    mov [p2y], eax
    ; --- serve / ball physics ---
    cmp dword [serve_t], 0
    je  .move
    dec dword [serve_t]
    jnz .render
    ; launch
    mov eax, [serve_dir]
    imul eax, 6
    mov [ballvx], eax
    call arc_rand
    xor edx, edx
    mov ecx, 7
    div ecx
    sub edx, 3                     ; -3..3
    mov [ballvy], edx
    jmp .render
.move:
    mov eax, [ballvx]
    add [ballx], eax
    mov eax, [ballvy]
    add [bally], eax
    ; top / bottom walls
    cmp dword [bally], 0
    jge .w1
    mov dword [bally], 0
    neg dword [ballvy]
.w1:
    mov eax, [lfb_h]
    sub eax, B_S
    cmp [bally], eax
    jle .w2
    mov [bally], eax
    neg dword [ballvy]
.w2:
    ; left paddle
    cmp dword [ballvx], 0
    jge .rp
    mov eax, [ballx]
    cmp eax, P1X + P_W
    jg  .out
    add eax, B_S
    cmp eax, P1X
    jl  .out
    mov eax, [bally]
    add eax, B_S
    cmp eax, [p1y]
    jl  .out
    mov eax, [bally]
    mov ebx, [p1y]
    add ebx, P_H
    cmp eax, ebx
    jg  .out
    mov dword [ballx], P1X + P_W
    neg dword [ballvx]
    cmp dword [ballvx], 14
    jge .sp1
    inc dword [ballvx]
.sp1:
    mov eax, [bally]
    add eax, B_S / 2
    sub eax, [p1y]
    sub eax, P_H / 2
    sar eax, 3
    mov [ballvy], eax
    jmp .render
.rp:
    ; right paddle
    mov eax, [ballx]
    add eax, B_S
    cmp eax, [p2x]
    jl  .out
    mov eax, [ballx]
    mov ebx, [p2x]
    add ebx, P_W
    cmp eax, ebx
    jg  .out
    mov eax, [bally]
    add eax, B_S
    cmp eax, [p2y]
    jl  .out
    mov eax, [bally]
    mov ebx, [p2y]
    add ebx, P_H
    cmp eax, ebx
    jg  .out
    mov eax, [p2x]
    sub eax, B_S
    mov [ballx], eax
    neg dword [ballvx]
    cmp dword [ballvx], -14
    jle .sp2
    dec dword [ballvx]
.sp2:
    mov eax, [bally]
    add eax, B_S / 2
    sub eax, [p2y]
    sub eax, P_H / 2
    sar eax, 3
    mov [ballvy], eax
    jmp .render
.out:
    mov eax, [ballx]
    add eax, B_S
    cmp eax, 0
    jge .o2
    inc dword [score2]             ; ball left the left edge -> P2 scores
    mov dword [serve_dir], -1
    jmp .scored
.o2:
    mov eax, [ballx]
    cmp eax, [lfb_w]
    jle .render
    inc dword [score1]
    mov dword [serve_dir], 1
.scored:
    mov dword [score_dirty], 1
    call pong_reset_ball
.render:
    call pong_render
    ; win?
    cmp dword [score1], WIN_SCORE
    je  .win1
    cmp dword [score2], WIN_SCORE
    je  .win2
    ret
.win1:
    mov dword [winner], 1
    jmp .win
.win2:
    mov dword [winner], 2
.win:
    mov dword [arc_mode], 3
    call show_winner
    ret

; pong_clamp_y: EAX = paddle y -> clamped
pong_clamp_y:
    cmp eax, 0
    jge .a
    xor eax, eax
.a:
    mov ebx, [lfb_h]
    sub ebx, P_H
    cmp eax, ebx
    jle .b
    mov eax, ebx
.b:
    ret

pong_render:
    ; erase previous ball + paddles
    mov eax, [ballx_prev]
    mov ebx, [bally_prev]
    mov ecx, B_S
    mov edx, B_S
    mov esi, C_BLACK
    call rect
    mov eax, P1X
    mov ebx, [p1y_prev]
    mov ecx, P_W
    mov edx, P_H
    call rect
    mov eax, [p2x]
    mov ebx, [p2y_prev]
    call rect
    ; centre line (dashes)
    mov eax, [lfb_w]
    sar eax, 1
    sub eax, 2
    mov [r_x], eax
    mov dword [r_w], 4
    mov dword [r_h], 16
    mov dword [r_col], C_DIM
    xor ebx, ebx
.cl:
    mov [r_y], ebx
    call fill_rect
    add ebx, 32
    cmp ebx, [lfb_h]
    jb  .cl
    ; paddles
    mov eax, P1X
    mov ebx, [p1y]
    mov ecx, P_W
    mov edx, P_H
    mov esi, C_BLUE
    call rect
    mov eax, [p2x]
    mov ebx, [p2y]
    mov esi, C_RED
    call rect
    ; ball
    mov eax, [ballx]
    mov ebx, [bally]
    mov ecx, B_S
    mov edx, B_S
    mov esi, C_WHITE
    call rect
    mov eax, [ballx]
    mov [ballx_prev], eax
    mov eax, [bally]
    mov [bally_prev], eax
    mov eax, [p1y]
    mov [p1y_prev], eax
    mov eax, [p2y]
    mov [p2y_prev], eax
    ; score
    cmp dword [score_dirty], 0
    je  .ns
    mov dword [score_dirty], 0
    mov eax, [lfb_w]
    sar eax, 1
    sub eax, 170
    mov ebx, 16
    mov ecx, 340
    mov edx, 44
    mov esi, C_BLACK
    call rect
    mov dword [t_y], 20
    mov dword [t_scale], 5
    mov dword [t_col], C_BLUE
    mov eax, [lfb_w]
    sar eax, 1
    sub eax, 140
    mov [t_x], eax
    mov eax, [score1]
    call arc_num2
    mov dword [t_col], C_RED
    mov eax, [lfb_w]
    sar eax, 1
    add eax, 60
    mov [t_x], eax
    mov eax, [score2]
    call arc_num2
.ns:
    ret

; show_winner: banner for [winner] in the middle of the screen
show_winner:
    mov eax, [lfb_w]
    sar eax, 1
    sub eax, 300
    mov ebx, 300
    mov ecx, 600
    mov edx, 160
    mov esi, C_BLACK
    call rect
    mov dword [t_y], 320
    mov dword [t_scale], 6
    mov dword [t_col], C_YELLOW
    mov esi, s_arc_p1w
    cmp dword [winner], 1
    je  .t
    mov esi, s_arc_p2w
.t:
    call arc_text_centered
    mov dword [t_y], 400
    mov dword [t_scale], 2
    mov dword [t_col], C_WHITE
    mov esi, s_arc_again
    call arc_text_centered
    ret

pong_over_step:
    KEYHELD K_SPACE
    je  .e
    call pong_enter
    ret
.e:
    KEYHELD K_ESC
    je  .q
    call arc_menu_enter
.q:
    ret

; ---------------------------------------------------------------------
; FIGHT
fight_enter:
    mov dword [arc_mode], 2
    call clear_lfb
    ; fighters
    mov esi, f1
    mov dword [esi+FX], 200
    mov dword [esi+FACE], 1
    mov dword [esi+COL], C_BLUE
    mov dword [esi+KL], K_A
    mov dword [esi+KR], K_D
    mov dword [esi+KJ], K_W
    mov dword [esi+KP], K_F
    mov dword [esi+KP2], K_F
    call fighter_reset
    mov esi, f2
    mov eax, [lfb_w]
    sub eax, 200 + F_W
    mov [esi+FX], eax
    mov dword [esi+FACE], -1
    mov dword [esi+COL], C_RED
    mov dword [esi+KL], K_LEFT
    mov dword [esi+KR], K_RIGHT
    mov dword [esi+KJ], K_UP
    mov dword [esi+KP], K_ENTER
    mov dword [esi+KP2], K_KP0
    call fighter_reset
    ; floor
    xor eax, eax
    mov ebx, FLOOR
    mov ecx, [lfb_w]
    mov edx, 4
    mov esi, C_GREY
    call rect
    ; labels
    mov dword [t_x], 40
    mov dword [t_y], 8
    mov dword [t_scale], 2
    mov dword [t_col], C_BLUE
    mov esi, s_arc_p1
    call arc_text
    mov eax, [lfb_w]
    sub eax, 40 + 2*8*2
    mov [t_x], eax
    mov dword [t_col], C_RED
    mov esi, s_arc_p2
    call arc_text
    ret

; fighter_reset: ESI = fighter (keeps FX/FACE/COL/keys)
fighter_reset:
    mov dword [esi+FY], 0
    mov dword [esi+VY], 0
    mov dword [esi+HP], 100
    mov dword [esi+ATK], 0
    mov dword [esi+CD], 0
    mov dword [esi+STUN], 0
    mov dword [esi+HIT], 0
    mov eax, [esi+FX]
    mov [esi+PX], eax
    mov dword [esi+PY], 0
    ret

fight_step:
    KEYHELD K_ESC
    je  .go
    call arc_menu_enter
    ret
.go:
    mov esi, f1
    mov edi, f2
    call fighter_update
    mov esi, f2
    mov edi, f1
    call fighter_update
    mov esi, f1
    mov edi, f2
    call fighter_separate          ; bodies are solid: no walking through
    mov esi, f2
    mov edi, f1
    call fighter_separate
    mov esi, f1
    mov edi, f2
    call fighter_hit
    mov esi, f2
    mov edi, f1
    call fighter_hit
    ; render: erase both, then draw both
    mov esi, f1
    call fighter_erase
    mov esi, f2
    call fighter_erase
    mov esi, f1
    call fighter_draw
    mov esi, f2
    call fighter_draw
    call fight_bars
    inc dword [arc_frame]
    ; KO?
    cmp dword [f1+HP], 0
    jg  .k2
    mov dword [winner], 2
    jmp .ko
.k2:
    cmp dword [f2+HP], 0
    jg  .ok
    mov dword [winner], 1
.ko:
    mov dword [arc_mode], 4
    call show_winner
.ok:
    ret

; fighter_update: ESI = self, EDI = opponent. Input + physics + timers.
fighter_update:
    cmp dword [esi+STUN], 0
    je  .ctl
    dec dword [esi+STUN]
    jmp .phys
.ctl:
    ; face the opponent
    mov eax, [esi+FX]
    cmp eax, [edi+FX]
    jl  .fr
    mov dword [esi+FACE], -1
    jmp .mv
.fr:
    mov dword [esi+FACE], 1
.mv:
    mov ebx, [esi+KL]
    cmp byte [key_state + ebx], 0
    je  .m2
    sub dword [esi+FX], F_SPEED
.m2:
    mov ebx, [esi+KR]
    cmp byte [key_state + ebx], 0
    je  .m3
    add dword [esi+FX], F_SPEED
.m3:
    mov ebx, [esi+KJ]
    cmp byte [key_state + ebx], 0
    je  .m4
    cmp dword [esi+FY], 0
    jne .m4
    cmp dword [esi+VY], 0
    jne .m4
    mov dword [esi+VY], JUMP_V
.m4:
    mov ebx, [esi+KP]
    cmp byte [key_state + ebx], 0
    jne .punch
    mov ebx, [esi+KP2]
    cmp byte [key_state + ebx], 0
    je  .phys
.punch:
    cmp dword [esi+CD], 0
    jne .phys
    cmp dword [esi+ATK], 0
    jne .phys
    mov dword [esi+ATK], PUNCH_T
    mov dword [esi+CD], PUNCH_CD
    mov dword [esi+HIT], 0
.phys:
    ; clamp x
    cmp dword [esi+FX], 0
    jge .c1
    mov dword [esi+FX], 0
.c1:
    mov eax, [lfb_w]
    sub eax, F_W
    cmp [esi+FX], eax
    jle .c2
    mov [esi+FX], eax
.c2:
    ; gravity / jump
    cmp dword [esi+VY], 0
    jne .air
    cmp dword [esi+FY], 0
    je  .tm
.air:
    mov eax, [esi+VY]
    add [esi+FY], eax
    dec dword [esi+VY]
    cmp dword [esi+FY], 0
    jg  .tm
    mov dword [esi+FY], 0
    mov dword [esi+VY], 0
.tm:
    cmp dword [esi+ATK], 0
    je  .t2
    dec dword [esi+ATK]
.t2:
    cmp dword [esi+CD], 0
    je  .t3
    dec dword [esi+CD]
.t3:
    ret

; fighter_separate: ESI = self, EDI = other. If the two bodies overlap (and are
; at roughly the same height) push self out of the other by the overlap, then
; re-clamp to the screen.
fighter_separate:
    mov eax, [esi+FY]
    sub eax, [edi+FY]
    cmp eax, 0
    jge .p
    neg eax
.p:
    cmp eax, F_H
    jge .no
    mov eax, [esi+FX]
    mov ebx, [edi+FX]
    mov ecx, eax
    sub ecx, ebx                   ; self - other
    cmp ecx, 0
    jl  .selfleft
    cmp ecx, F_W
    jge .no
    mov eax, ebx                   ; self is right of other: sit at other + F_W
    add eax, F_W
    jmp .set
.selfleft:
    neg ecx
    cmp ecx, F_W
    jge .no
    mov eax, ebx
    sub eax, F_W
.set:
    cmp eax, 0
    jge .c
    xor eax, eax
.c:
    mov ebx, [lfb_w]
    sub ebx, F_W
    cmp eax, ebx
    jle .w
    mov eax, ebx
.w:
    mov [esi+FX], eax
.no:
    ret

; fighter_hit: ESI = attacker, EDI = victim
fighter_hit:
    cmp dword [esi+ATK], 0
    je  .no
    cmp dword [esi+HIT], 0
    jne .no
    ; attack box x range [eax, ebx)
    mov eax, [esi+FX]
    cmp dword [esi+FACE], 1
    jne .left
    add eax, F_W
    mov ebx, eax
    add ebx, ARM_L
    jmp .chk
.left:
    mov ebx, eax
    sub eax, ARM_L
.chk:
    mov ecx, [edi+FX]              ; victim body [ecx, ecx+F_W)
    mov edx, ecx
    add edx, F_W
    cmp eax, edx
    jge .no
    cmp ebx, ecx
    jle .no
    ; vertical: |fy - vfy| < 70
    mov eax, [esi+FY]
    sub eax, [edi+FY]
    cmp eax, 0
    jge .pos
    neg eax
.pos:
    cmp eax, 70
    jge .no
    ; landed
    mov dword [esi+HIT], 1
    sub dword [edi+HP], DMG
    cmp dword [edi+HP], 0
    jge .h1
    mov dword [edi+HP], 0
.h1:
    mov dword [edi+STUN], STUN_T
    mov eax, [esi+FACE]
    imul eax, KNOCK
    add [edi+FX], eax
    cmp dword [edi+FX], 0          ; keep the knocked-back body on screen
    jge .k1
    mov dword [edi+FX], 0
.k1:
    mov eax, [lfb_w]
    sub eax, F_W
    cmp [edi+FX], eax
    jle .no
    mov [edi+FX], eax
.no:
    ret

; fighter_erase: ESI = fighter -> black out its last drawn box (incl. arm reach)
fighter_erase:
    mov eax, [esi+PX]
    sub eax, F_W
    mov ebx, FLOOR - F_H
    sub ebx, [esi+PY]
    mov ecx, F_W * 3
    mov edx, F_H
    push esi
    mov esi, C_BLACK
    call rect
    pop esi
    ret

; fighter_draw: ESI = fighter
fighter_draw:
    push esi
    mov ebp, esi
    ; torso colour (white flash on stun)
    mov esi, [ebp+COL]
    cmp dword [ebp+STUN], 0
    je  .col
    test dword [arc_frame], 2
    jz  .col
    mov esi, C_WHITE
.col:
    mov eax, [ebp+FX]
    mov ebx, FLOOR - 72
    sub ebx, [ebp+FY]
    mov ecx, F_W
    mov edx, 72
    call rect                      ; torso
    mov eax, [ebp+FX]
    add eax, 10
    mov ebx, FLOOR - F_H
    sub ebx, [ebp+FY]
    mov ecx, 28
    mov edx, 24
    mov esi, C_SKIN
    call rect                      ; head
    ; eye (facing side)
    mov eax, [ebp+FX]
    add eax, 14
    cmp dword [ebp+FACE], 1
    jne .eye
    add eax, 14
.eye:
    mov ebx, FLOOR - F_H + 8
    sub ebx, [ebp+FY]
    mov ecx, 6
    mov edx, 6
    mov esi, C_BLACK
    call rect
    ; arm when punching
    cmp dword [ebp+ATK], 0
    je  .noarm
    mov eax, [ebp+FX]
    cmp dword [ebp+FACE], 1
    jne .al
    add eax, F_W
    jmp .ad
.al:
    sub eax, ARM_L
.ad:
    mov ebx, FLOOR - 66
    sub ebx, [ebp+FY]
    mov ecx, ARM_L
    mov edx, ARM_H
    mov esi, C_SKIN
    call rect
.noarm:
    mov eax, [ebp+FX]
    mov [ebp+PX], eax
    mov eax, [ebp+FY]
    mov [ebp+PY], eax
    pop esi
    ret

; fight_bars: health bars (P1 left, P2 right-anchored)
fight_bars:
    mov eax, 40
    mov ebx, 30
    mov ecx, 400
    mov edx, 24
    mov esi, C_RED
    call rect
    mov ecx, [f1+HP]
    shl ecx, 2
    mov esi, C_GREEN
    call rect
    mov eax, [lfb_w]
    sub eax, 440
    mov ecx, 400
    mov esi, C_RED
    call rect
    mov ecx, [f2+HP]
    shl ecx, 2
    mov eax, [lfb_w]
    sub eax, 40
    sub eax, ecx
    mov esi, C_GREEN
    call rect
    ret

fight_over_step:
    KEYHELD K_SPACE
    je  .e
    call fight_enter
    ret
.e:
    KEYHELD K_ESC
    je  .q
    call arc_menu_enter
.q:
    ret

; ---------------------------------------------------------------------
; serial debug line (QEMU): 'H' = held keys, 'G' = game state, both as hex
arc_serial_poll:
    pushad
    cmp byte [com1_present], 0
    je  .q
    mov dx, COM1 + 5
    in  al, dx
    test al, 1
    jz  .q
    mov dx, COM1
    in  al, dx
    cmp al, 'H'
    je  .held
    cmp al, 'G'
    je  .game
    jmp .q
.held:
    mov esi, s_keys
    call ser_puts
    xor ebx, ebx
.hk:
    cmp byte [key_state + ebx], 0
    je  .hn
    mov al, bl
    call ser_hex8
    mov al, ' '
    call putc
.hn:
    inc ebx
    cmp ebx, 256
    jb  .hk
    call ser_nl
    jmp .q
.game:
    mov esi, s_arc_g
    call ser_puts
    mov esi, arc_mode              ; dump a fixed list of dwords
    mov ecx, (arc_vars_end - arc_mode) / 4
.gv:
    mov eax, [esi]
    call ser_hex32
    mov al, ' '
    call putc
    add esi, 4
    dec ecx
    jnz .gv
    mov esi, s_arc_gf
    call ser_puts
    mov esi, f1
    mov ecx, 9                     ; FX FY VY FACE HP ATK CD STUN HIT
.g1:
    mov eax, [esi]
    call ser_hex32
    mov al, ' '
    call putc
    add esi, 4
    dec ecx
    jnz .g1
    mov al, '|'
    call putc
    mov al, ' '
    call putc
    mov esi, f2
    mov ecx, 9
.g2:
    mov eax, [esi]
    call ser_hex32
    mov al, ' '
    call putc
    add esi, 4
    dec ecx
    jnz .g2
    call ser_nl
.q:
    popad
    ret


; ---------------------------------------------------------------------
; data
s_arc_novbe db "ARCADE: no VBE linear framebuffer - cannot run", 0
s_arc_title db "AGENTZERO ARCADE", 0
s_arc_sub   db "BARE METAL - NO OS - RING 0 - 60 FPS", 0
s_arc_m1    db "1 = PONG", 0
s_arc_m2    db "2 = FIGHT", 0
s_arc_h1    db "PONG   P1: W/S          P2: UP/DOWN", 0
s_arc_h2    db "FIGHT  P1: A D W(JUMP) F(PUNCH)   P2: ARROWS  ENTER(PUNCH)", 0
s_arc_h3    db "ESC = MENU     SPACE = PLAY AGAIN", 0
s_arc_p1w   db "P1 WINS", 0
s_arc_p2w   db "P2 WINS", 0
s_arc_again db "SPACE = AGAIN     ESC = MENU", 0
s_arc_p1    db "P1", 0
s_arc_p2    db "P2", 0
s_arc_g     db "game: mode p1y p2y ballx bally vx vy s1 s2 serve win frame = ", 0
s_arc_gf    db "  f(x y vy face hp atk cd stun hit): ", 0
align 4
; game variables dumped by 'G' (keep contiguous, dword each)
arc_mode    dd 0
p1y         dd 0
p2y         dd 0
ballx       dd 0
bally       dd 0
ballvx      dd 0
ballvy      dd 0
score1      dd 0
score2      dd 0
serve_t     dd 0
winner      dd 0
arc_frame   dd 0
arc_vars_end:
p2x         dd 0
p1y_prev    dd 0
p2y_prev    dd 0
ballx_prev  dd 0
bally_prev  dd 0
score_dirty dd 0
serve_dir   dd 1
f1          times F_SIZE db 0
f2          times F_SIZE db 0
