; stage2.asm - AgentZero serial+VGA REPL (milestone 3 + Matrix mode).
; Loaded by stage1 at 0x0000:0x8000 in 16-bit real mode. Enables A20, builds a
; flat GDT (null / 4 GiB code / 4 GiB data), sets CR0.PE and far-jumps into a
; 32-bit code segment. The REPL then runs at ring 0 in protected mode with flat
; 4 GiB addressing, mirroring everything to BOTH the COM1 serial line (the
; Agent's channel) and the VGA text buffer at 0xB8000 in bright green on black
; (Matrix style). Each command line is read whole, then every character is
; echoed back as an 8-bit binary string before the command executes.
; No OS, no interrupts (IF stays clear, no IDT) - just CPU, UART, VGA, hardware.
;
; Line protocol (host sends the command then a CR; each reply ends with CRLF):
;   C                        -> CPUID leaf 0 vendor string (e.g. GenuineIntel)
;   F                        -> CPUID leaf 1 EAX (family/model/stepping), 8 hex
;   I<4hex>                  -> inb from that I/O port, reply "=XX"
;   T                        -> RTC time from CMOS (ports 70/71) as HH:MM:SS (BCD)
;   M<8hex addr><2hex len>   -> read <len> bytes of linear memory, hex dump
;   P<2hex bus><2hex dev><1hex func><2hex off>
;                            -> PCI config dword via mechanism 1 (0xCF8/0xCFC)
;   O<4hex port><2hex val>!  -> outb (GATED: trailing '!' confirm byte required)
;   W<8hex addr><8hex dword>! -> write one dword to linear/physical memory or MMIO
;                              (GATED: trailing '!' confirm byte required)
;   ?                        -> list commands
;
; Build: nasm -f bin stage2.asm -o stage2.bin

BITS 16
ORG 0x8000

COM1 equ 0x3F8
CODE_SEL equ 0x08
DATA_SEL equ 0x10
VGA      equ 0x00020000            ; PM text console: a RAM shadow (80x50 char+attr cells).
                                   ; In the VBE graphics mode the legacy 0xB8000 text buffer
                                   ; isn't displayable, so the console lives in plain RAM and
                                   ; present_text renders it to the framebuffer as pixels.
                                   ; (The real-mode boot animation still uses VGASEG=0xB800.)
VGA_ATTR equ 0x0A                  ; black background, bright green foreground
SCR_ROWS equ 50                    ; 80x50 text mode (small 8x8 font, fine detail)
SCR_CELLS equ 80 * SCR_ROWS
RAIN_FRAMES equ 170                ; how many animation frames the intro runs
FRAME_COUNTS equ 29800             ; PIT ch0 counts per frame (~25 ms, CPU-independent)
%ifdef NIC_NATIVE
STAGE2_SECTORS equ 42              ; native build is larger (e1000/AR8131 driver + IP/UDP)
%elifdef ARCADE
STAGE2_SECTORS equ 48              ; arcade build: + game console (arcade.asm)
%elifdef WORM
STAGE2_SECTORS equ 80              ; worm build: + petri dish (worm.asm) + the brain image (>64 sectors: loaders copy/read in two segments)
%else
STAGE2_SECTORS equ 40              ; must match stage1.asm / pxe_stage1.asm (sector budget)
%endif
; The C. elegans brain primitive (brain.asm + the UDP 'n' command) is built into the
; default and WORM kernels. The native-NIC and arcade builds are at their sector
; budget, so they leave it out for now (bump their budget to add it).
%ifndef NIC_NATIVE
%ifndef ARCADE
%define HAVE_BRAIN
%endif
%endif
; --- Fourier "epicycle" compute (the old PC's CPU does the real fixed-point maths) ---
; The Agent preloads, into free high RAM (not part of the kernel image), a small
; coefficient block and a sine lookup table; the kernel's E command then evaluates
; the Fourier series (epicycle chain) in integer fixed point on this machine's CPU.
COEF_BASE equ 0x00100000           ; header + per-epicycle {amp, wstep, phase0}
SIN_BASE  equ 0x00120000           ; sine table: SINLEN int32 entries, Q14, [0,2pi)
SIN_SHIFT equ 14                    ; sine table fixed-point scale = 1<<14
SIN_MASK  equ 1023                  ; table length 1024 (power of two -> mod via AND)
SIN_QUARTER equ 256                 ; +quarter turn = cosine
EPI_MAX   equ 300                   ; max epicycles (301 pts x 4 = 1204B reply, < MTU;
                                    ; needs tx_buf >= 1204 and the 34-sector budget)

; ================= 16-bit real mode: set up and switch =================
stage2:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    ; Save the pristine BIOS INT 10h vector now (IVT[0x10] at physical 0x40), so a
    ; runtime VBE mode switch can far-call the video BIOS directly even if the PXE
    ; stack later repoints INT 10h in the IVT.
    mov eax, [0x0040]              ; offset (low word) : segment (high word)
    mov [saved_int10], eax
    call uart_init16

    in  al, 0x92                   ; enable A20 via the fast gate
    or  al, 2
    out 0x92, al
%ifdef IMAGE_DEMO
    ; ---- image demo: switch to a VBE linear-framebuffer graphics mode now
    ; (while BIOS VBE is fully available in real mode). Loses the text console;
    ; the whole screen becomes a pixel surface the Agent draws photos into. ----
    call vbe_setup
%elifdef ARCADE
    ; ---- arcade: straight into the VBE framebuffer (game console). Grab the ROM
    ; 8x8 font first (text mode is still up) for on-screen score/text. ----
    call extract_font
    call vbe_setup
%elifdef WORM
    call extract_font              ; worm: same boot path as the arcade (font + VBE)
    call vbe_setup
%else
    call pit_init16                ; PIT ch0 timebase for the opening animation

    ; ---- opening animation (real mode: int 10h mode switches are easy here) ----
    mov ax, 0x0003                 ; 80x25 big-char colour text
    int 0x10
    call anim_rain25               ; big-char binary rain (clear, not jumpy)
    mov ax, 0x1112                 ; load 8x8 font -> 80x50: chars shrink = zoom out
    xor bl, bl
    int 0x10
    call anim_condense             ; the rain condenses into the face (text mode, unchanged)
    call extract_font              ; grab the 8x8 ROM font for the graphics console
    call vbe_setup                 ; now switch to a VBE graphics mode (boot-time switch works
                                   ; on real HW); the console renders the 0xB8000 text buffer
                                   ; as pixels from here on, and images blit straight to the FB
%endif

    lgdt [gdt_desc]
    mov eax, cr0
    or  eax, 1                     ; CR0.PE = 1
    mov cr0, eax
    jmp CODE_SEL:pm_entry

uart_init16:
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al
    mov dx, COM1 + 0
    mov al, 0x01
    out dx, al
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al
    mov dx, COM1 + 4
    mov al, 0x0B
    out dx, al
    ret

; ================= real-mode opening animation =================
VGASEG   equ 0xB800
FR_CNT   equ 29800                 ; PIT ch0 counts per frame (~25 ms)

pit_init16:
    push ax
    mov al, 0x34                   ; ch0, lo/hi, mode 2, binary
    out 0x43, al
    xor al, al
    out 0x40, al
    out 0x40, al
    pop ax
    ret

pit_read16:                        ; -> AX = ch0 count
    push bx
    mov al, 0
    out 0x43, al
    in  al, 0x40
    mov bl, al
    in  al, 0x40
    mov bh, al
    mov ax, bx
    pop bx
    ret

; pit_delay16: wait DX ch0 counts (< 65536). Preserves DX.
pit_delay16:
    push cx
    push si
    push bx
    push dx
    call pit_read16
    mov si, ax                     ; prev
    xor cx, cx                     ; accumulated
    pop dx
    push dx
.l:
    call pit_read16                ; cur in AX
    mov bx, si
    sub bx, ax                     ; elapsed = prev-cur (mod 65536)
    add cx, bx
    mov si, ax
    cmp cx, dx
    jb  .l
    pop dx
    pop bx
    pop si
    pop cx
    ret

rand16:                            ; -> AX xorshift16
    push bx
    mov ax, [rseed]
    mov bx, ax
    shl ax, 7
    xor ax, bx
    mov bx, ax
    shr ax, 9
    xor ax, bx
    mov bx, ax
    shl ax, 8
    xor ax, bx
    mov [rseed], ax
    pop bx
    ret

; rm_cell: write at (row=AX, col=SI), char=CL, attr=CH. es=VGASEG. Clips to [rows16).
rm_cell:
    cmp ax, 0
    jl  .q
    cmp ax, [rows16]
    jge .q
    push ax
    push di
    push dx
    mov dx, 80
    mul dx                         ; AX = row*80
    add ax, si
    shl ax, 1
    mov di, ax
    mov [es:di], cx                ; CL char, CH attr
    pop dx
    pop di
    pop ax
.q:
    ret

; anim_rain25: 80-column single falling dot with a short trail, 80x25, timed.
anim_rain25:
    mov word [rows16], 25
    mov ax, VGASEG
    mov es, ax
    xor di, di
.ini:
    call rand16
    xor dx, dx
    mov bx, 25
    div bx                         ; DX = rand % 25
    neg dx
    mov [col25+di], dx
    add di, 2
    cmp di, 160
    jb  .ini
    mov word [frames16], 150       ; longer so it is easy to watch
.frame:
    ; advance the drops only every 2nd frame -> they fall slowly and readably,
    ; while the head digits still flicker every frame.
    mov ax, [frames16]
    and al, 1
    mov [adv_flag], al             ; 0 on every 2nd frame = advance frame
    xor di, di                     ; col*2
    xor si, si                     ; col
.col:
    mov bx, [col25+di]             ; head row (signed)
    ; head bright white (flickers each frame)
    push bx
    call rand16
    and al, 1
    add al, '0'
    mov cl, al
    mov ch, 0x0F
    mov ax, bx
    call rm_cell
    ; dim trail just above the head
    dec ax
    mov ch, 0x0A
    call rm_cell
    pop bx
    cmp byte [adv_flag], 0
    jne .keep                      ; not an advance frame -> leave the drop
    ; clear trail end and move the head down
    mov ax, bx
    sub ax, 5
    mov cx, 0x0A20
    call rm_cell
    inc bx
    cmp bx, 30
    jl  .store
    call rand16
    xor dx, dx
    push bx
    mov bx, 20
    div bx
    neg dx
    pop bx
    mov bx, dx
.store:
    mov [col25+di], bx
.keep:
    add di, 2
    inc si
    cmp si, 80
    jb  .col
    mov dx, 42000                  ; ~35 ms per frame
    call pit_delay16
    dec word [frames16]
    jnz .frame
    ret

; anim_condense: fill sparse rain (80x50), then reveal the face top-down so the
; digits "resolve" into the portrait, then clear below the face.
anim_condense:
    mov word [rows16], 50
    mov ax, VGASEG
    mov es, ax
    ; sparse rain texture over the whole 80x50 screen
    xor di, di
.fill:
    call rand16
    test ax, 3
    jz  .dig
    mov ax, 0x0A20                 ; space
    jmp .putf
.dig:
    call rand16
    and al, 1
    add al, '0'
    mov ah, 0x02                   ; dim green
.putf:
    mov [es:di], ax
    add di, 2
    cmp di, 8000
    jb  .fill
    ; reveal face rows 0..FACE_H-1, one per frame
    xor bp, bp
.cf:
    cmp bp, FACE_H
    jae .cfdone
    mov ax, bp
    mov dx, 80
    mul dx
    add ax, FACE_COL
    shl ax, 1
    mov di, ax                     ; dest = (bp*80+FACE_COL)*2
    mov ax, bp
    mov dx, FACE_W
    mul dx
    mov si, face_data
    add si, ax                     ; src = face_data + bp*FACE_W
    mov cx, FACE_W
.rowc:
    lodsb
    mov ah, 0x0A                   ; bright green
    stosw
    loop .rowc
    mov dx, FR_CNT
    call pit_delay16
    inc bp
    jmp .cf
.cfdone:
    ; settle to a clean face: clear the whole screen, redraw the full portrait
    xor di, di
    mov cx, 4000
    mov ax, 0x0A20
    rep stosw
    xor bp, bp
.ff:
    cmp bp, FACE_H
    jae .ffd
    mov ax, bp
    mov dx, 80
    mul dx
    add ax, FACE_COL
    shl ax, 1
    mov di, ax
    mov ax, bp
    mov dx, FACE_W
    mul dx
    mov si, face_data
    add si, ax
    mov cx, FACE_W
.ffl:
    lodsb
    mov ah, 0x0A
    stosw
    loop .ffl
    inc bp
    jmp .ff
.ffd:
    ret

; ================= VBE (linear framebuffer), real mode =================
; vbe_probe: query the VBE controller and find a 32-bpp linear-framebuffer mode
; (preferring 1024x768, else any 32-bpp LFB mode) WITHOUT switching to it. Stores
; the framebuffer physical base / pitch / bpp / width / height + mode number and
; sets vbe_ok=1 on success. Called at boot so the text kernel can switch to this
; mode later at runtime (gfx_enter). DS=ES=0 on entry.
vbe_probe:
    xor ax, ax                     ; the opening animation leaves ES=VGA seg; VBE calls
    mov ds, ax                     ; use ES:DI and we read the blocks via DS, so force both
    mov es, ax                     ; segments to 0 (flat low data by label offset)
    mov byte [vbe_ok], 0
    ; AX=4F00: VBE controller info -> vbe_info (ES:DI). Pre-seed the signature
    ; "VBE2" so a VBE 2.0+ BIOS returns the full 512-byte extended info block.
    mov dword [vbe_info], 'VBE2'
    mov ax, 0x4F00
    mov di, vbe_info
    int 0x10
    cmp ax, 0x004F
    jne .fail
    ; VideoModePtr is a real-mode far pointer at vbe_info+0x0E (off, then seg)
    mov ax, [vbe_info+0x0E]
    mov [vmode_off], ax
    mov ax, [vbe_info+0x10]
    mov [vmode_seg], ax
    ; pass 1: exact 1024x768x32
    mov word [want_w], 1024
    mov word [want_h], 768
    call vbe_scan
    cmp word [found_mode], 0xFFFF
    jne .ok
    ; pass 2: any 32-bpp LFB mode (want_w=0 = accept any resolution)
    mov word [want_w], 0
    call vbe_scan
    cmp word [found_mode], 0xFFFF
    je  .fail
.ok:
    mov byte [vbe_ok], 1
.fail:
    ret

; vbe_setup: probe AND switch to the mode now (IMAGE_DEMO boot path). Leaves
; vbe_ok=1 only if the mode was actually set.
vbe_setup:
    call vbe_probe
    cmp byte [vbe_ok], 0
    je  .done
    mov bx, [found_mode]
    or  bx, 0x4000                 ; bit14 = use linear framebuffer
    mov ax, 0x4F02
    int 0x10
    cmp ax, 0x004F
    je  .done
    mov byte [vbe_ok], 0           ; mode set failed
.done:
    ret

; vbe_scan: walk the mode list at [vmode_seg]:[vmode_off]. Accept a mode that is
; supported + graphics + has a linear framebuffer + 32 bpp, and (if want_w != 0)
; matches want_w x want_h. On a match stores framebuffer params and the mode in
; found_mode; otherwise found_mode = 0xFFFF.
vbe_scan:
    mov word [found_mode], 0xFFFF
    mov ax, [vmode_seg]
    mov fs, ax
    mov bx, [vmode_off]
.next:
    mov cx, [fs:bx]                ; next mode number
    add bx, 2
    cmp cx, 0xFFFF
    je  .done
    push bx
    push cx
    ; AX=4F01: mode info for CX -> vbe_modeinfo (ES:DI, ES=0)
    mov ax, 0x4F01
    mov di, vbe_modeinfo
    push fs
    int 0x10
    pop fs
    pop cx
    cmp ax, 0x004F
    jne .cont
    mov ax, [vbe_modeinfo]         ; ModeAttributes
    test ax, 0x0001                ; bit0: mode supported
    jz  .cont
    test ax, 0x0010                ; bit4: graphics mode
    jz  .cont
    test ax, 0x0080                ; bit7: linear framebuffer available
    jz  .cont
    cmp byte [vbe_modeinfo+0x19], 32   ; BitsPerPixel
    jne .cont
    cmp word [want_w], 0
    je  .match
    mov ax, [want_w]
    cmp [vbe_modeinfo+0x12], ax    ; XResolution
    jne .cont
    mov ax, [want_h]
    cmp [vbe_modeinfo+0x14], ax    ; YResolution
    jne .cont
.match:
    mov [found_mode], cx
    mov eax, [vbe_modeinfo+0x28]   ; PhysBasePtr (LFB physical base)
    mov [lfb_phys], eax
    movzx eax, word [vbe_modeinfo+0x12]
    mov [lfb_w], eax
    movzx eax, word [vbe_modeinfo+0x14]
    mov [lfb_h], eax
    movzx eax, word [vbe_modeinfo+0x32]  ; LinBytesPerScanLine (VBE 3.0)
    test eax, eax
    jnz .pitok
    movzx eax, word [vbe_modeinfo+0x10]  ; BytesPerScanLine (fallback)
.pitok:
    mov [lfb_pitch], eax
    movzx eax, byte [vbe_modeinfo+0x19]
    mov [lfb_bpp], eax
    pop bx
    ret
.cont:
    pop bx
    jmp .next
.done:
    ret

; extract_font: copy the BIOS 8x8 ROM font (256 glyphs x 8 bytes) into font_buf so
; the protected-mode graphics console can render the text buffer as pixels. Real mode.
extract_font:
    push es
    push ds
    push si
    push di
    push cx
    mov ax, 0x1130
    mov bh, 0x03                   ; ROM 8x8 double-dot font
    int 0x10                       ; -> ES:BP = font pointer
    mov ax, es
    mov ds, ax                     ; DS:SI = font source
    mov si, bp
    xor ax, ax
    mov es, ax                     ; ES:DI = 0:font_buf
    mov di, font_buf
    mov cx, 2048                   ; 256 * 8
    cld
    rep movsb
    pop cx
    pop di
    pop si
    pop ds
    pop es
    ret

; ================= 32-bit protected mode =================
BITS 32
pm_entry:
    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    mov esp, 0x00007000            ; low stack: 0x90000 would stomp the resident
                                   ; PXE base-code/UNDI (near top of base memory)

%ifdef IMAGE_DEMO
    jmp image_demo_pm              ; graphics mode is set; go draw pixels
%endif
%ifdef ARCADE
    jmp arcade_pm                  ; game console: fixed-rate input->update->render loop
%endif
%ifdef WORM
    jmp worm_pm                    ; petri dish: C. elegans brain + body, 60 fps
%endif
    call pit_init                  ; free-running PIT ch0 timebase (QEMU==real HW)
    call uart_detect               ; is COM1 real? (K50IJ has no serial port)
    ; The opening animation already drew the face in real mode. Here we only do
    ; the (silent) PXE setup needed for the network command channel.
    cmp word [0x5008], 0x5850       ; network-booted? PXE entry stashed at 0x5000
    jne .no_pxe
    mov byte [pxe_present], 1
    mov eax, [0x5000]
    mov [rmentry], eax
    ; GET_CACHED_INFO (0x0071) -> our IP (DHCP yiaddr)
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov word [pxe_param+2], 2
    mov ax, 0x0071
    call pxe_call
    movzx eax, word [pxe_param+8]
    shl eax, 4
    movzx ecx, word [pxe_param+6]
    add eax, ecx
    mov edx, [eax+16]
    mov [our_ip], edx
%ifdef NIC_NATIVE
    mov eax, [our_ip]              ; take over the NIC with the native e1000 driver
    mov [nn_ip], eax              ; (PXE was used only to learn our DHCP IP)
    call nn_init
%else
    ; UDP_OPEN (0x0030) bound to our IP
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+2], eax
    mov ax, 0x0030
    call pxe_call
%endif
.no_pxe:
    cmp byte [vbe_ok], 0           ; set up the graphics text console geometry
    je  .no_fb
    mov eax, [lfb_pitch]
    mul dword [lfb_h]
    mov [fb_size], eax             ; framebuffer byte size (for image blits)
    mov eax, [lfb_w]               ; centre the 640 x (SCR_ROWS*8) text block
    sub eax, 640
    sar eax, 1
    mov [X0], eax
    mov eax, [lfb_h]
    sub eax, SCR_ROWS * 8
    sar eax, 1
    mov [Y0], eax
.no_fb:
    call vga_clear                 ; the RAM shadow is garbage at boot - blank it first
    call show_face                 ; draw the Dario face into the text buffer
    cmp byte [vbe_ok], 0
    je  main_loop                  ; no VBE: stay in the text-mode fallback
    call clear_lfb                 ; graphics console: paint the face onto the framebuffer
    call present_text

main_loop:
    cmp byte [pxe_present], 0
    jne net_loop                   ; network-booted -> Agent over UDP
    cmp byte [com1_present], 0
    jne .interactive               ; serial port -> dev REPL (QEMU/real COM1)
.showcase:                         ; no serial, no net -> pure visual
    call rain_bg_step
    call pit_delay_frame
    jmp .showcase
.interactive:
    mov esi, prompt
    call out_puts
    call readline                  ; fills line_buf, echoes to serial+VGA
    cmp byte [line_buf], 0
    je  .interactive               ; empty line -> new prompt
    call exec_line
    jmp .interactive

; exec_line: line_buf holds a command; echo its binary, dispatch, emit output.
; Output goes to VGA always, and to serial (dev) or the UDP tx buffer (net mode)
; via out_putc. Handlers jump to exec_done. Returns to caller.
exec_line:
    call nl
    call dump_bin_line             ; "  " + 8-bit binary of each char
    call nl
    mov dword [parse_ptr], line_buf + 1
    mov al, [line_buf]
    cmp al, 'C'
    je  do_cpuid0
    cmp al, 'F'
    je  do_cpuid1
    cmp al, 'I'
    je  do_in
    cmp al, 'T'
    je  do_time
    cmp al, 'M'
    je  do_mem
    cmp al, 'P'
    je  do_pci
    cmp al, 'O'
    je  do_out
    cmp al, 'W'
    je  do_write
    cmp al, 'A'
    je  do_alu
    cmp al, 'J'
    je  do_rd32
    cmp al, 'H'
    je  do_keys_held
    cmp al, '?'
    je  do_help
    mov esi, s_unknown
    call out_puts
exec_done:
    ret

; net_loop: Agent-over-UDP command channel (network-booted machine, no serial).
; UDP socket already opened at boot. Poll UDP_READ; on a command packet, run it
; with output captured to tx_buf, then UDP_WRITE the reply back to the sender.
NET_PORT equ 0x50C3                ; UDP port 50000, network byte order (our listen)
RX_MAX   equ 1472                  ; max UDP payload we read (MTU 1500 - IP 20 - UDP 8)
Q_PORT   equ 0x51C3                ; UDP port 50001, net order (dev-PC question port)
DEVPC_IP equ 0x71B2A8C0            ; 192.168.178.113, network-byte-order bytes
INPUT_ROW equ 48                   ; on-screen input line (left column)
net_loop:
    mov byte [net_mode], 1
    call pit_init                  ; PXE may have reprogrammed the PIT
    call kbd_init                  ; real HW: enable 8042 translation + scanning
    call draw_prompt               ; "> " on the input line
    mov byte [need_present], 1     ; repaint so the prompt shows in the graphics console
    ; --- one-time network self-test (needs no keyboard) ---
    ; auto-send "hello" to the dev PC so the UDP round-trip (send path + answer
    ; display) can be verified independently of the flaky physical keyboard.
    mov dword [kbd_buf], 'hell'
    mov byte  [kbd_buf+4], 'o'
    mov dword [kbd_len], 5
%ifndef NO_HELLO
    call send_question
    call send_question
%endif
    mov dword [kbd_len], 0
%ifdef BLACKBOX_TEST
    ; --- RAM black-box survival self-test (method 1, phase 0 verification) ---
    ; At boot (reliable UDP window), report the persisted magic+count at 0x70000,
    ; then write a fresh magic+count, set the BIOS warm-boot flag, and 8042-reset.
    ; If RAM survives the warm reset, the dev PC sees the count climb 1->2->3 across
    ; boots; if it is cleared, the count never sticks. Stops looping after count 3.
    ; report 3 candidate slots' magics (low 0x70000, mid 0x800000=8MB, high
    ; 0x4000000=64MB) + the count, to find which survives the warm reset.
    mov eax, [0x00070000]
    mov [kbd_buf + 0], eax
    mov eax, [0x00800000]
    mov [kbd_buf + 4], eax
    mov eax, [0x04000000]
    mov [kbd_buf + 8], eax
    mov eax, [0x00800004]              ; count (kept in the 8MB slot)
    mov [kbd_buf + 12], eax
    mov dword [kbd_len], 16
    call send_question                 ; boot-time burst (this window is reliable)
    call send_question
    call send_question
    call send_question
    call send_question
    mov dword [kbd_len], 0
    mov eax, [0x00800000]
    cmp eax, 0xB10CB0C5                ; magic from a previous boot (8MB slot)?
    jne .bb_first
    mov eax, [0x00800004]
    cmp eax, 3
    jae .bb_done                      ; looped enough -> fall through to normal net_loop
    inc eax
    mov [0x00070004], eax
    mov [0x00800004], eax             ; count++ in all slots
    mov [0x04000004], eax
    jmp .bb_reboot
