; nictest.asm - native NIC bring-up (e1000) WITHOUT PXE/UNDI firmware.
;   M1: PCI discover + bus-master + MMIO + reset + TX DMA ring (send ARP).  [done]
;   M2: RX DMA ring (poll descriptors).
;   M3: minimal ARP + IP/UDP: answer ARP for our IP, echo UDP on port 50000.
; This is the native fast path that will replace the slow PXE-UNDI polled UDP.
;
; Build: nasm -f bin nictest.asm -o nictest.bin
;        cat pxe_stage1.bin nictest.bin > pxe_nictest.img
BITS 16
ORG 0x8000
CODE_SEL equ 0x08
DATA_SEL equ 0x10
STAGE2_SECTORS equ 34

; our IP (QEMU SLIRP default guest) - bytes 10.0.2.15; real metal: set to 192.168.178.114
IP0 equ 10
IP1 equ 0
IP2 equ 2
IP3 equ 15
UDP_PORT equ 50000

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

TXRING   equ 0x00090000           ; 8 TX descriptors (128B)
TXBUF    equ 0x00091000           ; outgoing frame
RXRING   equ 0x00092000           ; 16 RX descriptors (256B)
RXBUFS   equ 0x00200000           ; 16 x 2048B receive buffers (high RAM; 0xA0000 is VGA!)
RXCOUNT  equ 16
RXBUFSZ  equ 2048

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
    call pci_find_e1000
    mov byte [pci_off], 0x04           ; bus master + memory space
    call pci_read
    or  eax, 0x0006
    mov byte [pci_off], 0x04
    call pci_write
    call read_mac
    call e1000_reset
    call e1000_setup_tx
    call e1000_setup_rx
    call send_gratuitous_arp           ; announce ourselves once
    mov byte [0xB8002], 'R'            ; ready, servicing RX
    mov byte [0xB8003], 0x0A
.service:
    call rx_poll
    jmp .service

; ================= RX service =================
; poll the RX ring; on a frame, dispatch ARP / IP-UDP, then recycle the descriptor.
rx_poll:
    movzx esi, word [rx_tail]          ; descriptor we expect next
    mov eax, esi
    shl eax, 4                         ; *16 (descriptor size)
    add eax, RXRING
    mov edx, eax                       ; EDX -> current RX descriptor
    mov al, [edx + 12]                 ; status byte
    test al, 1                         ; DD (descriptor done)?
    jz  .none
    movzx ecx, word [edx + 8]          ; length
    mov edi, [edx]                     ; buffer phys addr (low 32)
    mov [rx_frame], edi
    mov [rx_len], ecx
    call handle_frame
    mov byte [edx + 12], 0             ; clear status (recycle)
    mov eax, esi                       ; advance RDT to this descriptor
    mov ebx, E_RDT
    push eax
    call mmio_wr
    pop eax
    inc esi                            ; next tail (mod RXCOUNT)
    cmp esi, RXCOUNT
    jb  .store
    xor esi, esi
.store:
    mov [rx_tail], si
.none:
    ret

; EDI=[rx_frame], ECX=[rx_len]
handle_frame:
    mov edi, [rx_frame]
    cmp ecx, 42
    jb  .ret
    mov ax, [edi + 12]                 ; ethertype
    cmp ax, 0x0608                     ; 0x0806 ARP (BE on wire)
    je  .arp
    cmp ax, 0x0008                     ; 0x0800 IP
    je  .ip
.ret:
    ret
.arp:
    jmp arp_handle
.ip:
    jmp ip_handle

; ---- ARP: if request for our IP, send a reply ----
arp_handle:
    mov edi, [rx_frame]
    mov ax, [edi + 20]                 ; ARP oper
    cmp ax, 0x0100                     ; request (BE)
    jne .ret
    ; target IP at +38 must equal ours
    mov al, [edi + 38]
    cmp al, IP0
    jne .ret
    mov al, [edi + 39]
    cmp al, IP1
    jne .ret
    mov al, [edi + 40]
    cmp al, IP2
    jne .ret
    mov al, [edi + 41]
    cmp al, IP3
    jne .ret
    ; build reply into TXBUF
    mov edi, TXBUF
    mov esi, [rx_frame]
    mov ebx, esi                       ; keep src frame base
    ; eth dst = requester's src MAC (frame +6), eth src = our MAC
    lea esi, [ebx + 6]
    call copy6
    call put_mac
    mov ax, 0x0608                     ; ethertype ARP
    stosw
    mov ax, 0x0100                     ; htype 1
    stosw
    mov ax, 0x0008                     ; ptype 0x0800
    stosw
    mov al, 6
    stosb
    mov al, 4
    stosb
    mov ax, 0x0200                     ; oper 2 (reply)
    stosw
    call put_mac                       ; sender MAC = us
    call put_ourip                     ; sender IP = us
    lea esi, [ebx + 22]                ; target MAC = requester's sender MAC (ARP +22)
    call copy6
    lea esi, [ebx + 28]                ; target IP = requester's sender IP (ARP +28)
    call copy4
    mov eax, 42
    call send_frame
