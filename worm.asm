; worm.asm - "a real animal's whole brain on a dead laptop": the C. elegans petri
; dish (included by stage2.asm when built with WORM=1). 32-bit protected mode,
; ring 0, no OS, no interrupts, no network after boot.
;
;   brain  : brain.asm - the 302-neuron connectome (worm/data/brain.inc) as a
;            fixed-point integrate-and-fire network, 2 steps per frame
;   body   : 24 points, 9 px apart, "follow the leader" chain. Forward: the head
;            leads and swings left/right (sine) -> the classic travelling wave.
;            Backward: the tail leads. Speed/direction = B-class minus A-class motor
;            neuron spikes; a reversal ends with an omega turn.
;   senses : H key / dish wall at the head -> ALM+AVM (anterior touch), T key / wall
;            at the tail -> PLM (posterior touch); food concentration at the head
;            rising -> ASEL, falling -> ASER+AWC (the "lost the scent -> reversal"
;            circuit). F drops food ahead of the worm, R resets.
;   screen : 1024x768 VBE. Dish on the left (background layer in RAM, so erasing
;            the body restores the food glow and the trail), live raster of all 302
;            neurons + 24 dorsal/ventral muscle bars on the right, HUD lines.
;   debug  : COM1 (QEMU) 'G' dumps the worm state as hex, 'H' the held keys.
; The body maths mirrors worm/wormenv.py (same integers, same tables).

NSEG        equ 24
SEG_LEN     equ 9
DISH_CX     equ 300
DISH_CY     equ 420
DISH_R      equ 260
FOOD_R      equ 180
FOOD_R2     equ FOOD_R * FOOD_R
EAT_R       equ 24
TOUCH_FRAMES equ 120               ; brain steps (2 per frame): a poke-and-hold of 1 s
TOUCH_EXT   equ 300
CHEMO_GAIN  equ 12
SWING_AMP   equ 46
SWING_RATE  equ 6                  ; phase advance per px of travel
SPEED_MAX   equ 4                  ; speed unit = 1/4 px per frame -> max 1 px/frame (60 px/s)
SPEED_SHIFT equ 5                  ; spd = drive >> 5, clamped to +-SPEED_MAX
DRIVE_SHIFT equ 4
OMEGA_TURN  equ 40
AMP_MAX     equ 12                 ; px: max lateral wave amplitude a segment's muscles produce
AMP_SHIFT   equ 5                  ; amplitude = (dorsal + ventral activation) >> 5
BIAS_SHIFT  equ 6                  ; lateral bias = (dorsal - ventral) >> 6, clamped
BIAS_MAX    equ 4
WAVE_K      equ 11                 ; phase lag per segment (angle units)
HEAD_SEGS   equ 4                  ; head segments add a foraging sweep of their own
HEAD_RATE   equ 3                  ; head sweep phase advance per frame
HEAD_AMP_SHIFT equ 6
HEAD_AMP_MAX equ 8
TURN_SHIFT  equ 10                 ; steer (Q4) = clamp(high-passed head dorsal-ventral >> 10, +-TURN_MAX)
TURN_MAX    equ 4
FOOD_ON_C   equ 160                ; concentration above which the pharynx is driven (food core)
PHARYNX_GAIN equ 1
NSM_SLOW_FRAMES equ 30             ; an NSM spike halves the speed for this many frames
FOOD_AMOUNT equ 150                ; pharyngeal pumps on the core needed to finish the food
C_PUMP      equ 0x002030C0         ; pharynx dot while pumping
OMEGA_MIN_BACK equ 16              ; frames: a shorter reversal ends without an omega turn
FOOD_RESPAWN equ 120
BG_LAYER    equ 0x00400000         ; background copy of the screen (3 MiB)
STAT_LAYER  equ 0x00800000         ; off-screen strip for the status line (drawn there, then copied)
STAT_H      equ 10
SPLASH_FRAMES equ 100
ARC_FRAME   equ 19886              ; PIT ch0 counts per frame (1193182 / 60), used by gfx.asm
C_DIM       equ 0x00303030

; colours (BGRX)
C_BLACK     equ 0x00000000
C_WHITE     equ 0x00FFFFFF
C_RED       equ 0x00FF3030
C_AGAR      equ 0x00061006
C_RING      equ 0x00305030
C_TRAIL     equ 0x00184018
C_BODY      equ 0x00E8E0C8
C_HEAD      equ 0x00FFFFFF
C_TAIL      equ 0x00908878
C_FINGER    equ 0x00FFE040
C_SENS      equ 0x00FFC040         ; cyan-ish (BGRX: B=FF G=C0 R=40)
C_INTER     equ 0x0040D0FF         ; yellow
C_MOTOR     equ 0x00FF60FF         ; magenta
C_DORSAL    equ 0x004060FF
C_VENTRAL   equ 0x00FF9040
C_HUD       equ 0x0080FF80
C_HUD2      equ 0x00608060

; brain graph panel: 302 neurons as nodes in three layered column groups
; (sensory -> interneurons -> motor), the strongest synapses drawn as dim lines
; in the background, and a neuron's outgoing synapses flash when it fires.
GX_S        equ 604                ; sensory columns x (2 cols, 40 apart)
GX_I        equ 744                ; interneuron columns x (3 cols)
GX_M        equ 924                ; motor columns x (3 cols)
GY          equ 84
ROWS_S      equ 43
ROWS_I      equ 34
ROWS_M      equ 38
PITCH_S     equ 12
PITCH_I     equ 15
PITCH_M     equ 13
NODE        equ 6                  ; node square size
%ifndef EDGE_THR
EDGE_THR    equ 8                  ; |weight| >= this -> the synapse is drawn in the background
%endif
FLASH_THR   equ 12                 ; |weight| >= this -> it flashes when the neuron fires
C_EDGE      equ 0x00141E14         ; static synapse lines (dim)
RX          equ 604                ; muscle bars / labels x
MUSC_Y      equ 620
MUSC_H      equ 28

; keys (set 1 scancodes)
K_H     equ 0x23
K_T     equ 0x14
K_F     equ 0x21
K_R     equ 0x13
K_SPACE equ 0x39

%include "gfx.asm"

; =====================================================================
worm_pm:
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
    ; ---- splash: "no OS / 302 neurons" while the brain image is expanded ----
    call clear_lfb
    mov dword [t_y], 250
    mov dword [t_col], C_HUD
    mov dword [t_scale], 6
    mov esi, s_w_title
    call arc_text_centered
    mov dword [t_y], 330
    mov dword [t_scale], 3
    mov dword [t_col], C_WHITE
    mov esi, s_w_sub1
    call arc_text_centered
    mov dword [t_y], 380
    mov esi, s_w_sub2
    call arc_text_centered
    mov dword [t_y], 460
    mov dword [t_scale], 2
    mov dword [t_col], C_HUD2
    mov esi, s_w_load
    call arc_text_centered
    mov esi, brain_blob
    call brain_init
    test eax, eax
    jz  .badbrain
    call graph_init
    mov ecx, SPLASH_FRAMES
.sp:
    push ecx
    call arc_wait_frame
    pop ecx
    dec ecx
    jnz .sp
    call worm_reset
.loop:
    call kbd_drain
    call worm_keys
    call worm_think
    call worm_move
    call worm_render
    call worm_beep_tick
    call arc_diag
    call arc_wait_frame
    inc dword [w_frame]
    jmp .loop
.badbrain:
    mov dword [t_y], 520
    mov dword [t_col], C_RED
    mov esi, s_w_bad
    call arc_text_centered
.hang:
    hlt
    jmp .hang
.novbe:
    mov esi, s_w_novbe
    mov edi, 0xB8000
.nv:
    lodsb
    test al, al
    jz  .hang
    mov [edi], al
    mov byte [edi+1], 0x0C
    add edi, 2
    jmp .nv

; ---------------------------------------------------------------------
; worm_reset: brain state, body, food, background, HUD
worm_reset:
    call brain_reset_state
    xor ecx, ecx
