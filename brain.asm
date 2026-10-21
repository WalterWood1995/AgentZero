; brain.asm - the C. elegans "brain" neural primitive (included by stage2.asm,
; 32-bit protected mode, ring 0). The connectome arrives as a compact CSR blob
; (worm/connectome.py -> brain.bin): header + per-source offsets + packed entries
; (dst 9 bits | weight 7 bits signed). brain_init expands it into a dense int16
; matrix W[row][col] in RAM; brain_step runs one leaky integrate-and-fire step:
;
;   acc[i] = sum_j W[i][j] * s[j]                      (int32, pmaddwd)
;   inp    = sat16(acc >> W_SHIFT) +sat ext -sat a -sat gi   (gi: neuron rows only)
;   v      = sat16(v - (v >> LEAK) + inp), v = max(v, VMIN)
;   fire   = v >= thr[i];  s' = fire ? SPIKE : 0;  v = fire ? RESET : v
;   a      = a - (a >> ASHIFT) + (fire ? ainc[i] : 0)       (spike-frequency adaptation)
;   gi'    = min((sum s' over neurons) * GI_GAIN >> GI_SHIFT, GI_MAX)   (global inhibition)
;
; The same arithmetic, bit for bit, is in worm/wormsim.py (the host-side truth the
; kernel is checked against). Rows 0..301 are neurons, 304..399 the 96 body-wall
; muscles (threshold 0x7FFF: never fire, v = muscle activation).
;
; Memory map (inside the L-loadable compute window [0x100000, 0x180000)):
BR_BLOB   equ 0x00100000           ; CSR blob (header 128 B, offsets, entries)
BR_THR    equ 0x00104000           ; int16[NR]  per-row threshold
BR_AINC   equ 0x00104400           ; int16[NR]  per-row adaptation increment
BR_V      equ 0x00104800           ; int16[NR]  membrane
BR_S      equ 0x00104C00           ; int16[NR]  spike output (SPIKE or 0)
BR_EXT    equ 0x00105000           ; int16[NR]  external input (set by host or the worm env)
BR_A      equ 0x00105400           ; int16[NR]  adaptation
BR_ACC    equ 0x00105800           ; int32[NR]  synaptic sum
BR_W      equ 0x00110000           ; int16[NR][NC] dense weights (400 x 304 x 2 = 243200 B)
BR_NR     equ 400
BR_NC     equ 304
BR_NBLK   equ BR_NR / 8            ; 50 blocks of 8 rows
BR_NCBLK  equ BR_NC / 8            ; 38 blocks of 8 columns (neuron rows)