.bb_first:
    mov dword [0x00070000], 0xB10CB0C5
    mov dword [0x00800000], 0xB10CB0C5
    mov dword [0x04000000], 0xB10CB0C5
    mov dword [0x00070004], 1
    mov dword [0x00800004], 1
    mov dword [0x04000004], 1
.bb_reboot:
    mov word [0x00000472], 0x1234     ; BIOS warm-boot flag: skip POST memory test
    mov ecx, 0x08000000               ; let the UDP bursts flush before the reset
.bb_d: dec ecx
    jnz .bb_d
    mov al, 0xFE
    out 0x64, al                      ; 8042 CPU reset -> re-PXE-boot
    cli
    hlt
.bb_done:
%endif
.poll:
%ifdef NIC_AR8131
    call ar_hud                    ; live NIC diagnostics on the bottom text row
    mov byte [need_present], 1
%endif
    ; drain the PS/2 keyboard fully this iteration (no overflow/beep on fast
    ; typing); each mapped key echoes, Enter sends the line over UDP
    call kbd_service
    cmp byte [need_present], 0      ; repaint the graphics console only when the text
    je  .nopres                    ; buffer actually changed (keystroke / reply / command)
    mov byte [need_present], 0
    call refresh_console
.nopres:
    ; Always tight-poll UDP_READ (no delay). On real hardware a polling gap drops
    ; incoming packets, so the Agent's bursts need continuous reading.
%ifdef NIC_NATIVE
    call nn_poll_cmd               ; native e1000: poll RX, answer ARP, deliver one UDP
    test ax, ax                    ; AX=0 -> rx_buf has a command, ECX=len, peer_* set
    jnz .poll
    cmp ecx, RX_MAX
    jbe .lenok
    mov ecx, RX_MAX
%else
    ; UDP_READ
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+6], eax          ; dest_ip filter = our IP
    mov word [pxe_param+12], NET_PORT   ; d_port = our listening port
    mov word [pxe_param+14], RX_MAX     ; buffer_size (max UDP payload, no IP fragmentation)
    mov word [pxe_param+16], rx_buf     ; buffer offset
    mov word [pxe_param+18], 0          ; buffer segment
    mov ax, 0x0032                 ; PXENV_UDP_READ
    call pxe_call
    cmp word [pxe_param], 0        ; Status 0 = got a packet
    jne .poll
    ; remember sender for the reply
    mov eax, [pxe_param+2]
    mov [peer_ip], eax
    mov ax, [pxe_param+10]
    mov [peer_port], ax
    movzx ecx, word [pxe_param+14] ; received length
    cmp ecx, RX_MAX
    jbe .lenok
    mov ecx, RX_MAX