.p:
    mov eax, ecx
    imul eax, -SEG_LEN
    add eax, DISH_CX - 40
    shl eax, 8
    mov [wx + ecx*4], eax
    mov dword [wy + ecx*4], DISH_CY << 8
    shr eax, 8
    mov [wpx + ecx*4], eax
    mov dword [wpy + ecx*4], DISH_CY
    inc ecx
    cmp ecx, NSEG
    jb  .p
    mov dword [w_heading], 0
    mov dword [w_phase], 0
    mov dword [w_drive], 0
    mov dword [w_spd], 0
    mov dword [w_touch_head], 0
    mov dword [w_touch_tail], 0
    mov dword [w_food_x], DISH_CX + 120
    mov dword [w_food_y], DISH_CY - 100
    mov dword [w_food_on], 1
    mov dword [w_food_timer], 0
    mov dword [w_c_now], 0
    mov dword [w_c_slow], 0
    mov dword [w_was_back], 0
    mov dword [w_back_frames], 0
    mov dword [w_ate], 0
    mov dword [w_frame], 0
    mov dword [w_fw], 0
    mov dword [w_bw], 0
    mov dword [w_finger_x], -1
    mov dword [w_keys_prev], 0
    mov dword [w_phase_head], 0
    mov dword [w_dv_slow], 0
    mov dword [w_steer], 0
    mov dword [w_steer_acc], 0
    mov dword [w_nsm_timer], 0
    mov dword [w_pump], 0
    mov dword [w_pumps], 0
    mov dword [w_food_amount], FOOD_AMOUNT
    mov edi, w_lat
    mov ecx, NSEG
    xor eax, eax
    rep stosd
    call bg_draw_all
    call bg_blit_all
    call hud_static
    ret

; ---------------------------------------------------------------------
; keys: edge-triggered H / T / F / R (Space = poke head too)
worm_keys:
    xor ebx, ebx                   ; new mask
    cmp byte [key_state + K_H], 0
    je  .k1
    or  ebx, 1
.k1:
    cmp byte [key_state + K_SPACE], 0
    je  .k1b
    or  ebx, 1
.k1b:
    cmp byte [key_state + K_T], 0
    je  .k2
    or  ebx, 2
.k2:
    cmp byte [key_state + K_F], 0
    je  .k3
    or  ebx, 4
.k3:
    cmp byte [key_state + K_R], 0
    je  .k4
    or  ebx, 8
.k4:
    mov eax, ebx
    mov ecx, [w_keys_prev]
    mov [w_keys_prev], ebx
    not ecx
    and eax, ecx                   ; newly pressed
    test eax, 1
    jz  .t
    mov dword [w_touch_head], TOUCH_FRAMES
    mov eax, 3000                  ; low blip
    mov ecx, 4
    call worm_beep
.t:
    mov eax, ebx
    and eax, ecx
    test eax, 2
    jz  .f
    mov dword [w_touch_tail], TOUCH_FRAMES
    mov eax, 2500
    mov ecx, 4
    call worm_beep
.f:
    mov eax, ebx
    and eax, ecx
    test eax, 4
    jz  .r
    mov eax, 1                     ; ahead
    call place_food
.r:
    mov eax, ebx
    and eax, ecx
    test eax, 8
    jz  .d
    call worm_reset
.d:
    ret

; ---------------------------------------------------------------------
; concentration: EAX = x, EBX = y (px) -> EAX = 0..255 (quadratic glow, no sqrt)
concentration:
    cmp dword [w_food_on], 0
    je  .zero
    sub eax, [w_food_x]
    sub ebx, [w_food_y]
    imul eax, eax
    imul ebx, ebx
    add eax, ebx                   ; d2
    cmp eax, FOOD_R2
    jae .zero
    mov ebx, FOOD_R2
    sub ebx, eax
    imul eax, ebx, 255
    xor edx, edx
    mov ebx, FOOD_R2
    div ebx
    ret
.zero:
    xor eax, eax
    ret

; ext_add: ECX = stim slot (0..15), EAX = value -> EXT[stim[slot]] +=sat value
ext_add:
    push ebx
    push edx
    mov ebx, [br_blob]
    movzx ebx, word [ebx + 64 + ecx*2]   ; neuron row
    movsx edx, word [BR_EXT + ebx*2]
    add edx, eax
    cmp edx, 32767
    jle .n1
    mov edx, 32767
.n1:
    cmp edx, -32768
    jge .n2
    mov edx, -32768
.n2:
    mov [BR_EXT + ebx*2], dx
    pop edx
    pop ebx
    ret

; worm_sense: EXT = bias + touch + chemo (called once per brain step)
worm_sense:
    call brain_bias_ext
    cmp dword [w_touch_head], 0
    je  .nh
    dec dword [w_touch_head]
    mov eax, TOUCH_EXT
    xor ecx, ecx
    call ext_add
    mov ecx, 1
    call ext_add
    mov ecx, 2
    call ext_add
.nh:
    cmp dword [w_touch_tail], 0
    je  .nt
    dec dword [w_touch_tail]
    mov eax, TOUCH_EXT
    mov ecx, 3
    call ext_add
    mov ecx, 4
    call ext_add
.nt:
    mov eax, [wx]
    sar eax, 8
    mov ebx, [wy]
    sar ebx, 8
    call concentration             ; EAX = c
    mov [w_c_now], eax
    mov ebx, [w_c_slow]
    mov ecx, ebx
    sar ecx, 3
    sub ebx, ecx
    add ebx, eax
    mov [w_c_slow], ebx            ; c_slow = c_slow - c_slow>>3 + c
    push eax
    mov eax, [w_c_now]
    cmp eax, FOOD_ON_C
    jle .nofood
    imul eax, PHARYNX_GAIN         ; sitting on food: drive the pharynx (NSM, MC)
    cmp eax, TOUCH_EXT
    jle .pf
    mov eax, TOUCH_EXT
.pf:
    mov ecx, 12
    call ext_add
    mov ecx, 13
    call ext_add
    mov ecx, 14
    call ext_add
    mov ecx, 15
    call ext_add
.nofood:
    pop eax
    shl eax, 3
    sub eax, ebx                   ; dc = 8c - c_slow
    jz  .d
    js  .fall
    imul eax, CHEMO_GAIN
    cmp eax, TOUCH_EXT
    jle .r1
    mov eax, TOUCH_EXT
.r1:
    mov ecx, 5                     ; ASEL (ON)
    call ext_add
    ret
.fall:
    neg eax
    imul eax, CHEMO_GAIN
    cmp eax, TOUCH_EXT
    jle .f1
    mov eax, TOUCH_EXT
.f1:
    mov ecx, 6                     ; ASER (OFF)
    call ext_add
    mov ecx, 7                     ; AWCL
    call ext_add
    mov ecx, 8                     ; AWCR
    call ext_add
.d:
    ret

; worm_think: brain steps for this frame -> w_fw, w_bw, w_drive
worm_think:
    xor esi, esi                   ; fw
    xor edi, edi                   ; bw
    mov ecx, [br_steps]
.s:
    push ecx
    call worm_sense
    call brain_step
    call brain_fwd
    add esi, eax
    call brain_bwd
    add edi, eax
    call pharynx_check
    pop ecx
    dec ecx
    jnz .s
    mov [w_fw], esi
    mov [w_bw], edi
    call muscle_offsets
    mov eax, [w_drive]
    mov ebx, eax
    sar ebx, DRIVE_SHIFT
    sub eax, ebx
    add eax, esi
    sub eax, edi
    mov [w_drive], eax
    ret

; stim_fired: ECX = stim slot -> ZF clear if that neuron fired this step
stim_fired:
    push ebx
    mov ebx, [br_blob]
    movzx ebx, word [ebx + 64 + ecx*2]
    cmp word [BR_S + ebx*2], 0
    pop ebx
    ret

