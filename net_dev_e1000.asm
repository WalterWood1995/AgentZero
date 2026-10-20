; net_dev_e1000.asm - Intel e1000 device layer for net_native.asm (QEMU target).
; Provides dev_init / dev_send / dev_rx_get over MMIO + DMA descriptor rings.
E_CTRL   equ 0x0000
E_TCTL   equ 0x0400
E_TIPG   equ 0x0410
E_RCTL   equ 0x0100
E_TDBAL  equ 0x3800
E_TDBAH  equ 0x3804
E_TDLEN  equ 0x3808
E_TDH    equ 0x3810
E_TDT    equ 0x3818
E_RDBAL  equ 0x2800
E_RDBAH  equ 0x2804
E_RDLEN  equ 0x2808
E_RDH    equ 0x2810
E_RDT    equ 0x2818
E_RAL0   equ 0x5400
E_RAH0   equ 0x5404
E_TXRING equ 0x00090000
E_RXRING equ 0x00092000
E_RXBUFS equ 0x00200000
E_RXCNT  equ 16

dev_init:
    call e_pci_find
    mov byte [e_pci_off], 0x04         ; bus master + memory space
    call e_pci_read
    or  eax, 0x0006
    mov byte [e_pci_off], 0x04
    call e_pci_write
    mov ebx, E_RAL0                    ; cache MAC -> nn_mac
    call e_mmio_rd
    mov [nn_mac], eax
    mov ebx, E_RAH0
    call e_mmio_rd
    mov [nn_mac + 4], ax
    ; reset
    mov ebx, E_CTRL
    call e_mmio_rd
    or  eax, (1 << 26)
    call e_mmio_wr
    mov ecx, 0x00400000
.w: dec ecx
    jnz .w
    mov ebx, E_CTRL
    mov eax, (1 << 6) | (1 << 5)
    call e_mmio_wr
    ; TX ring
    mov edi, E_TXRING
    mov ecx, 128 / 4
    xor eax, eax
    rep stosd
    mov ebx, E_TDBAL
    mov eax, E_TXRING
    call e_mmio_wr
    mov ebx, E_TDBAH
    xor eax, eax
    call e_mmio_wr
    mov ebx, E_TDLEN
    mov eax, 128
    call e_mmio_wr
    mov ebx, E_TDH
    xor eax, eax
    call e_mmio_wr
    mov ebx, E_TDT
    xor eax, eax
    call e_mmio_wr
    mov ebx, E_TIPG
    mov eax, 0x0060200A
    call e_mmio_wr
    mov ebx, E_TCTL
    mov eax, (1 << 1) | (1 << 3) | (0x0F << 4) | (0x3F << 12)
    call e_mmio_wr
    ; RX ring
    mov edi, E_RXRING
    xor ecx, ecx
.rinit:
    mov eax, E_RXBUFS
    mov edx, ecx
    shl edx, 11
    add eax, edx
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], 0
    add edi, 16
    inc ecx
    cmp ecx, E_RXCNT
    jb  .rinit
    mov ebx, E_RDBAL
    mov eax, E_RXRING
    call e_mmio_wr
    mov ebx, E_RDBAH
    xor eax, eax
    call e_mmio_wr
    mov ebx, E_RDLEN
    mov eax, E_RXCNT * 16
    call e_mmio_wr
    mov ebx, E_RDH
    xor eax, eax
    call e_mmio_wr
    mov ebx, E_RDT
    mov eax, E_RXCNT - 1
    call e_mmio_wr
    mov word [e_rxtail], 0
    mov ebx, E_RCTL
    mov eax, (1 << 1) | (1 << 15) | (1 << 26)   ; EN | BAM | SECRC (2048-byte buffers)
    call e_mmio_wr
    ret

dev_send:                              ; EAX = frame length in NN_TXBUF
    mov [e_txlen], eax
    mov dword [E_TXRING + 0], NN_TXBUF
    mov dword [E_TXRING + 4], 0
    mov ax, [e_txlen]
    mov word  [E_TXRING + 8], ax
    mov byte  [E_TXRING + 10], 0
    mov byte  [E_TXRING + 11], 0x0B    ; EOP|IFCS|RS
    mov word  [E_TXRING + 12], 0
    mov word  [E_TXRING + 14], 0
    mov ebx, E_TDT
    mov eax, 1
    call e_mmio_wr
    mov ecx, 0x00200000
.p: mov al, [E_TXRING + 12]
    test al, 1
    jnz .done
    dec ecx
    jnz .p
.done:
    mov ebx, E_TDT
    xor eax, eax
    call e_mmio_wr
    mov ebx, E_TDH
    xor eax, eax
    call e_mmio_wr
    ret

dev_rx_get:                            ; -> CF=0 with nn_frame/nn_flen set, or CF=1
    movzx esi, word [e_rxtail]
    mov edx, esi
    shl edx, 4
    add edx, E_RXRING
    test byte [edx + 12], 1            ; DD?
    jz  .none
    movzx ecx, word [edx + 8]
    mov eax, [edx]
    mov [nn_frame], eax
    mov [nn_flen], ecx
    mov byte [edx + 12], 0
    mov eax, esi
    mov ebx, E_RDT
    call e_mmio_wr
    movzx esi, word [e_rxtail]
    inc esi
    cmp esi, E_RXCNT
    jb  .adv
    xor esi, esi
.adv:
    mov [e_rxtail], si
    clc
    ret
.none:
    stc
    ret

e_mmio_wr:
    push edx
    mov edx, [e_mmio]
    add edx, ebx
    mov [edx], eax
    pop edx
    ret
e_mmio_rd:
    push edx
    mov edx, [e_mmio]
    add edx, ebx
    mov eax, [edx]
    pop edx
    ret
e_pci_addr:
    movzx ebx, byte [e_pci_bus]
    shl ebx, 16
    movzx edx, byte [e_pci_dev]
    and edx, 0x1F
    shl edx, 11
    or  ebx, edx
    movzx edx, byte [e_pci_off]
    and edx, 0xFC
    or  ebx, edx
    or  ebx, 0x80000000
    mov eax, ebx
    ret
e_pci_read:
    push ebx
    push edx
    call e_pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    pop edx
    pop ebx
    ret
e_pci_write:
    push eax
    push ebx
    push edx
    mov [e_pci_val], eax
    call e_pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov eax, [e_pci_val]
    mov dx, 0xCFC
    out dx, eax
    pop edx
    pop ebx
    pop eax
    ret
e_pci_find:
    mov byte [e_pci_bus], 0
    xor ecx, ecx
.next:
    mov [e_pci_dev], cl
    mov byte [e_pci_off], 0x00
    call e_pci_read
    cmp ax, 0x8086
    jne .skip
    shr eax, 16
    cmp ax, 0x100E
    je  .found
.skip:
    inc ecx
    cmp ecx, 32
    jb  .next
    stc
    ret
.found:
    mov byte [e_pci_off], 0x10
    call e_pci_read
    and eax, 0xFFFFFFF0
    mov [e_mmio], eax
    ret

e_mmio    dd 0
e_rxtail  dw 0
e_txlen   dd 0
e_pci_bus db 0
e_pci_dev db 0
e_pci_off db 0
e_pci_val dd 0
