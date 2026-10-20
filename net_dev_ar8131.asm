; net_dev_ar8131.asm - Atheros AR8131 (1969:1026) device layer for net_native.asm.
; The old Asus's NIC. Provides dev_init / dev_send / dev_rx_get. Register map and
; descriptor formats from the Linux atl1c driver (atl1c_hw.h / atl1c.h).
;
; STRATEGY (round 3): full atl1c-style bring-up INCLUDING PHY init over MDIO.
; Rounds 1-2 (minimal takeover and bare soft-reset) left the TPD consumer index
; stuck at 0 = TX DMA never ran. PXE/UNDI drives the chip through its own firmware
; path and never programs the standard atl1c TXQ/ring engine (J reads showed
; TXQ_CTRL=0, rings unconfigured), so there is nothing to inherit - we must build
; the whole TX path. The missing piece was the PHY: toggling the MAC/queues drops
; the GMII link, and with no PHY init the TX MAC has no clock, so the consumer
; index never advances. This cut does: MAC+DMA soft reset -> PHY reset via GPHY_CTRL
; -> advertise + restart autoneg over MDIO -> poll link up, read speed/duplex from
; MII_GIGA_PSSR -> program rings + DMA + TXQ/RXQ -> MAC_CTRL with the resolved
; speed/duplex. A rich HUD (PSSR/BMSR/IDLE) makes the live link state readable from
; a single photo when TX still fails.
;
; Build knobs:
;   -dAR_NOPHY   skip the GPHY reset + autoneg (keep PXE's live PHY/link), still
;                read PSSR for speed/duplex. Use to bisect PHY-reset vs ring issues.
;   -dAR_NORESET skip the MAC soft reset (pure minimal takeover). Diagnostic only.
;
; Rings (TPD=TX, RFD=RX free buffers, RRD=RX return/completion):
AR_TPD    equ 0x00090000           ; 64 x 16B transmit packet descriptors
AR_RFD    equ 0x00090400           ; 64 x 8B receive free descriptors
AR_RRD    equ 0x00090600           ; 64 x 16B receive return descriptors
AR_RXBUFS equ 0x00200000           ; 64 x 2048B receive buffers
AR_CNT    equ 64

; registers (atl1c)
R_MASTER  equ 0x1400
R_IDLE    equ 0x1410            ; IDLE_STATUS (poll after soft reset)
R_GPHY    equ 0x140C            ; GPHY_CTRL (PHY power + reset)
R_MDIO    equ 0x1414            ; MDIO_CTRL (MII management access)
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
R_TPD_PIDX equ 0x15F2            ; 16-bit prio0 TPD producer index
R_TPD_CIDX equ 0x15F6            ; 16-bit prio0 TPD consumer index
R_IMR     equ 0x1604
R_ISR     equ 0x1600
R_DMACTRL equ 0x15C0

; MASTER_CTRL bits
MASTER_SOFT_RST equ 0x1
MASTER_OOB_DIS  equ 0x40
MASTER_SA_TIMER equ 0x80

; MDIO_CTRL bits (clause 22, internal PHY, clk 25/4 = 0)
MDIO_SPRES   equ 0x00400000      ; BIT(22) suppress preamble
MDIO_OP_READ equ 0x00200000      ; BIT(21) 1=read 0=write
MDIO_START   equ 0x00800000      ; BIT(23)
MDIO_BUSY    equ 0x08000000       ; BIT(27)
MDIO_REG_SH  equ 16              ; reg addr << 16 (mask 0x1F)

; GPHY_CTRL bits
GPHY_EXT_RESET  equ 0x0001        ; BIT(0)  out of DSP reset
GPHY_GATE_25M   equ 0x0020        ; BIT(5)
GPHY_PHY_IDDQ   equ 0x0080        ; BIT(7)  power down
GPHY_IDDQ_DIS   equ 0x0100        ; BIT(8)
GPHY_SEL_ANA    equ 0x1000        ; BIT(12) select analog reset
GPHY_PLL_ON     equ 0x2000        ; BIT(13) PLL always on
GPHY_PWDOWN_HW  equ 0x4000        ; BIT(14)
GPHY_PLL_BYPASS equ 0x8000        ; BIT(15)

; MII (clause-22) register numbers + bits
MII_BMCR     equ 0                ; control
MII_BMSR     equ 1                ; status (BMSR_LSTATUS 0x0004)
MII_ADV      equ 4               ; autoneg advertisement
MII_CTRL1000 equ 9               ; 1000BASE-T control
MII_PSSR     equ 0x11            ; GIGA PHY-specific status
BMCR_RESTART equ 0x9200          ; RESET|ANENABLE|ANRESTART (0x8000|0x1000|0x0200)
ADV_10_100   equ 0x0DE1          ; CSMA|10H|10F|100H|100F|PAUSE|PAUSE_ASYM
ADV_1000     equ 0x0300          ; 1000 full + half
PSSR_RESOLVED equ 0x0800
PSSR_DPLX     equ 0x2000
PSSR_SPEED    equ 0xC000
PSSR_1000     equ 0x8000
PSSR_100      equ 0x4000

dev_init:
    call ar_pci_find                 ; 1969:1026 -> ar_mmio, enable bus master
    jnc .present
    ret                              ; NIC absent (e.g. QEMU): skip init, no stray MMIO
.present:
    ; ---- MAC address (atl1c layout) ---- read before any reset
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
    ; ---- stop the engines (so the soft reset is clean) ----
    mov ebx, R_TXQ
    call ar_rd32
    and eax, ~0x20
    mov ebx, R_TXQ
    call ar_wr32
    mov ebx, R_RXQ
    call ar_rd32
    and eax, ~0x80000000
    mov ebx, R_RXQ
    call ar_wr32
    mov ebx, R_MACCTRL
    call ar_rd32
    and eax, ~0x3
    mov ebx, R_MACCTRL
    call ar_wr32
    mov ecx, 0x00400000
.s0: dec ecx
    jnz .s0
%ifndef AR_NORESET
    ; ---- soft reset MAC + DMA, then wait for all engines idle ----
    mov eax, MASTER_OOB_DIS | MASTER_SOFT_RST
    mov ebx, R_MASTER
    call ar_wr32
    mov ecx, 0x00800000              ; settle
.s1: dec ecx
    jnz .s1
    mov esi, 200000                  ; poll IDLE_STATUS until TXQ/RXQ/TXMAC/RXMAC idle
.iw:
    mov ebx, R_IDLE
    call ar_rd32
    mov [ar_idle], eax
    test eax, 0x0F
    jz  .idle_ok
    dec esi
    jnz .iw
.idle_ok:
    mov eax, MASTER_OOB_DIS | MASTER_SA_TIMER   ; clear SOFT_RST
    mov ebx, R_MASTER
    call ar_wr32
%endif
%ifndef AR_NOPHY
    call ar_phy_reset                ; take the PHY out of power-down + ext reset
    call ar_phy_autoneg              ; advertise 10/100/1000, restart autoneg
%endif
    call ar_link_wait                ; poll MII_GIGA_PSSR -> ar_link_up/ar_speed/ar_duplex
    ; ---- re-write MAC address (soft reset cleared the station address) ----
    movzx eax, byte [nn_mac + 2]
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
    ; ---- DMA config (PXE's known-good value for this chip) ----
    mov eax, 0x00647C24
    mov ebx, R_DMACTRL
    call ar_wr32
    ; ---- latch ring base/size ----
    mov ebx, R_LOADPTR
    mov eax, 1
    call ar_wr32
    ; ---- enable queues with the proper atl1c config ----
    mov eax, 0x020000F5             ; L1C_TXQ_CFGV (0x020000D5) | TXQ_CTRL_EN (0x20)
    mov ebx, R_TXQ
    call ar_wr32
    mov eax, 0x80800000             ; RXQ_CTRL_EN (0x80000000) | rfd_burst 8<<20
    mov ebx, R_RXQ
    call ar_wr32
    ; ---- MAC_CTRL: TX/RX enable + CRC/PAD/BC + resolved speed/duplex ----
    mov eax, 0x3 | 0x40 | 0x80 | 0x4000000   ; TX_EN|RX_EN|ADD_CRC|PAD|BC_EN
    or  eax, (7 << 10)                        ; preamble length 7
    cmp dword [ar_speed], 1000
    jne .sp10100
    or  eax, (2 << 20)                        ; MAC_CTRL_SPEED_1000
    jmp .spdone
.sp10100:
    or  eax, (1 << 20)                        ; MAC_CTRL_SPEED_10_100
.spdone:
    cmp byte [ar_duplex], 0
    je  .hd
    or  eax, 0x20                             ; MAC_CTRL_DUPLX (full)
.hd:
    mov ebx, R_MACCTRL
    call ar_wr32
    mov ecx, 0x02000000              ; let the MAC settle
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

; ---- PHY: take it out of power-down and pulse the external (DSP) reset ----
ar_phy_reset:
    mov ebx, R_GPHY
    call ar_rd32
    and eax, ~(GPHY_EXT_RESET | GPHY_PHY_IDDQ | GPHY_GATE_25M | GPHY_PWDOWN_HW | GPHY_PLL_BYPASS)
    or  eax, GPHY_IDDQ_DIS | GPHY_PLL_ON | GPHY_SEL_ANA
    mov edx, eax                     ; remember (ar_wr32 preserves edx)
    mov ebx, R_GPHY
    call ar_wr32
    mov ecx, 0x01000000              ; ~10ms
.p0: dec ecx
    jnz .p0
    mov eax, edx
    or  eax, GPHY_EXT_RESET
    mov ebx, R_GPHY
    call ar_wr32
    mov ecx, 0x04000000              ; ~50ms for the DSP reset to lift
.p1: dec ecx
    jnz .p1
    ret

; ---- PHY: advertise 10/100/1000 and restart autonegotiation ----
ar_phy_autoneg:
    mov bl, MII_ADV
    mov cx, ADV_10_100
    call ar_mdio_write
    mov bl, MII_CTRL1000
    mov cx, ADV_1000
    call ar_mdio_write
    mov bl, MII_BMCR
    mov cx, BMCR_RESTART
    call ar_mdio_write
    ret

; ---- poll MII_GIGA_PSSR until speed/duplex resolved; fill ar_* state ----
ar_link_wait:
    mov dword [ar_link_up], 0
    mov dword [ar_speed], 0
    mov byte [ar_duplex], 0
    mov esi, 1500                    ; ~1500 polls * ~2ms ~= 3s
.lw:
    mov bl, MII_PSSR
    call ar_mdio_read                ; -> AX = PSSR
    mov [ar_pssr], ax
    test ax, PSSR_RESOLVED
    jz  .notyet
    mov dword [ar_link_up], 1
    test ax, PSSR_DPLX
    jz  .half
    mov byte [ar_duplex], 1
.half:
    mov dx, ax
    and dx, PSSR_SPEED
    cmp dx, PSSR_1000
    je  .g1000
    cmp dx, PSSR_100
    je  .g100
    mov dword [ar_speed], 10
    ret
.g100:
    mov dword [ar_speed], 100
    ret
.g1000:
    mov dword [ar_speed], 1000
    ret
.notyet:
    mov ecx, 0x00400000              ; ~2ms
.d: dec ecx
    jnz .d
    dec esi
    jnz .lw
    ret                              ; timeout: ar_link_up stays 0

; ---- MDIO (clause 22). read: BL=reg -> AX ; write: BL=reg, CX=data ----
ar_mdio_read:
    movzx eax, bl
    and eax, 0x1F
    shl eax, MDIO_REG_SH
    or  eax, MDIO_SPRES | MDIO_START | MDIO_OP_READ
    mov ebx, R_MDIO
    call ar_wr32
    mov ecx, 0x00100000
.w: mov ebx, R_MDIO
    call ar_rd32
    test eax, MDIO_BUSY | MDIO_START
    jz  .done
    dec ecx
    jnz .w
.done:
    and eax, 0xFFFF
    ret
ar_mdio_write:
    movzx eax, cx
    movzx edx, bl
    and edx, 0x1F
    shl edx, MDIO_REG_SH
    or  eax, edx
    or  eax, MDIO_SPRES | MDIO_START
    mov ebx, R_MDIO
    call ar_wr32
    mov ecx, 0x00100000
.w: mov ebx, R_MDIO
    call ar_rd32
    test eax, MDIO_BUSY | MDIO_START
    jz  .done
    dec ecx
    jnz .w
.done:
    ret

dev_send:                            ; EAX = frame length in NN_TXBUF
    cmp byte [ar_present], 0
    je  .done                        ; NIC absent: nothing to transmit
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
    cmp byte [ar_present], 0
    je  .none                        ; NIC absent: ring always empty
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
    mov byte [ar_present], 1
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
; Row 48: M<mmio> A<our MAC> C<live MAC_CTRL> T<TPD consumer idx> R<RRD[0].word3>
;         Q<live TXQ_CTRL> B<TPD base readback>.
; Row 47: P<live PSSR> L<BMSR> U<link_up> S<speed/100> I<IDLE_STATUS> D<DMA_CTRL>.
; TPD consumer != 0 => a TX completed. PSSR bit11 (0x0800) set => link resolved;
; bits 14:15 => speed (10=1000M). That one photo tells the whole TX story.
VGATXT equ 0x00020000
ar_hud:
    cmp byte [ar_present], 0
    jne .go
    ret                              ; NIC absent: no live registers to show
.go:
    ; ----- row 47: PHY / link diagnostics -----
    mov edi, VGATXT + 47 * 160
    mov al, 'P'
    call ar_pc
    mov bl, MII_PSSR
    call ar_mdio_read
    mov cl, 4
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'L'
    call ar_pc
    mov bl, MII_BMSR
    call ar_mdio_read                ; BMSR is latched; read twice for live link bit
    mov bl, MII_BMSR
    call ar_mdio_read
    mov cl, 4
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'U'
    call ar_pc
    mov eax, [ar_link_up]
    mov cl, 1
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'S'
    call ar_pc
    mov eax, [ar_speed]
    mov cl, 4
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'I'
    call ar_pc
    mov ebx, R_IDLE
    call ar_rd32
    mov cl, 8
    call ar_hex
    mov al, ' '
    call ar_pc
    mov al, 'D'
    call ar_pc
    mov ebx, R_DMACTRL
    call ar_rd32
    mov cl, 8
    call ar_hex
    ; ----- row 48: MAC / ring diagnostics -----
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
ar_present db 0
ar_macraw  times 8 db 0
ar_txlen   dd 0
ar_pssr    dw 0
ar_idle    dd 0
ar_link_up dd 0
ar_speed   dd 0
ar_duplex  db 0
ar_tpd_prod dw 0
ar_rrd_clean dw 0
ar_rfd_prod dw 0
ar_pci_bus db 0
ar_pci_dev db 0
ar_pci_fn  db 0
ar_pci_off db 0
ar_pci_val dd 0
