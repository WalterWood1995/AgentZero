; net_native.asm - native Intel e1000 driver (MMIO + DMA rings, no PXE/UNDI), plus a
; minimal ARP/IP/UDP responder. %include'd by a host (nictest.asm or stage2.asm) that
; provides these symbols: rx_buf, tx_buf, tx_len(word), peer_ip(dd), peer_port(word).
; The host sets nn_ip (our 4 IP bytes) before calling nn_init.
;
; Public (32-bit PM, flat segments) entry points:
;   nn_init       - PCI discover e1000, bus-master, reset, TX+RX rings, announce ARP.
;   nn_poll_cmd   - poll RX once. Returns AX=0 if a UDP command for us:NN_PORT arrived
;                   (payload copied to rx_buf, ECX/[nn_rxlen]=length, peer_ip/peer_port/
;                   nn_peer_mac set); AX=1 otherwise (ARP answered internally / nothing).
;   nn_reply      - wrap tx_buf[0..tx_len] as a UDP datagram to the last peer and send.
; This mirrors the PXE UDP_READ/UDP_WRITE interface so net_loop can swap transports.

NN_PORT equ 50000
NN_PORT_BE equ ((NN_PORT & 0xFF) << 8) | (NN_PORT >> 8)   ; 50000 -> 0x50C3 on the wire

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

NN_TXRING equ 0x00090000           ; 8 TX descriptors (128B)
NN_TXBUF  equ 0x00091000           ; outgoing frame
NN_RXRING equ 0x00092000           ; 16 RX descriptors (256B)
NN_RXBUFS equ 0x00200000           ; 16 x 2048B receive buffers (high RAM; 0xA0000 is VGA)
NN_RXCNT  equ 16

; ---------- init ----------
nn_init:
    call nn_pci_find
    mov byte [nn_pci_off], 0x04        ; PCI command: bus master + memory space
    call nn_pci_read
    or  eax, 0x0006
    mov byte [nn_pci_off], 0x04
    call nn_pci_write
    call nn_read_mac
    call nn_reset
    call nn_setup_tx
    call nn_setup_rx
    call nn_gratuitous_arp
    ret