%endif
.lenok:
    mov byte [rx_buf+ecx], 0       ; null-terminate the raw packet
    cmp byte [rx_buf], 'G'         ; G = blit raw pixels into the VBE framebuffer
    je  .do_gblit
    cmp byte [rx_buf], 'Z'         ; Z = RLE-blit (fast for text/reader pages)
    je  .do_zblit
    cmp byte [rx_buf], 'V'         ; V = switch display into graphics mode (show image)
    je  .do_gfxon
    cmp byte [rx_buf], 'U'         ; U = back to text mode + redraw the face
    je  .do_gfxoff
    cmp byte [rx_buf], 'Q'         ; Q = reply framebuffer geometry
    je  .do_qgeo
    cmp byte [rx_buf], 'B'         ; block write (multi-line) parsed from rx_buf
    je  .do_block
    cmp byte [rx_buf], 'b'         ; b = block write WITHOUT repaint (assemble a frame; the
    je  .do_block_q               ;     last packet of the frame is a 'B' -> one repaint)
    cmp byte [rx_buf], 'g'         ; g = raw 8-bit grey rows -> THIS CPU maps brightness to
    je  .do_gray                   ;     ramp chars + 3 attributes (ascii_cam --kernel-render)
    cmp byte [rx_buf], 'L'         ; L = bulk-load raw bytes into the compute scratch RAM
    je  .do_load
    cmp byte [rx_buf], 'E'         ; E = evaluate the Fourier epicycle chain at a time step
    je  .do_epi
    cmp byte [rx_buf], 'Y'         ; Y<8hex off><4hex len> = read framebuffer (screenshot)
    je  .do_fbread
    cmp byte [rx_buf], 'K'         ; K! = reboot (8042 CPU reset) -> re-PXE-boots
    je  .do_reboot
    cmp byte [rx_buf], 'N'         ; N<text> = inject keystrokes (type; \r = Enter)
    je  .do_keys
%ifdef HAVE_BRAIN
    cmp byte [rx_buf], 'n'         ; n = C. elegans brain primitive (nI init, nM mode, nS steps)
    je  .do_brain
%endif
    ; copy rx_buf -> line_buf up to CR/LF/limit (single-line commands)
    xor esi, esi
.cp:
    cmp esi, ecx
    jae .cpdone
    mov al, [rx_buf+esi]
    cmp al, 13
    je  .cpdone
    cmp al, 10
    je  .cpdone
    mov [line_buf+esi], al
    inc esi
    cmp esi, 120
    jb  .cp
.cpdone:
    mov byte [line_buf+esi], 0
    cmp byte [line_buf], 0
    je  .poll                      ; empty -> ignore
    mov word [tx_len], 0
    ; display commands (X=clear screen, D<text>=write a line) go straight to VGA
    ; with no binary echo - this is how the Agent draws a face / text on screen.
    mov al, [line_buf]
    cmp al, 'X'
    je  .do_clear
    cmp al, 'D'
    je  .do_disp
    cmp al, 'R'
    je  .do_rain
    cmp al, 'S'
    je  .do_pos
    ; otherwise run it as a hardware command, output captured into tx_buf
    call exec_line
    jmp .reply
    ; display commands produce no reply (fire-and-forget) -> jump to .poll, not
    ; .reply. Skipping the per-packet UDP_WRITE ack lets the kernel process
    ; packets fast enough not to drop a burst on real hardware.
.do_clear:
    mov byte [rain_on], 0          ; display mode: stop ambient rain for a clean face
    call vga_clear
    mov byte [gfx_mode], 0         ; leaving any image -> clear the framebuffer on repaint
    mov byte [need_present], 1
    jmp .poll
.do_rain:
    mov byte [rain_on], 1          ; resume ambient rain
    jmp .poll
.do_disp:
    mov esi, line_buf + 1          ; text after 'D'
    call vga_puts
    mov al, 13
    call vga_putc
    mov al, 10
    call vga_putc
    mov byte [need_present], 1
    jmp .poll
.do_pos:
    ; S<2hex row><2hex col><text> : write text at (row,col). Idempotent.
    mov byte [rain_on], 0
    mov dword [parse_ptr], line_buf + 1
    mov bl, 2
    call phex                      ; row
    and eax, 0x7F
    mov ecx, eax
    mov bl, 2
    call phex                      ; col
    and eax, 0x7F
    imul ecx, ecx, 80
    add ecx, eax
    mov [vga_pos], ecx             ; cursor = row*80 + col
    mov esi, [parse_ptr]           ; text after the hex fields
    call vga_puts
    mov byte [need_present], 1
    jmp .poll
.do_block:
    ; B<2hex startrow> then newline-separated lines -> write each at (row+i, 0).
    ; One packet carries many rows, so the whole face is ~3 packets not ~50.
    ; Idempotent (overwrites same cells), fire-and-forget (no ack).
    ; Bytes 0x01/0x02/0x03 inside a line switch the attribute (dim green / bright
    ; green / white) for the following cells; the block ends with the normal attr.
    mov byte [blk_pres], 1
    jmp .do_block_c
.do_block_q:                       ; b: same, but no repaint (ascii_cam frame parts)
    mov byte [blk_pres], 0
.do_block_c:
    mov byte [rain_on], 0
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 2
    call phex                      ; start row
    and eax, 0x7F
    mov [blk_row], eax
    mov esi, [parse_ptr]
.blk_line:
    mov al, [esi]                  ; skip blank/newline separators
    cmp al, 10
    jne .blk_go
    inc esi
    jmp .blk_line
.blk_go:
    test al, al
    jz  .blk_done                  ; end of packet
    mov eax, [blk_row]
    imul eax, eax, 80
    mov [vga_pos], eax             ; cursor = row*80 (col 0)
.blk_wr:
    mov al, [esi]
    test al, al
    jz  .blk_done
    cmp al, 10
    je  .blk_eol
    cmp al, 4
    jae .blk_put
    movzx eax, al                  ; 1/2/3 -> attribute table (dim / bright / white)
    mov al, [attr_tab + eax]
    mov [cur_attr], al
    inc esi
    jmp .blk_wr
.blk_put:
    call vga_putc
    inc esi
    jmp .blk_wr
.blk_eol:
    inc esi
    inc dword [blk_row]
    jmp .blk_line
.blk_done:
    mov byte [cur_attr], VGA_ATTR  ; chat/face text after the block stays normal green
    cmp byte [blk_pres], 0
    je  .poll                      ; 'b': frame not complete yet, no repaint
    mov byte [need_present], 1     ; repaint the console with the new block of text
    jmp .poll
.do_gray:
    ; g<2hex row><1hex repaint><raw grey bytes, 80 per row>: the old PC renders the
    ; picture itself - each byte -> one of 10 ramp chars (" .:-=+*#%@") and dim /
    ; bright / white by brightness. One row = 80 bytes, so a packet carries whole rows.
    mov byte [rain_on], 0
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 2
    call phex                      ; start row (phex keeps ecx = packet length)
    and eax, 0x7F
    imul edi, eax, 80
    shl edi, 1
    add edi, VGA                   ; cell pointer at (row, col 0)
    mov bl, 1
    call phex                      ; repaint flag 0/1
    and al, 1
    mov [blk_pres], al
    mov esi, [parse_ptr]           ; first grey byte
    lea edx, [rx_buf + ecx]        ; end of packet
.gr_loop:
    cmp esi, edx
    jae .gr_done
    cmp edi, VGA + SCR_CELLS * 2
    jae .gr_done                   ; never past the text buffer
    movzx eax, byte [esi]
    imul eax, eax, 10
    shr eax, 8                     ; 0..9 ramp index
    mov bl, [gray_ramp + eax]
    mov bh, [gray_attr + eax]
    mov [edi], bx                  ; char + attribute cell
    add edi, 2
    inc esi
    jmp .gr_loop
.gr_done:
    cmp byte [blk_pres], 0
    je  .poll
    mov byte [need_present], 1
    jmp .poll
.do_gfxon:                         ; V: (graphics console is always on) - just ack
    mov byte [tx_buf], 1
    mov byte [tx_buf+1], 0         ; 2-byte ack: the Asus PXE ROM never transmits (or
    mov word [tx_len], 2           ; delivers) a 1-byte UDP payload, so a 1-byte ack is lost
    jmp .reply
.do_gfxoff:                        ; U: drop any full-screen image, repaint the text/face
    mov byte [gfx_mode], 0
    call restore_text
    jmp .poll
.do_gblit:                         ; G<8hex LFB offset><raw pixels>: blit to framebuffer
    cmp ecx, 9
    jbe .poll
    mov byte [gfx_mode], 1         ; a full-screen image is now shown (text hidden)
    sub ecx, 9
    mov [pix_len], ecx
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 8
    call phex                      ; EAX = LFB byte offset
    cmp eax, [fb_size]
    jae .poll
    mov edx, [fb_size]
    sub edx, eax
    mov ecx, [pix_len]
    cmp ecx, edx
    jbe .okg
    mov ecx, edx
.okg:
    mov edi, [lfb_phys]
    add edi, eax
    lea esi, [rx_buf+9]
    rep movsb
    jmp .poll
.do_zblit:                         ; Z<8hex LFB offset><runs: count(2 LE)+pixel(4)...>
    cmp ecx, 15                    ; need 'Z' + 8 hex + >=1 run (6 bytes) = 15 bytes
    jb  .poll
    mov byte [gfx_mode], 1
    add ecx, rx_buf                ; absolute end of the run stream
    mov [z_end], ecx
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 8
    call phex                      ; EAX = start LFB byte offset
    cmp eax, [fb_size]
    jae .poll
    mov edi, [lfb_phys]
    add edi, eax                   ; EDI = dest pixel
    mov edx, [lfb_phys]
    add edx, [fb_size]             ; EDX = framebuffer end (bound)
    lea esi, [rx_buf+9]            ; ESI = run stream
.zrun:
    cmp esi, [z_end]
    jae .poll                      ; all runs consumed
    movzx ecx, word [esi]          ; run length (pixels)
    add esi, 2
    mov eax, [esi]                 ; run pixel (BGRX)
    add esi, 4
    mov ebx, edx                   ; clamp count to room left in the framebuffer
    sub ebx, edi
    shr ebx, 2
    cmp ecx, ebx
    jbe .zok
    mov ecx, ebx
.zok:
    test ecx, ecx
    jz  .poll
    rep stosd                      ; write ECX copies of EAX at [EDI]
    jmp .zrun
.do_fbread:                        ; Y<8hex off><4hex len> -> reply len framebuffer bytes
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 8
    call phex                      ; EAX = byte offset into the framebuffer
    mov esi, eax
    mov bl, 4
    call phex                      ; EAX = length (<= ~1400)
    mov ecx, eax
    cmp ecx, 1400
    jbe .fr_lenok
    mov ecx, 1400
.fr_lenok:
    mov edx, [fb_size]             ; clamp off+len to the framebuffer
    cmp esi, edx
    jb  .fr_inrange
    xor ecx, ecx                   ; offset past end -> empty reply
    jmp .fr_copy
.fr_inrange:
    mov eax, edx
    sub eax, esi                   ; bytes left
    cmp ecx, eax
    jbe .fr_copy
    mov ecx, eax
.fr_copy:
    mov [tx_len], cx
    mov edi, tx_buf
    add esi, [lfb_phys]            ; source = lfb_phys + offset
    rep movsb
    jmp .reply
.do_reboot:                        ; K! -> pulse the 8042 reset line (CPU reset)
    cmp byte [rx_buf+1], '!'
    jne .poll
    mov al, 0xFE
    out 0x64, al                   ; 8042: assert INIT -> machine resets, re-PXE-boots
    cli
    hlt
.do_keys:                          ; N<text> -> feed each byte to kbd_char (as if typed)
    dec ecx                        ; drop the 'N'; ECX = text length
    jle .keys_done
    mov esi, rx_buf + 1
.keys_loop:
    mov al, [esi]
    inc esi
    call kbd_char                  ; echoes / line-buffers; CR(13) fires Enter -> send
    dec ecx
    jnz .keys_loop
.keys_done:
    jmp .poll
.do_qgeo:                          ; Q: reply 4 LE dwords w,h,pitch,bpp
    mov eax, [lfb_w]
    mov [tx_buf+0], eax
    mov eax, [lfb_h]
    mov [tx_buf+4], eax
    mov eax, [lfb_pitch]
    mov [tx_buf+8], eax
    mov eax, [lfb_bpp]
    mov [tx_buf+12], eax
    mov word [tx_len], 16
    jmp .reply
.do_load:
    ; L<8hex phys addr><raw bytes> -> copy the raw bytes to physical RAM, bounded to
    ; the compute scratch window [0x00100000, 0x00180000) so it can never scribble the
    ; kernel, the VGA shadow, or device MMIO. Acked (reply "L") so the loader can retry.
    cmp ecx, 9
    jbe .poll
    sub ecx, 9                     ; ECX = raw byte count
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 8
    call phex                      ; EAX = destination physical address
    cmp eax, 0x00100000
    jb  .poll
    mov edx, eax
    add edx, ecx                   ; end address
    cmp edx, 0x00180000
    ja  .poll
    mov edi, eax
    lea esi, [rx_buf+9]
    rep movsb
    mov byte [tx_buf], 'L'
    mov byte [tx_buf+1], 0         ; 2-byte ack (1-byte UDP payloads never leave the ROM)
    mov word [tx_len], 2
    jmp .reply