; brain_init: ESI -> blob. Parses the header, builds THR/AINC, expands W, zeroes the
; state. Returns EAX = 1 ok, 0 bad magic.
brain_init:
    pushad
    ; enable SSE/SSE2 for ring 0: CR4.OSFXSR|OSXMMEXCPT, CR0.EM=0 CR0.MP=1
    mov eax, cr4
    or  eax, (1 << 9) | (1 << 10)
    mov cr4, eax
    mov eax, cr0
    and eax, ~(1 << 2)
    or  eax, (1 << 1)
    mov cr0, eax
    cmp dword [esi], 0x314D5257    ; 'WRM1'
    jne .bad
    mov [br_blob], esi
    movzx eax, word [esi+12]
    mov [br_nsyn], eax
    movzx eax, word [esi+14]
    mov [br_ncontacts], eax
    movzx eax, word [esi+16]
    mov [br_leak_cnt], eax         ; shift counts live in the low qword of an m128
    movzx eax, word [esi+18]
    mov [br_wshift_cnt], eax
    movsx eax, word [esi+20]
    mov [br_reset], eax
    movsx eax, word [esi+22]
    mov [br_vmin], eax
    movsx eax, word [esi+24]
    mov [br_spike], eax
    movzx eax, word [esi+26]
    mov [br_steps], eax
    movzx eax, word [esi+28]
    mov [br_fwd_lo], eax
    movzx eax, word [esi+30]
    mov [br_fwd_hi], eax
    movzx eax, word [esi+32]
    mov [br_bwd_lo], eax
    movzx eax, word [esi+34]
    mov [br_bwd_hi], eax
    movzx eax, word [esi+36]
    mov [br_sens_end], eax
    movzx eax, word [esi+38]
    mov [br_inter_end], eax
    movzx eax, word [esi+40]
    mov [br_motor_end], eax
    movzx eax, word [esi+42]
    mov [br_muscle_row0], eax
    movzx eax, word [esi+54]
    mov [br_ash_cnt], eax
    movzx eax, word [esi+58]
    mov [br_gi_gain], eax
    movzx eax, word [esi+60]
    mov [br_gi_shift], eax
    movsx eax, word [esi+62]
    mov [br_gi_max], eax
    ; broadcast constants into m128 vectors (8 x int16)
    mov eax, [br_vmin]
    call br_bcast16
    movdqa [br_vmin_v], xmm0
    mov eax, [br_spike]
    call br_bcast16
    movdqa [br_spike_v], xmm0
    mov eax, [br_reset]
    call br_bcast16
    movdqa [br_reset_v], xmm0
    ; per-row thresholds (thr-1, for the pcmpgtw compare) and adaptation increments
    movsx eax, word [esi+44]        ; thr sensory
    movsx ebx, word [esi+120]       ; ainc sensory
    xor ecx, ecx
    mov edx, [br_sens_end]
    call br_fill_rows
    movsx eax, word [esi+46]
    movsx ebx, word [esi+122]
    mov ecx, [br_sens_end]
    mov edx, [br_inter_end]
    call br_fill_rows
    movsx eax, word [esi+48]
    movsx ebx, word [esi+124]
    mov ecx, [br_inter_end]
    mov edx, [br_motor_end]
    call br_fill_rows
    movsx eax, word [esi+50]        ; muscles + pad rows: never fire, no adaptation
    xor ebx, ebx
    mov ecx, [br_motor_end]
    mov edx, BR_NR
    call br_fill_rows
    ; zero W and the state
    mov edi, BR_W
    mov ecx, (BR_NR * BR_NC * 2) / 4
    xor eax, eax
    rep stosd
    call brain_reset_state
    ; expand CSR: for src j: for e in offs[j]..offs[j+1]: W[dst][j] += w
    lea ebp, [esi+128]              ; offsets u16[NC+1]
    lea edx, [esi+128+612]          ; entries u16[nsyn]
    xor ecx, ecx                    ; j
.col:
    movzx eax, word [ebp+ecx*2]     ; start
    movzx ebx, word [ebp+ecx*2+2]   ; end
.ent:
    cmp eax, ebx
    jae .ncol
    movzx edi, word [edx+eax*2]
    push eax
    mov eax, edi
    and edi, 0x1FF                  ; dst row
    shr eax, 9                      ; 7-bit weight
    shl eax, 25
    sar eax, 25                     ; sign-extend
    imul edi, edi, BR_NC
    add edi, ecx
    add [BR_W+edi*2], ax
    pop eax
    inc eax
    jmp .ent
.ncol:
    inc ecx
    cmp ecx, BR_NC
    jb  .col
    mov byte [br_ready], 1
    popad
    mov eax, 1
    ret
.bad:
    popad
    xor eax, eax
    ret

; br_fill_rows: rows [ECX, EDX): THR = AX-1, AINC = BX
br_fill_rows:
    push ecx
    dec eax
.l:
    cmp ecx, edx
    jae .d
    mov [BR_THR+ecx*2], ax
    mov [BR_AINC+ecx*2], bx
    inc ecx
    jmp .l
.d:
    inc eax
    pop ecx
    ret

; br_bcast16: AX -> xmm0 = 8 copies
br_bcast16:
    movd xmm0, eax
    punpcklwd xmm0, xmm0
    pshufd xmm0, xmm0, 0
    ret

; brain_reset_state: v = s = ext = a = 0, gi = 0, step counter = 0
brain_reset_state:
    pushad
    mov edi, BR_V
    mov ecx, (BR_A + 0x400 - BR_V) / 4   ; V, S, EXT, A: 4 x 1 KiB slots, contiguous
    xor eax, eax
    rep stosd
    mov [br_gi], eax
    mov [br_step_no], eax
    popad
    ret