; pharynx_check (after a brain step): NSM spike -> slow down; MC spike -> a pump,
; and pumping on the food core eats it. Preserves ESI/EDI.
pharynx_check:
    push esi
    push edi
    mov ecx, 12
    call stim_fired
    jne .nsm
    mov ecx, 13
    call stim_fired
    je  .mc
.nsm:
    mov dword [w_nsm_timer], NSM_SLOW_FRAMES
.mc:
    mov ecx, 14
    call stim_fired
    jne .pump
    mov ecx, 15
    call stim_fired
    je  .d
.pump:
    mov dword [w_pump], 4
    inc dword [w_pumps]
    cmp dword [w_food_on], 0
    je  .d
    cmp dword [w_c_now], FOOD_ON_C
    jle .d
    dec dword [w_food_amount]
    jg  .d
    call eat_food
.d:
    pop edi
    pop esi
    ret

; eat_food: the food is finished (contact or pumping)
eat_food:
    pushad
    inc dword [w_ate]
    mov dword [w_food_on], 0
    mov dword [w_food_timer], FOOD_RESPAWN
    mov eax, 800                   ; high chirp
    mov ecx, 6
    call worm_beep
    call bg_draw_all
    call bg_blit_all
    call hud_static
    popad
    ret

; muscle_offsets: per segment lateral offset (px) from its body-wall muscles:
; amplitude from dorsal+ventral activation, bias from dorsal-ventral, the head
; segments add a foraging sweep; head muscles steer (high-passed, Q4).
muscle_offsets:
    pushad
    xor ecx, ecx                   ; k
    xor ebp, ebp                   ; dv (head, k < 8)
.k:
    mov edi, [br_muscle_row0]
    add edi, ecx
    movsx eax, word [BR_V + edi*2]          ; MDL
    movsx ebx, word [BR_V + edi*2 + 48]     ; MDR
    add eax, ebx
    sar eax, 1                              ; md
    movsx ebx, word [BR_V + edi*2 + 96]     ; MVL
    movsx edx, word [BR_V + edi*2 + 144]    ; MVR
    add ebx, edx
    sar ebx, 1                              ; mv
    mov [w_md], eax
    mov [w_mv], ebx
    cmp ecx, 8
    jae .nodv
    sub eax, ebx
    add ebp, eax
    mov eax, [w_md]
.nodv:
    add eax, ebx                            ; md + mv
    mov edx, eax
    sar eax, AMP_SHIFT
    cmp eax, 0
    jge .a1
    xor eax, eax
.a1:
    cmp eax, AMP_MAX
    jle .a2
    mov eax, AMP_MAX
.a2:
    mov [w_amp], eax
    sar edx, HEAD_AMP_SHIFT
    cmp edx, 0
    jge .h1
    xor edx, edx
.h1:
    cmp edx, HEAD_AMP_MAX
    jle .h2
    mov edx, HEAD_AMP_MAX
.h2:
    mov [w_hamp], edx
    mov eax, [w_md]
    sub eax, [w_mv]
    sar eax, BIAS_SHIFT
    cmp eax, -BIAS_MAX
    jge .b1
    mov eax, -BIAS_MAX
.b1:
    cmp eax, BIAS_MAX
    jle .b2
    mov eax, BIAS_MAX
.b2:
    mov [w_bias], eax
    ; o = amp * sin(phase - k*WAVE_K) >> 14 + bias
    mov eax, ecx
    imul eax, WAVE_K
    neg eax
    add eax, [w_phase]
    call sin_q14
    imul eax, [w_amp]
    sar eax, 14
    add eax, [w_bias]
    cmp ecx, HEAD_SEGS
    jae .noh
    push eax
    mov eax, [w_phase_head]
    call sin_q14
    imul eax, [w_hamp]
    sar eax, 14
    pop edx
    add eax, edx
.noh:
    mov [w_lat + ecx*4], eax
    inc ecx
    cmp ecx, NSEG
    jb  .k
    ; steering: dv_slow = dv_slow - dv_slow>>4 + dv ; steer = clamp((dv*16 - dv_slow) >> 10, +-4)
    mov eax, [w_dv_slow]
    mov ebx, eax
    sar ebx, 4
    sub eax, ebx
    add eax, ebp
    mov [w_dv_slow], eax
    mov ebx, ebp
    shl ebx, 4
    sub ebx, eax
    sar ebx, TURN_SHIFT
    cmp ebx, -TURN_MAX
    jge .s1
    mov ebx, -TURN_MAX
.s1:
    cmp ebx, TURN_MAX
    jle .s2
    mov ebx, TURN_MAX
.s2:
    mov [w_steer], ebx
    popad
    ret

; ---------------------------------------------------------------------
; isqrt: EAX = n (unsigned) -> EAX = floor(sqrt(n)). Clobbers EBX, ECX, EDX.
isqrt:
    mov edx, eax                   ; n
    xor eax, eax                   ; result
    mov ebx, 1 << 30               ; bit
.sb:
    cmp ebx, edx
    jbe .go
    shr ebx, 2
    jnz .sb
    ret
.go:
    test ebx, ebx
    jz  .d
    lea ecx, [eax + ebx]           ; result + bit
    shr eax, 1
    cmp edx, ecx
    jb  .nx
    sub edx, ecx
    add eax, ebx
.nx:
    shr ebx, 2
    jmp .go
.d:
    ret

; iatan2: EAX = y, EBX = x -> EAX = angle 0..255 (256 = full turn). Clobbers ECX, EDX.
iatan2:
    mov ecx, eax                   ; y
    mov edx, ebx                   ; x
    or  ebx, eax
    jz  .zero
    mov eax, ecx
    cmp eax, 0
    jge .ay
    neg eax
.ay:
    mov ebx, edx
    cmp ebx, 0
    jge .ax
    neg ebx
.ax:                               ; eax = |y|, ebx = |x|
    push ecx
    push edx
    cmp ebx, eax
    jb  .steep
    shl eax, 8
    xor edx, edx
    div ebx                        ; r = |y|<<8 / |x|
    movzx eax, byte [atan_tab + eax]
    jmp .q
.steep:
    xchg eax, ebx
    shl eax, 8
    xor edx, edx
    div ebx                        ; r = |x|<<8 / |y|
    movzx eax, byte [atan_tab + eax]
    neg eax
    add eax, 64
.q:
    pop edx
    pop ecx
    cmp edx, 0
    jge .xp
    neg eax
    add eax, 128
.xp:
    cmp ecx, 0
    jge .yp
    neg eax
.yp:
    and eax, 255
    ret
.zero:
    xor eax, eax
    ret

; sin_q14 / cos_q14: EAX = angle -> EAX = Q14 (sign-extended)
sin_q14:
    and eax, 255
    movsx eax, word [sin256 + eax*2]
    ret
cos_q14:
    add eax, 64
    and eax, 255
    movsx eax, word [sin256 + eax*2]
    ret

; worm_move: body kinematics (mirrors wormenv.Worm.move)
worm_move:
    mov eax, [w_drive]
    sar eax, SPEED_SHIFT
    cmp eax, SPEED_MAX
    jle .c1
    mov eax, SPEED_MAX
.c1:
    cmp eax, -SPEED_MAX
    jge .c2
    mov eax, -SPEED_MAX
.c2:
    cmp dword [w_nsm_timer], 0
    je  .noslow
    dec dword [w_nsm_timer]
    mov ebx, eax                   ; on food: halve the speed (truncating)
    shr ebx, 31
    add eax, ebx
    sar eax, 1
.noslow:
    mov [w_spd], eax
    cmp dword [w_pump], 0
    je  .nopump
    dec dword [w_pump]
