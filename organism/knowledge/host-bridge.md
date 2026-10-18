# Host bridge / chipset core — i440FX (00:00.0) + PIIX4 ACPI/PM (00:01.3)

Target: the "motherboard" of this QEMU-hosted AgentZero machine. Two PCI functions,
both touched READ-ONLY through `hw.py` (ring-0 PCI config reads over UDP to
127.0.0.1:50000). All dwords below are actual reads.

---

## 1. 00:00.0 — i440FX host / DRAM bridge (8086:1237)

Config space (dwords at offset):

```
00: 12378086   04: 00000103   08: 06000002   0C: 00000000
2C: 11001AF4
54: 10000000   58: 11111000   5C: 33111111
70: 000A0000
```

- **Identity (00: `12378086`)** — Vendor 0x8086 (Intel), Device 0x1237 = the 82441FX
  (i440FX / "Natoma") **PCI-and-Memory Controller (PMC)**, the host bridge. It is the
  root of the PCI bus and the DRAM controller; CPU-to-PCI and CPU-to-DRAM traffic
  passes through it. (CPU is GenuineIntel, CPUID leaf1 EAX 0x00000663, Pentium-II-class
  family 6 — matches a Natoma-era board.)
- **Command/Status (04: `00000103`)** — Command = 0x0103: bit0 **I/O space enable**,
  bit1 **memory space enable**, bit8 **SERR# enable**. Status = 0x0000 (no new caps,
  no errors latched; the host bridge has no capabilities list).
- **Class (08: `06000002`)** — Class 0x06 (bridge), subclass 0x00 (host bridge),
  prog-IF 0x00 → class code **060000**. Revision 0x02. Matches the MANIFEST.
- **Header (0C: `00000000`)** — Header type 0x00 (normal, single-function layout here),
  no BIST, latency timer 0, cacheline 0. No BARs (10–24 all zero): the host bridge is
  not memory-mapped — it is accessed only via its config registers and the legacy
  CF8/CFC PCI config mechanism it implements.
- **Subsystem (2C: `11001AF4`)** — Subsystem vendor 0x1AF4 (Red Hat/Qumranet),
  subsystem ID 0x1100 → confirms this is the QEMU/KVM virtual i440FX. (01:01.3 reports
  the same subsystem.)
- **PAM registers (58: `11111000`, 5C: `33111111`)** — the i440FX Programmable Attribute
  Map, which controls read/write routing (DRAM vs PCI/ROM) of the legacy 0xC0000–0xFFFFF
  region in 16 KB segments. Little-endian byte layout:
  - PAM0 (0x59)=0x10, PAM1 (0x5A)=0x11, PAM2 (0x5B)=0x11,
    PAM3 (0x5C)=0x11, PAM4 (0x5D)=0x11, PAM5 (0x5E)=0x11, PAM6 (0x5F)=0x33.
  - Each nibble is RE/WE (read-enable/write-enable) for a segment. 0x33 on PAM6
    (the 0xF0000–0xFFFFF System BIOS segment) = read+write enabled → **BIOS has been
    shadowed into DRAM** (copied from ROM to RAM and left writable). The 0x11 nibbles
    are option-ROM/video-BIOS segments shadowed read+write. This is normal
    post-BIOS-handoff state.
  - Register 0x54 area (`10000000`) sits just below PAM/DRB; low bytes zero.
- **SMRAM (70: `000A0000`)** — the SMRAMC register byte at 0x72 = 0x0A. This governs
  System Management RAM at 0xA0000–0xBFFFF for SMM. 0x0A → default/compatible SMRAM
  (D_OPEN clear, SMRAM present) — SMM memory is gated, not currently CPU-open.

**Summary:** a virtual i440FX host bridge, I/O+mem decode on, BIOS shadowed and
writable in DRAM via PAM, SMRAM present and gated. No BARs — pure config-register device.

---

## 2. 00:01.3 — PIIX4 ACPI / Power Management function (8086:7113)

Config space (dwords at offset):

```
00: 71138086   04: 02800103   08: 06800003   0C: 00000000
2C: 11001AF4   3C: 00000109
40: 00000601   58: 02000000   5C: 90000000   60: 60000000   64: 08000000
80: 00000001   90: 00000701   D0: 00090000
```

- **Identity (00: `71138086`)** — Vendor 0x8086, Device 0x7113 = Intel **82371AB/EB
  PIIX4** ACPI/Power-Management function. It is function 3 of the PIIX4 multi-function
  South Bridge (function 0 = ISA bridge 00:01.0, function 1 = IDE, function 2 = USB).
- **Command/Status (04: `02800103`)** — Command = 0x0103: bit0 I/O enable, bit1 mem
  enable, bit8 SERR#. Status = 0x0280: bit7 fast-back-to-back capable, bit9 **DEVSEL
  timing = medium**.