.ret:
    ret

; ---- IP/UDP: echo UDP payload on our port back to sender ----
ip_handle:
    mov edi, [rx_frame]
    ; dst IP (IP header +16) must be ours
    mov al, [edi + 30]
    cmp al, IP0
    jne .ret
    mov al, [edi + 33]
    cmp al, IP3
    jne .ret
    mov al, [edi + 23]                 ; protocol (IP +9)
    cmp al, 17                         ; UDP
    jne .ret
    ; IP header length (IHL) -> UDP offset. assume 20 (IHL=5); verify
    mov al, [edi + 14]
    and al, 0x0F
    cmp al, 5
    jne .ret
    ; UDP header at +34: src port(34), dst port(36), len(38), csum(40), data(42)
    mov ax, [edi + 36]                 ; dst port (BE)
    cmp ax, (UDP_PORT >> 8) | ((UDP_PORT & 0xFF) << 8)
    jne .ret
    ; udp length
    movzx ecx, word [edi + 38]
    xchg cl, ch                        ; BE -> host
    cmp ecx, 8
    jbe .ret
    sub ecx, 8                         ; payload length
    mov [udp_plen], ecx
    ; build echo reply into TXBUF
    mov edi, TXBUF
    mov esi, [rx_frame]
    mov ebx, esi
    lea esi, [ebx + 6]                 ; eth dst = sender MAC
    call copy6
    call put_mac                       ; eth src = us
    mov ax, 0x0008                     ; ethertype IP
    stosw
    ; IP header (20 bytes)
    mov al, 0x45
    stosb                              ; ver/IHL
    mov al, 0
    stosb                              ; DSCP
    mov eax, 0
    mov ax, [udp_plen]
    add ax, 28                         ; total len = 20 IP + 8 UDP + payload
    xchg al, ah
    stosw
    mov ax, 0
    stosw                              ; id
    stosw                              ; flags/frag
    mov al, 64
    stosb                              ; TTL
    mov al, 17
    stosb                              ; proto UDP
    mov ax, 0
    stosw                              ; checksum = 0 (fill later)
    call put_ourip                     ; src IP = us
    lea esi, [ebx + 26]                ; dst IP = sender's src IP (IP +12)
    call copy4
    ; UDP header: swap ports
    mov ax, [ebx + 36]                 ; our port (was dst) -> src
    stosw
    mov ax, [ebx + 34]                 ; sender port -> dst
    stosw
    mov ax, [udp_plen]
    add ax, 8
    xchg al, ah
    stosw                              ; udp length
    mov ax, 0
    stosw                              ; udp checksum 0 (optional for IPv4)
    ; copy payload
    lea esi, [ebx + 42]
    mov ecx, [udp_plen]
    rep movsb
    ; fill IP header checksum
    call ip_checksum
    mov eax, [udp_plen]
    add eax, 42
    call send_frame
.ret:
    ret

; IP header checksum over TXBUF+14 .. +34 (20 bytes), store at TXBUF+24
ip_checksum:
    mov esi, TXBUF + 14
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
    mov [TXBUF + 24], ax
    ret

; ---- helpers ----
copy6:                                 ; ESI -> EDI, 6 bytes
    movsd
    movsw
    ret
copy4:
    movsd
    ret
put_mac:                               ; append our 6-byte MAC at EDI
    mov esi, our_mac
    movsd
    movsw
    ret
put_ourip:
    mov al, IP0
    stosb
    mov al, IP1
    stosb
    mov al, IP2
    stosb
    mov al, IP3
    stosb
    ret

read_mac:                              ; cache MAC from RAL/RAH into our_mac
    mov ebx, E_RAL0
    call mmio_rd
    mov [our_mac], eax
    mov ebx, E_RAH0
    call mmio_rd
    mov [our_mac + 4], ax
    ret

send_gratuitous_arp:
    mov edi, TXBUF
    mov eax, 0xFFFFFFFF
    stosd
    mov ax, 0xFFFF
    stosw
    call put_mac
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
    call put_mac
    call put_ourip
    xor eax, eax
    stosd
    xor ax, ax
    stosw
    call put_ourip
    mov eax, 42
    call send_frame
    ret

; ---- e1000 MMIO ----
mmio_wr:                               ; EBX=offset, EAX=value
    push edx
    mov edx, [mmio]
    add edx, ebx
    mov [edx], eax
    pop edx
    ret
mmio_rd:                               ; EBX=offset -> EAX
    push edx
    mov edx, [mmio]
    add edx, ebx
    mov eax, [edx]
    pop edx
    ret

