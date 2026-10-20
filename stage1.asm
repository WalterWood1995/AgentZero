; stage1.asm - AgentZero boot sector / loader.
; BIOS loads this 512-byte sector at 0x7C00. It loads stage2 (the serial+VGA
; REPL / PCI self-scan) from the following disk sectors into 0x0000:0x8000 and
; jumps to it. Uses INT 13h AH=42h (LBA extended read) first - far more reliable
; for USB sticks and hard disks on real hardware - and falls back to the classic
; AH=02h CHS read if extensions are unavailable (e.g. legacy floppy emulation).
;
; Build: nasm -f bin stage1.asm -o stage1.bin

BITS 16
ORG 0x7C00

STAGE2_SEG equ 0x0000
STAGE2_OFF equ 0x8000
STAGE2_SECTORS equ 34          ; read 32 sectors (16 KiB) of stage2 (face data + VBE)
STAGE2_LBA equ 1               ; stage2 starts right after this boot sector

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [drive], dl            ; BIOS passes boot drive in DL

    ; --- try INT 13h AH=42h extended (LBA) read ---
    mov ah, 0x41               ; check extensions present
    mov bx, 0x55AA
    mov dl, [drive]
    int 0x13
    jc  .chs                   ; no extensions -> CHS
    cmp bx, 0xAA55
    jne .chs

    mov si, dap
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    jnc stage2_ok
    ; fall through to CHS on error

.chs:
    ; CHS = cyl0, head0, sector2 (1-based), AL sectors.
    mov ah, 0x02
    mov al, STAGE2_SECTORS
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [drive]
    mov bx, STAGE2_OFF         ; ES:BX = 0x0000:0x8000
    int 0x13
    jc  disk_err

stage2_ok:
    jmp STAGE2_SEG:STAGE2_OFF

disk_err:
    mov si, err
.p:
    lodsb
    test al, al
    jz .h
    mov ah, 0x0E
    int 0x10
    jmp .p
.h:
    cli
    hlt
    jmp .h

; Disk Address Packet for the LBA extended read.
align 4
dap:
    db 0x10                    ; packet size
    db 0                       ; reserved
    dw STAGE2_SECTORS          ; sectors to transfer
    dw STAGE2_OFF              ; buffer offset
    dw STAGE2_SEG              ; buffer segment
    dq STAGE2_LBA              ; starting LBA

err   db "stage1: disk read error", 0
drive db 0

    times 510-($-$$) db 0
    dw 0xAA55