.nopump:
    mov ebx, [w_phase_head]
    add ebx, HEAD_RATE
    and ebx, 255
    mov [w_phase_head], ebx
    mov ebx, [w_steer_acc]         ; head muscles steer (Q4 accumulator)
    add ebx, [w_steer]
    mov edx, ebx
    sar edx, 4
    add edx, [w_heading]
    and edx, 255
    mov [w_heading], edx
    and ebx, 15
    mov [w_steer_acc], ebx
    test eax, eax
    jz  .food
    jle .noomega
    cmp dword [w_was_back], 0
    je  .noomega
    cmp dword [w_back_frames], OMEGA_MIN_BACK
    jl  .noom2
    mov ebx, OMEGA_TURN            ; omega turn after a long reversal: new direction
    cmp dword [w_phase], 128
    jb  .om
    neg ebx
.om:
    add [w_heading], ebx
    and dword [w_heading], 255
.noom2:
    mov dword [w_back_frames], 0
.noomega:
    xor ebx, ebx
    cmp eax, 0
    jge .wb
    inc ebx
    inc dword [w_back_frames]
.wb:
    mov [w_was_back], ebx
    ; phase += spd * SWING_RATE (signed: a reversal runs the wave forward)
    mov ebx, eax
    imul ebx, SWING_RATE
    sar ebx, 2
    add ebx, [w_phase]
    and ebx, 255
    mov [w_phase], ebx
    mov ebx, eax
    cmp ebx, 0
    jge .ab
    neg ebx
.ab:
    mov [w_d], ebx                 ; d = |spd| (quarter px)
    cmp dword [w_spd], 0
    jl  .back
    ; forward: head leads along the heading (the undulation comes from the muscles)
    mov dword [w_lead], 0
    mov dword [w_dir], 1
    mov eax, [w_heading]
    jmp .lead
.back:
    mov dword [w_lead], NSEG - 1
    mov dword [w_dir], -1
    mov eax, [wy + (NSEG-1)*4]
    sub eax, [wy + (NSEG-2)*4]
    mov ebx, [wx + (NSEG-1)*4]
    sub ebx, [wx + (NSEG-2)*4]
    call iatan2
.lead:
    mov [w_ang], eax
    call cos_q14
    imul eax, [w_d]
    sar eax, 8                     ; quarter px * Q14 cos -> Q8 px
    mov ebx, [w_lead]
    add [wx + ebx*4], eax
    mov eax, [w_ang]
    call sin_q14
    imul eax, [w_d]
    sar eax, 8
    add [wy + ebx*4], eax
    ; follow the leader
    mov esi, [w_lead]
    add esi, [w_dir]
.fl:
    cmp esi, 0
    jl  .fd
    cmp esi, NSEG
    jge .fd
    mov edi, esi
    sub edi, [w_dir]               ; previous point
    mov eax, [wx + esi*4]
    sub eax, [wx + edi*4]
    mov [w_dx], eax
    mov eax, [wy + esi*4]
    sub eax, [wy + edi*4]
    mov [w_dy], eax
    mov eax, [w_dx]
    sar eax, 8
    imul eax, eax
    mov ebx, [w_dy]
    sar ebx, 8
    imul ebx, ebx
    add eax, ebx
    call isqrt                     ; dist (px)
    test eax, eax
    jz  .fn
    mov ecx, eax
    mov eax, [w_dx]
    imul eax, SEG_LEN
    cdq
    idiv ecx
    add eax, [wx + edi*4]
    mov [wx + esi*4], eax
    mov eax, [w_dy]
    imul eax, SEG_LEN
    cdq
    idiv ecx
    add eax, [wy + edi*4]
    mov [wy + esi*4], eax
.fn:
    add esi, [w_dir]
    jmp .fl
.fd:
    cmp dword [w_spd], 0
    jge .wall
    mov eax, [wy]                  ; after backing up the heading follows the body
    sub eax, [wy + 4]
    mov ebx, [wx]
    sub ebx, [wx + 4]
    call iatan2
    mov [w_heading], eax
.wall:
    ; dish wall = a touch on whichever end hit it; push the point back inside
    xor esi, esi                   ; head
    call wall_check
    mov esi, NSEG - 1              ; tail
    call wall_check
.food:
    cmp dword [w_food_on], 0
    je  .respawn
    mov eax, [wx]
    sar eax, 8
    sub eax, [w_food_x]
    mov ebx, [wy]
    sar ebx, 8
    sub ebx, [w_food_y]
    imul eax, eax
    imul ebx, ebx
    add eax, ebx
    cmp eax, EAT_R * EAT_R
    jae .d
    call eat_food
    ret
.respawn:
    cmp dword [w_food_timer], 0
    je  .d
    dec dword [w_food_timer]
    jnz .d
    xor eax, eax                   ; random place
    call place_food
.d:
    ret

; wall_check: ESI = point index
wall_check:
    mov eax, [wx + esi*4]
    sar eax, 8
    sub eax, DISH_CX
    mov ebx, [wy + esi*4]
    sar ebx, 8
    sub ebx, DISH_CY
    mov [w_dx], eax
    mov [w_dy], ebx
    imul eax, eax
    imul ebx, ebx
    add eax, ebx
    cmp eax, (DISH_R - 8) * (DISH_R - 8)
    jbe .ok
    test esi, esi
    jnz .tail
    cmp dword [w_touch_head], TOUCH_FRAMES
    jge .push
    mov dword [w_touch_head], TOUCH_FRAMES
    jmp .push
.tail:
    cmp dword [w_touch_tail], TOUCH_FRAMES
    jge .push
    mov dword [w_touch_tail], TOUCH_FRAMES
.push:
    call isqrt
    test eax, eax
    jnz .dd
    inc eax
.dd:
    mov ecx, eax
    mov eax, [w_dx]
    imul eax, DISH_R - 10
    cdq
    idiv ecx
    add eax, DISH_CX
    shl eax, 8
    mov [wx + esi*4], eax
    mov eax, [w_dy]
    imul eax, DISH_R - 10
    cdq
    idiv ecx
    add eax, DISH_CY
    shl eax, 8
    mov [wy + esi*4], eax
.ok:
    ret

; place_food: EAX = 1 -> 260 px ahead of the head, 0 -> random; redraws the background
place_food:
    test eax, eax
    jz  .rand
    mov eax, [w_heading]
    call cos_q14
    imul eax, 200
    sar eax, 14
    mov ebx, [wx]
    sar ebx, 8
    add eax, ebx
    mov [w_food_x], eax
    mov eax, [w_heading]
    call sin_q14
    imul eax, 200
    sar eax, 14
    mov ebx, [wy]
    sar ebx, 8
    add eax, ebx
    mov [w_food_y], eax
    jmp .clamp
.rand:
    call arc_rand
    mov ebx, eax
    xor edx, edx
    mov ecx, 320
    div ecx
    add edx, DISH_CX - 160
    mov [w_food_x], edx
    mov eax, ebx
    shr eax, 16
    xor edx, edx
    div ecx
    add edx, DISH_CY - 160
    mov [w_food_y], edx
.clamp:
    mov eax, [w_food_x]
    sub eax, DISH_CX
    mov ebx, [w_food_y]
    sub ebx, DISH_CY
    mov [w_dx], eax
    mov [w_dy], ebx
    imul eax, eax
    imul ebx, ebx
    add eax, ebx
    call isqrt
    cmp eax, DISH_R - 80
    jbe .on
    mov ecx, eax
    mov eax, [w_dx]
    imul eax, DISH_R - 80
    cdq
    idiv ecx
    add eax, DISH_CX
    mov [w_food_x], eax
    mov eax, [w_dy]
    imul eax, DISH_R - 80
    cdq
    idiv ecx
    add eax, DISH_CY
    mov [w_food_y], eax
.on:
    mov dword [w_food_on], 1
    mov dword [w_food_timer], 0
    mov dword [w_food_amount], FOOD_AMOUNT
    call bg_draw_all
    call bg_blit_all
    call hud_static
    ret

; ---------------------------------------------------------------------
; background layer
; bg_draw_all: black, agar disc, dish ring, food glow -> BG_LAYER
bg_draw_all:
    pushad
    mov edi, BG_LAYER
    mov ecx, [fb_size]
    shr ecx, 2
    xor eax, eax
    rep stosd
    mov eax, [lfb_phys]
    mov [w_lfb_save], eax
    mov dword [lfb_phys], BG_LAYER ; fill_rect now paints the background layer
    mov ebx, -DISH_R               ; dy
