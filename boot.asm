; boot.asm - AgentZero v0, milestone 1: "hello from bare metal"
; A 512-byte BIOS boot sector. On power-up the BIOS loads this at 0x7C00 in
; 16-bit real mode and jumps here. We do two things that matter for the Agent:
;   1) print a banner to the screen via BIOS int 10h (so a human/camera sees it)
;   2) init the 16550 UART (COM1) and write the banner to serial, because serial
;      is the Agent's headless control channel (QEMU: -serial stdio; real box: COM1).
; Then halt. No disk, no protected mode yet - that comes in milestone 2.
;
; Build:  nasm -f bin boot.asm -o boot.img
; Run  :  qemu-system-i386 -drive format=raw,file=boot.img -serial stdio -display none

BITS 16
ORG 0x7C00

COM1 equ 0x3F8                 ; COM1 base I/O port

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00             ; stack just below us
    sti

    ; --- screen banner via BIOS teletype ---
    mov si, msg
.print_screen:
    lodsb
    test al, al
    jz .init_serial
    mov ah, 0x0E              ; int 10h teletype
    mov bh, 0
    int 0x10
    jmp .print_screen

.init_serial:
    ; --- 16550 UART init: 115200 8N1, FIFO on ---
    mov dx, COM1 + 1          ; IER
    mov al, 0x00
    out dx, al               ; disable interrupts
    mov dx, COM1 + 3          ; LCR
    mov al, 0x80
    out dx, al               ; DLAB=1 (set baud divisor)
    mov dx, COM1 + 0          ; DLL
    mov al, 0x01
    out dx, al               ; divisor low  = 1 -> 115200
    mov dx, COM1 + 1          ; DLM
    mov al, 0x00
    out dx, al               ; divisor high = 0
    mov dx, COM1 + 3          ; LCR
    mov al, 0x03
    out dx, al               ; DLAB=0, 8 bits, no parity, 1 stop
    mov dx, COM1 + 2          ; FCR
    mov al, 0xC7
    out dx, al               ; enable+clear FIFOs, 14-byte threshold
    mov dx, COM1 + 4          ; MCR
    mov al, 0x0B
    out dx, al               ; DTR, RTS, OUT2

    ; --- write banner to serial ---
    mov si, msg
.print_serial:
    lodsb
    test al, al
    jz .halt
    call serial_putc
    jmp .print_serial

.halt:
    cli
.hang:
    hlt
    jmp .hang

; serial_putc: wait for THR empty (LSR bit5), then write AL
serial_putc:
    push ax
    push dx
    mov ah, al               ; save char
.wait:
    mov dx, COM1 + 5          ; LSR
    in al, dx
    test al, 0x20            ; THR empty?
    jz .wait
    mov dx, COM1 + 0          ; THR
    mov al, ah
    out dx, al
    pop dx
    pop ax
    ret

msg db "AgentZero v0 - alive on bare metal (screen + COM1)", 13, 10, 0

    times 510-($-$$) db 0    ; pad to 510 bytes
    dw 0xAA55                ; boot signature