; ---------- drain the RX ring; answer ARP, discard noise, stop on a UDP command ----------
; Draining every ready descriptor each call (not one per call) keeps the 16-entry ring
; from overflowing under a burst (real-HW command bursts, or QEMU's post-boot TFTP flood)
; which would otherwise make the NIC drop our command packets.
nn_poll_cmd:
.loop:
    movzx esi, word [nn_rxtail]        ; current descriptor index
    mov edx, esi
    shl edx, 4
    add edx, NN_RXRING                 ; EDX -> descriptor
    test byte [edx + 12], 1            ; DD?
    jz  .nothing
    movzx ecx, word [edx + 8]
    mov eax, [edx]
    mov [nn_frame], eax
    mov [nn_flen], ecx
    mov byte [nn_cmd], 0
    call nn_handle                     ; ARP -> reply; UDP for us -> rx_buf + nn_cmd=1
                                       ; (clobbers regs; recompute from nn_rxtail below)
    movzx esi, word [nn_rxtail]
    mov edx, esi
    shl edx, 4
    add edx, NN_RXRING
    mov byte [edx + 12], 0             ; recycle descriptor
    mov eax, esi                       ; RDT = this index (hand buffer back to NIC)
    mov ebx, E_RDT
    call nn_mmio_wr
    movzx esi, word [nn_rxtail]
    inc esi
    cmp esi, NN_RXCNT
    jb  .adv
    xor esi, esi
.adv:
    mov [nn_rxtail], si
    cmp byte [nn_cmd], 1
    jne .loop                          ; noise/ARP: keep draining the ring
    mov ecx, [nn_rxlen]
    xor ax, ax                         ; AX=0: command ready in rx_buf
    ret
.nothing:
    mov ax, 1
    ret

nn_handle:
    mov edi, [nn_frame]
    cmp dword [nn_flen], 42
    jb  .ret
    mov ax, [edi + 12]
    cmp ax, 0x0608                     ; ARP
    je  nn_arp
    cmp ax, 0x0008                     ; IP
    je  nn_handle_ip
.ret:
    ret

; ARP: reply to who-has nn_ip
nn_arp:
    mov edi, [nn_frame]
    mov ax, [edi + 20]
    cmp ax, 0x0100                     ; request
    jne .ret
    mov esi, edi
    add esi, 38                        ; target IP
    mov edi, nn_ip
    call nn_ip4_eq
    jnz .ret
    ; build reply in NN_TXBUF
    mov ebx, [nn_frame]
    mov edi, NN_TXBUF
    lea esi, [ebx + 6]                 ; dst = requester MAC
    call nn_cp6
    call nn_put_mac
    mov ax, 0x0608
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0008
    stosw
    mov al, 6
    stosb
    mov al, 4
    stosb
    mov ax, 0x0200                     ; reply
    stosw
    call nn_put_mac
    call nn_put_ip
    lea esi, [ebx + 22]                ; target MAC = requester sender MAC
    call nn_cp6
    lea esi, [ebx + 28]                ; target IP = requester sender IP
    call nn_cp4
    mov eax, 42
    call nn_send
.ret:
    ret

; IP/UDP: deliver a UDP datagram for us:NN_PORT into rx_buf
nn_handle_ip:
    mov edi, [nn_frame]
    lea esi, [edi + 30]                ; dst IP
    mov edi, nn_ip
    call nn_ip4_eq
    jnz .ret
    mov edi, [nn_frame]
    mov al, [edi + 23]                 ; protocol
    cmp al, 17
    jne .ret
    mov al, [edi + 14]
    and al, 0x0F
    cmp al, 5                          ; IHL=5 (20-byte IP header)
    jne .ret
    mov ax, [edi + 36]                 ; UDP dst port
    cmp ax, NN_PORT_BE
    jne .ret
    movzx ecx, word [edi + 38]         ; UDP length (BE)
    xchg cl, ch
    cmp ecx, 8
    jbe .ret
    sub ecx, 8
    mov [nn_rxlen], ecx
    ; capture peer (sender MAC/IP/port)
    mov esi, [nn_frame]
    lea esi, [esi + 6]
    mov edi, nn_peer_mac
    call nn_cp6
    mov esi, [nn_frame]
    mov eax, [esi + 26]                ; sender IP (IP src)
    mov [peer_ip], eax
    mov ax, [esi + 34]                 ; sender UDP src port (BE)
    mov [peer_port], ax
    ; copy payload -> rx_buf
    mov esi, [nn_frame]
    add esi, 42
    mov edi, rx_buf
    mov ecx, [nn_rxlen]
    rep movsb
    mov byte [nn_cmd], 1
.ret:
    ret

; ---------- build + send a UDP reply from tx_buf[0..tx_len] ----------
nn_reply:
    mov ebx, NN_TXBUF
    mov edi, ebx
    mov esi, nn_peer_mac               ; eth dst = peer
    call nn_cp6
    call nn_put_mac                    ; eth src = us
    mov ax, 0x0008                     ; IP
    stosw
    mov al, 0x45
    stosb
    mov al, 0
    stosb
    movzx eax, word [tx_len]
    add eax, 28                        ; IP total length
    xchg al, ah
    stosw
    xor ax, ax
    stosw                              ; id
    stosw                              ; flags/frag
    mov al, 64
    stosb                              ; TTL
    mov al, 17
    stosb                              ; UDP
    xor ax, ax
    stosw                              ; checksum (filled below)
    call nn_put_ip                     ; src IP
    mov eax, [peer_ip]                 ; dst IP
    stosd
    mov ax, NN_PORT_BE                 ; src port = our listen port
    stosw
    mov ax, [peer_port]                ; dst port = peer
    stosw
    movzx eax, word [tx_len]
    add eax, 8
    xchg al, ah
    stosw                              ; UDP length
    xor ax, ax
    stosw                              ; UDP checksum 0
    mov esi, tx_buf                    ; payload
    movzx ecx, word [tx_len]
    rep movsb
    ; IP header checksum over NN_TXBUF+14..+34
    mov esi, NN_TXBUF + 14
    xor eax, eax
    mov ecx, 10
.sum:
    movzx edx, word [esi]
    add eax, edx
    add esi, 2
    dec ecx
    jnz .sum
.fold:
    mov edx, eax
    shr edx, 16
    and eax, 0xFFFF
    add eax, edx
    cmp eax, 0x10000
    jae .fold
    not ax
    mov [NN_TXBUF + 24], ax
    movzx eax, word [tx_len]
    add eax, 42
    call nn_send
    ret

; ---------- helpers ----------
nn_ip4_eq:                             ; ESI vs EDI, 4 bytes -> ZF set if equal
    mov eax, [esi]
    cmp eax, [edi]
    ret
nn_cp6:
    movsd
    movsw
    ret
nn_cp4:
    movsd
    ret
nn_put_mac:
    push esi
    mov esi, nn_mac
    movsd
    movsw
    pop esi
    ret
nn_put_ip:
    push esi
    mov esi, nn_ip
    movsd
    pop esi
    ret
nn_read_mac:
    mov ebx, E_RAL0
    call nn_mmio_rd
    mov [nn_mac], eax
    mov ebx, E_RAH0
    call nn_mmio_rd
    mov [nn_mac + 4], ax
    ret
nn_gratuitous_arp:
    mov edi, NN_TXBUF
    mov eax, 0xFFFFFFFF
    stosd
    mov ax, 0xFFFF
    stosw
    call nn_put_mac
    mov ax, 0x0608
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0008
    stosw
    mov al, 6
    stosb
    mov al, 4
    stosb
    mov ax, 0x0100
    stosw
    call nn_put_mac
    call nn_put_ip
    xor eax, eax
    stosd
    xor ax, ax
    stosw
    call nn_put_ip
    mov eax, 42
    call nn_send
    ret

nn_mmio_wr:
    push edx
    mov edx, [nn_mmio]
    add edx, ebx
    mov [edx], eax
    pop edx
    ret
nn_mmio_rd:
    push edx
    mov edx, [nn_mmio]
    add edx, ebx
    mov eax, [edx]
    pop edx
    ret

nn_reset:
    mov ebx, E_CTRL
    call nn_mmio_rd
    or  eax, (1 << 26)
    call nn_mmio_wr
    mov ecx, 0x00400000
.w: dec ecx
    jnz .w
    mov ebx, E_CTRL
    mov eax, (1 << 6) | (1 << 5)
    call nn_mmio_wr
    ret

nn_setup_tx:
    mov edi, NN_TXRING
    mov ecx, 128 / 4
    xor eax, eax
    rep stosd
    mov ebx, E_TDBAL
    mov eax, NN_TXRING
    call nn_mmio_wr
    mov ebx, E_TDBAH
    xor eax, eax
    call nn_mmio_wr
    mov ebx, E_TDLEN
    mov eax, 128
    call nn_mmio_wr
    mov ebx, E_TDH
    xor eax, eax
    call nn_mmio_wr
    mov ebx, E_TDT
    xor eax, eax
    call nn_mmio_wr
    mov ebx, E_TIPG
    mov eax, 0x0060200A
    call nn_mmio_wr
    mov ebx, E_TCTL
    mov eax, (1 << 1) | (1 << 3) | (0x0F << 4) | (0x3F << 12)
    call nn_mmio_wr
    ret

nn_setup_rx:
    mov edi, NN_RXRING
    xor ecx, ecx
.init:
    mov eax, NN_RXBUFS
    mov edx, ecx
    shl edx, 11
    add eax, edx
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], 0
    add edi, 16
    inc ecx
    cmp ecx, NN_RXCNT
    jb  .init
    mov ebx, E_RDBAL
    mov eax, NN_RXRING
    call nn_mmio_wr
    mov ebx, E_RDBAH
    xor eax, eax
    call nn_mmio_wr
    mov ebx, E_RDLEN
    mov eax, NN_RXCNT * 16
    call nn_mmio_wr
    mov ebx, E_RDH
    xor eax, eax
    call nn_mmio_wr
    mov ebx, E_RDT
    mov eax, NN_RXCNT - 1
    call nn_mmio_wr
    mov word [nn_rxtail], 0
    mov ebx, E_RCTL
    mov eax, (1 << 1) | (1 << 15) | (1 << 26)   ; EN | BAM | SECRC (2048-byte buffers)
    call nn_mmio_wr
    ret