.row:
    mov eax, DISH_R * DISH_R
    mov ecx, ebx
    imul ecx, ecx
    sub eax, ecx
    push ebx
    call isqrt                     ; outer half-width
    pop ebx
    mov esi, eax
    mov eax, (DISH_R - 3) * (DISH_R - 3)
    mov ecx, ebx
    imul ecx, ecx
    sub eax, ecx
    jns .in
    xor eax, eax
    jmp .in2
.in:
    push ebx
    call isqrt                     ; inner half-width
    pop ebx
.in2:
    mov edi, eax
    ; agar: [cx-inner, cx+inner]
    mov eax, DISH_CX
    sub eax, edi
    mov [r_x], eax
    lea eax, [edi*2 + 1]
    mov [r_w], eax
    mov eax, ebx
    add eax, DISH_CY
    mov [r_y], eax
    mov dword [r_h], 1
    mov dword [r_col], C_AGAR
    call fill_rect
    ; ring: [cx-outer, cx+outer] minus the agar span
    mov eax, DISH_CX
    sub eax, esi
    mov [r_x], eax
    mov eax, esi
    sub eax, edi
    mov [r_w], eax
    mov dword [r_col], C_RING
    call fill_rect
    mov eax, DISH_CX
    add eax, edi
    inc eax
    mov [r_x], eax
    call fill_rect
    inc ebx
    cmp ebx, DISH_R
    jle .row
    call draw_food_glow
    call graph_static_edges        ; dim synapse lines into the background layer
    mov eax, [w_lfb_save]
    mov [lfb_phys], eax
    popad
    ret

; draw_food_glow: radial glow into the current [lfb_phys] target (quadratic falloff)
draw_food_glow:
    cmp dword [w_food_on], 0
    je  .d
    mov ebx, -FOOD_R               ; dy
.gy:
    mov eax, ebx
    add eax, [w_food_y]
    cmp eax, 0
    jl  .ny
    cmp eax, [lfb_h]
    jge .ny
    imul eax, [lfb_pitch]
    add eax, [lfb_phys]
    mov [w_rowp], eax
    mov ecx, -FOOD_R               ; dx
.gx:
    mov eax, ecx
    imul eax, eax
    mov edx, ebx
    imul edx, edx
    add eax, edx                   ; d2
    cmp eax, FOOD_R2
    jae .nx
    mov edx, FOOD_R2
    sub edx, eax
    mov eax, edx
    imul eax, edx                  ; (R2-d2)^2 for a softer core
    xor edx, edx
    mov esi, FOOD_R2 * FOOD_R2 / 255
    div esi                        ; intensity 0..255
    mov esi, eax                   ; R = i
    mov edx, eax
    imul edx, 5
    shr edx, 3                     ; G = 5i/8
    shl edx, 8
    shr eax, 3                     ; B = i/8
    or  eax, edx
    mov edx, esi
    shl edx, 16
    or  eax, edx
    mov edx, ecx
    add edx, [w_food_x]
    cmp edx, 0
    jl  .nx
    cmp edx, 580                   ; keep the glow off the brain graph
    jge .nx
    push eax
    mov eax, edx                   ; clip the glow to the agar disc
    sub eax, DISH_CX
    imul eax, eax
    mov esi, ebx
    add esi, [w_food_y]
    sub esi, DISH_CY
    imul esi, esi
    add eax, esi
    cmp eax, (DISH_R - 3) * (DISH_R - 3)
    pop eax
    jae .nx
    mov esi, [w_rowp]
    mov [esi + edx*4], eax
.nx:
    inc ecx
    cmp ecx, FOOD_R
    jl  .gx
.ny:
    inc ebx
    cmp ebx, FOOD_R
    jl  .gy
.d:
    ret

; bg_blit_all: BG_LAYER -> LFB (whole screen)
bg_blit_all:
    pushad
    mov esi, BG_LAYER
    mov edi, [lfb_phys]
    mov ecx, [fb_size]
    shr ecx, 2
    rep movsd
    popad
    ret

; bg_blit_rect: restore the background under [r_x],[r_y],[r_w],[r_h] (clipped)
bg_blit_rect:
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
    lea edi, [edi + eax*4]         ; byte offset
    mov [w_off], edi
.row:
    mov edi, [w_off]
    mov ecx, ebx
    push esi
    mov esi, edi
    add esi, BG_LAYER
    add edi, [lfb_phys]
    rep movsd
    pop esi
    mov eax, [lfb_pitch]
    add [w_off], eax
    dec esi
    jnz .row
.q:
    popad
    ret

; ---------------------------------------------------------------------
; render
worm_render:
    ; erase the body (restore background) at the previously drawn positions
    xor ecx, ecx
.er:
    mov eax, [wpx + ecx*4]
    sub eax, 6
    mov [r_x], eax
    mov eax, [wpy + ecx*4]
    sub eax, 6
    mov [r_y], eax
    mov dword [r_w], 13
    mov dword [r_h], 13
    call bg_blit_rect
    inc ecx
    cmp ecx, NSEG
    jb  .er
    cmp dword [w_finger_x], -1
    je  .nf
    mov eax, [w_finger_x]
    mov [r_x], eax
    mov eax, [w_finger_y]
    mov [r_y], eax
    mov dword [r_w], 10
    mov dword [r_h], 10
    call bg_blit_rect
    mov dword [w_finger_x], -1
.nf:
    ; trail dot at the head: into the background layer and the screen
    mov eax, [wx]
    sar eax, 8
    mov ebx, [wy]
    sar ebx, 8
    mov ecx, 2
    mov edx, 2
    mov esi, C_TRAIL
    mov edi, [lfb_phys]
    mov [w_lfb_save], edi
    mov dword [lfb_phys], BG_LAYER
    call rect
    mov edi, [w_lfb_save]
    mov [lfb_phys], edi
    call rect
    ; drawn positions: chain point + local normal * muscle offset
    call drawn_positions
    ; body segments (tail first so the head is drawn on top)
    mov ecx, NSEG - 1
.seg:
    mov eax, [wpx + ecx*4]
    mov ebx, [wpy + ecx*4]
    movzx edx, byte [seg_width + ecx]
    mov esi, edx
    shr esi, 1
    sub eax, esi
    sub ebx, esi
    mov esi, C_BODY
    test ecx, ecx
    jnz .nh
    mov esi, C_HEAD
.nh:
    cmp ecx, NSEG - 4
    jb  .nt
    mov esi, C_TAIL
.nt:
    push ecx
    mov ecx, edx
    call rect
    pop ecx
    dec ecx
    jns .seg
    ; pharynx: a dot in the head while it pumps
    cmp dword [w_pump], 0
    je  .nopumpdot
    mov eax, [wpx]
    sub eax, 2
    mov ebx, [wpy]
    sub ebx, 2
    mov ecx, 4
    mov edx, 4
    mov esi, C_PUMP
    call rect
.nopumpdot:
    ; "finger" poke marker
    cmp dword [w_touch_head], 0
    jne .fh
    cmp dword [w_touch_tail], 0
    je  .nfinger
    mov eax, [wpx + (NSEG-1)*4]
    mov ebx, [wpy + (NSEG-1)*4]
    jmp .fdraw
.fh:
    mov eax, [wpx]
    mov ebx, [wpy]
.fdraw:
    sub eax, 5
    sub ebx, 22
    mov [w_finger_x], eax
    mov [w_finger_y], ebx
    mov ecx, 10
    mov edx, 10
    mov esi, C_FINGER
    call rect
.nfinger:
    call graph_draw
    call muscles_draw
    call hud_status
    ret

; drawn_positions: wpx/wpy[k] = chain point k + (normal to the chain at k) * off[k]
drawn_positions:
    pushad
    xor ecx, ecx
