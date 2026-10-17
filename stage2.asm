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
;   ?                        -> list commands
;
; Build: nasm -f bin stage2.asm -o stage2.bin

BITS 16
ORG 0x8000

COM1 equ 0x3F8
CODE_SEL equ 0x08
DATA_SEL equ 0x10
VGA      equ 0xB8000
VGA_ATTR equ 0x0A                  ; black background, bright green foreground
RAIN_FRAMES equ 170                ; how many animation frames the intro runs
FRAME_COUNTS equ 29800             ; PIT ch0 counts per frame (~25 ms, CPU-independent)

; ================= 16-bit real mode: set up and switch =================
stage2:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    call uart_init16

    in  al, 0x92                   ; enable A20 via the fast gate
    or  al, 2
    out 0x92, al

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

    call pit_init                  ; free-running PIT ch0 timebase (QEMU==real HW)
    call uart_detect               ; is COM1 real? (K50IJ has no serial port)
    call vga_clear                 ; black screen, green attribute
    call rain_intro                ; Matrix-style binary rain opener
    call vga_clear
    call pci_scan                  ; autodetect + list PCI hardware on screen
    mov esi, banner
    call out_puts

    ; if network-booted, pxe_stage1 left the PXE real-mode API entry at 0x5000
    cmp word [0x5008], 0x5850
    jne .no_pxe
    mov byte [pxe_present], 1
    mov eax, [0x5000]              ; RMEntry (off|seg<<16) -> our variable
    mov [rmentry], eax
    mov esi, s_pxe
    call out_puts
    movzx eax, word [0x5002]       ; RMEntry segment
    call print_hex16
    mov al, ':'
    call out_putc
    movzx eax, word [0x5000]       ; RMEntry offset
    call print_hex16
    call nl

    ; --- first PXE call: UDP_OPEN (proves the PM<->real-mode trampoline) ---
    mov edi, pxe_param             ; zero the param struct
    xor eax, eax
    mov ecx, 32
    rep stosd
    ; GET_CACHED_INFO (0x0071) PacketType=2 (DHCP ACK) -> our IP (yiaddr)
    mov word [pxe_param+2], 2
    mov ax, 0x0071
    call pxe_call
    ; Buffer far ptr at pxe_param+6 (off) / +8 (seg) -> DHCP packet; yiaddr @ +16
    movzx eax, word [pxe_param+8]
    shl eax, 4
    movzx ecx, word [pxe_param+6]
    add eax, ecx
    mov edx, [eax+16]              ; yiaddr = our IP
    mov [our_ip], edx
    mov al, 'I'
    call out_putc
    mov al, '='
    call out_putc
    mov eax, edx                  ; print IP as 8 hex (network-order bytes)
    call print_hex32
    call nl

    ; UDP_OPEN (0x0030) with our real src_ip -> expect SUCCESS
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+2], eax         ; src_ip
    mov ax, 0x0030
    call pxe_call
    mov al, 'O'
    call out_putc
    mov al, '='
    call out_putc
    movzx eax, word [pxe_ax]
    call print_hex16
    mov al, '/'
    call out_putc
    movzx eax, word [pxe_param]
    call print_hex16
    call nl
.no_pxe:

    call rain_bg_init              ; arm the ambient terminal rain

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
    cmp al, '?'
    je  do_help
    mov esi, s_unknown
    call out_puts
exec_done:
    ret

; net_loop: Agent-over-UDP command channel (network-booted machine, no serial).
; UDP socket already opened at boot. Poll UDP_READ; on a command packet, run it
; with output captured to tx_buf, then UDP_WRITE the reply back to the sender.
NET_PORT equ 0x50C3                ; UDP port 50000, network byte order
net_loop:
    mov byte [net_mode], 1
    call pit_init                  ; PXE may have reprogrammed the PIT
.poll:
    call rain_bg_step
    call pit_delay_frame
    ; UDP_READ
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+6], eax          ; dest_ip filter = our IP
    mov word [pxe_param+12], NET_PORT   ; d_port = our listening port
    mov word [pxe_param+14], 240        ; buffer_size (max)
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
    ; copy rx_buf -> line_buf up to CR/LF/limit, null-terminate
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
    ; run the command, output captured into tx_buf
    mov word [tx_len], 0
    call exec_line
    ; UDP_WRITE the reply back to the sender
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [peer_ip]
    mov [pxe_param+2], eax          ; dest ip
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
    cmp bx, 500
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

getc:                              ; -> AL. Animates the ambient rain while idle.
    push edx
.w:
    mov dx, COM1 + 5
    in  al, dx
    test al, 0x01
    jnz .have                      ; byte waiting -> read it now (no delay)
    call rain_bg_step              ; otherwise advance the terminal rain one frame
    call pit_delay_frame_or_serial ; pace it, but bail instantly on input
    jmp .w
.have:
    mov dx, COM1 + 0
    in  al, dx
    pop edx
    ret

; ---- VGA text buffer (0xB8000, 80x25), bright green on black ----
vga_clear:
    pushad
    mov edi, VGA
    mov ecx, 2000
    mov ax, (VGA_ATTR << 8) | ' '
.l:
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .l
    mov dword [vga_pos], 0
    popad
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
    mov ah, VGA_ATTR
    mov [ebx], ax                  ; al=char, ah=attr
    inc edi
    mov [vga_pos], edi
    cmp edi, 2000
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
    cmp eax, 2000
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
    mov ecx, 24 * 80
.c:
    mov ax, [esi]
    mov [edi], ax
    add esi, 2
    add edi, 2
    dec ecx
    jnz .c
    mov edi, VGA + 24 * 80 * 2
    mov ecx, 80
    mov ax, (VGA_ATTR << 8) | ' '
.cl:
    mov [edi], ax
    add edi, 2
    dec ecx
    jnz .cl
    mov dword [vga_pos], 24 * 80
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
    mov ebx, 25
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
    cmp edx, 25                    ; whole trail off the bottom -> respawn on top
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
    cmp eax, 25
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
    cmp eax, 25
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
    mov ebx, 25
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
    cmp eax, 25
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
    cmp eax, 25
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
    cmp eax, 25
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
          db "P<bb><dd><f><oo>=pci O<pppp><vv>!=outb(gated) ?=help",13,10,0
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
peer_ip   dd 0                     ; last command sender's IP
peer_port dw 0                     ; last command sender's UDP port
tx_len    dw 0
align 4
rx_buf    times 256 db 0           ; received command packet
tx_buf    times 512 db 0           ; reply payload
align 4
pxe_param times 128 db 0           ; PXE API parameter struct buffer (seg 0)
s_udpopen db "UDP_OPEN ax=",0
s_status  db " status=",0
pci_dev   db 0
pci_func  db 0
vbuf      times 16 db 0
tmp_port  dd 0
tmp_val   dd 0
parse_ptr dd 0
vga_pos   dd 0
rng_state dd 0
frame_ctr dd 0
col_head  times 80 dd 0
col_speed times 80 dd 0
col_tick  times 80 dd 0
col_tail  times 80 dd 0
col_prev  times 80 dd 0
com1_present db 0
line_buf  times 128 db 0

    times (16*512)-($-$$) db 0