%ifdef HAVE_BRAIN
.do_brain:
    ; nI            -> expand the CSR blob the host loaded at BR_BLOB; reply "nI"+nsyn(u16)
    ; nM<1hex>      -> 0 = SSE2 dense path, 1 = scalar sparse path; reply "nM"
    ; nS<4hex k>    -> run k steps with the current EXT (host loads it at BR_EXT with L);
    ;                  reply v int16[NR] + spike bitmap (NR/8 bytes) + gi int16
    mov word [tx_len], 0
    mov al, [rx_buf+1]
    cmp al, 'I'
    je  .br_init
    cmp al, 'M'
    je  .br_mode
    cmp al, 'S'
    je  .br_steps
    jmp .poll
.br_init:
    mov esi, BR_BLOB
    call brain_init
    test eax, eax
    jz  .poll
    mov word [tx_buf], 'nI'        ; NASM char constants are little-endian: bytes "nI"
    mov eax, [br_nsyn]
    mov [tx_buf+2], ax
    mov word [tx_len], 4
    jmp .reply
.br_mode:
    mov al, [rx_buf+2]
    call hexval
    and al, 1
    mov [br_mode], al
    mov word [tx_buf], 'nM'
    mov word [tx_len], 2
    jmp .reply
.br_steps:
    cmp byte [br_ready], 0
    je  .poll
    mov dword [parse_ptr], rx_buf + 2
    mov bl, 4
    call phex
    mov ecx, eax
.br_sl:
    test ecx, ecx
    jz  .br_sd
    call brain_step
    dec ecx
    jmp .br_sl
.br_sd:
    mov esi, BR_V
    mov edi, tx_buf
    mov ecx, BR_NR / 2
    rep movsd                      ; v[] (800 B)
    xor ebx, ebx                   ; spike bitmap: bit = s[row] != 0
.br_bm:
    xor al, al
    mov ecx, 8
.br_bb:
    shr al, 1
    cmp word [BR_S+ebx*2], 0
    je  .br_b0
    or  al, 0x80
.br_b0:
    inc ebx
    dec ecx
    jnz .br_bb
    stosb
    cmp ebx, BR_NR
    jb  .br_bm
    mov eax, [br_gi]
    stosw
    mov word [tx_len], BR_NR*2 + BR_NR/8 + 2
    jmp .reply
%endif
.do_epi:
    ; E<4hex t> -> evaluate the preloaded Fourier series at time step t, in fixed point,
    ; and reply the (N+1) accumulated points (the chain of epicycle centres ending at the
    ; pen tip) as little-endian int16 x,y pairs. The CPU here does all the multiply-add.
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 4
    call phex
    mov [epi_t], eax               ; time step t
    mov word [tx_len], 0
    mov eax, [COEF_BASE + 0]        ; N = epicycle count
    cmp eax, EPI_MAX
    jbe .epi_nok
    mov eax, EPI_MAX
.epi_nok:
    mov [epi_n], eax
    mov eax, [COEF_BASE + 4]        ; centre X (pixels)
    mov [epi_cx], eax
    mov eax, [COEF_BASE + 8]        ; centre Y (pixels)
    mov [epi_cy], eax
    xor eax, eax
    mov [epi_xacc], eax             ; accumulators, Q14 pixel units
    mov [epi_yacc], eax
    mov eax, [epi_cx]               ; point 0 = the centre
    call emit16
    mov eax, [epi_cy]
    call emit16
    xor ecx, ecx                    ; k = 0
