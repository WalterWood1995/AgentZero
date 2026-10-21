; pxe_stage1.asm - PXE network-boot loader for the AgentZero.
; A PXE boot ROM downloads the whole NBP file (this stub + stage2 appended) over
; TFTP to 0x0000:0x7C00 and jumps there in 16-bit real mode. There is no disk,
; so instead of INT 13h we relocate the appended stage2 image (which sits right
; after us at 0x7E00) up to 0x8000 - the address stage2 is assembled for (ORG
; 0x8000) - then jump to it. Lets the exact same stage2.bin boot from USB or PXE.
;
; The copy is DESTINATION-OVERLAPPING (src 0x7E00, dst 0x8000, len 8 KiB), so we
; copy backwards (high to low) to avoid clobbering source bytes before reading.
;
; Build: nasm -f bin pxe_stage1.asm -o pxe_stage1.bin
;        cat pxe_stage1.bin stage2.bin > pxe.img   (serve pxe.img over TFTP)

BITS 16
ORG 0x7C00

%ifdef NIC_NATIVE
STAGE2_BYTES equ 42 * 512           ; native build: larger stage2 (e1000/AR8131 driver + IP/UDP)
%elifdef ARCADE
STAGE2_BYTES equ 48 * 512           ; arcade build: + game console
%elifdef WORM
STAGE2_BYTES equ 80 * 512           ; worm build: + petri dish + brain image
%else
STAGE2_BYTES equ 40 * 512           ; stage2 is padded to 40 sectors (must match stage1/stage2)
%endif

; Scratch block at physical 0x5000 (free low memory) hands the PXE entry info to
; stage2 after it switches to protected mode:
;   0x5000 RMEntry offset   0x5002 RMEntry segment  (real-mode PXE API entry)
;   0x5004 PXENV+ offset     0x5006 PXENV+ segment
;   0x5008 magic 0x5850 'PX' => network-booted, PXE API available
start:
    cli
    ; PXE NBP entry: ES:BX -> PXENV+, CS:IP = 0:7C00. Capture the real-mode API
    ; entry point (PXENV+.RMEntry at offset 0x0A) BEFORE we clobber ES.
    mov ax, [es:bx+0x0A]            ; RMEntry offset
    mov cx, [es:bx+0x0C]            ; RMEntry segment
    mov dx, es                      ; PXENV+ segment
    xor di, di
    mov ds, di                      ; DS = 0 for the scratch block
    mov word [0x5000], ax
    mov word [0x5002], cx
    mov word [0x5004], bx
    mov word [0x5006], dx
    mov word [0x5008], 0x5850       ; magic: PXE-booted

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    cld

    ; backward copy stage2: 0x7E00 -> 0x8000, STAGE2_BYTES bytes (word at a time).
    ; Source/destination are addressed through their own segments (0x07E0 / 0x0800)
    ; so a stage2 larger than 32 KiB (offsets past 0xFFFF) still copies correctly.
    mov ax, 0x07E0
    mov ds, ax
    mov ax, 0x0800
    mov es, ax
    std
    mov si, STAGE2_BYTES - 2
    mov di, STAGE2_BYTES - 2
    mov cx, STAGE2_BYTES / 2
    rep movsw
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax

    jmp 0x0000:0x8000

    times 512-($-$$) db 0           ; pad stub to exactly one sector
