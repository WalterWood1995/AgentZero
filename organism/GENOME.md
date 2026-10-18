# AgentZero Organism — the Agent generation mechanism ("genome")

A living, self-organizing society of Agents that *understand* and *operate* a bare
machine's hardware, with no operating system. Agents are born, specialize, replicate
into sub-Agents for complex subsystems, and leave behind understanding and skills
that accumulate — until the whole becomes an organism that is, functionally, an OS
and its applications, grown rather than written.

This file is the genome: the rules every Agent is born with.

## 1. An Agent is a cell

Each Agent is bound to one hardware **target** (a device, or a subsystem of one) and
is made of four parts:

- **Senses + hands** — `hw.py`, and only `hw.py`. It wraps the kernel's ring-0
  instruction set over UDP: CPUID, PCI config read, physical-memory read, I/O-port
  read, RTC, (gated) I/O-port write, (gated) physical-memory / MMIO dword write,
  framebuffer write. This minimal, universal
  "read/write hardware" interface is the Agent's entire contact with the metal.
  There is no generic OS abstraction in between — that is the source of the
  efficiency: the Agent programs exactly what the task needs.
- **Brain** — Claude. Given the target, the probe data, and its own knowledge of
  computer architecture, it reasons about what the device is, how it works, and
  which operations are useful and safe.
- **Output** — two artifacts it leaves in the shared body:
  - `knowledge/<slug>.md` — a model of the target: identity, registers/capabilities,
    how it works, how to drive it, open questions.
  - `skills/<slug>.py` — a concrete, replayable operation on the target (built on
    `hw.py`), with a safety gate. A skill is understanding made executable. A skill
    is either **read-only** (probes, never changes state) or a **gated write skill**
    (see section 4.1): it changes hardware state, so it must declare exactly which
    writes it makes and why they are safe, and it refuses to run until armed.
- **Replication rule** — if the target is too complex to understand as one unit (a
  CPU, a GPU), the Agent **decomposes** it into subsystems and **spawns one child
  Agent per subsystem**, each inheriting context and a narrowed target. Children
  report back; the parent integrates their knowledge. (A cell dividing into a tissue.)

## 2. Shared body = the growing genome + memory

- `knowledge/` and `skills/` are shared by all Agents and persist. A new Agent is
  *born from* this store (it reads what relatives already learned) and *writes back*
  to it. Successful skills sediment into the organism's repertoire.
- `MANIFEST.md` (built by the Explorer) is the body map: every device found, and
  which Agent owns it.

## 3. Lifecycle

1. **Explorer** (the first Agent) opens the organism's eyes: `hw.py pci-scan` +
   CPUID enumerate the whole machine, written to `MANIFEST.md`.
2. For each device, the Explorer **spawns a Device Agent** with the standard brief
   (section 5). Independent devices are explored **in parallel** (many cells at once).
3. A Device Agent probes its target with `hw.py`, reasons, and emits knowledge + a
   skill. If its target is complex, it spawns **sub-Agents** per subsystem.
4. Knowledge and skills accumulate. Higher-level **application** functions (a text
   editor, a media player, a file mover) are later composed by a coordinator that
   wires existing device-skills together — organs forming an organ system.

## 4. Safety (the organism must not harm its own body)

- Probing is **read-only** by default: PCI config read, memory read, I/O read. These
  cannot damage hardware. An Agent does these freely.
- Any **write** (I/O-port write, memory write, device programming) is **gated**: the
  kernel requires a confirm byte, and an Agent proposes writes as a skill for review
  before they are armed. No Agent writes to hardware it does not yet understand.
- The SATA/AHCI storage controller is **off-limits** (it is what hangs this machine's
  Linux). Agents enumerate it in PCI space but never initialize or write it.

### 4.1 Gated write skills — how the organism *operates* hardware

Understanding is read-only; operation is writing. The step from one to the other is
deliberate and reviewed, never incidental. A write skill is born in four stages:

1. **Propose.** The Agent writes `skills/<slug>.py` that states, up front and in
   words, the *exact* writes it will make (each address/port and value), *why each
   one is safe* (what the register does, why this value cannot brick or hang the
   device, and how it is reversed), and what it will read back to *prove* the write
   landed. It targets only hardware the organism already understands (there is a
   `knowledge/` note for it). It never touches the SATA/AHCI controller.