.k:
    mov eax, ecx
    dec eax
    jns .a
    xor eax, eax
.a:
    mov ebx, ecx
    inc ebx
    cmp ebx, NSEG
    jb  .b
    mov ebx, NSEG - 1
.b:
    mov esi, [wx + eax*4]
    sub esi, [wx + ebx*4]
    sar esi, 8                     ; tx
    mov edi, [wy + eax*4]
    sub edi, [wy + ebx*4]
    sar edi, 8                     ; ty
    mov [w_tx], esi
    mov [w_ty], edi
    mov eax, esi
    imul eax, eax
    mov ebx, edi
    imul ebx, ebx
    add eax, ebx
    push ecx                       ; isqrt clobbers ECX (the segment index)
    call isqrt
    pop ecx
    test eax, eax
    jnz .n
    inc eax
.n:
    mov ebp, eax                   ; n
    mov eax, [w_ty]
    neg eax
    imul eax, [w_lat + ecx*4]
    cdq
    idiv ebp                       ; nx = -ty*off/n
    mov ebx, [wx + ecx*4]
    sar ebx, 8
    add eax, ebx
    mov [wpx + ecx*4], eax
    mov eax, [w_tx]
    imul eax, [w_lat + ecx*4]
    cdq
    idiv ebp                       ; ny = tx*off/n
    mov ebx, [wy + ecx*4]
    sar ebx, 8
    add eax, ebx
    mov [wpy + ecx*4], eax
    inc ecx
    cmp ecx, NSEG
    jb  .k
    popad
    ret

; graph_init: node_x/node_y[i] for the 302 neurons (layered columns per group)
graph_init:
    pushad
    xor ecx, ecx
.n:
    mov eax, ecx
    mov ebx, GX_S
    mov esi, ROWS_S
    mov edi, PITCH_S
    cmp ecx, [br_sens_end]
    jb  .g
    sub eax, [br_sens_end]
    mov ebx, GX_I
    mov esi, ROWS_I
    mov edi, PITCH_I
    cmp ecx, [br_inter_end]
    jb  .g
    mov eax, ecx
    sub eax, [br_inter_end]
    mov ebx, GX_M
    mov esi, ROWS_M
    mov edi, PITCH_M
.g:
    xor edx, edx
    div esi                        ; eax = column, edx = row
    imul eax, 40
    add eax, ebx
    mov [node_x + ecx*2], ax
    imul edx, edi
    add edx, GY
    mov [node_y + ecx*2], dx
    inc ecx
    cmp ecx, 302
    jb  .n
    mov byte [flash_n], 0
    popad
    ret

; node_colour: ECX = neuron -> ESI = group colour
node_colour:
    mov esi, C_SENS
    cmp ecx, [br_sens_end]
    jb  .d
    mov esi, C_INTER
    cmp ecx, [br_inter_end]
    jb  .d
    mov esi, C_MOTOR
.d:
    ret

; draw_edges: ECX = source neuron; draws its synapses with |w| >= EDGE_THR to other
; neurons as lines from node centre to node centre. ESI = colour, or -1 = restore
; the background pixels (undo a flash). Preserves all registers.
draw_edges:
    pushad
    mov [w_lcol], esi
    mov dword [w_ethr], EDGE_THR
    cmp esi, C_EDGE
    je  .thr
    mov dword [w_ethr], FLASH_THR  ; flashes (and their undo) use the higher threshold
.thr:
    mov esi, [br_blob]
    lea ebp, [esi+128]              ; offsets
    lea edx, [esi+128+612]          ; entries
    movzx eax, word [ebp+ecx*2]
    movzx ebx, word [ebp+ecx*2+2]
    mov [w_eend], ebx
    movzx ebx, word [node_x + ecx*2]
    add ebx, NODE / 2
    mov [w_lx0], ebx
    movzx ebx, word [node_y + ecx*2]
    add ebx, NODE / 2
    mov [w_ly0], ebx
.e:
    cmp eax, [w_eend]
    jae .d
    movzx ebx, word [edx+eax*2]
    mov edi, ebx
    and edi, 0x1FF                  ; dst
    cmp edi, 302
    jae .next
    shl ebx, 16
    sar ebx, 25                     ; weight
    cmp ebx, 0
    jge .pos
    neg ebx
.pos:
    cmp ebx, [w_ethr]
    jl  .next
    movzx ebx, word [node_x + edi*2]
    add ebx, NODE / 2
    mov [w_lx1], ebx
    movzx ebx, word [node_y + edi*2]
    add ebx, NODE / 2
    mov [w_ly1], ebx
    push eax
    push edx
    call draw_line
    pop edx
    pop eax
.next:
    inc eax
    jmp .e
.d:
    popad
    ret

; draw_line: ([w_lx0],[w_ly0]) -> ([w_lx1],[w_ly1]) into the current [lfb_phys],
; colour [w_lcol] (or -1 = copy the pixel from BG_LAYER). Bresenham, no clipping
; (all nodes lie inside the screen). Clobbers EAX..EDI; preserves EBP.
draw_line:
    push ebp
    mov eax, [w_lx0]
    mov ebx, [w_ly0]
    mov ecx, [w_lx1]
    sub ecx, eax                    ; dx
    mov edx, [w_ly1]
    sub edx, ebx                    ; dy
    mov dword [w_sx], 4             ; step in bytes
    cmp ecx, 0
    jge .dxp
    neg ecx
    mov dword [w_sx], -4
.dxp:
    mov esi, [lfb_pitch]
    mov [w_sy], esi
    cmp edx, 0
    jge .dyp
    neg edx
    neg dword [w_sy]
.dyp:
    mov [w_ldx], ecx
    mov [w_ldy], edx
    mov edi, ecx
    sub edi, edx                    ; err = dx - dy
    mov esi, ebx
    imul esi, [lfb_pitch]
    lea esi, [esi + eax*4]          ; byte offset of the first pixel
    cmp ecx, edx
    jge .len
    mov ecx, edx
.len:
    inc ecx                         ; pixel count = max(dx,dy)+1
    mov ebx, [w_lcol]               ; colour (or -1)
    mov ebp, [lfb_phys]
.px:
    mov eax, ebx
    cmp ebx, -1
    jne .put
    mov eax, [BG_LAYER + esi]
.put:
    mov [ebp + esi], eax
    dec ecx
    jz  .d
    lea eax, [edi + edi]            ; e2 = 2*err
    mov edx, [w_ldy]
    neg edx
    cmp eax, edx                    ; e2 > -dy ?
    jle .ny
    sub edi, [w_ldy]
    add esi, [w_sx]
.ny:
    cmp eax, [w_ldx]                ; e2 < dx ?
    jge .px
    add edi, [w_ldx]
    add esi, [w_sy]
    jmp .px
.d:
    pop ebp
    ret

; graph_static_edges: all strong synapses as dim lines into the current target
; (called by bg_draw_all with [lfb_phys] = BG_LAYER)
graph_static_edges:
    pushad
    xor ecx, ecx
.n:
    mov esi, C_EDGE
    call draw_edges
    inc ecx
    cmp ecx, 302
    jb  .n
    popad
    ret

; graph_draw: undo last frame's flashes, flash the synapses of the neurons that
; fired this step, then draw all 302 nodes on top (fired = bright, v high = half)
graph_draw:
    pushad
    movzx ebx, byte [flash_n]
    xor edx, edx
.undo:
    cmp edx, ebx
    jae .undone
    movzx ecx, word [flash_list + edx*2]
    mov esi, -1
    call draw_edges
    inc edx
    jmp .undo
.undone:
    xor edx, edx                    ; new flash count
    xor ecx, ecx
.f:
    cmp word [BR_S + ecx*2], 0
    je  .nf
    cmp edx, FLASH_MAX
    jae .nf
    mov [flash_list + edx*2], cx
    inc edx
    call node_colour
    call draw_edges
