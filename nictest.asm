; nictest.asm - standalone test host for net_native.asm (the native e1000 driver).
; Boots via pxe_stage1 (0x8000, real mode) -> protected mode, brings up the NIC with
; nn_init, then echoes any UDP datagram it receives on port 50000 (proves native
; RX/ARP/IP/UDP end to end; test with a hostfwd UDP round-trip in QEMU).
;
; Build: nasm -f bin nictest.asm -o nictest.bin
;        cat pxe_stage1.bin nictest.bin > pxe_nictest.img
BITS 16
ORG 0x8000
CODE_SEL equ 0x08
DATA_SEL equ 0x10
STAGE2_SECTORS equ 34

stage2:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    in  al, 0x92
    or  al, 2
    out 0x92, al
    lgdt [gdt_desc]
    mov eax, cr0
    or  eax, 1
    mov cr0, eax
    jmp CODE_SEL:pm_entry

BITS 32
pm_entry:
    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x7000
    mov byte [0xB8000], 'N'
    mov byte [0xB8001], 0x0A
    ; our IP = 10.0.2.15 (QEMU SLIRP guest)
    mov byte [nn_ip + 0], 10
    mov byte [nn_ip + 1], 0
    mov byte [nn_ip + 2], 2
    mov byte [nn_ip + 3], 15
    call nn_init
    mov byte [0xB8002], 'R'
    mov byte [0xB8003], 0x0A
.loop:
    call nn_poll_cmd
    test ax, ax
    jnz .loop
    ; got a command (ECX bytes in rx_buf): echo it back
    mov [tx_len], cx
    mov esi, rx_buf
    mov edi, tx_buf
    rep movsb
    call nn_reply
    jmp .loop

%include "net_native.asm"
%include "net_dev_e1000.asm"

; ---- host-provided buffers the driver writes into ----
rx_buf    times 2048 db 0
tx_buf    times 2048 db 0
tx_len    dw 0
peer_ip   dd 0
peer_port dw 0

gdt_start:
    dq 0x0000000000000000
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xCF
    db 0x00
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF
    db 0x00
gdt_end:
gdt_desc:
    dw gdt_end - gdt_start - 1
    dd gdt_start

    times (STAGE2_SECTORS*512)-($-$$) db 0