2. **Review.** A human (or a coordinator Agent) reads the proposal and checks the
   writes against the knowledge note. This is the moment the SATA rule and the
   "only what you understand" rule are enforced.
3. **Arm.** The skill will not write until it is explicitly armed — it requires
   `--arm` on the command line (or `ARM=1` in the environment). Unarmed, it prints
   the plan and the gate self-test only (it shows that an *unconfirmed* write is
   refused by the kernel) and exits without changing anything. This makes a dry run
   the default and an accidental write impossible.
4. **Execute.** Armed, the skill issues each write through the kernel's confirm-byte
   gate (`hw.outb(...)` / `hw.write32(...)`, which send the trailing `!`), then reads
   back to verify, and — where the operation is meant to be transient — restores the
   previous state so the machine is left as it was found.

Two write primitives reach the metal, both gated in the kernel (the kernel refuses a
write whose command lacks the `!` confirm byte, so nothing writes by accident):

- **`hw.outb(port, val)`** — one byte to an I/O port (kernel `O<port><val>!`).
- **`hw.write32(addr, dword)`** — one dword to a linear/physical address, which
  reaches both plain RAM and memory-mapped device registers such as a NIC's BAR0
  MMIO block (kernel `W<addr><dword>!`).

Device programming (descriptor rings, control registers) is built from these. The
rule of thumb for "safe": prefer registers that are plain read/write and observable
(write a value, read it back); do not set enable/reset/bus-master bits on a device
until a reviewed skill has established that doing so is safe; keep the first
operations reversible; and verify the device is still healthy (e.g. NIC link still
up) after writing.

## 5. The Device Agent brief (the template every Agent is born with)

> You are a hardware-understanding Agent in the AgentZero organism, bound to ONE
> target: **<device>** (`<bus:dev.fn> <vendor>:<device> class <class>`), on a
> bare-metal machine with no OS, reachable only through `hw.py` (ring-0 primitives
> over UDP to <ip>).
>
> 1. Probe it (READ-ONLY): `python organism/hw.py <ip> cfg <bus> <dev> <fn>` for its
>    full PCI config space; `pci`, `mem`, `in` for specific reads. Never write.
> 2. Identify it (vendor/device/class, what chip, what it does) and read its config
>    space: BARs, capabilities, status — explain what you see.
> 3. Write `organism/knowledge/<slug>.md`: identity, what it is, how it works, the
>    registers/capabilities you found, how one would drive it, and open questions.
> 4. If you found a safe, useful read-only operation, write `organism/skills/<slug>.py`
>    (built on `hw.py`) that performs it and prints a result.
> 5. If the device is too complex for one Agent, list the subsystems that each
>    deserve their own sub-Agent, and (if asked to) spawn them.
>
> You touch the metal ONLY through `hw.py`. You never write to hardware. Be concrete:
> cite the actual bytes/dwords you read.

## 5.1 Compute organs and applications

The organism not only *senses* and *operates* hardware — it *computes* with it. The
machine's own CPU is a compute organ the Agent drives on demand:

- **ALU** — the kernel's `A<op><a><b>` command makes the CPU evaluate a math problem
  (add/sub/mul, gcd, sum, factorial) and return the answer. `hw.alu(...)`.
- **Fixed-point evaluators** — for maths too heavy to do one op at a time over the
  link, the Agent preloads data into the machine's RAM (`hw.load`, the gated `L`
  bulk-write bounded to a scratch window) and the kernel runs a tight integer loop on
  the CPU. The first such evaluator is the Fourier epicycle series (`E` command,
  `hw.fourier(t)`): the Claude brain supplies the *method* (a portrait's contour →
  DFT → fixed-point coefficients + an integer sine table), and the old PC's CPU does
  the real per-frame maths.

An **application** is an organ system: a function composed from device-, compute-,
and display-skills. The first application, **the Fourier portrait**, wires three
together — the CPU computes the epicycle chain each frame (compute organ), the dev
side turns the returned points into pixels (method/brain), and the VBE framebuffer
shows the drawing (display organ). The brain designs; the machine runs and shows.

## 6. Why this beats an OS

An OS ships generic, one-size-fits-all drivers and abstractions, carrying overhead
for cases a given machine never hits. This organism grows understanding of *this*
machine's *actual* hardware and emits skills that do *exactly* what is needed — and
it carries intelligence an OS never has (it can reason, improvise, and specialize).
Fewer layers, no dead weight, and a brain in the loop.
