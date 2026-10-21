# AgentZero: a laptop with no operating system, as a bare-metal body for AI

> A scrapped 2009 laptop that cannot even boot Linux. Instead of installing anything, we wrote an x86
> bare-metal kernel from scratch and made the machine run a real animal's whole brain, draw your face
> with its own neural network, and take orders from an AI over the network.
> Open source (MIT): https://github.com/WalterWood1995/AgentZero

## What it is

AgentZero is a **bare-metal kernel built for AI agents**: no operating system, no driver stack, no runtime,
not a line of C. A 32-bit x86 kernel written from scratch drives the hardware directly, and an agent reads
and writes the machine's CPU, memory, PCI configuration space, I/O ports and framebuffer over the network
through a **ring-0 instruction set**. The machine does three things only: pull the kernel over the network
at boot, execute instructions, and write results back to the network or the screen.

It began with a 2009 Asus K50IJ (Core 2 Duo T4300, 2 GB RAM, GMA 4500M graphics, Atheros AR8131 NIC,
a German keyboard). Its SATA controller hangs every Linux during storage probing at boot — by any normal
standard the machine is dead. So we **bypass storage entirely**: PXE network boot, a kernel that never
touches the disk, and the machine is as stable as new.

## What it already does

- **Self-reporting hardware at boot**: a PCI scan lists the real chipset on screen; the dev PC reads CPUID,
  RTC, PCI, physical memory and I/O ports over UDP, with gated write primitives against accidents.
- **The old machine does the maths**: a fixed-point Fourier series on its CPU draws the world map and portraits frame by frame.
- **A bare-metal chat terminal and web reader**: type on the old keyboard, read the AI's answers and Wikipedia pages on its screen.
- **A 60 fps game console**: PS/2 key-state table, PIT-timed frame loop, Pong and a two-player fighter.
- **The worm brain** (chapter one of the film).
- **A live ASCII portrait and the old machine's own neural network** (chapter two).

## Chapter one: a real animal's whole brain

*C. elegans* is the only animal with a complete public connectome: 302 neurons, about ten thousand
synapses (OpenWorm tables, MIT licence; underlying data White 1986 / Varshney 2011).

- **Data**: a host script compacts the connectome into an 8 KB sparse table baked into the kernel image;
  at boot the kernel expands it into a 400×304 int16 dense matrix.
- **Compute**: two integrate-and-fire steps per frame with SSE2 `pmaddwd` — synaptic sum, leak, threshold,
  refractory reset, spike-frequency adaptation, global inhibition — 120 steps per second, entirely on the
  2009 dual-core CPU. A bit-exact Python reference exists; both kernel compute paths (SSE2 dense and scalar
  sparse) match it with **maxdiff = 0**.
- **The model's output is the action**: the spike difference between A-class and B-class motor neurons sets
  backward or forward motion; the membrane potentials of 96 body-wall muscle rows bend each body segment;
  touch neurons ALM/AVM/PLM receive pokes and the dish wall, chemosensory neurons ASEL/ASER/AWC receive rising
  and falling food concentration, pharyngeal neurons NSM/MC are driven on food — so it reverses, surges,
  follows the gradient, slows down and eats with its pharyngeal pump.
- **Visualisation**: the right half of the screen draws the 302 neurons as a layered network with synapses
  as wires that flash when a neuron fires — you watch activity propagate through the real connectome.

Honest caveat: this is a **qualitative cartoon**. The wiring is real; the neuron dynamics are a simplified
LIF model. The raw weights alone either stay silent or avalanche, so three homeostatic mechanisms (row
normalisation, spike-frequency adaptation, global inhibition) and three literature-based assumptions (the
Chalfie 1985 touch escape circuit, mutual inhibition of the forward/backward command neurons, the Gray 2005
lost-the-scent pirouette circuit) were added and are documented with the data.

## Chapter two: it draws your face with its own neural network

The dev PC's camera films a face and sends only grey-level cells to the old machine over UDP (about 4 KB per
frame). **The characters are computed by the old machine itself**: inside the kernel runs a tiny MLP —
9 grey values from a 3×3 neighbourhood in, 32 hidden units, 16 glyphs out — int16 fixed point, 1.8 KB of
weights. 12,288 cells per frame are inferred one by one, all in ring-0 assembly, 10 frames per second on the
real machine, **bit-exact against the Python reference, cell for cell**. The side panel shows the model at
work live: the probe cell's input, hidden layer, output scores, the W1/W2 weight maps, the multiply-adds.
The same screen can also put your face next to the worm brain, with your movements as its sensory input.

## Why this way

- **Remove the software layers**: no OS, no drivers, no runtime — the agent faces the hardware directly.
  Both efficiency and understandability come from that.
- **An old machine is network-controllable bare-metal compute**: as long as the CPU and the NIC are alive, a
  "scrapped" machine can serve as a body and a compute unit for an AI.
- **A local neural network as action**: the model runs on the old CPU and its output becomes the action
  directly — the worm's motion, the characters on the screen — with no layer in between.
- **Verifiable end to end**: every computation is checked against a Python ground truth (maxdiff = 0,
  bit-exact cells), every behaviour has an unattended QEMU test.

## How to run it

- Toolchain: NASM + QEMU (portable Windows builds are enough); `bash build.sh` builds the kernel,
  `WORM=1 bash build.sh` builds the petri-dish kernel.
- Development: `python worm/brain_qemu_test.py` (bit-exact check), `python worm/worm_qemu_test.py`
  (behaviour acceptance and frame recording).
- Real machine: `pxe_server.py` (proxyDHCP + TFTP) stays running, the old machine boots from the network
  first, and swapping the kernel is copying one file.

## Next

- The Drosophila larva brain (~3,000 neurons, ~550,000 synapses): still real-time on the old CPU once sparse.
- A native NIC driver (AR8131): leave the resident PXE stack behind for a faster, steadier channel.
- More "the model's output is the action" experiments: let the old machine's neural network operate its own hardware.

## Credits and sources

- Worm connectome: the OpenWorm project (MIT); underlying data White et al. 1986, Chen/Hall/Chklovskii 2006,
  Varshney et al. 2011, WormAtlas.
- Face landmarks: MediaPipe.
- Everything else (kernel, neural networks, body model, visualisation, tests, shooting and editing scripts)
  was written for this project, MIT licence.