.nf:
    inc ecx
    cmp ecx, 302
    jb  .f
    mov [flash_n], dl
    ; nodes
    xor ecx, ecx
.node:
    call node_colour
    cmp word [BR_S + ecx*2], 0
    jne .full
    movsx eax, word [BR_V + ecx*2]
    movsx edi, word [BR_THR + ecx*2]
    sar edi, 1
    cmp eax, edi
    jge .half
    shr esi, 2
    and esi, 0x003F3F3F
    jmp .put
.half:
    shr esi, 1
    and esi, 0x007F7F7F
    jmp .put
.full:
    or  esi, 0x00A0A0A0
.put:
    movzx eax, word [node_x + ecx*2]
    movzx ebx, word [node_y + ecx*2]
    push ecx
    mov ecx, NODE
    mov edx, NODE
    call rect
    pop ecx
    inc ecx
    cmp ecx, 302
    jb  .node
    popad
    ret

; muscles_draw: 24 dorsal (up) / ventral (down) bars from the muscle rows' v
muscles_draw:
    mov eax, RX
    mov ebx, MUSC_Y
    mov ecx, 24 * 9 + 4
    mov edx, MUSC_H * 2 + 2
    mov esi, C_BLACK
    call rect
    xor ecx, ecx                   ; segment 0..23
.m:
    mov edi, [br_muscle_row0]
    add edi, ecx
    movsx eax, word [BR_V + edi*2]        ; MDL
    movsx ebx, word [BR_V + edi*2 + 48]   ; MDR (+24 rows)
    add eax, ebx
    sar eax, 4
    call clamp_bar
    mov [w_bar], eax
    mov eax, ecx
    imul eax, 9
    add eax, RX
    mov ebx, MUSC_Y + MUSC_H
    sub ebx, [w_bar]
    push ecx
    mov ecx, 7
    mov edx, [w_bar]
    mov esi, C_DORSAL
    call rect
    pop ecx
    movsx eax, word [BR_V + edi*2 + 96]   ; MVL (+48 rows)
    movsx ebx, word [BR_V + edi*2 + 144]  ; MVR (+72 rows)
    add eax, ebx
    sar eax, 4
    call clamp_bar
    mov [w_bar], eax
    mov eax, ecx
    imul eax, 9
    add eax, RX
    mov ebx, MUSC_Y + MUSC_H + 2
    push ecx
    mov ecx, 7
    mov edx, [w_bar]
    mov esi, C_VENTRAL
    call rect
    pop ecx
    inc ecx
    cmp ecx, 24
    jb  .m
    ret

clamp_bar:
    cmp eax, 1
    jge .a
    mov eax, 1
.a:
    cmp eax, MUSC_H
    jle .b
    mov eax, MUSC_H
.b:
    ret

; dec_to_edi: EAX = value (unsigned), ECX = digits -> fixed-width decimal at [EDI], EDI += ECX
dec_to_edi:
    push eax
    push ebx
    push ecx
    push edx
    add edi, ecx
    mov ebx, edi
    mov esi, 10
.l:
    xor edx, edx
    div esi
    add dl, '0'
    dec ebx
    mov [ebx], dl
    dec ecx
    jnz .l
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; sdec_to_edi: EAX signed, 4 digits with sign
sdec_to_edi:
    mov byte [edi], '+'
    cmp eax, 0
    jge .p
    neg eax
    mov byte [edi], '-'
.p:
    inc edi
    mov ecx, 4
    call dec_to_edi
    ret

; hud_static: title lines + panel labels (drawn once; redrawn after a full blit)
hud_static:
    mov dword [t_x], 8
    mov dword [t_y], 6
    mov dword [t_col], C_HUD
    mov dword [t_scale], 2
    mov esi, s_w_hud1
    call arc_text
    ; "... NNNNN SYNAPSES ..." -> fill in the real numbers from the brain image
    mov edi, numbuf2
    mov eax, [br_ncontacts]
    mov ecx, 5
    call dec_to_edi
    mov byte [edi], 0
    mov esi, numbuf2
    call arc_text
    mov esi, s_w_hud1b
    call arc_text
    mov dword [t_x], 8
    mov dword [t_y], 30
    mov dword [t_scale], 1
    mov dword [t_col], C_HUD2
    mov esi, s_w_hud2
    call arc_text
    mov dword [t_x], 8
    mov dword [t_y], 42
    mov esi, s_w_hud3
    call arc_text
    ; graph labels
    mov dword [t_x], GX_S
    mov dword [t_y], GY - 26
    mov dword [t_col], C_WHITE
    mov esi, s_w_live
    call arc_text
    mov dword [t_x], GX_S
    mov dword [t_y], GY - 13
    mov dword [t_col], C_SENS
    mov esi, s_w_sens
    call arc_text
    mov dword [t_x], GX_I
    mov dword [t_y], GY - 13
    mov dword [t_col], C_INTER
    mov esi, s_w_inter
    call arc_text
    mov dword [t_x], GX_M
    mov dword [t_y], GY - 13
    mov dword [t_col], C_MOTOR
    mov esi, s_w_motor
    call arc_text
    mov dword [t_x], RX
    mov dword [t_y], MUSC_Y - 12
    mov dword [t_col], C_WHITE
    mov esi, s_w_musc
    call arc_text
    mov dword [t_x], RX
    mov dword [t_y], MUSC_Y + MUSC_H * 2 + 8
    mov dword [t_col], C_HUD2
    mov esi, s_w_keys
    call arc_text
    mov dword [t_x], RX
    mov dword [t_y], MUSC_Y + MUSC_H * 2 + 20
    mov esi, s_w_keys2
    call arc_text
    ret

; hud_status: live line (bottom left)
hud_status:
    mov edi, statbuf
    mov esi, s_w_st1               ; "FRAME "
    call strcpy_edi
    mov eax, [w_frame]
    mov ecx, 6
    call dec_to_edi
    mov esi, s_w_st2               ; "  FWD "
    call strcpy_edi
    mov eax, [w_fw]
    mov ecx, 3
    call dec_to_edi
    mov esi, s_w_st3               ; " BWD "
    call strcpy_edi
    mov eax, [w_bw]
    mov ecx, 3
    call dec_to_edi
    mov esi, s_w_st4               ; "  DRIVE "
    call strcpy_edi
    mov eax, [w_drive]
    call sdec_to_edi
    mov esi, s_w_st5               ; "  "
    call strcpy_edi
    mov esi, s_w_fwd
    cmp dword [w_spd], 0
    jg  .st
    mov esi, s_w_stop
    je  .st
    mov esi, s_w_rev
.st:
    call strcpy_edi
    mov esi, s_w_st6               ; "  FOOD "
    call strcpy_edi
    mov eax, [w_c_now]
    mov ecx, 3
    call dec_to_edi
    mov esi, s_w_st7               ; " EATEN "
    call strcpy_edi
    mov eax, [w_ate]
    mov ecx, 2
    call dec_to_edi
    mov esi, s_w_st8               ; "  TOUCH "
    call strcpy_edi
    mov al, '-'
    cmp dword [w_touch_head], 0
    je  .h
    mov al, 'H'
.h:
    stosb
    mov al, '-'
    cmp dword [w_touch_tail], 0
    je  .t
    mov al, 'T'
.t:
    stosb
    mov esi, s_w_st9               ; "  PUMPS "
    call strcpy_edi
    mov eax, [w_pumps]
    mov ecx, 4
    call dec_to_edi
    mov byte [edi], 0
    ; draw the strip off-screen (no tearing on screenshots), then copy it in
    mov eax, [lfb_phys]
    mov [w_lfb_save], eax
    mov dword [lfb_phys], STAT_LAYER
    mov eax, 8
    xor ebx, ebx
    mov ecx, 760
    mov edx, STAT_H
    mov esi, C_BLACK
    call rect
    mov dword [t_x], 8
    mov dword [t_y], 0
    mov dword [t_scale], 1
    mov dword [t_col], C_HUD
    mov esi, statbuf
    call arc_text
    mov eax, [w_lfb_save]
    mov [lfb_phys], eax
    mov esi, STAT_LAYER
    mov edi, [lfb_h]
    sub edi, 44
    imul edi, [lfb_pitch]
    add edi, eax
    mov ecx, STAT_H
