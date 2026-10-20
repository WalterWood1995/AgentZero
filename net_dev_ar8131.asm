; net_dev_ar8131.asm - Atheros AR8131 (1969:1026) device layer for net_native.asm.
; The old Asus's NIC. Provides dev_init / dev_send / dev_rx_get. Register map and
; descriptor formats from the Linux atl1c driver (atl1c_hw.h / atl1c.h).
;
; STRATEGY (first cut): the PXE firmware already reset the chip, brought the PHY/link
; up and set DMA/speed, so we do a MINIMAL TAKEOVER - stop the queues, repoint the
; descriptor rings at ours, re-enable - instead of a full reset + PHY bring-up (which
; needs several constants not in the public header). If this proves unreliable the
; fallback is a full atl1c-style reset.
;
; Rings (TPD=TX, RFD=RX free buffers, RRD=RX return/completion):
AR_TPD    equ 0x00090000           ; 64 x 16B transmit packet descriptors
AR_RFD    equ 0x00090400           ; 64 x 8B receive free descriptors
AR_RRD    equ 0x00090600           ; 64 x 16B receive return descriptors
AR_RXBUFS equ 0x00200000           ; 64 x 2048B receive buffers
AR_CNT    equ 64

; registers (atl1c)
R_MASTER  equ 0x1400
R_LOADPTR equ 0x1534
R_RXBASEHI equ 0x1540
R_TXBASEHI equ 0x1544
R_RFD_LO  equ 0x1550
R_RFD_SZ  equ 0x1560
R_RXBUFSZ equ 0x1564
R_RRD_LO  equ 0x1568
R_RRD_SZ  equ 0x1578
R_MACCTRL equ 0x1480
R_MACADDR equ 0x1488
R_TPD_LO  equ 0x1580
R_TPD_SZ  equ 0x1584
R_TXQ     equ 0x1590
R_RXQ     equ 0x15A0
R_RFD_PIDX equ 0x15E0            ; 16-bit RFD producer index mailbox
R_TPD_PIDX equ 0x15F2            ; 16-bit TPD producer index
R_TPD_CIDX equ 0x15F6            ; 16-bit TPD consumer index
R_IMR     equ 0x1604
R_ISR     equ 0x1600
R_DMACTRL equ 0x15C0
R_MASTER_SOFT_RST equ 0x1

dev_init:
    call ar_pci_find                 ; 1969:1026 -> ar_mmio, enable bus master
    ; ---- MAC address (atl1c layout) ----
    mov ebx, R_MACADDR               ; d0 = mac[2..5]
    call ar_rd32
    mov [ar_macraw], eax
    mov ebx, R_MACADDR + 4           ; d1 = mac[0..1]
    call ar_rd32
    mov [ar_macraw + 4], eax
    mov eax, [ar_macraw + 4]
    mov [nn_mac + 0], ah             ; mac0 = d1>>8
    mov [nn_mac + 1], al             ; mac1 = d1
    mov eax, [ar_macraw]
    bswap eax                        ; eax = mac2 mac3 mac4 mac5 (now in byte order)
    mov [nn_mac + 2], eax            ; stores mac2..mac5
    ; ---- capture PXE's working config BEFORE reset (so we reuse its magic values) ----
    mov ebx, R_DMACTRL
    call ar_rd32
    mov [ar_dmactrl], eax
    mov ebx, R_TXQ
    call ar_rd32
    mov [ar_txqcfg], eax
    mov ebx, R_RXQ
    call ar_rd32
    mov [ar_rxqcfg], eax
    mov ebx, R_MACCTRL
    call ar_rd32
    mov [ar_macctrl], eax            ; keep PXE's speed/duplex bits
    ; ---- stop the engines ----
    mov eax, [ar_txqcfg]
    and eax, ~0x20
    mov ebx, R_TXQ
    call ar_wr32
    mov eax, [ar_rxqcfg]
    and eax, ~0x80000000
    mov ebx, R_RXQ
    call ar_wr32
    mov eax, [ar_macctrl]
    and eax, ~0x3
    mov ebx, R_MACCTRL
    call ar_wr32
    mov ecx, 0x00400000
