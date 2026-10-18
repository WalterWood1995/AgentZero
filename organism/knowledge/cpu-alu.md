# CPU — the ALU as a compute unit (ring-0 `A` command)

Target: the machine's own CPU (QEMU `-cpu` reports vendor **GenuineIntel**).
Driven through `hw.py` against the QEMU-hosted AgentZero kernel (127.0.0.1, UDP).
Unlike the NIC/MMIO organs, this "organ" is the processor itself: the kernel asks
the ALU to do real arithmetic in ring 0 and hands the result back over UDP.

## 1. Identity

- This is not a device on the PCI bus — it is the x86 ALU reached *through* the
  kernel. The kernel's `A` command decodes a tiny op-code + two 32-bit operands,
  runs the matching integer instruction sequence on the CPU, and returns the result.
- It is the organism's general compute primitive: give it a math problem, it computes
  it on the metal with no OS and no libc.

## 2. The command

Wire form (gated-free — a read-class op, no `!` confirm byte needed):

```
A<op><8 hex a><8 hex b>   ->   <hex result>
```

`hw.alu(op, a, b=0)` builds this and parses the hex reply to an int. Ops:

| op  | meaning            | uses b? |
|-----|--------------------|---------|
| `+` | a + b (low 32)     | yes     |
| `-` | a - b (low 32)     | yes     |
| `*` | a * b (low 32)     | yes     |
| `g` | gcd(a, b)          | yes     |
| `s` | sum 1..a           | no      |
| `f` | factorial a (low 32) | no    |

## 3. Semantics

- **32-bit, wrapping.** Every result is the low 32 bits (mod 2^32). Add/sub/mul can
  overflow and wrap silently — e.g. `0x7FFFFFFF + 1 = 0x80000000` (2147483648), still
  in range, but a true carry out of bit 31 is discarded. The Python truth it is
  checked against is therefore always masked `& 0xFFFFFFFF`.
- **Factorial must stay ≤ 12.** `12! = 479001600` fits in 32 bits; `13! = 6227020800`
  overflows and the low-32 result would no longer equal the real factorial. The skill
  caps at 12 on purpose.
- **gcd** is exact (Euclid); `sum 1..a` is the triangular number a(a+1)/2, also wrapping.

## 4. How it is driven

`organism/skills/cpu_math_answer.py` hands a handful of problems to the ALU via
`hw.alu`, computes each one in Python, and **asserts the old PC's answer equals the
Python truth** — so each line is a proof the CPU got it right. It then paints a titled
panel of problem→answer onto the old PC's 80×50 text screen with `hw.disp_clear` +
`hw.disp_lines` (title: "AgentZero - computed by this CPU, no OS").

## 5. VERIFIED results (QEMU run, 127.0.0.1:50021)

CPUID vendor came back **GenuineIntel**. All six problems: old-PC ALU answer ==
Python truth (asserts passed):

| problem            | ALU answer (old PC) | Python truth | match |
|--------------------|---------------------|--------------|-------|
| sum 1..100         | 5050                | 5050         | OK    |
| 12! (factorial)    | 479001600           | 479001600    | OK    |
| 65535 * 65535      | 4294836225          | 4294836225   | OK    |
| gcd(1071, 462)     | 21                  | 21           | OK    |
| 0x7FFFFFFF + 1     | 2147483648          | 2147483648   | OK    |
| 1000000 - 999991   | 9                   | 9            | OK    |

`65535 * 65535 = 0xFFFE0001 = 4294836225` exercises the full 32-bit multiply result;
`0x7FFFFFFF + 1 = 0x80000000` sits right at the sign-bit boundary. The panel was then
rendered on the old PC's screen and captured by screenshot — the title, all six
`label = answer [CPU==truth]` rows, and the footer are legible on the green-on-black
VBE text console.

## 6. Open questions / next steps

- Only low-32 results are observable; a 64-bit-result path (e.g. EDX:EAX from `mul`,
  or a wider factorial) would need a kernel op that returns both halves.
- Division / modulo and bitwise ops are not yet exposed by the `A` command — natural
  additions if the organism needs a richer calculator.
- This organ is a building block: the same ALU already backs the fixed-point Fourier
  epicycle evaluator (`E` command) — see `fourier.py` / `skills/fourier_dario.py`.