nn_send:                               ; EAX = frame length in NN_TXBUF
    mov [nn_txlen], eax
    mov dword [NN_TXRING + 0], NN_TXBUF
    mov dword [NN_TXRING + 4], 0
    mov ax, [nn_txlen]
    mov word  [NN_TXRING + 8], ax
    mov byte  [NN_TXRING + 10], 0
    mov byte  [NN_TXRING + 11], 0x0B
    mov word  [NN_TXRING + 12], 0
    mov word  [NN_TXRING + 14], 0
    mov ebx, E_TDT
    mov eax, 1
    call nn_mmio_wr
    mov ecx, 0x00200000
.p: mov al, [NN_TXRING + 12]
    test al, 1
    jnz .done
    dec ecx
    jnz .p
.done:
    mov ebx, E_TDT
    xor eax, eax
    call nn_mmio_wr
    mov ebx, E_TDH
    xor eax, eax
    call nn_mmio_wr
    ret

; ---- PCI mechanism 1 ----
nn_pci_addr:
    movzx ebx, byte [nn_pci_bus]
    shl ebx, 16
    movzx edx, byte [nn_pci_dev]
    and edx, 0x1F
    shl edx, 11
    or  ebx, edx
    movzx edx, byte [nn_pci_fn]
    and edx, 7
    shl edx, 8
    or  ebx, edx
    movzx edx, byte [nn_pci_off]
    and edx, 0xFC
    or  ebx, edx
    or  ebx, 0x80000000
    mov eax, ebx
    ret