.s0: dec ecx
    jnz .s0
%ifdef AR_RESET
    ; ---- soft reset MAC + DMA (OFF by default: it drops the PHY link and we don't
    ; re-init the PHY; minimal-takeover keeps PXE's live link/PHY/DMA instead) ----
    mov ebx, R_MASTER
    call ar_rd32
    mov edx, eax
    or  eax, 0x1                     ; MASTER_CTRL_SOFT_RST
    call ar_wr32
    mov ecx, 0x02000000
.s1: dec ecx
    jnz .s1
    mov eax, edx
    mov ebx, R_MASTER
    call ar_wr32
    mov ecx, 0x02000000
.s2: dec ecx
    jnz .s2
    mov eax, [ar_dmactrl]            ; restore DMA config after reset
    mov ebx, R_DMACTRL
    call ar_wr32
    movzx eax, byte [nn_mac + 2]     ; re-write MAC (reset cleared it)
    shl eax, 8
    mov al, [nn_mac + 3]
    shl eax, 8
    mov al, [nn_mac + 4]
    shl eax, 8
    mov al, [nn_mac + 5]
    mov ebx, R_MACADDR
    call ar_wr32
    movzx eax, byte [nn_mac + 0]
    shl eax, 8
    mov al, [nn_mac + 1]
    mov ebx, R_MACADDR + 4
    call ar_wr32
%endif
    ; ---- disable interrupts ----
    mov ebx, R_IMR
    xor eax, eax
    call ar_wr32
    mov ebx, R_ISR
    mov eax, 0xFFFFFFFF
    call ar_wr32
    ; ---- program our rings ----
    mov ebx, R_TXBASEHI
    xor eax, eax
    call ar_wr32
    mov ebx, R_TPD_LO
    mov eax, AR_TPD
    call ar_wr32
    mov ebx, R_TPD_SZ
    mov eax, AR_CNT
    call ar_wr32
    mov ebx, R_RXBASEHI
    xor eax, eax
    call ar_wr32
    mov ebx, R_RFD_LO
    mov eax, AR_RFD
    call ar_wr32
    mov ebx, R_RFD_SZ
    mov eax, AR_CNT
    call ar_wr32
    mov ebx, R_RXBUFSZ
    mov eax, 2048
    call ar_wr32
    mov ebx, R_RRD_LO
    mov eax, AR_RRD
    call ar_wr32
    mov ebx, R_RRD_SZ
    mov eax, AR_CNT
    call ar_wr32
    ; ---- fill RFD ring with buffer addresses ----
    mov edi, AR_RFD
    xor ecx, ecx
.rfill:
    mov eax, AR_RXBUFS
    mov edx, ecx
    shl edx, 11                      ; *2048
    add eax, edx
    mov [edi], eax
    mov dword [edi + 4], 0
    add edi, 8
    inc ecx
    cmp ecx, AR_CNT
    jb  .rfill
    ; ---- latch ring base/size ----
    mov ebx, R_LOADPTR
    mov eax, 1
    call ar_wr32
    ; ---- re-enable queues + MAC with the PROPER atl1c config (PXE's TXQ/RXQ regs
    ; read 0 / C0000000 because UNDI doesn't use the atl1c ring engine - restoring
    ; those left TX unconfigured, which is why the TX consumer never advanced) ----
    mov eax, 0x020000F5             ; L1C_TXQ_CFGV (0x020000D5) | TXQ_CTRL_EN (0x20)
    mov ebx, R_TXQ
    call ar_wr32
    mov eax, 0x80800000             ; RXQ_CTRL_EN (0x80000000) | rfd_burst 8<<20
    mov ebx, R_RXQ
    call ar_wr32
    mov eax, [ar_macctrl]
    or  eax, 0x3 | 0x40 | 0x80 | 0x4000000   ; TX_EN|RX_EN|ADD_CRC|PAD|BC_EN
    mov ebx, R_MACCTRL
    call ar_wr32
    mov ecx, 0x02000000              ; let the link/MAC settle after reset
.s3: dec ecx
    jnz .s3
    ; ---- hand all RX buffers to the NIC ----
    mov ebx, R_RFD_PIDX
    mov eax, AR_CNT - 1
    call ar_wr16
    mov word [ar_tpd_prod], 0
    mov word [ar_rrd_clean], 0
    mov word [ar_rfd_prod], AR_CNT - 1
    ret

dev_send:                            ; EAX = frame length in NN_TXBUF
    mov [ar_txlen], eax
    movzx edi, word [ar_tpd_prod]
    mov edx, edi
    shl edx, 4
    add edx, AR_TPD                  ; EDX -> TPD[prod]
    mov ax, [ar_txlen]
    mov [edx + 0], ax                ; buffer_len
    mov word [edx + 2], 0            ; vlan
    mov dword [edx + 4], 0x80000000  ; word1: EOP
    mov dword [edx + 8], NN_TXBUF    ; buffer_addr lo
    mov dword [edx + 12], 0          ; buffer_addr hi
    inc edi
    cmp edi, AR_CNT
    jb  .ok
    xor edi, edi
.ok:
    mov [ar_tpd_prod], di
    mov ebx, R_TPD_PIDX              ; doorbell
    movzx eax, word [ar_tpd_prod]
    call ar_wr16
    mov ecx, 0x00200000              ; poll consumer index until it catches up
.p: mov ebx, R_TPD_CIDX
    call ar_rd16
    cmp ax, [ar_tpd_prod]
    je  .done
    dec ecx
    jnz .p
.done:
    ret

dev_rx_get:                          ; -> CF=0 with nn_frame/nn_flen set, or CF=1
    movzx esi, word [ar_rrd_clean]
    mov edx, esi
    shl edx, 4
    add edx, AR_RRD                  ; EDX -> RRD[clean]
    mov eax, [edx + 12]              ; word3
    test eax, 0x80000000             ; RXD valid?
    jz  .none
    mov ecx, eax
    and ecx, 0x3FFF                  ; packet size
    mov [nn_flen], ecx
    mov eax, [edx]                   ; word0
    shr eax, 20
    and eax, 0xFFF                   ; RFD index
    shl eax, 11                      ; *2048
    add eax, AR_RXBUFS
    mov [nn_frame], eax
    mov dword [edx + 12], 0          ; clear valid
    movzx esi, word [ar_rrd_clean]
    inc esi
    cmp esi, AR_CNT
    jb  .a
    xor esi, esi
.a:
    mov [ar_rrd_clean], si
    movzx eax, word [ar_rfd_prod]    ; re-post a receive buffer
    inc eax
    cmp eax, AR_CNT
    jb  .b
    xor eax, eax
.b:
    mov [ar_rfd_prod], ax
    mov ebx, R_RFD_PIDX
    movzx eax, word [ar_rfd_prod]
    call ar_wr16
    clc
    ret
.none:
    stc
    ret

; ---- MMIO (EBX=offset) ----
ar_wr32:
    push edx
    mov edx, [ar_mmio]
    add edx, ebx
    mov [edx], eax
    pop edx
    ret
ar_rd32:
    push edx
    mov edx, [ar_mmio]
    add edx, ebx
    mov eax, [edx]
    pop edx
    ret
ar_wr16:                             ; writes AX
    push edx
    mov edx, [ar_mmio]
    add edx, ebx
    mov [edx], ax
    pop edx
    ret
ar_rd16:                             ; -> AX
    push edx
    mov edx, [ar_mmio]
    add edx, ebx
    movzx eax, word [edx]
    pop edx
    ret

; ---- PCI mechanism 1: find 1969:1026, enable bus master + memory ----
ar_pci_addr:
    movzx ebx, byte [ar_pci_bus]
    shl ebx, 16
    movzx edx, byte [ar_pci_dev]
    and edx, 0x1F
    shl edx, 11
    or  ebx, edx
    movzx edx, byte [ar_pci_fn]
    and edx, 7
    shl edx, 8
    or  ebx, edx
    movzx edx, byte [ar_pci_off]
    and edx, 0xFC
    or  ebx, edx
    or  ebx, 0x80000000
    mov eax, ebx
    ret
ar_pci_read:
    push ebx
    push edx
    call ar_pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    pop edx
    pop ebx
    ret
ar_pci_write:
    push eax
    push ebx
    push edx
    mov [ar_pci_val], eax
    call ar_pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov eax, [ar_pci_val]
    mov dx, 0xCFC
    out dx, eax
    pop edx
    pop ebx
    pop eax
    ret
ar_pci_find:                         ; AR8131 is on bus 3 on the Asus; scan buses 0..5
    mov byte [ar_pci_fn], 0
    mov byte [ar_pci_bus], 0
.bus:
    mov byte [ar_pci_dev], 0
.dev:
    mov byte [ar_pci_off], 0x00
    call ar_pci_read
    cmp eax, 0x10261969              ; device:vendor = 1026:1969
    je  .found
    mov al, [ar_pci_dev]
    inc al
    mov [ar_pci_dev], al
    cmp al, 32
    jb  .dev
    mov al, [ar_pci_bus]
    inc al
    mov [ar_pci_bus], al
    cmp al, 6
    jb  .bus
    stc
    ret
.found:
    mov byte [ar_pci_off], 0x04      ; bus master + memory space
    call ar_pci_read
    or  eax, 0x0006
    push eax
    mov byte [ar_pci_off], 0x04
    pop eax
    call ar_pci_write
    mov byte [ar_pci_off], 0x10      ; BAR0
    call ar_pci_read
    and eax, 0xFFFFFFF0
    mov [ar_mmio], eax
    ret

; ---- on-screen diagnostic HUD (bottom rows of the 80x50 text console) ----
; Shows: M<mmio> A<our MAC> C<live MAC_CTRL> T<TPD consumer idx> R<RRD[0].word3>.
; TPD consumer != 0 means a TX completed; RRD word3 bit31 means a frame was received.
VGATXT equ 0x00020000
ar_hud:
    mov edi, VGATXT + 48 * 160
    mov al, 'M'
    call ar_pc
    mov eax, [ar_mmio]
    mov cl, 8
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'A'
    call ar_pc
    xor ebp, ebp
.macl:
    movzx eax, byte [nn_mac + ebp]
    mov cl, 2
    call ar_hex
    inc ebp
    cmp ebp, 6
    jb  .macl
    mov al, ' '
    call ar_pc
    mov al, 'C'
    call ar_pc
    mov ebx, R_MACCTRL
    call ar_rd32
    mov cl, 8
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'T'
    call ar_pc
    mov ebx, R_TPD_CIDX
    call ar_rd16
    mov cl, 4
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'R'
    call ar_pc
    mov eax, [AR_RRD + 12]
    mov cl, 8
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'Q'
    call ar_pc
    mov ebx, R_TXQ                    ; live TXQ_CTRL (bit5 = enabled?)
    call ar_rd32
    mov cl, 8
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'B'
    call ar_pc
    mov ebx, R_TPD_LO                ; TPD ring base readback (did it latch to AR_TPD?)
    call ar_rd32
    mov cl, 8
    call ar_hex
    ret
ar_pc:                               ; AL = char -> text cell at EDI, green, EDI+=2
    mov [edi], al
    mov byte [edi + 1], 0x0A
    add edi, 2
    ret
ar_hex:                              ; EAX value, CL = digit count, EDI = text ptr
    movzx ebx, cl
.nx:
    dec ebx
    mov ecx, ebx
    shl ecx, 2
    mov edx, eax
    shr edx, cl
    and edx, 0xF
    cmp dl, 10
    jb  .d
    add dl, 'A' - 10
    jmp .pw
.d:
    add dl, '0'
.pw:
    mov [edi], dl
    mov byte [edi + 1], 0x0A
    add edi, 2
    test ebx, ebx
    jnz .nx
    ret

ar_mmio    dd 0
ar_macraw  times 8 db 0
ar_macctrl dd 0
ar_dmactrl dd 0
ar_txqcfg  dd 0
ar_rxqcfg  dd 0
ar_txlen   dd 0
ar_tpd_prod dw 0
ar_rrd_clean dw 0
ar_rfd_prod dw 0
ar_pci_bus db 0
ar_pci_dev db 0
ar_pci_fn  db 0
ar_pci_off db 0
ar_pci_val dd 0
