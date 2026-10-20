; net_native.asm - device-agnostic native network stack (minimal ARP/IP/UDP) that
; replaces the slow PXE-UNDI UDP channel. The NIC itself is driven by a pluggable
; device layer (%include'd separately): net_dev_e1000.asm (QEMU) or net_dev_ar8131.asm
; (the Asus's Atheros NIC). The device layer must provide:
;   dev_init     - bring the NIC up; cache its 6-byte MAC into nn_mac.
;   dev_send     - transmit NN_TXBUF, EAX = frame length.
;   dev_rx_get   - if a frame is ready: set [nn_frame]=buffer ptr, [nn_flen]=len,
;                  recycle the descriptor, return CF=0. Else return CF=1 (ring empty).
; The host (nictest.asm / stage2.asm) provides: rx_buf, tx_buf, tx_len(word),
; peer_ip(dd), peer_port(word), and sets nn_ip (our 4 IP bytes) before nn_init.
;
; Public: nn_init, nn_poll_cmd (AX=0 => command in rx_buf, ECX=len), nn_reply.

NN_PORT equ 50000
NN_PORT_BE equ ((NN_PORT & 0xFF) << 8) | (NN_PORT >> 8)   ; 0x50C3 on the wire
NN_TXBUF  equ 0x00091000           ; outgoing frame scratch (shared with the device send)

; ---------- init ----------
nn_init:
    call dev_init                  ; device-specific: NIC up + nn_mac cached
    call nn_gratuitous_arp
    ret

; ---------- drain the RX ring; answer ARP, discard noise, stop on a UDP command ----------
nn_poll_cmd:
.loop:
    call dev_rx_get                ; CF=1 -> nothing ready
    jc  .nothing
    mov byte [nn_cmd], 0
    call nn_handle                 ; ARP -> reply; UDP for us -> rx_buf + nn_cmd=1
    cmp byte [nn_cmd], 1
    jne .loop                      ; noise/ARP: keep draining
    mov ecx, [nn_rxlen]
    xor ax, ax
    ret
.nothing:
    mov ax, 1
    ret

nn_handle:
    mov edi, [nn_frame]
    cmp dword [nn_flen], 42
    jb  .ret
    mov ax, [edi + 12]
    cmp ax, 0x0608                 ; ARP
    je  nn_arp
    cmp ax, 0x0008                 ; IP
    je  nn_handle_ip
.ret:
    ret

; ARP: reply to who-has nn_ip
nn_arp:
    mov edi, [nn_frame]
    mov ax, [edi + 20]
    cmp ax, 0x0100                 ; request
    jne .ret
    mov esi, edi
    add esi, 38                    ; target IP
    mov edi, nn_ip
    call nn_ip4_eq
    jnz .ret
    mov ebx, [nn_frame]
    mov edi, NN_TXBUF
    lea esi, [ebx + 6]             ; dst = requester MAC
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
    mov ax, 0x0200                 ; reply
    stosw
    call nn_put_mac
    call nn_put_ip
    lea esi, [ebx + 22]            ; target MAC = requester sender MAC
    call nn_cp6
    lea esi, [ebx + 28]            ; target IP = requester sender IP
    call nn_cp4
    mov eax, 42
    call dev_send
.ret:
    ret

; IP/UDP: deliver a UDP datagram for us:NN_PORT into rx_buf
nn_handle_ip:
    mov edi, [nn_frame]
    lea esi, [edi + 30]            ; dst IP
    mov edi, nn_ip
    call nn_ip4_eq
    jnz .ret
    mov edi, [nn_frame]
    mov al, [edi + 23]             ; protocol
    cmp al, 17
    jne .ret
    mov al, [edi + 14]
    and al, 0x0F
    cmp al, 5                      ; IHL=5
    jne .ret
    mov ax, [edi + 36]             ; UDP dst port
    cmp ax, NN_PORT_BE
    jne .ret
    movzx ecx, word [edi + 38]     ; UDP length (BE)
    xchg cl, ch
    cmp ecx, 8
    jbe .ret
    sub ecx, 8
    mov [nn_rxlen], ecx
    mov esi, [nn_frame]
    lea esi, [esi + 6]
    mov edi, nn_peer_mac
    call nn_cp6
    mov esi, [nn_frame]
    mov eax, [esi + 26]            ; sender IP
    mov [peer_ip], eax
    mov ax, [esi + 34]             ; sender UDP src port (BE)
    mov [peer_port], ax
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
    mov edi, NN_TXBUF
    mov esi, nn_peer_mac           ; eth dst = peer
    call nn_cp6
    call nn_put_mac                ; eth src = us
    mov ax, 0x0008                 ; IP
    stosw
    mov al, 0x45
    stosb
    mov al, 0
    stosb
    movzx eax, word [tx_len]
    add eax, 28
    xchg al, ah
    stosw                          ; IP total length
    xor ax, ax
    stosw                          ; id
    stosw                          ; flags/frag
    mov al, 64
    stosb                          ; TTL
    mov al, 17
    stosb                          ; UDP
    xor ax, ax
    stosw                          ; checksum (filled below)
    call nn_put_ip                 ; src IP
    mov eax, [peer_ip]             ; dst IP
    stosd
    mov ax, NN_PORT_BE             ; src port
    stosw
    mov ax, [peer_port]            ; dst port
    stosw
    movzx eax, word [tx_len]
    add eax, 8
    xchg al, ah
    stosw                          ; UDP length
    xor ax, ax
    stosw                          ; UDP checksum 0
    mov esi, tx_buf
    movzx ecx, word [tx_len]
    rep movsb
    mov esi, NN_TXBUF + 14         ; IP header checksum over 20 bytes
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
    call dev_send
    ret

; ---------- stack helpers + state ----------
nn_ip4_eq:                         ; ESI vs EDI, 4 bytes -> ZF if equal
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
    call dev_send
    ret

nn_ip       times 4 db 0           ; our IP (host sets before nn_init)
nn_mac      times 6 db 0           ; device layer fills this in dev_init
nn_peer_mac times 6 db 0
nn_frame    dd 0                   ; device layer sets: ptr to the current RX frame
nn_flen     dd 0                   ; ...and its length
nn_rxlen    dd 0
nn_cmd      db 0
