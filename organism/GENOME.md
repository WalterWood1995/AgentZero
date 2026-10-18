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
  read, RTC, (gated) I/O-port write, framebuffer write. This minimal, universal
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
    `hw.py`), with a safety gate. A skill is understanding made executable.
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

## 6. Why this beats an OS

An OS ships generic, one-size-fits-all drivers and abstractions, carrying overhead
for cases a given machine never hits. This organism grows understanding of *this*
machine's *actual* hardware and emits skills that do *exactly* what is needed — and
it carries intelligence an OS never has (it can reason, improvise, and specialize).
Fewer layers, no dead weight, and a brain in the loop.