nn_pci_read:
    push ebx
    push edx
    call nn_pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    pop edx
    pop ebx
    ret
nn_pci_write:
    push eax
    push ebx
    push edx
    mov [nn_pci_val], eax
    call nn_pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov eax, [nn_pci_val]
    mov dx, 0xCFC
    out dx, eax
    pop edx
    pop ebx
    pop eax
    ret
nn_pci_find:                           ; scan bus0 dev0..31 fn0 for 8086:100e
    mov byte [nn_pci_bus], 0
    mov byte [nn_pci_fn], 0
    xor ecx, ecx
.next:
    mov [nn_pci_dev], cl
    mov byte [nn_pci_off], 0x00
    call nn_pci_read
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
    mov byte [nn_pci_off], 0x10
    call nn_pci_read
    and eax, 0xFFFFFFF0
    mov [nn_mmio], eax
    ret

; ---- state ----
nn_ip       times 4 db 0               ; our IP (host sets before nn_init)
nn_mac      times 6 db 0
nn_peer_mac times 6 db 0
nn_mmio     dd 0
nn_rxtail   dw 0
nn_frame    dd 0
nn_flen     dd 0
nn_rxlen    dd 0
nn_txlen    dd 0
nn_cmd      db 0
nn_pci_bus  db 0
nn_pci_dev  db 0
nn_pci_fn   db 0
nn_pci_off  db 0
nn_pci_val  dd 0