- **Class (08: `06800003`)** — Class 0x06 (bridge), subclass 0x80 ("other bridge
  device"), prog-IF 0x00 → class code **068000**. Revision 0x03. Matches the MANIFEST
  (ACPI functions don't fit a standard class, so they report 068000).
- **Interrupt (3C: `00000109`)** — Interrupt line = 0x09 (routed to **IRQ9**, the
  classic ACPI/SCI interrupt), interrupt pin = 0x01 (**INTA#**).
- **Subsystem (2C: `11001AF4`)** — same 0x1AF4/0x1100 QEMU subsystem as the host bridge.
- **PMBA — PM Base Address (40: `00000601`)** — the Power-Management I/O base. bit0=1
  marks it I/O space; masking the low bits gives base **0x0600**. The ACPI PM register
  block (PM1a_STS/EN, PM1_CNT, and the 24-bit **PM timer at 0x0600+0x08 = I/O 0x0608**,
  plus PM1 control and GPE blocks) lives here. This is the function's one real resource.
- **PMREGMISC (80: `00000001`)** — byte 0x80 bit0 = **PMIOSE (PM I/O Space Enable) = 1**:
  the PM base at 0x0600 is live and decoding. (Confirms the ACPI block is active.)
- **SMBA — SMBus Base Address (90: `00000701`)** — bit0=1 → I/O space; base **0x0700**.
  The PIIX4 integrates an SMBus host controller whose registers sit at I/O 0x0700.
- **SMB_HOSTC (D0: `00090000`)** — byte 0xD2 = 0x09 → SMBus host interface enabled with
  its interrupt/SMI configuration set.
- **Device-activity / GPE-routing bytes (58/5C/60/64: `02000000`/`90000000`/`60000000`/
  `08000000`)** — PIIX4 PM device-monitor / general-purpose-event and resume config
  registers in the 0x58–0x6F range; non-zero bytes 0x5B=0x02, 0x5F=0x90, 0x63=0x60,
  0x67=0x08 reflect firmware-programmed GPE/trap routing. Not safety-relevant to read.

**Summary:** the PIIX4 ACPI/PM function exposes two I/O windows — **PM/ACPI block at
0x0600** (PMIOSE-enabled, PM timer at 0x0608) and **SMBus at 0x0700** — and signals its
SCI on IRQ9/INTA#. This is the machine's power-management and system-event hub.

---

## 3. Subsystem decomposition — who would each deserve a sub-Agent

This chipset is the genome's "complex subsystem" case: the i440FX + PIIX south bridge
together form one organ with several distinct functional subsystems. If this organ were
to differentiate, the host-bridge Agent would spawn one child per subsystem below, each
with a narrowed target and the standard brief. (Division of labor only — not spawned.)

| Sub-Agent | Target | Why it deserves its own cell |
|-----------|--------|------------------------------|
| **host-dram** | 00:00.0 i440FX PAM/DRB/SMRAM | DRAM map, BIOS-shadow routing (PAM), SMRAM/SMM gating — a self-contained memory-layout model, unrelated to power or legacy I/O. |
| **isa-lpc-bridge** | 00:01.0 PIIX3 ISA bridge (8086:7000, 060100) | The gateway to all legacy I/O: PCI-to-ISA bridging, interrupt routing (PIRQ→IRQ), legacy address decode. Owns a whole bus below it. |
| **acpi-pm** (this one, could narrow) | 00:01.3 PM block @ 0x0600, PM timer, GPEs, SCI/IRQ9 | Power states, PM timer as a clock source, system-control-interrupt events — a behavior-rich I/O subsystem distinct from the SMBus on the same function. |
| **smbus** | PIIX4 SMBus host @ 0x0700 (SMBA/SMB_HOSTC) | A separate serial bus with its own protocol and attached devices (SPD EEPROMs, sensors); deserves its own enumeration and skills. |
| **legacy-timers-pic-pit** | 8254 PIT, 8259 PIC, RTC/CMOS behind the ISA bridge | The classic fixed-port legacy block (0x40–0x43 PIT, 0x20/0xA0 PIC, 0x70/0x71 RTC) — not PCI devices, reached only as I/O ports behind the ISA bridge; its own timing/interrupt specialty. |

Rationale per genome §1 replication rule: each subsystem has an independent register
model, a different driving discipline, and ideally its own read-only skill. One Agent
holding all of them would carry dead weight for any single task; dividing lets each
child emit exactly the knowledge + skill its narrow target needs, and the parent
integrates them.

---

## 4. Open questions

- PM timer: reading I/O 0x0608 (via `hw.py in`, but it's a 32-bit counter — `inb` only
  returns a byte) should show a free-running 3.579545 MHz counter. A proper read needs
  a 4-byte `in` primitive the kernel may not yet expose. Worth confirming.
- SMBus at 0x0700: what, if anything, is attached? Enumerating would need I/O reads of
  the SMBus host registers (read-only probe of status/data ports) — candidate for a
  smbus sub-Agent.
- PAM nibbles confirm BIOS is shadowed+writable in DRAM; is the shadow still consistent
  with ROM? A memory read of 0xF0000 could be compared — purely read-only.
- GPE/device-trap bytes (0x58–0x67) encode firmware power-event routing; decoding them
  fully needs the PIIX4 datasheet register map — left for the acpi-pm sub-Agent.
- SMRAMC=0x0A: SMRAM is gated (not CPU-open). Confirming D_LCK (locked) would tell
  whether firmware sealed SMM — a read-only check of byte 0x72 bit4.