; brain_bias_ext: EXT = the tonic bias vector from the header (the worm env calls
; this every step, then adds the stimuli)
brain_bias_ext:
    pushad
    mov edi, BR_EXT
    mov ecx, BR_NR / 2
    xor eax, eax
    rep stosd
    mov esi, [br_blob]
    movzx ecx, word [esi+52]        ; nbias
    lea esi, [esi+96]
.l:
    test ecx, ecx
    jz  .d
    movzx eax, word [esi]           ; row
    mov bx, [esi+2]                 ; value
    mov [BR_EXT+eax*2], bx
    add esi, 4
    dec ecx
    jmp .l
.d:
    popad
    ret

; brain_step: one step (see the header comment). Uses the dense SSE2 path, or the
; scalar sparse path when br_mode = 1 (both must give identical results).
brain_step:
    pushad
    cmp byte [br_mode], 0
    jne .sparse
    ; ---- phase 1 (SSE2): acc[i] = row_i . s ----
    mov esi, BR_W
    mov edi, BR_ACC
    mov ecx, BR_NR
.row:
    pxor xmm0, xmm0
    mov edx, BR_S
    mov ebx, BR_NCBLK
.col:
    movdqa xmm1, [esi]
    pmaddwd xmm1, [edx]
    paddd xmm0, xmm1
    add esi, 16
    add edx, 16
    dec ebx
    jnz .col
    pshufd xmm1, xmm0, 0x4E         ; horizontal add of the 4 dwords
    paddd xmm0, xmm1
    pshufd xmm1, xmm0, 0xB1
    paddd xmm0, xmm1
    movd [edi], xmm0
    add edi, 4
    dec ecx
    jnz .row
    jmp .phase2
.sparse:
    ; ---- phase 1 (scalar, CSR): acc[dst] += w * s[src] ----
    mov edi, BR_ACC
    mov ecx, BR_NR
    xor eax, eax
    rep stosd
    mov esi, [br_blob]
    lea ebp, [esi+128]              ; offsets
    lea edx, [esi+128+612]          ; entries
    xor ecx, ecx                    ; src j
.sc:
    movsx edi, word [BR_S+ecx*2]    ; s[j]
    test edi, edi
    jz  .snext
    movzx eax, word [ebp+ecx*2]
    movzx ebx, word [ebp+ecx*2+2]
.se:
    cmp eax, ebx
    jae .snext
    push eax
    movzx eax, word [edx+eax*2]
    push ebx
    mov ebx, eax
    and ebx, 0x1FF                  ; dst
    shl eax, 16                     ; bit 15 (weight sign) -> bit 31
    sar eax, 25                     ; weight (sign-extended 7 bits)
    imul eax, edi                   ; w * s
    add [BR_ACC+ebx*4], eax
    pop ebx
    pop eax
    inc eax
    jmp .se
.snext:
    inc ecx
    cmp ecx, BR_NC
    jb  .sc
.phase2:
    ; ---- phase 2 (SSE2, 8 rows per block): integrate, fire, adapt ----
    mov eax, [br_gi]
    call br_bcast16
    movdqa xmm6, xmm0               ; gi broadcast (neuron blocks only)
    pxor xmm7, xmm7                 ; spike total accumulator (int16 lanes)
    xor ecx, ecx                    ; block index
.blk:
    mov eax, ecx
    shl eax, 4                      ; byte offset of this block in the int16 vectors
    lea ebx, [eax*2]                ; byte offset in the int32 acc
    movdqa xmm0, [BR_ACC+ebx]
    movdqa xmm1, [BR_ACC+ebx+16]
    psrad xmm0, [br_wshift_cnt]
    psrad xmm1, [br_wshift_cnt]
    packssdw xmm0, xmm1             ; inp = sat16(acc >> wshift)
    paddsw xmm0, [BR_EXT+eax]
    psubsw xmm0, [BR_A+eax]
    cmp ecx, BR_NCBLK
    jae .nogi
    psubsw xmm0, xmm6
