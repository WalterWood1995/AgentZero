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
SCR_ROWS equ 50                    ; 80x50 text mode (small 8x8 font, fine detail)
SCR_CELLS equ 80 * SCR_ROWS
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
    call pit_init16                ; PIT ch0 timebase for the opening animation

    ; ---- opening animation (real mode: int 10h mode switches are easy here) ----
    mov ax, 0x0003                 ; 80x25 big-char colour text
    int 0x10
    call anim_rain25               ; big-char binary rain (clear, not jumpy)
    mov ax, 0x1112                 ; load 8x8 font -> 80x50: chars shrink = zoom out
    xor bl, bl
    int 0x10
    call anim_condense             ; the rain condenses into the face

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
    ; UDP_OPEN (0x0030) bound to our IP
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+2], eax
    mov ax, 0x0030
    call pxe_call
.no_pxe:
    call show_face                 ; ensure the face is shown (condense already did)

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
NET_PORT equ 0x50C3                ; UDP port 50000, network byte order (our listen)
Q_PORT   equ 0x51C3                ; UDP port 50001, net order (dev-PC question port)
DEVPC_IP equ 0x71B2A8C0            ; 192.168.178.113, network-byte-order bytes
INPUT_ROW equ 48                   ; on-screen input line (left column)
net_loop:
    mov byte [net_mode], 1
    call pit_init                  ; PXE may have reprogrammed the PIT
    call kbd_init                  ; real HW: enable 8042 translation + scanning
    call draw_prompt               ; "> " on the input line
    ; --- one-time network self-test (needs no keyboard) ---
    ; auto-send "hello" to the dev PC so the UDP round-trip (send path + answer
    ; display) can be verified independently of the flaky physical keyboard.
    mov dword [kbd_buf], 'hell'
    mov byte  [kbd_buf+4], 'o'
    mov dword [kbd_len], 5
    call send_question
    call send_question
    mov dword [kbd_len], 0
.poll:
    ; drain the PS/2 keyboard fully this iteration (no overflow/beep on fast
    ; typing); each mapped key echoes, Enter sends the line over UDP
    call kbd_service
    ; Always tight-poll UDP_READ (no delay). On real hardware a polling gap drops
    ; incoming packets, so the Agent's bursts need continuous reading.
    ; UDP_READ
    mov edi, pxe_param
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov eax, [our_ip]
    mov [pxe_param+6], eax          ; dest_ip filter = our IP
    mov word [pxe_param+12], NET_PORT   ; d_port = our listening port
    mov word [pxe_param+14], 760        ; buffer_size (max)
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
    cmp ecx, 760
    jbe .lenok
    mov ecx, 760
.lenok:
    mov byte [rx_buf+ecx], 0       ; null-terminate the raw packet
    cmp byte [rx_buf], 'B'         ; block write (multi-line) parsed from rx_buf
    je  .do_block
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
    jmp .poll
.do_block:
    ; B<2hex startrow> then newline-separated lines -> write each at (row+i, 0).
    ; One packet carries many rows, so the whole face is ~3 packets not ~50.
    ; Idempotent (overwrites same cells), fire-and-forget (no ack).
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
    jz  .poll                      ; end of packet
    mov eax, [blk_row]
    imul eax, eax, 80
    mov [vga_pos], eax             ; cursor = row*80 (col 0)
.blk_wr:
    mov al, [esi]
    test al, al
    jz  .poll
    cmp al, 10
    je  .blk_eol
    call vga_putc
    inc esi
    jmp .blk_wr
.blk_eol:
    inc esi
    inc dword [blk_row]
    jmp .blk_line
.reply:
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
    mov edi, INPUT_ROW * 80 * 2 + 0xB8000
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
    mov ecx, 24                    ; bound the drain per iteration
.ks:
    in  al, 0x64
    mov edi, 0xB8000 + HUD_CELL     ; HUD: controller status at col 0
    call hud_byte
    test al, 1                     ; output buffer empty?
    jz  .ksret
    test al, 0x20                  ; aux (mouse) byte?
    jnz .ksaux
    in  al, 0x60                   ; scancode
    mov edi, 0xB8000 + HUD_CELL + 6 ; HUD: scancode at col 3
    call hud_byte
    cmp al, 0xE0                   ; extended-key prefix (arrows etc.)?
    je  .ksext
    test al, 0x80                  ; break (release) code?
    jnz .ksnext
    movzx eax, al
    mov al, [scancode_map + eax]
    test al, al                    ; unmapped key?
    jz  .ksnext
    call kbd_char                  ; echo / handle the character
.ksnext:
    dec ecx
    jnz .ks
.ksret:
    pop edx
    pop ecx
    ret
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
    in  al, 0x60                   ; discard the extended code
    jmp .ksnext

; kbd_char: handle a typed character in AL (echo on the input line; Enter sends).
kbd_char:
    pushad
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
    add edi, 0xB8000
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
    add edi, 0xB8000
    mov word [edi], 0x0A20         ; erase
    jmp .done
.enter:
    cmp dword [kbd_len], 0
    je  .done
    call send_question             ; UDP the line to the dev-PC agent service
    ; clear the input line
    mov edi, (INPUT_ROW * 80 + 2) * 2 + 0xB8000
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
    mov word [0xB8000 + HUD_CELL + 18], 0x0E57   ; 'W'
    mov word [0xB8000 + HUD_CELL + 20], 0x0E3D   ; '='
    mov al, [pxe_param+1]               ; status high byte
    mov edi, 0xB8000 + HUD_CELL + 22
    call hud_byte
    mov al, [pxe_param+0]               ; status low byte
    mov edi, 0xB8000 + HUD_CELL + 26
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
    mov ah, VGA_ATTR
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
rain_on   db 1                     ; 1 = ambient rain in net_loop; 0 = clean display
peer_ip   dd 0                     ; last command sender's IP
peer_port dw 0                     ; last command sender's UDP port
tx_len    dw 0
align 4
blk_row   dd 0                     ; current row for B (block) writes
rx_buf    times 768 db 0           ; received command packet
tx_buf    times 512 db 0           ; reply payload
kbd_len   dd 0
kbd_buf   times 128 db 0           ; typed line (the user's question)
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

%include "face_data.inc"            ; Dario portrait baked into the kernel

    times (24*512)-($-$$) db 0