.epi_loop:
    cmp ecx, [epi_n]
    jae .epi_done
    ; coeff ptr = COEF_BASE + 16 + k*12
    mov eax, ecx
    imul eax, eax, 12
    add eax, COEF_BASE + 16
    mov ebp, eax                    ; EBP -> {amp(0), wstep(4), phase0(8)}
    ; idx = ((wstep * t) >> 8 + phase0) & 1023
    mov eax, [ebp + 4]              ; wstep (Q8 table-steps per time unit, signed)
    imul eax, [epi_t]
    sar eax, 8
    add eax, [ebp + 8]              ; + phase0
    and eax, SIN_MASK               ; mod 1024 (two's complement safe for power of two)
    mov edi, eax                    ; EDI = sin index
    ; s = SIN[idx]
    mov esi, [SIN_BASE + edi*4]     ; sine, Q14 signed
    ; c = SIN[(idx + quarter) & mask]
    lea eax, [edi + SIN_QUARTER]
    and eax, SIN_MASK
    mov eax, [SIN_BASE + eax*4]     ; cosine, Q14 signed
    ; x_acc += amp * c ; y_acc += amp * s   (amp pixels, product -> Q14 pixels)
    imul eax, [ebp + 0]             ; amp * cos
    add [epi_xacc], eax
    mov eax, esi
    imul eax, [ebp + 0]             ; amp * sin
    add [epi_yacc], eax
    ; emit this centre point: (x_acc>>14)+CX , (y_acc>>14)+CY
    push ecx
    mov eax, [epi_xacc]
    sar eax, SIN_SHIFT
    add eax, [epi_cx]
    call emit16
    mov eax, [epi_yacc]
    sar eax, SIN_SHIFT
    add eax, [epi_cy]
    call emit16
    pop ecx
    inc ecx
    jmp .epi_loop
.epi_done:
    jmp .reply
.reply:
%ifdef NIC_NATIVE
    call nn_reply                  ; native e1000: wrap tx_buf in UDP + DMA transmit
    jmp .poll
%else
    ; UDP_WRITE the reply back to the sender
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [peer_ip]
    mov [pxe_param+2], eax          ; dest ip
    mov [pxe_param+6], eax          ; gw = dest: old UNDI stacks drop UDP_WRITE when
                                    ; the gateway field is 0, even on-link (m9 quirk).
                                    ; Without this, command replies vanish on real HW
                                    ; (QEMU's SLIRP tolerates gw=0, so this passed there).
    mov word [pxe_param+10], NET_PORT  ; src_port = our port
    mov ax, [peer_port]
    mov [pxe_param+12], ax          ; dst_port = sender's port
    mov ax, [tx_len]
    mov [pxe_param+14], ax          ; payload length
    mov word [pxe_param+16], tx_buf
    mov word [pxe_param+18], 0
    mov ax, 0x0033                 ; PXENV_UDP_WRITE
    call pxe_call
    jmp .poll
%endif

; emit16: append AX (low 16 bits of EAX) to tx_buf as a little-endian int16.
; Standalone (non-local) so it does not disturb net_loop's local-label scope.
emit16:
    push ebx
    movzx ebx, word [tx_len]
    cmp bx, 1280                     ; cap < tx_buf (1536); 301 pts x4 = 1204B fits, < MTU
    jae .full
    mov [tx_buf + ebx], ax
    add word [tx_len], 2
.full:
    pop ebx
    ret

; ---- C: CPUID leaf 0 vendor ----
do_cpuid0:
    xor eax, eax
    cpuid
    mov [vbuf+0], ebx
    mov [vbuf+4], edx
    mov [vbuf+8], ecx
    mov byte [vbuf+12], 0
    mov esi, vbuf
    call out_puts
    call nl
    jmp exec_done

; ---- F: CPUID leaf 1 EAX ----
do_cpuid1:
    mov eax, 1
    cpuid
    call print_hex32
    call nl
    jmp exec_done

; ---- J<8hex addr>: 32-bit read of [addr] (proper dword/MMIO read, unlike M's bytes) ----
do_rd32:
    mov dword [parse_ptr], line_buf + 1
    mov bl, 8
    call phex                      ; EAX = address
    mov eax, [eax]                 ; aligned 32-bit read (works for device MMIO registers)
    call print_hex32
    call nl
    jmp exec_done

; ---- I<4hex>: read I/O port ----
do_in:
    mov bl, 4
    call phex                      ; EAX = port
    mov edx, eax
    in  al, dx
    push eax
    mov al, '='
    call out_putc
    pop eax
    call print_hex8
    call nl
    jmp exec_done

; ---- T: RTC time via CMOS 0x70/0x71 ----
do_time:
    mov al, 0x04
    call cmos_read
    call print_hex8
    mov al, ':'
    call out_putc
    mov al, 0x02
    call cmos_read
    call print_hex8
    mov al, ':'
    call out_putc
    mov al, 0x00
    call cmos_read
    call print_hex8
    call nl
    jmp exec_done

; ---- M<8hex addr><2hex len>: read linear memory, hex dump ----
do_mem:
    mov bl, 8
    call phex                      ; EAX = linear address
    mov esi, eax
    mov bl, 2
    call phex                      ; EAX = length
    and eax, 0xFF
    mov ecx, eax
    test ecx, ecx
    jz  .done
.l:
    mov al, [esi]                  ; flat 4 GiB read
    inc esi
    call print_hex8
    mov al, ' '
    call out_putc
    dec ecx
    jnz .l
.done:
    call nl
    jmp exec_done

; ---- P<2hex bus><2hex dev><1hex func><2hex off>: PCI config read ----
do_pci:
    mov bl, 2
    call phex                      ; bus
    and eax, 0xFF
    shl eax, 16
    mov edi, eax
    mov bl, 2
    call phex                      ; dev
    and eax, 0x1F
    shl eax, 11
    or  edi, eax
    mov bl, 1
    call phex                      ; func
    and eax, 0x07
    shl eax, 8
    or  edi, eax
    mov bl, 2
    call phex                      ; offset (dword aligned)
    and eax, 0xFC
    or  edi, eax
    or  edi, 0x80000000
    mov eax, edi
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    call print_hex32
    call nl
    jmp exec_done

; ---- O<4hex port><2hex val>!: GATED outb ----
do_out:
    mov bl, 4
    call phex
    mov [tmp_port], eax
    mov bl, 2
    call phex
    mov [tmp_val], eax
    mov esi, [parse_ptr]
    mov al, [esi]
    cmp al, '!'                    ; mandatory confirm byte
    jne .abort
    mov edx, [tmp_port]
    mov eax, [tmp_val]
    out dx, al                     ; the gated hardware write
    mov esi, s_wok
    call out_puts
    jmp exec_done
.abort:
    mov esi, s_wabort
    call out_puts
    jmp exec_done

; ---- W<8hex addr><8hex dword>!: GATED physical/MMIO dword write ----
; Mirrors the O (outb) gate exactly: the trailing '!' confirm byte is mandatory,
; or the write is refused. Writes one 32-bit dword to a flat linear (= physical)
; address, so it reaches both plain RAM and memory-mapped device registers (e.g.
; the e1000 MMIO block at BAR0). This is the organism's hand for device
; programming; an Agent proposes the exact writes as a reviewed, armed skill.
do_write:
    mov bl, 8
    call phex                      ; EAX = linear/physical address
    mov [tmp_addr], eax
    mov bl, 8
    call phex                      ; EAX = dword value
    mov [tmp_dw], eax
    mov esi, [parse_ptr]
    mov al, [esi]
    cmp al, '!'                    ; mandatory confirm byte
    jne .abort
    mov edi, [tmp_addr]
    mov eax, [tmp_dw]
    mov [edi], eax                 ; the gated 32-bit write (flat 4 GiB segment)
    mov esi, s_wok
    call out_puts
    jmp exec_done
.abort:
    mov esi, s_wabort
    call out_puts
    jmp exec_done

; ---- A<op><8hex a><8hex b>: the old PC's CPU computes a math problem ----
; op is one ASCII char selecting the operation; the result (32-bit) is printed as
; 8 hex digits. This is the machine's own ALU doing real arithmetic on demand - the
; organism asking the hardware "what is X?" and showing the answer. ops:
;   + add   - sub   * mul   g gcd(a,b)   s sum 1..a   f factorial a (low 32 bits)
do_alu:
    mov esi, [parse_ptr]
    movzx eax, byte [esi]          ; op char (dereference parse_ptr)
    inc esi
    mov [parse_ptr], esi
    mov [alu_op], al
    mov bl, 8
    call phex
    mov [alu_a], eax
    mov bl, 8
    call phex
    mov [alu_b], eax
    mov al, [alu_op]
    mov eax, [alu_a]
    mov ebx, [alu_b]
    cmp byte [alu_op], '+'
    je  .add
    cmp byte [alu_op], '-'
    je  .sub
    cmp byte [alu_op], '*'
    je  .mul
    cmp byte [alu_op], 'g'
    je  .gcd
    cmp byte [alu_op], 's'
    je  .sum
    cmp byte [alu_op], 'f'
    je  .fact
    mov esi, s_unknown             ; unknown op
    call out_puts
    jmp exec_done
.add:
    add eax, ebx
    jmp .emit
.sub:
    sub eax, ebx
    jmp .emit
.mul:
    imul eax, ebx
    jmp .emit
.gcd:                              ; Euclid: while b: a,b = b, a mod b
    test ebx, ebx
    jz  .emit
    xor edx, edx
    div ebx                        ; EDX = a mod b
    mov eax, ebx
    mov ebx, edx
    jmp .gcd
.sum:                              ; 1+2+...+a  (closed form a*(a+1)/2, low 32 bits)
    mov ecx, eax
    inc ecx
    imul eax, ecx
    shr eax, 1
    jmp .emit
.fact:                            ; a!  (low 32 bits), iterative multiply
    mov ecx, eax
    mov eax, 1
.factl:
    test ecx, ecx
    jz  .emit
    imul eax, ecx
    dec ecx
    jmp .factl
.emit:
    call print_hex32
    call nl
    jmp exec_done

; ---- H: list the scancodes currently held down (debug for the key table) ----
do_keys_held:
    mov esi, s_keys
    call out_puts
    xor ebx, ebx
.hk:
    cmp byte [key_state + ebx], 0
    je  .hn
    mov eax, ebx
    call print_hex8
    mov al, ' '
    call out_putc
.hn:
    inc ebx
    cmp ebx, 256
    jb  .hk
    call nl
    jmp exec_done

do_help:
    mov esi, s_help
    call out_puts
    jmp exec_done

; ================= input / parsing =================

; readline: read serial until CR into line_buf (asciiz), echo to serial+VGA.
readline:
    push ecx
    xor ecx, ecx
.l:
    call getc
    cmp al, 13                     ; CR terminates the line
    je  .done
    cmp al, 10                     ; LF also terminates (host/QEMU newline)
    je  .done
    cmp ecx, 127
    jae .l
    mov [line_buf + ecx], al
    inc ecx
    call out_putc
    jmp .l
.done:
    mov byte [line_buf + ecx], 0
    pop ecx
    ret

; phex: BL = number of hex chars to read from [parse_ptr] -> EAX; advances ptr.
phex:
    push ebx
    push esi
    mov esi, [parse_ptr]
    xor edx, edx
.l:
    movzx eax, byte [esi]
    inc esi
    call hexval
    shl edx, 4
    and eax, 0x0F
    or  dl, al
    dec bl
    jnz .l
    mov [parse_ptr], esi
    mov eax, edx
    pop esi
    pop ebx
    ret

hexval:                            ; AL ascii hex -> AL nibble (0..15)
    cmp al, '9'
    jbe .num
    and al, 0xDF
    sub al, 7
.num:
    sub al, '0'
    ret

cmos_read:                         ; AL = CMOS reg -> AL = value (BCD)
    out 0x70, al
    in  al, 0x71
    ret

; ================= output (serial + VGA mirror) =================

; out_putc: AL -> VGA always; and COM1 (dev) or the UDP tx buffer (net mode).
out_putc:
    call vga_putc
    cmp byte [net_mode], 0
    jne .tobuf
    call putc
    ret
.tobuf:
    push eax
    push ebx
    movzx ebx, word [tx_len]
    cmp bx, 1280                     ; cap < tx_buf (1536); 301 pts x4 = 1204B fits, < MTU
    jae .full
    mov [tx_buf + ebx], al
    inc word [tx_len]
.full:
    pop ebx
    pop eax
    ret

; out_puts: DS:ESI asciiz -> both.
out_puts:
    push eax
    push esi
.l:
    lodsb
    test al, al
    jz  .d
    call out_putc
    jmp .l
.d:
    pop esi
    pop eax
    ret

nl:
    push eax
    mov al, 13
    call out_putc
    mov al, 10
    call out_putc
    pop eax
    ret

; dump_bin_line: "  " then each char of line_buf as 8 binary digits + space.
dump_bin_line:
    push esi
    push eax
    mov al, ' '
    call out_putc
    mov al, ' '
    call out_putc
    mov esi, line_buf
.ch:
    mov al, [esi]
    test al, al
    jz  .end
    call out_bin8
    mov al, ' '
    call out_putc
    inc esi
    jmp .ch
.end:
    pop eax
    pop esi
    ret

; out_bin8: AL -> 8 binary digits (MSB first) via out_putc.
out_bin8:
    push eax
    push ecx
    mov ah, al
    mov ecx, 8
.b:
    rol ah, 1
    mov al, ah
    and al, 1
    add al, '0'
    call out_putc
    dec ecx
    jnz .b
    pop ecx
    pop eax
    ret

; print_hex8: AL -> two hex chars.
print_hex8:
    push eax
    mov ah, al
    shr al, 4
    call .nib
    mov al, ah
    and al, 0x0F
    call .nib
    pop eax
    ret
.nib:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .emit
    add al, 7
.emit:
    call out_putc
    ret

; print_hex32: EAX -> 8 hex chars.
print_hex32:
    push eax
    push ebx
    push ecx
    mov ebx, eax
    mov ecx, 8
.loop:
    rol ebx, 4
    mov al, bl
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .emit
    add al, 7
.emit:
    call out_putc
    loop .loop
    pop ecx
    pop ebx
    pop eax
    ret

; ---- COM1 ----
putc:                              ; AL -> serial, preserves all
    push eax
    push edx
    mov ah, al
.w:
    mov dx, COM1 + 5
    in  al, dx
    test al, 0x20
    jz  .w
    mov dx, COM1 + 0
    mov al, ah
    out dx, al
    pop edx
    pop eax
    ret

getc:                              ; -> AL. Blocking serial read (dev REPL).
    push edx
.w:
    mov dx, COM1 + 5
    in  al, dx
    test al, 0x01
    jz  .w
    mov dx, COM1 + 0
    in  al, dx
    pop edx
    ret

; ---- VGA text buffer (0xB8000, 80x25), bright green on black ----
vga_clear:
    pushad
    mov edi, VGA
    mov ecx, SCR_CELLS
    mov ax, (VGA_ATTR << 8) | ' '
.l:
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .l
    mov dword [vga_pos], 0
    popad
    ret

; show_face: draw the baked-in portrait (face_data) centred on the screen.
show_face:
    pushad
    xor ecx, ecx                   ; row
.r:
    cmp ecx, FACE_H
    jae .d
    mov eax, ecx
    imul eax, eax, 80
    add eax, FACE_COL
    mov [vga_pos], eax             ; cursor = row*80 + FACE_COL
    mov esi, face_data
    mov eax, ecx
    imul eax, eax, FACE_W
    add esi, eax                   ; src = face_data + row*FACE_W
    mov edi, FACE_W
.c:
    mov al, [esi]
    inc esi
    call vga_putc
    dec edi
    jnz .c
    inc ecx
    jmp .r
.d:
    popad
    ret

; ================= PS/2 keyboard (local input on the old PC) =================
; draw_prompt: draw "> " at the start of the input line.
draw_prompt:
    mov dword [kbd_len], 0
    mov edi, INPUT_ROW * 80 * 2 + VGA
    mov word [edi], 0x0A3E         ; '>'
    mov word [edi+2], 0x0A20       ; ' '
    ; enable & shape the hardware text cursor (underline, visible)
    mov dx, 0x3D4
    mov al, 0x0A
    out dx, al
    mov dx, 0x3D5
    mov al, 0x0D                   ; start scanline 13, bit5(disable)=0 -> visible
    out dx, al
    mov dx, 0x3D4
    mov al, 0x0B
    out dx, al
    mov dx, 0x3D5
    mov al, 0x0F                   ; end scanline 15
    out dx, al
    mov eax, INPUT_ROW * 80 + 2
    call set_cursor
    ret

; kbd_init: initialise the 8042 controller for a real-hardware keyboard.
; Forces scancode-translation ON (so port 0x60 yields set-1 codes like QEMU) and
; enables keyboard scanning (0xF4). Every controller wait is timeout-guarded so a
; dead/odd 8042 can never hang the boot. Clobbers eax, ecx, edx.
kbd_init:
    call .flush
    mov al, 0xAD                   ; disable keyboard port
    out 0x64, al
    call .wait_in
    mov al, 0xA7                   ; disable aux (mouse) port
    out 0x64, al
    call .flush
    mov al, 0x20                   ; read controller command byte
    out 0x64, al
    call .wait_out
    in  al, 0x60
    or  al, 0x40                   ; bit6 = translation ON (deliver set-1 at 0x60)
    and al, 0xEF                   ; bit4 = 0 -> keyboard clock enabled
    and al, 0xFE                   ; bit0 = 0 -> NO keyboard IRQ1 (we poll). Stops the
                                   ; real-mode BIOS INT 09h handler, which runs with
                                   ; interrupts on during PXE trampolines, from stealing
                                   ; our scancodes out of port 0x60 before we poll them.
    mov ah, al
    call .wait_in
    mov al, 0x60                   ; write controller command byte
    out 0x64, al
    call .wait_in
    mov al, ah
    out 0x60, al
    call .wait_in
    mov al, 0xAE                   ; enable keyboard port
    out 0x64, al
    call .wait_in
    mov al, 0xF4                   ; tell the keyboard device to start scanning
    out 0x60, al
    call .flush                    ; eat the 0xFA ack
    in  al, 0x21                   ; mask IRQ1 at the PIC too, so even if PXE re-enables
    or  al, 0x02                   ; keyboard interrupts the BIOS ISR still never fires
    out 0x21, al
    ret
.wait_in:                          ; wait until input buffer empty (safe to write)
    mov ecx, 0x40000
.wi:
    in  al, 0x64
    test al, 2
    jz  .wid
    dec ecx
    jnz .wi
.wid:
    ret
.wait_out:                         ; wait until output buffer full (safe to read)
    mov ecx, 0x40000
.wo:
    in  al, 0x64
    test al, 1
    jnz .wod
    dec ecx
    jnz .wo
.wod:
    ret
.flush:                            ; drain any pending output bytes
    mov ecx, 0x1000
.fl:
    in  al, 0x64
    test al, 1
    jz  .fld
    in  al, 0x60
    dec ecx
    jnz .fl
.fld:
    ret

; hud_byte: AL = byte -> two hex chars at VGA cell [EDI] (attr 0x0E). Preserves regs.
HUD_CELL equ 49 * 80 * 2           ; bottom-left corner, clear of face & dialogue
hud_byte:
    push eax
    push ebx
    push edi
    mov bl, al
    shr al, 4
    call .nib
    mov al, bl
    call .nib
    pop edi
    pop ebx
    pop eax
    ret
.nib:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .e
    add al, 7
.e:
    mov [edi], al
    mov byte [edi+1], 0x0E
    add edi, 2
    ret

; set_cursor: EAX = linear text position (row*80 + col) -> move the hardware cursor.
set_cursor:
    push eax
    push ebx
    push edx
    mov ebx, eax
    mov dx, 0x3D4
    mov al, 0x0F                   ; cursor-location low
    out dx, al
    mov dx, 0x3D5
    mov al, bl
    out dx, al
    mov dx, 0x3D4
    mov al, 0x0E                   ; cursor-location high
    out dx, al
    mov dx, 0x3D5
    mov al, bh
    out dx, al
    pop edx
    pop ebx
    pop eax
    ret

; kbd_service: drain the whole 8042 output buffer this call, echoing every
; mapped make code (Enter sends the line). Draining fully each iteration stops
; the keyboard FIFO overflowing (which otherwise drops keys and beeps) on fast
; typing. Handles the E0 extended prefix (arrows/nav) by discarding that pair.
; Shows the raw status + last scancode as hex in the bottom-left HUD.
kbd_service:
    push ecx
    push edx
    push ebx
    mov ecx, 24                    ; bound the drain per iteration
.ks:
    in  al, 0x64
    mov edi, VGA + HUD_CELL         ; HUD: controller status at col 0
    call hud_byte
    test al, 1                     ; output buffer empty?
    jz  .ksret
    test al, 0x20                  ; aux (mouse) byte?
    jnz .ksaux
    in  al, 0x60                   ; scancode
    call kbd_track                 ; maintain the pressed/released key table
    mov edi, VGA + HUD_CELL + 6     ; HUD: scancode at col 3
    call hud_byte
    cmp al, 0xE0                   ; extended-key prefix (arrows etc.)?
    je  .ksext
    cmp al, 0x2A                   ; left shift pressed
    je  .ksshon
    cmp al, 0x36                   ; right shift pressed
    je  .ksshon
    cmp al, 0xAA                   ; left shift released
    je  .ksshoff
    cmp al, 0xB6                   ; right shift released
    je  .ksshoff
    test al, 0x80                  ; break (release) code?
    jnz .ksnext
    movzx eax, al
    mov ebx, scancode_map
    cmp byte [shift_state], 0
    je  .ksmap
    mov ebx, scancode_shift        ; shifted layer: uppercase + URL symbols (: / _ ?)
.ksmap:
    mov al, [ebx + eax]
    test al, al                    ; unmapped key?
    jz  .ksnext
    call kbd_char                  ; echo / handle the character
.ksnext:
    dec ecx
    jnz .ks
.ksret:
    pop ebx
    pop edx
    pop ecx
    ret
.ksshon:
    mov byte [shift_state], 1
    jmp .ksnext
.ksshoff:
    mov byte [shift_state], 0
    jmp .ksnext
.ksaux:
    in  al, 0x60                   ; discard aux byte
    jmp .ksnext
.ksext:
    mov edx, 0x8000                ; wait briefly for the code after E0, discard it
.ksew:
    in  al, 0x64
    test al, 1
    jnz .ksec
    dec edx
    jnz .ksew
    jmp .ksnext
.ksec:
    in  al, 0x60                   ; discard the extended code (but track its state)
    call kbd_track
    jmp .ksnext

; kbd_track: AL = one raw byte from port 0x60 -> update key_state[] (the
; pressed/released table games poll). Index = set-1 make code (0..0x7F), or
; 0x80|code for E0-prefixed (extended) keys such as the arrows. Handles the E0
; prefix, the set-2 F0 break prefix (in case translation is off), and ignores
; the E1 (pause) prefix and the FA/FE/FF ack/resend/error bytes. Preserves all.
kbd_track:
    push eax
    push ebx
    cmp al, 0xE0
    je  .ext
    cmp al, 0xE1
    je  .done
    cmp al, 0xF0
    je  .brk
    cmp al, 0xFA
    jae .done
    movzx ebx, al
    mov ah, al
    and ah, 0x80                   ; set-1 break bit
    and ebx, 0x7F
    cmp byte [kbd_e0], 0
    je  .n1
    or  ebx, 0x80                  ; extended key -> upper half of the table
    mov byte [kbd_e0], 0
.n1:
    cmp byte [kbd_f0], 0
    je  .n2
    mov ah, 0x80                   ; F0-prefixed = release
    mov byte [kbd_f0], 0
.n2:
    test ah, ah
    jnz .rel
    mov byte [key_state + ebx], 1
    jmp .done
.rel:
    mov byte [key_state + ebx], 0
    jmp .done
.ext:
    mov byte [kbd_e0], 1
    jmp .done
.brk:
    mov byte [kbd_f0], 1
.done:
    pop ebx
    pop eax
    ret

; kbd_drain: read every byte waiting in the 8042 output buffer into kbd_track
; (no echo, no line editing - the game layer reads key_state directly). Also
; records the raw controller status and last scancode for on-screen diagnostics.
; Bounded per call. Preserves all registers.
kbd_drain:
    push eax
    push ecx
    mov ecx, 32
.d:
    in  al, 0x64
    mov [kbd_last_status], al
    test al, 1
    jz  .q
    test al, 0x20                  ; aux (mouse) byte -> discard
    jnz .aux
    in  al, 0x60
    mov [kbd_last_sc], al
    call kbd_track
    inc dword [kbd_byte_count]
    dec ecx
    jnz .d
    jmp .q
.aux:
    in  al, 0x60
    dec ecx
    jnz .d
.q:
    pop ecx
    pop eax
    ret

; kbd_char: handle a typed character in AL (echo on the input line; Enter sends).
kbd_char:
    pushad
    cmp byte [gfx_mode], 0          ; a full-screen image/reader page is up?
    je  .console
    ; reader/image mode: send each printable key to the dev PC IMMEDIATELY (per-key
    ; navigation) with no echo or line buffering, so 'j'/'k'/'f'/'n'/'q' act at once.
    cmp al, 32
    jb  .done                       ; ignore Enter/backspace while a page is shown
    inc byte [kbd_seq]              ; a per-keypress sequence number so the dev PC can
    mov [kbd_buf], al               ; dedup the redundant copies (char + seq = 2 bytes)
    mov bl, [kbd_seq]
    mov [kbd_buf+1], bl
    mov dword [kbd_len], 2
    call send_question              ; send a few times - this UNDI stack drops single
    call send_question              ; UDP packets, and one lost key would strand the
    call send_question              ; user on the page; the dev PC dedups by seq
    mov dword [kbd_len], 0
    jmp .done
.console:
    mov byte [need_present], 1      ; console/chat: line-based, echo, repaint on change
    cmp al, 13
    je  .enter
    cmp al, 8
    je  .bs
    movzx ebx, byte [kbd_len]
    cmp ebx, 70                    ; keep within the left column
    jae .done
    mov [kbd_buf + ebx], al
    inc dword [kbd_len]
    mov edi, INPUT_ROW * 80 + 2
    add edi, ebx
    shl edi, 1
    add edi, VGA
    mov [edi], al                  ; echo
    mov byte [edi+1], 0x0F
    jmp .done
.bs:
    cmp dword [kbd_len], 0
    je  .done
    dec dword [kbd_len]
    movzx ebx, byte [kbd_len]
    mov edi, INPUT_ROW * 80 + 2
    add edi, ebx
    shl edi, 1
    add edi, VGA
    mov word [edi], 0x0A20         ; erase
    jmp .done
.enter:
    cmp dword [kbd_len], 0
    je  .done
    call send_question             ; UDP the line to the dev-PC agent service
    ; clear the input line
    mov edi, (INPUT_ROW * 80 + 2) * 2 + VGA
    mov ecx, 72
    mov ax, 0x0A20
.cl:
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .cl
    mov dword [kbd_len], 0
.done:
    mov eax, [kbd_len]             ; keep the hardware cursor at the caret
    add eax, INPUT_ROW * 80 + 2
    call set_cursor
    popad
    ret

; send_question: UDP_WRITE kbd_buf to the dev PC (DEVPC_IP:Q_PORT).
send_question:
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov dword [pxe_param+2], DEVPC_IP
    mov dword [pxe_param+6], DEVPC_IP   ; gw = dest: old UNDI stacks need an on-link
                                        ; gateway set or UDP_WRITE delivers nowhere
    mov word [pxe_param+10], NET_PORT   ; src port = our 50000
    mov word [pxe_param+12], Q_PORT     ; dst port = 50001
    mov eax, [kbd_len]
    mov [pxe_param+14], ax              ; length
    mov word [pxe_param+16], kbd_buf
    mov word [pxe_param+18], 0
    mov ax, 0x0033                      ; PXENV_UDP_WRITE
    call pxe_call
    ; HUD: 'W=' + UDP_WRITE status word (0000 = success) at bottom row, col 9
    mov word [VGA + HUD_CELL + 18], 0x0E57   ; 'W'
    mov word [VGA + HUD_CELL + 20], 0x0E3D   ; '='
    mov al, [pxe_param+1]               ; status high byte
    mov edi, VGA + HUD_CELL + 22
    call hud_byte
    mov al, [pxe_param+0]               ; status low byte
    mov edi, VGA + HUD_CELL + 26
    call hud_byte
    ret

; vga_puts: DS:ESI asciiz -> VGA only. Preserves all.
vga_puts:
    push eax
    push esi
.l:
    lodsb
    test al, al
    jz  .d
    call vga_putc
    jmp .l
.d:
    pop esi
    pop eax
    ret

; vga_putc: AL char -> VGA at [vga_pos]; handles CR/LF and scroll. Preserves all.
vga_putc:
    pushad
    cmp al, 13
    je  .cr
    cmp al, 10
    je  .lf
    mov edi, [vga_pos]
    mov ebx, edi
    shl ebx, 1
    add ebx, VGA
    mov ah, [cur_attr]
    mov [ebx], ax                  ; al=char, ah=attr
    inc edi
    mov [vga_pos], edi
    cmp edi, SCR_CELLS
    jae .scroll
    jmp .done
.cr:
    mov eax, [vga_pos]
    xor edx, edx
    mov ecx, 80
    div ecx                        ; eax=row
    mul ecx                        ; eax=row*80
    mov [vga_pos], eax
    jmp .done
.lf:
    mov eax, [vga_pos]
    xor edx, edx
    mov ecx, 80
    div ecx
    inc eax                        ; next row
    mul ecx
    mov [vga_pos], eax
    cmp eax, SCR_CELLS
    jae .scroll
    jmp .done
.scroll:
    call vga_scroll
.done:
    popad
    ret

; vga_scroll: scroll up one line, clear the last line, cursor to last line start.
vga_scroll:
    pushad
    mov esi, VGA + 160
    mov edi, VGA
    mov ecx, (SCR_ROWS-1) * 80
.c:
    mov ax, [esi]
    mov [edi], ax
    add esi, 2
    add edi, 2
    dec ecx
    jnz .c
    mov edi, VGA + (SCR_ROWS-1) * 80 * 2
    mov ecx, 80
    mov ax, (VGA_ATTR << 8) | ' '
.cl:
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .cl
    mov dword [vga_pos], (SCR_ROWS-1) * 80
    popad
    ret

; ================= Matrix digital rain (0/1) =================
; rand32: xorshift32 PRNG -> EAX. Clobbers EAX, EDX only.
rand32:
    mov eax, [rng_state]
    mov edx, eax
    shl eax, 13
    xor eax, edx
    mov edx, eax
    shr eax, 17
    xor eax, edx
    mov edx, eax
    shl eax, 5
    xor eax, edx
    mov [rng_state], eax
    ret

; --- PIT channel 0 free-running timebase ---
; Channel 0 runs continuously at 1.193182 MHz (the BIOS timer tick). We just
; read its counter and measure elapsed counts, so timing is identical on QEMU
; and on real hardware regardless of CPU speed. Reprogrammed to mode 2 so the
; count decrements cleanly by 1 (mode 3 steps by 2); the ~18.2 Hz period is
; unchanged and we have no IRQ handler anyway (IF stays clear).
; uart_detect: probe COM1's scratch register (offset 7) to tell a real 16550
; from a missing port. An absent port reads back 0xFF, so writing/reading two
; patterns distinguishes them. Sets com1_present (1/0). On a machine with no
; serial port (e.g. the Asus K50IJ) every COM1 read is 0xFF, which otherwise
; looks like "data always ready" and breaks the rain + jams the REPL.
uart_detect:
    push eax
    push edx
    mov dx, COM1 + 7
    mov al, 0x5A
    out dx, al
    in  al, dx
    cmp al, 0x5A
    jne .no
    mov al, 0xA5
    out dx, al
    in  al, dx
    cmp al, 0xA5
    jne .no
    mov byte [com1_present], 1
    jmp .done
.no:
    mov byte [com1_present], 0
.done:
    pop edx
    pop eax
    ret

pit_init:
    push eax
    mov al, 0x34                   ; ch0, lobyte/hibyte, mode 2, binary
    out 0x43, al
    xor al, al
    out 0x40, al                   ; reload low  = 0
    out 0x40, al                   ; reload high = 0  -> 65536
    pop eax
    ret

; pit_read: -> AX = current channel 0 count. Clobbers EAX only.
pit_read:
    push edx
    mov al, 0x00                   ; counter-latch command, channel 0
    out 0x43, al
    mov dx, 0x40
    in  al, dx                     ; latched low byte
    mov ah, al
    in  al, dx                     ; latched high byte
    xchg al, ah                    ; AX = (high << 8) | low
    pop edx
    ret

; pit_delay_frame: busy-wait ~FRAME_COUNTS ch0 counts. Preserves all registers.
pit_delay_frame:
    pushad
    call pit_read
    movzx ebp, ax                  ; prev
    xor ecx, ecx                   ; accumulated counts
.l:
    call pit_read
    movzx ebx, ax                  ; cur
    mov eax, ebp
    sub eax, ebx                   ; prev - cur (ch0 counts down)
    jns .nowrap
    add eax, 65536                 ; wrapped
.nowrap:
    add ecx, eax
    mov ebp, ebx
    cmp ecx, FRAME_COUNTS
    jb  .l
    popad
    ret

; pit_delay_frame_or_serial: like pit_delay_frame but returns early the moment a
; byte is waiting on COM1 - so the ambient rain never blocks command input and
; the UART (no FIFO) is polled tightly enough not to drop bytes.
pit_delay_frame_or_serial:
    pushad
    call pit_read
    movzx ebp, ax
    xor ecx, ecx
.l:
    mov dx, COM1 + 5
    in  al, dx
    test al, 1
    jnz .done                      ; serial data waiting -> bail out
    call pit_read
    movzx ebx, ax
    mov eax, ebp
    sub eax, ebx
    jns .nowrap
    add eax, 65536
.nowrap:
    add ecx, eax
    mov ebp, ebx
    cmp ecx, FRAME_COUNTS
    jb  .l
.done:
    popad
    ret

; rain_intro: Matrix-style binary rain. 80 columns, each with its own fall
; speed and trail length, bright-white head -> bright green -> dark green,
; characters flicker between 0 and 1 every frame. PIT-timed, RAIN_FRAMES long.
rain_intro:
    pushad
    rdtsc                          ; seed from the cycle counter
    or  eax, 1                     ; must be non-zero for xorshift
    mov [rng_state], eax

    xor ecx, ecx                   ; per-column init
.init:
    call rand32
    xor edx, edx
    mov ebx, SCR_ROWS
    div ebx
    neg edx
    mov [col_head + ecx*4], edx    ; head start -(rand%25)
    call rand32
    xor edx, edx
    mov ebx, 4
    div ebx
    inc edx                        ; speed 1..4 frames per step
    mov [col_speed + ecx*4], edx
    mov [col_tick + ecx*4], edx
    call rand32
    xor edx, edx
    mov ebx, 9
    div ebx
    add edx, 5                     ; trail length 5..13
    mov [col_tail + ecx*4], edx
    inc ecx
    cmp ecx, 80
    jb  .init

    mov dword [frame_ctr], RAIN_FRAMES
.frame:
    xor ecx, ecx                   ; column
.col:
    mov eax, [col_tick + ecx*4]    ; time to step this column?
    dec eax
    mov [col_tick + ecx*4], eax
    jnz .draw                      ; not yet - just reflicker in place

    mov edx, [col_speed + ecx*4]   ; reset the step counter
    mov [col_tick + ecx*4], edx
    mov esi, [col_head + ecx*4]
    mov eax, esi                   ; clear old trail end: row = head - taillen
    sub eax, [col_tail + ecx*4]
    call .clear_cell
    mov eax, esi
    inc eax                        ; advance head
    mov edx, eax
    sub edx, [col_tail + ecx*4]
    cmp edx, SCR_ROWS                    ; whole trail off the bottom -> respawn on top
    jl  .store_head
    call rand32
    xor edx, edx
    mov ebx, 20
    div ebx
    neg edx
    mov eax, edx
.store_head:
    mov [col_head + ecx*4], eax

.draw:
    mov esi, [col_head + ecx*4]
    xor edi, edi                   ; k = 0 .. taillen-1
.k:
    mov eax, edi
    cmp eax, [col_tail + ecx*4]
    jge .coldone
    mov eax, esi
    sub eax, edi                   ; row = head - k
    cmp eax, 0
    jl  .knext
    cmp eax, SCR_ROWS
    jge .knext
    push eax                       ; row (rand32 clobbers eax/edx)
    call rand32
    and eax, 1
    add al, '0'                    ; flicker 0/1
    mov bl, al
    mov bh, 0x02                   ; dark green trail
    cmp edi, 3
    jge .wr
    mov bh, 0x0A                   ; bright green near head
    test edi, edi
    jnz .wr
    mov bh, 0x0F                   ; white head
.wr:
    pop eax
    imul eax, eax, 80
    add eax, ecx
    shl eax, 1
    add eax, VGA
    mov [eax], bl
    mov [eax+1], bh
.knext:
    inc edi
    jmp .k
.coldone:
    inc ecx
    cmp ecx, 80
    jb  .col

    call pit_delay_frame
    cmp byte [com1_present], 0      ; only a real serial port can skip the intro
    je  .nobail
    mov dx, COM1 + 5               ; a waiting command byte ends the intro
    in  al, dx
    test al, 1
    jnz .fin
.nobail:
    dec dword [frame_ctr]
    jnz .frame
.fin:
    popad
    ret

; .clear_cell: EAX = row, ECX = column -> blank that cell. Clobbers EAX only.
.clear_cell:
    cmp eax, 0
    jl  .cc_done
    cmp eax, SCR_ROWS
    jge .cc_done
    push ebx
    imul eax, eax, 80
    add eax, ecx
    shl eax, 1
    add eax, VGA
    mov word [eax], (VGA_ATTR << 8) | ' '
    pop ebx
.cc_done:
    ret

; ================= ambient terminal rain =================
; A sparse, single-dot-per-column drizzle that flows behind the REPL. It only
; ever writes a cell that is blank and only clears a cell that still holds its
; own dark-green digit, so it never touches the PCI table, banner, prompt,
; commands or results. Stepped one frame per idle getc poll.

rain_bg_init:
    pushad
    xor ecx, ecx
.l:
    call rand32
    xor edx, edx
    mov ebx, SCR_ROWS
    div ebx
    neg edx
    mov [col_head + ecx*4], edx    ; start -(rand%25)
    call rand32
    xor edx, edx
    mov ebx, 6
    div ebx
    inc edx                        ; speed 1..6 frames per step (gentle)
    mov [col_speed + ecx*4], edx
    mov [col_tick + ecx*4], edx
    mov dword [col_prev + ecx*4], -1
    inc ecx
    cmp ecx, 80
    jb  .l
    popad
    ret

rain_bg_step:
    pushad
    xor ecx, ecx                   ; column
.col:
    mov eax, [col_tick + ecx*4]
    dec eax
    mov [col_tick + ecx*4], eax
    jnz .next                      ; not this column's turn this frame
    mov edx, [col_speed + ecx*4]
    mov [col_tick + ecx*4], edx

    ; erase previous dot, but only if the cell still holds our dark-green digit
    mov eax, [col_prev + ecx*4]
    cmp eax, 0
    jl  .noerase
    cmp eax, SCR_ROWS
    jge .noerase
    imul eax, eax, 80
    add eax, ecx
    shl eax, 1
    add eax, VGA
    cmp byte [eax+1], 0x02         ; our attribute?
    jne .noerase
    mov bl, [eax]
    cmp bl, '0'
    je  .doerase
    cmp bl, '1'
    jne .noerase
.doerase:
    mov word [eax], (0x02 << 8) | ' '
.noerase:

    ; advance head, respawn above the top with a gap when it falls off
    mov eax, [col_head + ecx*4]
    inc eax
    cmp eax, SCR_ROWS
    jl  .store
    call rand32
    xor edx, edx
    mov ebx, 30
    div ebx
    neg edx
    mov eax, edx                   ; -(rand%30)
.store:
    mov [col_head + ecx*4], eax

    mov dword [col_prev + ecx*4], -1   ; assume nothing drawn
    cmp eax, 0
    jl  .next
    cmp eax, SCR_ROWS
    jge .next
    mov edx, eax                   ; row
    imul eax, eax, 80
    add eax, ecx
    shl eax, 1
    add eax, VGA
    cmp byte [eax], ' '            ; draw only onto blank cells (never text)
    jne .next
    mov [col_prev + ecx*4], edx    ; record row BEFORE rand32 clobbers edx
    push eax
    call rand32
    and eax, 1
    add al, '0'
    mov bl, al
    pop eax
    mov [eax], bl
    mov byte [eax+1], 0x02         ; dark green = subtle background
.next:
    inc ecx
    cmp ecx, 80
    jb  .col
    popad
    ret

; ================= PCI self-scan (hardware autodetect) =================
; At boot, enumerate PCI mechanism 1 and list every present function as
;   bb:dd.f  vendor:device  classdword
; so the Agent (or a photo of the screen) can read what hardware this machine
; actually has - the first step to knowing which drivers to write.

print_hex16:                       ; AX -> 4 hex (MSB first)
    push eax
    mov al, ah
    call print_hex8
    pop eax
    push eax
    call print_hex8
    pop eax
    ret

; pci_read: AL = dword-aligned offset -> EAX = config dword at [pci_bus/dev/func]
pci_read:
    push edx
    push ebx
    movzx ebx, byte [pci_bus]
    shl ebx, 16
    movzx edx, byte [pci_dev]
    and edx, 0x1F
    shl edx, 11
    or  ebx, edx
    movzx edx, byte [pci_func]
    and edx, 7
    shl edx, 8
    or  ebx, edx
    movzx edx, al
    and edx, 0xFC
    or  ebx, edx
    or  ebx, 0x80000000
    mov eax, ebx
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    pop ebx
    pop edx
    ret

; print_pci_line: EBX = config dword at offset 0 (device:vendor)
print_pci_line:
    mov al, [pci_bus]
    call print_hex8
    mov al, ':'
    call out_putc
    mov al, [pci_dev]
    call print_hex8
    mov al, '.'
    call out_putc
    mov al, [pci_func]
    call print_hex8
    mov al, ' '
    call out_putc
    mov eax, ebx                   ; vendor = low 16
    call print_hex16
    mov al, ':'
    call out_putc
    mov eax, ebx
    shr eax, 16                    ; device = high 16
    call print_hex16
    mov al, ' '
    call out_putc
    mov al, 8                      ; class/subclass/progif/rev dword
    call pci_read
    call print_hex32
    call nl
    ret

pci_scan:
    mov esi, s_pcihdr
    call out_puts
    mov byte [pci_bus], 0
.bus_l:
    mov byte [pci_dev], 0
.dev_l:
    mov byte [pci_func], 0
.func_l:
    xor al, al
    call pci_read
    mov ebx, eax                   ; off0 = device:vendor
    cmp bx, 0xFFFF                 ; BX = vendor
    jne .present
    cmp byte [pci_func], 0
    je  .nextdev                   ; func0 absent -> whole device absent
    jmp .incfunc
.present:
    call print_pci_line
    cmp byte [pci_func], 0
    jne .incfunc
    mov al, 0x0C                   ; header type byte is 0x0E
    call pci_read
    shr eax, 16                    ; AL = byte 0x0E (header type)
    test al, 0x80                  ; multifunction?
    jz  .nextdev
.incfunc:
    inc byte [pci_func]
    cmp byte [pci_func], 8
    jb  .func_l
.nextdev:
    inc byte [pci_dev]
    cmp byte [pci_dev], 32
    jb  .dev_l
    inc byte [pci_bus]
    cmp byte [pci_bus], 6          ; scan buses 0..5
    jb  .bus_l
    ret

; ================= PM <-> real-mode trampoline for PXE API =================
; pxe_call: invoke the PXE real-mode API (16-bit) from our 32-bit kernel.
;   in : AX = opcode; the parameter struct is in `pxe_param` (seg 0)
;   out: [pxe_ax] = AX exit code; the struct's Status field is updated
; Switches PM -> 16-bit PM -> real mode, far-calls PXENV+.RMEntry, returns to PM.
; Call with interrupts off. All code here lives below 64 KiB so real-mode
; seg-0 offsets equal the flat PM addresses.
BITS 32
pxe_call:
    pushad
    mov [pxe_op], ax
    mov [pm_esp], esp
    jmp 0x18:pc_prot16             ; enter 16-bit protected mode
BITS 16
pc_prot16:
    mov ax, 0x20                   ; 16-bit data segment
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov eax, cr0
    and eax, 0xFFFFFFFE            ; clear PE
    mov cr0, eax
    jmp 0x0000:pc_real16           ; flush into real mode (CS base 0)
pc_real16:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0x6000                 ; real-mode stack (separate from the PM stack
    lidt [real_idt]                ; at 0x7000 so the PXE call can't clobber it)
    sti                            ; PXE may need BIOS/NIC interrupts

    ; PXENV+ RMEntry legacy convention: ES:DI -> param struct, BX = opcode
    mov bx, [pxe_op]
    xor ax, ax
    mov es, ax
    mov di, pxe_param
    call far [rmentry]             ; PXENV+.RMEntry (off@0x5000 seg@0x5002)
    mov [pxe_ax], ax

    cli
    lgdt [gdt_desc]
    mov eax, cr0
    or  eax, 1                     ; set PE
    mov cr0, eax
    jmp 0x08:pc_prot32             ; back to 32-bit protected mode
BITS 32
pc_prot32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, [pm_esp]
    popad
    ret

; ================= graphics console: render the text buffer as pixels ===========
; The display stays in one VBE graphics mode (set once at boot). The existing text
; code still writes char+attr cells to the 0xB8000 buffer; present_text paints that
; buffer into the linear framebuffer with the 8x8 ROM font. Images blit straight to
; the framebuffer, and restore_text repaints the text over them. No runtime mode
; switching (which this old GMA won't do), so it is reliable on real hardware.

; clear_lfb: fill the whole framebuffer black.
clear_lfb:
    cmp byte [vbe_ok], 0
    je  .q
    pushad
    mov edi, [lfb_phys]
    mov ecx, [fb_size]
    shr ecx, 2
    xor eax, eax
    rep stosd
    popad
.q:
    ret

; present_text: paint the 80 x SCR_ROWS text buffer at VGA (0xB8000) into the LFB.
present_text:
    cmp byte [vbe_ok], 0
    je  .q
    pushad
    xor ebx, ebx                   ; row
.prow:
    xor ecx, ecx                   ; col
.pcol:
    mov eax, ebx
    imul eax, 80
    add eax, ecx
    shl eax, 1
    movzx edx, byte [VGA + eax]    ; char
    movzx esi, byte [VGA + eax + 1]; attr
    call draw_glyph
    inc ecx
    cmp ecx, 80
    jb  .pcol
    inc ebx
    cmp ebx, SCR_ROWS
    jb  .prow
    popad
.q:
    ret

; draw_glyph: render one 8x8 glyph. ecx=col, ebx=row, dl=char, esi=attr. Colour from
; the attribute low nibble (white / bright green / dim green). Preserves all regs.
draw_glyph:
    pushad
    and esi, 0x0F
    mov eax, 0x0000FF00            ; bright green (BGRX: G=0xFF)
    cmp esi, 0x0F
    jne .c1
    mov eax, 0x00FFFFFF            ; white
.c1:
    cmp esi, 0x02
    jne .c2
    mov eax, 0x00008000           ; dim green
.c2:
    mov [g_fg], eax
    mov eax, ecx                  ; px0 = X0 + col*8
    shl eax, 3
    add eax, [X0]
    mov [g_px0], eax
    mov eax, ebx                  ; py0 = Y0 + row*8
    shl eax, 3
    add eax, [Y0]
    mov [g_py0], eax
    movzx eax, dl                 ; font row base = font_buf + char*8
    shl eax, 3
    add eax, font_buf
    mov [g_fontp], eax
    xor eax, eax
    mov [g_gy], eax
.gy:
    mov esi, [g_fontp]
    mov eax, [g_gy]
    movzx edx, byte [esi+eax]     ; 8 glyph bits for this row
    mov eax, [g_py0]
    add eax, [g_gy]
    imul eax, [lfb_pitch]
    add eax, [lfb_phys]
    mov ecx, [g_px0]
    lea edi, [eax + ecx*4]        ; dest pixel address
    mov cl, 0x80                  ; bit mask (MSB first)
.gx:
    test dl, cl
    jz  .blk
    mov eax, [g_fg]
    jmp .put
.blk:
    xor eax, eax
.put:
    mov [edi], eax
    add edi, 4
    shr cl, 1
    jnz .gx
    inc dword [g_gy]
    cmp dword [g_gy], 8
    jb  .gy
    popad
    ret

; restore_text: blank the framebuffer and repaint the text buffer (return from a
; full-screen image back to the face / chat).
restore_text:
    call clear_lfb
    call present_text
    ret

; refresh_console: repaint after a text change. If an image was up, clear first.
refresh_console:
    cmp byte [gfx_mode], 0
    je  .plain
    mov byte [gfx_mode], 0
    call restore_text
    ret
.plain:
    call present_text
    ret

%ifdef IMAGE_DEMO
; ================= image demo: draw into the linear framebuffer (32-bit PM) =====
; Flat 4 GiB segments make the (high) LFB physical address directly writable.
; The gradient shows at boot; then the Agent streams a photo over UDP with the
; 'G' command (one block of pixels per packet) and it appears on the whole screen.
image_demo_pm:
    cmp byte [vbe_ok], 0
    je  img_nofb                   ; VBE mode-set failed -> nothing to draw into
    call draw_test                 ; gradient = "alive + graphics mode" until a photo lands
    mov eax, [lfb_pitch]
    mul dword [lfb_h]
    mov [fb_size], eax             ; framebuffer byte size (for G-command bounds check)
    ; bring up the PXE UDP channel if we network-booted (same as the text kernel)
    cmp word [0x5008], 0x5850
    jne img_hang                   ; no network (USB boot): just leave the gradient up
    mov byte [pxe_present], 1
    mov eax, [0x5000]
    mov [rmentry], eax
    mov edi, pxe_param             ; GET_CACHED_INFO (0x0071) -> our IP (DHCP yiaddr)
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov word [pxe_param+2], 2
    mov ax, 0x0071
    call pxe_call
    movzx eax, word [pxe_param+8]
    shl eax, 4
    movzx ecx, word [pxe_param+6]
    add eax, ecx
    mov edx, [eax+16]
    mov [our_ip], edx
    mov edi, pxe_param             ; UDP_OPEN (0x0030) bound to our IP
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+2], eax
    mov ax, 0x0030
    call pxe_call
    ; fall into the image network loop
image_net_loop:
    call pit_init                  ; PXE may have reprogrammed the PIT
.poll:
    mov edi, pxe_param             ; UDP_READ into rx_buf
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+6], eax          ; dest_ip filter = our IP
    mov word [pxe_param+12], NET_PORT   ; d_port = our listening port (50000)
    mov word [pxe_param+14], 760        ; buffer_size (max)
    mov word [pxe_param+16], rx_buf     ; buffer offset
    mov word [pxe_param+18], 0          ; buffer segment
    mov ax, 0x0032                 ; PXENV_UDP_READ
    call pxe_call
    cmp word [pxe_param], 0        ; Status 0 = got a packet
    jne .poll
    movzx ecx, word [pxe_param+14] ; received length
    cmp byte [rx_buf], 'Q'         ; Q = query framebuffer geometry
    je  .query
    cmp byte [rx_buf], 'G'         ; G<8hex LFB byte offset><raw pixel bytes>
    jne .poll
    cmp ecx, 9                     ; need 'G' + 8 hex + at least 1 pixel byte
    jbe .poll
    sub ecx, 9                     ; pixel byte count
    mov [pix_len], ecx             ; stash (phex uses edx/eax)
    mov dword [parse_ptr], rx_buf + 1
    mov bl, 8
    call phex                      ; EAX = LFB byte offset
    cmp eax, [fb_size]
    jae .poll                      ; offset past the framebuffer -> drop
    mov edx, [fb_size]
    sub edx, eax                   ; bytes of room left from that offset
    mov ecx, [pix_len]
    cmp ecx, edx
    jbe .okl
    mov ecx, edx                   ; clamp so a bad packet can't write past the FB
.okl:
    mov edi, [lfb_phys]
    add edi, eax
    lea esi, [rx_buf+9]            ; pixel bytes start after 'G' + 8 hex
    rep movsb                      ; blit into the linear framebuffer
    jmp .poll
.query:
    ; reply to the sender with the real geometry: 4 LE dwords w,h,pitch,bpp.
    ; Lets show_image.py lay pixels out with the exact pitch (no skew guesswork).
    mov eax, [pxe_param+2]
    mov [peer_ip], eax
    mov ax, [pxe_param+10]
    mov [peer_port], ax
    mov eax, [lfb_w]
    mov [tx_buf+0], eax
    mov eax, [lfb_h]
    mov [tx_buf+4], eax
    mov eax, [lfb_pitch]
    mov [tx_buf+8], eax
    mov eax, [lfb_bpp]
    mov [tx_buf+12], eax
    mov edi, pxe_param             ; UDP_WRITE 16 bytes back
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [peer_ip]
    mov [pxe_param+2], eax          ; dest ip
    mov [pxe_param+6], eax          ; gw = dest (real-HW UNDI quirk)
    mov word [pxe_param+10], NET_PORT  ; src_port = our port
    mov ax, [peer_port]
    mov [pxe_param+12], ax          ; dst_port = sender's port
    mov word [pxe_param+14], 16     ; 4 dwords
    mov word [pxe_param+16], tx_buf
    mov word [pxe_param+18], 0
    mov ax, 0x0033                 ; PXENV_UDP_WRITE
    call pxe_call
    jmp .poll
img_hang:
    hlt
    jmp img_hang
img_nofb:
    ; no framebuffer: can't show anything (text console is gone); just park.
    hlt
    jmp img_nofb

; draw_test: full-screen gradient so a photo of the screen proves the mode,
; resolution and framebuffer layout are correct. Pixel = BGRX (32 bpp):
; blue = x, green = y, red = x+y.
draw_test:
    mov edi, [lfb_phys]            ; current scanline base
    xor ebx, ebx                   ; y
.row:
    push edi
    xor edx, edx                   ; x
.col:
    mov al, dl                     ; B = low bits of x
    mov [edi], al
    mov al, bl                     ; G = low bits of y
    mov [edi+1], al
    mov al, dl
    add al, bl                     ; R = x + y
    mov [edi+2], al
    mov byte [edi+3], 0            ; X (unused)
    add edi, 4
    inc edx
    cmp edx, [lfb_w]
    jb  .col
    pop edi
    add edi, [lfb_pitch]           ; next scanline
    inc ebx
    cmp ebx, [lfb_h]
    jb  .row
    ret
%endif

; ================= GDT (flat) =================
align 8
gdt_start:
    dq 0x0000000000000000
gdt_code:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xCF
    db 0x00
gdt_data:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF
    db 0x00
gdt_code16:                     ; 0x18: 16-bit code, base 0, limit 64K (for PM->RM)
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0x00
    db 0x00
gdt_data16:                     ; 0x20: 16-bit data, base 0, limit 64K
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0x00
    db 0x00
gdt_end:
gdt_desc:
    dw gdt_end - gdt_start - 1
    dd gdt_start
real_idt:                       ; real-mode IVT pseudo-descriptor (base 0, 1K)
    dw 0x03FF
    dd 0x00000000

; ================= data =================
banner    db 13,10,"PM32 ok - AgentZero v1 ring0 32-bit [MATRIX]. '?' for commands.",13,10,0
prompt    db "agent> ",0
s_unknown db " ?",13,10,0
s_help    db "C=cpuid-vendor F=cpuid-leaf1 I<4hex>=inb T=rtc M<8hex><2hex>=mem "
          db "P<bb><dd><f><oo>=pci O<pppp><vv>!=outb(gated) "
          db "W<aaaaaaaa><dddddddd>!=mem/mmio-dword(gated) "
          db "A<op><aaaaaaaa><bbbbbbbb>=alu L<addr><raw>=load E<tttt>=fourier "
          db "nI/nM<m>/nS<kkkk>=worm-brain(udp) ?=help",13,10,0
s_wok     db "write ok",13,10,0
s_wabort  db "write aborted (need '!')",13,10,0
s_pcihdr  db "== PCI scan  bus:dev.fn  vendor:device  class ==",13,10,0
s_pxe     db "PXE net-boot: API RMEntry=",0
s_halt    db "-- DEBUG HALT (PXE calls done) --",13,10,0
pci_bus   db 0
pxe_present db 0
pxe_op    dw 0
pxe_ax    dw 0
pm_esp    dd 0
rmentry   dd 0                     ; PXE real-mode API entry (off|seg<<16)
our_ip    dd 0                     ; our station IP (from cached DHCP yiaddr)
net_mode  db 0                     ; 1 = capture out_putc into tx_buf (UDP reply)
rain_on   db 1                     ; 1 = ambient rain in net_loop; 0 = clean display
peer_ip   dd 0                     ; last command sender's IP
peer_port dw 0                     ; last command sender's UDP port
tx_len    dw 0
align 4
blk_row   dd 0                     ; current row for B (block) writes
blk_pres  db 1                     ; 1 = repaint after this block (B), 0 = defer (b)
cur_attr  db VGA_ATTR              ; attribute vga_putc writes (block ctrl bytes change it)
attr_tab  db VGA_ATTR, 0x02, 0x0A, 0x0F   ; ctrl byte 0(unused)/1 dim/2 bright/3 white
gray_ramp db " .:-=+*#%@"              ; g command: brightness -> char (same ramp as ascii_art.py)
gray_attr db 0x02,0x02,0x02,0x02,0x0A,0x0A,0x0A,0x0F,0x0F,0x0F   ; dim / bright / white tiers
rx_buf    times 1536 db 0          ; received command packet (fits a full 1472-byte UDP read)
tx_buf    times 1536 db 0          ; reply payload (fits a 301-point Fourier reply, 1204B)
kbd_len   dd 0
kbd_buf   times 128 db 0           ; typed line (the user's question)
shift_state db 0                   ; 1 while a Shift key is held
kbd_e0      db 0                   ; kbd_track: E0 prefix seen, next byte is extended
kbd_f0      db 0                   ; kbd_track: F0 prefix seen, next byte is a release
kbd_last_status db 0               ; kbd_drain: last 8042 status byte (diagnostics)
kbd_last_sc db 0                   ; kbd_drain: last raw scancode byte (diagnostics)
align 4
kbd_byte_count dd 0                ; kbd_drain: total scancode bytes seen
key_state   times 256 db 0         ; 1 = key held. [code] set-1 make code, [0x80|code] E0 keys
s_keys      db "keys:",0
align 2
scancode_map:                      ; PS/2 set-1 make code -> ASCII, German QWERTZ
    db 0, 0                                               ; 00 esc
    db '1','2','3','4','5','6','7','8','9','0','-','='     ; 02-0D (unshifted digits same)
    db 8                                                  ; 0E backspace
    db 0                                                  ; 0F tab
    db 'q','w','e','r','t','z','u','i','o','p','[',']'     ; 10-1B (0x15 Y-pos -> 'z')
    db 13                                                 ; 1C enter
    db 0                                                  ; 1D lctrl
    db 'a','s','d','f','g','h','j','k','l',';',39          ; 1E-28
    db '`'                                                ; 29
    db 0                                                  ; 2A lshift
    db 92                                                 ; 2B backslash
    db 'y','x','c','v','b','n','m',',','.','-'             ; 2C-35 (0x2C Z-pos -> 'y', 0x35 -> '-')
    db 0, 0, 0                                             ; 36-38 rshift/kp*/lalt
    db ' '                                                ; 39 space
    times 128-($-scancode_map) db 0
align 2
scancode_shift:                    ; Shift held: uppercase + German-position symbols
    db 0, 0                                               ; 00 esc
    db '!','"','#','$','%','&','/','(',')','=','?','`'     ; 02-0D (7->'/', ss->'?')
    db 8                                                  ; 0E backspace
    db 0                                                  ; 0F tab
    db 'Q','W','E','R','T','Z','U','I','O','P',0,'*'       ; 10-1B
    db 13                                                 ; 1C enter
    db 0                                                  ; 1D lctrl
    db 'A','S','D','F','G','H','J','K','L',':','"'         ; 1E-28 (;->':')
    db 0                                                  ; 29
    db 0                                                  ; 2A lshift
    db 39                                                 ; 2B  (#->apostrophe)
    db 'Y','X','C','V','B','N','M',';',':','_'             ; 2C-35 (,->';' .->':' -->'_')
    db 0, 0, 0                                             ; 36-38
    db ' '                                                ; 39 space
    times 128-($-scancode_shift) db 0
align 4
; ---- VBE / framebuffer state (filled by vbe_setup in real mode) ----
vbe_ok      db 0                   ; 1 = graphics mode set and params valid
align 4
lfb_phys    dd 0                   ; framebuffer physical base address
lfb_pitch   dd 0                   ; bytes per scanline
lfb_bpp     dd 0                   ; bits per pixel (32)
lfb_w       dd 0                   ; width in pixels
lfb_h       dd 0                   ; height in pixels
fb_size     dd 0                   ; framebuffer byte size = pitch * height
pix_len     dd 0                   ; pixel byte count of the current G packet
z_end       dd 0                   ; end pointer of the current Z (RLE) run stream
gfx_mode    db 0                   ; 1 = a full-screen image is shown (text hidden)
need_present db 0                  ; 1 = text buffer changed, repaint the console next poll
kbd_seq     db 0                   ; per-keypress sequence (for dedup of redundant key sends)
align 4
saved_int10 dd 0                   ; BIOS INT 10h vector saved at boot (offset:segment)
; ---- graphics text console state ----
X0          dd 0                   ; pixel origin of the 80xSCR_ROWS text block (centred)
Y0          dd 0
g_fg        dd 0                   ; draw_glyph scratch
g_px0       dd 0
g_py0       dd 0
g_fontp     dd 0
g_gy        dd 0
font_buf    times 2048 db 0        ; 8x8 ROM font (256 glyphs x 8 bytes)
vmode_off   dw 0                   ; VideoModePtr offset
vmode_seg   dw 0                   ; VideoModePtr segment
want_w      dw 0                   ; mode-scan target width (0 = any)
want_h      dw 0                   ; mode-scan target height
found_mode  dw 0xFFFF              ; matched VBE mode number (0xFFFF = none)
align 4
pxe_param times 128 db 0           ; PXE API parameter struct buffer (seg 0)
s_udpopen db "UDP_OPEN ax=",0
s_status  db " status=",0
pci_dev   db 0
pci_func  db 0
vbuf      times 16 db 0
tmp_port  dd 0
tmp_val   dd 0
tmp_addr  dd 0                     ; W command: target linear/physical address
tmp_dw    dd 0                     ; W command: dword value to write
alu_op    dd 0                     ; A command: operation char
alu_a     dd 0                     ; A command: operand a
alu_b     dd 0                     ; A command: operand b
epi_t     dd 0                     ; E command: time step
epi_n     dd 0                     ; E command: epicycle count
epi_cx    dd 0                     ; E command: centre X (pixels)
epi_cy    dd 0                     ; E command: centre Y (pixels)
epi_xacc  dd 0                     ; E command: X accumulator (Q14 pixels)
epi_yacc  dd 0                     ; E command: Y accumulator (Q14 pixels)
parse_ptr dd 0
vga_pos   dd 0
rseed     dw 0xACE1                 ; real-mode animation PRNG seed
adv_flag  db 0                      ; 0 = advance rain drops this frame
frames16  dw 0
rows16    dw 25
col25     times 80 dw 0              ; per-column rain head rows (80x25 intro)
rng_state dd 0
frame_ctr dd 0
col_head  times 80 dd 0
col_speed times 80 dd 0
col_tick  times 80 dd 0
col_tail  times 80 dd 0
col_prev  times 80 dd 0
com1_present db 0
line_buf  times 128 db 0
align 2
vbe_info      times 512 db 0        ; VBE controller info block (AX=4F00)
vbe_modeinfo  times 256 db 0        ; VBE mode info block (AX=4F01)

%ifdef NIC_NATIVE
BITS 32
%include "net_native.asm"           ; device-agnostic ARP/IP/UDP stack (fast path)
%ifdef NIC_AR8131
%include "net_dev_ar8131.asm"       ; real metal: Atheros AR8131 (old Asus)
%else
%include "net_dev_e1000.asm"        ; QEMU: Intel e1000
%endif
%endif
%include "face_data.inc"            ; Dario portrait baked into the kernel
BITS 32
%ifdef HAVE_BRAIN
%include "brain.asm"                ; C. elegans brain primitive (SSE2 LIF step)
%endif
%ifdef ARCADE
%include "arcade.asm"               ; game console: PS/2 input + frame loop + Pong + Fight
%endif
%ifdef WORM
%include "worm.asm"                 ; petri dish: body, food, raster, HUD (uses brain.asm)
%include "worm/data/brain.inc"      ; the connectome image (worm/connectome.py)
%endif

    times (STAGE2_SECTORS*512)-($-$$) db 0