.nogi:
    movdqa xmm1, [BR_V+eax]
    movdqa xmm2, xmm1
    psraw xmm2, [br_leak_cnt]
    psubsw xmm1, xmm2               ; v - (v >> leak)
    paddsw xmm1, xmm0               ; + inp
    pmaxsw xmm1, [br_vmin_v]
    movdqa xmm3, xmm1
    pcmpgtw xmm3, [BR_THR+eax]      ; fire = v > thr-1
    movdqa xmm4, xmm3
    pand xmm4, [br_spike_v]         ; s' = fire ? spike : 0
    movdqa [BR_S+eax], xmm4
    cmp ecx, BR_NCBLK
    jae .nosum
    paddw xmm7, xmm4
.nosum:
    movdqa xmm2, xmm3
    pand xmm2, [br_reset_v]         ; fire ? reset : 0
    pandn xmm3, xmm1                ; !fire ? v : 0   (xmm3 = ~fire & v)
    por xmm3, xmm2
    movdqa [BR_V+eax], xmm3
    movdqa xmm0, [BR_A+eax]
    movdqa xmm2, xmm0
    psraw xmm2, [br_ash_cnt]
    psubsw xmm0, xmm2               ; a - (a >> ash)
    movdqa xmm2, [BR_AINC+eax]
    movdqa xmm3, xmm1               ; recompute fire mask (xmm3 was consumed)
    pcmpgtw xmm3, [BR_THR+eax]
    pand xmm2, xmm3
    paddsw xmm0, xmm2
    movdqa [BR_A+eax], xmm0
    inc ecx
    cmp ecx, BR_NBLK
    jb  .blk
    ; gi' = min((total * gain) >> shift, gi_max)
    movdqa xmm0, xmm7
    pshufd xmm1, xmm0, 0x4E
    paddw xmm0, xmm1
    pshufd xmm1, xmm0, 0xB1
    paddw xmm0, xmm1
    movd eax, xmm0
    movzx edx, ax                   ; lane 0
    shr eax, 16                     ; lane 1
    add eax, edx                    ; total (<= 304*spike, fits)
    imul eax, [br_gi_gain]
    mov ecx, [br_gi_shift]
    sar eax, cl
    cmp eax, [br_gi_max]
    jle .gok
    mov eax, [br_gi_max]
.gok:
    mov [br_gi], eax
    inc dword [br_step_no]
    popad
    ret

; brain_sum_range: ECX = lo, EDX = hi -> EAX = sum of s[lo..hi) (spike counts * SPIKE)
brain_sum_range:
    xor eax, eax
.l:
    cmp ecx, edx
    jae .d
    movsx ebx, word [BR_S+ecx*2]
    add eax, ebx
    inc ecx
    jmp .l
.d:
    ret

; brain_fwd / brain_bwd: EAX = forward (B-class) / backward (A-class) motor drive this step
brain_fwd:
    push ebx
    push ecx
    push edx
    mov ecx, [br_fwd_lo]
    mov edx, [br_fwd_hi]
    call brain_sum_range
    pop edx
    pop ecx
    pop ebx
    ret
brain_bwd:
    push ebx
    push ecx
    push edx
    mov ecx, [br_bwd_lo]
    mov edx, [br_bwd_hi]
    call brain_sum_range
    pop edx
    pop ecx
    pop ebx
    ret

; ---- brain state (kernel data) ----
align 16
br_vmin_v   times 16 db 0
br_spike_v  times 16 db 0
br_reset_v  times 16 db 0
br_leak_cnt dd 0, 0, 0, 0          ; shift counts for psraw/psrad (low qword)
br_wshift_cnt dd 0, 0, 0, 0
br_ash_cnt  dd 0, 0, 0, 0
br_blob     dd 0
br_nsyn     dd 0
br_ncontacts dd 0
br_reset    dd 0
br_vmin     dd 0
br_spike    dd 0
br_steps    dd 2
br_fwd_lo   dd 0
br_fwd_hi   dd 0
br_bwd_lo   dd 0
br_bwd_hi   dd 0
br_sens_end dd 0
br_inter_end dd 0
br_motor_end dd 0
br_muscle_row0 dd 304
br_gi_gain  dd 0
br_gi_shift dd 0
br_gi_max   dd 0
br_gi       dd 0
br_step_no  dd 0
br_mode     db 0                   ; 0 = SSE2 dense, 1 = scalar sparse (CSR)
br_ready    db 0