.cp:
    push ecx
    mov ecx, 768 * 4 / 4
    push esi
    push edi
    rep movsd
    pop edi
    pop esi
    add esi, [lfb_pitch]
    add edi, [lfb_pitch]
    pop ecx
    dec ecx
    jnz .cp
    ret

strcpy_edi:
    lodsb
    test al, al
    jz  .d
    stosb
    jmp strcpy_edi
.d:
    ret

; ---------------------------------------------------------------------
; PC speaker chirp: EAX = PIT divisor (1193182 / Hz), ECX = frames
worm_beep:
    mov [w_beep], ecx
    push eax
    mov al, 0xB6                   ; ch2, lo/hi, mode 3 (square wave)
    out 0x43, al
    pop eax
    out 0x42, al
    mov al, ah
    out 0x42, al
    in  al, 0x61
    or  al, 3                      ; gate + speaker on
    out 0x61, al
    ret
worm_beep_tick:
    cmp dword [w_beep], 0
    je  .d
    dec dword [w_beep]
    jnz .d
    in  al, 0x61
    and al, 0xFC
    out 0x61, al
.d:
    ret

; ---------------------------------------------------------------------
; serial debug (QEMU): 'H' = held keys, 'G' = worm state (hex dwords)
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
    je  .state
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
.state:
    mov esi, s_w_g
    call ser_puts
    mov eax, [w_frame]
    call .dw
    mov eax, [br_step_no]
    call .dw
    mov eax, [wx]
    sar eax, 8
    call .dw
    mov eax, [wy]
    sar eax, 8
    call .dw
    mov eax, [w_heading]
    call .dw
    mov eax, [w_drive]
    call .dw
    mov eax, [w_spd]
    call .dw
    mov eax, [w_fw]
    call .dw
    mov eax, [w_bw]
    call .dw
    mov eax, [w_touch_head]
    call .dw
    mov eax, [w_touch_tail]
    call .dw
    mov eax, [w_food_x]
    call .dw
    mov eax, [w_food_y]
    call .dw
    mov eax, [w_food_on]
    call .dw
    mov eax, [w_ate]
    call .dw
    mov eax, [w_c_now]
    call .dw
    mov eax, [br_gi]
    call .dw
    xor eax, eax                   ; neurons firing this step
    xor ebx, ebx
.cnt:
    cmp word [BR_S + ebx*2], 0
    je  .c0
    inc eax
.c0:
    inc ebx
    cmp ebx, 302
    jb  .cnt
    call .dw
    mov eax, [wx + (NSEG-1)*4]
    sar eax, 8
    call .dw
    mov eax, [wy + (NSEG-1)*4]
    sar eax, 8
    call .dw
    mov eax, [w_nsm_timer]
    call .dw
    mov eax, [w_pumps]
    call .dw
    mov eax, [w_food_amount]
    call .dw
    call ser_nl
    jmp .q
.dw:
    call ser_hex32
    mov al, ' '
    call putc
    ret
.q:
    popad
    ret

; ---------------------------------------------------------------------
; data
s_w_novbe   db "WORM: no VBE linear framebuffer - cannot run", 0
s_w_title   db "C. ELEGANS", 0
s_w_sub1    db "302 NEURONS - NO OS - BARE METAL", 0
s_w_sub2    db "A WHOLE ANIMAL BRAIN IN X86 ASSEMBLY", 0
s_w_load    db "LOADING THE CONNECTOME INTO RAM ...", 0
s_w_bad     db "BAD BRAIN IMAGE", 0
s_w_hud1    db "C.ELEGANS  302 NEURONS  ", 0
s_w_hud1b   db " SYNAPSES  NO OS  X86 ASM", 0
s_w_hud2    db "ASUS K50IJ (2009) - PXE BOOT, NO DISK - THE NETWORK IS NOT USED AFTER BOOT: PULL THE CABLE, IT KEEPS LIVING", 0
s_w_hud3    db "REAL CONNECTOME (OPENWORM / WHITE 1986), CARTOON DYNAMICS: INTEGRATE-AND-FIRE, INT16 + SSE2, 120 BRAIN STEPS/S", 0
s_w_live    db "BRAIN LIVE - DOT=NEURON LINE=SYNAPSE FLASH=SPIKE", 0
s_w_sens    db "SENSORY 86", 0
s_w_inter   db "INTERNEURONS 102", 0
s_w_motor   db "MOTOR 114", 0
s_w_musc    db "BODY-WALL MUSCLES  DORSAL / VENTRAL", 0
s_w_keys    db "H = POKE HEAD   T = POKE TAIL", 0
s_w_keys2   db "F = DROP FOOD   R = RESET", 0
s_w_st1     db "FRAME ", 0
s_w_st2     db "  FWD ", 0
s_w_st3     db " BWD ", 0
s_w_st4     db "  DRIVE ", 0
s_w_st5     db "  ", 0
s_w_st6     db "  FOOD ", 0
s_w_st7     db " EATEN ", 0
s_w_st8     db "  TOUCH ", 0
s_w_st9     db "  PUMPS ", 0
s_w_fwd     db "FORWARD ", 0
s_w_rev     db "REVERSE ", 0
s_w_stop    db "PAUSED  ", 0
s_w_g       db "worm: frame step hx hy heading drive spd fw bw th tt fx fy fon ate c gi fired tx ty nsm pumps amount = ", 0
seg_width   db 7, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 8, 8, 8, 7, 7, 6, 6, 5, 4, 3
numbuf2     times 8 db 0
statbuf     times 96 db 0
align 4
wx          times NSEG dd 0        ; body points, Q8 px (head = 0)
wy          times NSEG dd 0
wpx         times NSEG dd 0        ; last drawn (px) for erasing
wpy         times NSEG dd 0
w_heading   dd 128
w_phase     dd 0
w_drive     dd 0
w_spd       dd 0
w_touch_head dd 0
w_touch_tail dd 0
w_food_x    dd 0
w_food_y    dd 0
w_food_on   dd 0
w_food_timer dd 0
w_c_now     dd 0
w_c_slow    dd 0
w_was_back  dd 0
w_back_frames dd 0
w_ate       dd 0
w_frame     dd 0
w_fw        dd 0
w_bw        dd 0
w_finger_x  dd -1
w_finger_y  dd 0
w_keys_prev dd 0
w_d         dd 0
w_swing     dd 0
w_lead      dd 0
w_dir       dd 0
w_ang       dd 0
w_dx        dd 0
w_dy        dd 0
w_lfb_save  dd 0
w_rowp      dd 0
w_off       dd 0
w_bar       dd 0
w_beep      dd 0
w_phase_head dd 0
w_dv_slow   dd 0
w_steer     dd 0
w_steer_acc dd 0
w_nsm_timer dd 0
w_pump      dd 0
w_pumps     dd 0
w_food_amount dd 0
w_md        dd 0
w_mv        dd 0
w_amp       dd 0
w_hamp      dd 0
w_bias      dd 0
w_tx        dd 0
w_ty        dd 0
w_lat       times NSEG dd 0        ; per-segment lateral offset (px) from the muscles
w_lx0       dd 0                   ; draw_line / draw_edges scratch
w_ly0       dd 0
w_lx1       dd 0
w_ly1       dd 0
w_lcol      dd 0
w_ldx       dd 0
w_ldy       dd 0
w_sx        dd 0
w_sy        dd 0
w_eend      dd 0
w_ethr      dd 0
FLASH_MAX   equ 302
flash_n     db 0
align 2
flash_list  times FLASH_MAX dw 0   ; neurons whose synapses were flashed last frame
node_x      times 302 dw 0         ; graph node positions
node_y      times 302 dw 0
%include "worm/data/tables.inc"
