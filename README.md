# AgentZero

**A from-scratch, OS-less x86 kernel that an AI agent drives at ring 0 — over the network.**

AgentZero turns a bare PC into a headless agent terminal: it boots with no operating
system, enumerates its own hardware, and listens for one-letter *hardware instructions*
over UDP. An agent on another machine sends a command, the kernel executes it directly on
the metal (CPUID, PCI config, port I/O, physical memory, RTC, gated port writes) and sends
the result back — with a Matrix-style green binary-rain UI on the screen for good measure.

No operating system. No NIC driver (it borrows the firmware's PXE UDP stack). No serial
cable. Just the CPU, the chipset, and the agent.

![AgentZero running on real hardware](docs/images/real-hardware.jpg)

> *Above: AgentZero booted over the network on a 2009 Asus K50IJ laptop — PCI self-scan,
> banner, and the ambient binary rain, all in ring 0 with no OS.*

---

## Why

It started with an old Asus K50IJ that could no longer boot its Linux (antiX) reliably —
it kept hanging while the kernel probed the SATA/AHCI controller. The bet: a tiny
self-written kernel that **never touches the disk** might boot where the full OS stalls,
and could serve as an unattended, agent-controlled hardware terminal.

The bet paid off. AgentZero boots the old laptop fine (it enumerates the SATA controller
in PCI space but never initializes it), and an agent now drives it live over the LAN.

## Features

- **32-bit protected mode**, flat 4 GiB segments, ring 0, no interrupts (polled).
- **Self-scanning**: on boot it enumerates PCI (mechanism 1) and prints every device as
  `bus:dev.fn vendor:device class` — the kernel tells you what hardware it's on.
- **The AgentZero ISA** — a compact hardware instruction set (see below).
- **Two control channels**:
  - **Serial** (COM1) for development under QEMU.
  - **Network (UDP)** on real hardware, via the resident **PXE UDP API** — no NIC driver.
- **PXE network boot** — iterate without ever re-flashing a USB stick: rebuild, and the
  machine pulls the new kernel on its next network boot.
- **USB / raw-disk boot** too (LBA with CHS fallback).
- **Matrix UI**: a binary digital-rain intro and an ambient rain behind the terminal;
  each command is echoed as 8-bit binary before it runs.

![PCI self-scan](docs/images/pci-selfscan.png) ![Binary rain](docs/images/rain.png)

## The AgentZero ISA

Each command is one line; the reply ends with CRLF.

| Cmd | Form | Does |
|-----|------|------|
| `C` | `C` | CPUID leaf 0 vendor string (e.g. `GenuineIntel`) |
| `F` | `F` | CPUID leaf 1 EAX (family/model/stepping) |
| `I` | `I<4hex port>` | `inb` from an I/O port → `=XX` |
| `T` | `T` | RTC time from CMOS (ports 70/71), `HH:MM:SS` BCD |
| `M` | `M<8hex addr><2hex len>` | read linear memory, hex dump (flat 4 GiB) |
| `P` | `P<2hex bus><2hex dev><1hex fn><2hex off>` | PCI config dword (0xCF8/0xCFC) |
| `O` | `O<4hex port><2hex val>!` | **gated** `outb` — the trailing `!` confirm byte is required |
| `?` | `?` | list commands |

`O` is the only write. Everything else is read-only probing; the mandatory `!` confirm
byte keeps an agent from firing a dangerous port write by accident.

The agent also drives the screen directly with display commands (no reply):

| Cmd | Form | Does |
|-----|------|------|
| `X` / `R` | `X` / `R` | clear the screen / resume ambient rain |
| `D` | `D<text>` | write a line |
| `S` | `S<2hex row><2hex col><text>` | write text at (row, col), idempotent |
| `B` | `B<2hex startrow>⏎<lines>` | block write: each line at (startrow + i, 0) |

## The agent chat terminal

Beyond one-letter probes, AgentZero runs as a full **network chat terminal** — the machine
becomes the agent's face and keyboard, with no OS underneath:

- It boots into a **portrait avatar** rendered as ASCII (baked into the kernel as
  `face_data.inc`, rendered from a photo by `gen_facedata.py`) on the right, after a Matrix
  rain intro that zooms and condenses into the face.
- You **type a question on the machine's own keyboard** — a from-scratch PS/2 8042 driver
  (German QWERTZ map, hardware text cursor). Keystrokes leave the box as raw UDP.
- A service on the dev PC answers and sends the text back; the kernel paints it on the
  **left** while the face stays on the right.

```bash
python agent_chat.py     # dev PC: answers questions on UDP 50001, replies to :50000
```

Answers come from **Claude** (the Anthropic API) in character and sized for the 40-column
screen, with a graceful fall-back to canned replies when no key is set. Put the key in
`ANTHROPIC_API_KEY` or a gitignored `api_key.txt` (org-scoped keys also need
`ANTHROPIC_WORKSPACE_ID` / `workspace_id.txt`).

It also has a tiny **browser skill**: type `web <domain>` on the machine's own keyboard
(e.g. `web en.wikipedia.org`, all lowercase + a dot, so no Shift keys are needed) and the
page is fetched, boiled down by Claude, and painted on the left of the screen. From the dev
PC: `python web.py <url>`.

**Talking face**: the dev PC reads each answer aloud through Windows SAPI (an English voice),
and while it speaks, `face_anim.py` flaps the ASCII portrait's mouth on the screen with
positioned `S` writes - so the face has a voice *and* moves its mouth, then closes it when
done. All driven over UDP, no kernel change. Mute the voice with `AGENTZERO_TTS=0`; tune the
mouth with `MOUTH_ROWS` / `MOUTH_C0` / `MOUTH_C1`.

Three real-hardware gotchas, all fixed here:

- **The BIOS steals your keystrokes.** Polling the 8042 from protected mode drops keys: the
  PXE UDP calls briefly return to real mode with interrupts on, and the real-mode BIOS
  INT 09h handler reads port 0x60 first. Fix — disable the keyboard IRQ1 (8042 command-byte
  bit 0) and mask IRQ1 at the PIC, so scancodes wait in the output buffer for the poll.
- **`PXENV_UDP_WRITE` sends nowhere with `gw = 0`** on this old UNDI stack, even on-subnet.
  Fix — set the gateway field to the destination IP.
- **Windows kills the UDP service on reply.** `sendto` to a port with no listener returns an
  ICMP port-unreachable that makes the *next* `recvfrom` raise `WinError 10054`. Fix — ignore
  it and keep serving.

## Build

Needs [NASM](https://www.nasm.us/). Point to it with `NASM=` or have `nasm` on `PATH`:

```bash
NASM=/path/to/nasm bash build.sh
```

Produces `disk.img` (USB / raw disk) and `pxe.img` (PXE network boot).

## Run in QEMU

Set `QEMU` to your `qemu-system-i386` (or have it on `PATH`), then:

```bash
# serial REPL (dev)
python agent_repl.py C F I0064 T P0000000 "O0080AB!" "?"

# network boot + UDP command channel, end to end
python pxe_udp_test.py 8 C F P0000000

# grab a screenshot of the self-scan / Matrix screen
python scan_shot.py shot.png
```

## Network boot a real machine (no more USB flashing)

1. Enable the NIC's PXE boot ROM in the BIOS (on the Asus: *Boot → Onboard LAN Boot ROM →
   Enabled*).
2. On your dev PC, run the tiny proxyDHCP + TFTP server (it doesn't hand out IPs — your
   router keeps doing that — it only tells PXE clients where to fetch `pxe.img`):

   ```bash
   python pxe_server.py 192.168.x.y      # your dev PC's LAN IP
   ```
   Allow inbound UDP 67/68/69/4011 through the firewall.
3. Boot the target, pick **Network** (F8 / F12). It pulls `pxe.img` over TFTP and runs it.
4. Drive it over UDP (the kernel listens on port 50000):

   ```bash
   python udp_agent.py 192.168.x.z C F P0000000 M00007DFC04 "?"
   ```

To iterate: edit, `bash build.sh`, network-boot again. The USB stick never comes out.

## USB boot

Write `disk.img` raw to a USB stick (e.g. with `dd`, Rufus in DD mode, or `burn_usb.ps1`
on Windows — it has safety gates and asks for the disk number), set the BIOS to boot it in
Legacy/CSM mode, and go.

## How it works

- **stage1.asm** — 512-byte boot sector; loads stage2 via INT 13h (LBA, CHS fallback).
- **pxe_stage1.asm** — PXE variant; the firmware loads the whole image to 0x7C00, this
  stub relocates stage2 to 0x8000 so the *same* `stage2.bin` boots from USB or network.
- **stage2.asm** — the kernel: enables A20, builds a flat GDT, enters 32-bit protected
  mode, self-scans PCI, and runs the command loop (serial REPL, or the UDP net loop on a
  PXE-booted machine). It calls the PXE UDP API by briefly dropping back to real mode
  (16-bit GDT segment → clear PE → restore the real-mode IVT → far-call the PXENV+ entry →
  back to PM). Timing uses the free-running PIT channel 0, so animations run at the same
  speed in QEMU and on real silicon.

Host-side tooling: `agent_repl.py` (serial), `udp_agent.py` (network), `agent_chat.py`
(the chat answer service), `pxe_server.py` (proxyDHCP+TFTP), `ascii_art.py` /
`gen_facedata.py` (render a photo to the ASCII avatar), `face.py` (push a face over UDP),
`pxe_qemu_test.py` / `pxe_udp_test.py` / `scan_shot.py` / `matrix_shot.py` /
`kbd_qemu_test.py` / `face_qemu_test.py` (QEMU harnesses), `burn_usb.ps1` (USB writer).

## Status

Proven end to end on real hardware: an agent on a PC driving a bare-metal Asus K50IJ over
the LAN, reading its real chipset live — and now a full chat terminal, where you type a
question on the laptop's own keyboard and the agent answers on its screen, all with no OS.
Display is driven by idempotent positioned/block writes, which fixed the earlier
packet-drop rough edge. Treat this as a working research kernel, not production.

## License

MIT — see [LICENSE](LICENSE).