e1000_reset:
    mov ebx, E_CTRL
    call mmio_rd
    or  eax, (1 << 26)
    call mmio_wr
    mov ecx, 0x00400000
.w: dec ecx
    jnz .w
    mov ebx, E_CTRL
    mov eax, (1 << 6) | (1 << 5)
    call mmio_wr
    ret

e1000_setup_tx:
    mov edi, TXRING
    mov ecx, 128 / 4
    xor eax, eax
    rep stosd
    mov ebx, E_TDBAL
    mov eax, TXRING
    call mmio_wr
    mov ebx, E_TDBAH
    xor eax, eax
    call mmio_wr
    mov ebx, E_TDLEN
    mov eax, 128
    call mmio_wr
    mov ebx, E_TDH
    xor eax, eax
    call mmio_wr
    mov ebx, E_TDT
    xor eax, eax
    call mmio_wr
    mov ebx, E_TIPG
    mov eax, 0x0060200A
    call mmio_wr
    mov ebx, E_TCTL
    mov eax, (1 << 1) | (1 << 3) | (0x0F << 4) | (0x3F << 12)
    call mmio_wr
    ret

e1000_setup_rx:
    ; init RX descriptors: each points at its 2KB buffer, status 0
    mov edi, RXRING
    xor ecx, ecx
.init:
    mov eax, RXBUFS
    mov edx, ecx
    shl edx, 11                        ; *2048
    add eax, edx
    mov [edi + 0], eax                 ; buffer addr low
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], 0
    add edi, 16
    inc ecx
    cmp ecx, RXCOUNT
    jb  .init
    mov ebx, E_RDBAL
    mov eax, RXRING
    call mmio_wr
    mov ebx, E_RDBAH
    xor eax, eax
    call mmio_wr
    mov ebx, E_RDLEN
    mov eax, RXCOUNT * 16
    call mmio_wr
    mov ebx, E_RDH
    xor eax, eax
    call mmio_wr
    mov ebx, E_RDT                      ; tail = last index (all buffers owned by NIC)
    mov eax, RXCOUNT - 1
    call mmio_wr
    mov word [rx_tail], 0
    mov ebx, E_RCTL                     ; EN | BAM(broadcast) | 2048 bufsz | SECRC
    mov eax, (1 << 1) | (1 << 15) | (1 << 26)
    call mmio_wr
    ret

send_frame:                            ; EAX = frame length in TXBUF
    mov [txlen], eax
    mov dword [TXRING + 0], TXBUF
    mov dword [TXRING + 4], 0
    mov ax, [txlen]
    mov word  [TXRING + 8], ax
    mov byte  [TXRING + 10], 0
    mov byte  [TXRING + 11], 0x0B      ; EOP|IFCS|RS
    mov word  [TXRING + 12], 0
    mov word  [TXRING + 14], 0
    mov ebx, E_TDT
    mov eax, 1
    call mmio_wr
    mov ecx, 0x00200000
.p: mov al, [TXRING + 12]
    test al, 1
    jnz .done
    dec ecx
    jnz .p
.done:
    mov ebx, E_TDT
    xor eax, eax
    call mmio_wr
    mov ebx, E_TDH
    xor eax, eax
    call mmio_wr
    ret

; ---- PCI mechanism 1 ----
pci_addr:
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
    movzx edx, byte [pci_off]
    and edx, 0xFC
    or  ebx, edx
    or  ebx, 0x80000000
    mov eax, ebx
    ret
pci_read:
    push ebx
    push edx
    call pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    pop edx
    pop ebx
    ret
pci_write:
    push eax
    push ebx
    push edx
    mov [pci_val], eax
    call pci_addr
    mov dx, 0xCF8
    out dx, eax
    mov eax, [pci_val]
    mov dx, 0xCFC
    out dx, eax
    pop edx
    pop ebx
    pop eax
    ret
pci_find_e1000:
    mov byte [pci_bus], 0
    mov byte [pci_func], 0
    xor ecx, ecx
.next:
    mov [pci_dev], cl
    mov byte [pci_off], 0x00
    call pci_read
    cmp ax, 0x8086
    jne .skip
    shr eax, 16
    cmp ax, 0x100E
    je  .found
.skip:
    inc ecx
    cmp ecx, 32
    jb  .next
    mov byte [0xB8000], 'X'
    cli
    hlt
.found:
    mov byte [pci_off], 0x10
    call pci_read
    and eax, 0xFFFFFFF0
    mov [mmio], eax
    ret

pci_bus  db 0
pci_dev  db 0
pci_func db 0
pci_off  db 0
pci_val  dd 0
mmio     dd 0
our_mac  times 6 db 0
rx_tail  dw 0
rx_frame dd 0
rx_len   dd 0
udp_plen dd 0
txlen    dd 0

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
