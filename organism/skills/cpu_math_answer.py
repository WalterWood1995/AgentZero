#!/usr/bin/env python3
# skills/cpu_math_answer.py - the organism USES the old PC as a compute unit.
#
# THE OLD PC'S CPU DOES THE MATHS: every problem below is handed to the machine's
# ALU through the kernel's gated-free ring-0 `A<op><8hex a><8hex b>` command (via
# hw.alu). The dev PC computes the SAME answer in Python and ASSERTS they match, so
# each line is a proof that the old PC's CPU got the arithmetic right. Then it paints
# a clean titled panel of the problems and the CPU's answers onto the old PC's screen
# (hw.disp_clear + hw.disp_lines) - no OS, no libc, just the ALU and 80x50 text.
#
# All results are 32-bit (the ALU wraps mod 2^32). Factorial is kept <= 12 because
# 13! overflows 32 bits.
#
# Usage (drive a running kernel):
#   python skills/cpu_math_answer.py [ip]        # ip defaults to 127.0.0.1 (QEMU)
# Importable with no side effects: `from cpu_math_answer import run, PROBLEMS`.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW

MASK = 0xFFFFFFFF


def _fact(n):
    r = 1
    for i in range(2, n + 1):
        r *= i
    return r


def _gcd(a, b):
    while b:
        a, b = b, a % b
    return a


# Each problem: (op, a, b, label, truth) - truth is the Python-computed answer,
# masked to 32 bits exactly as the old PC's ALU returns it.
PROBLEMS = [
    ("s", 100, 0, "sum 1..100",        (100 * 101 // 2) & MASK),
    ("f", 12,  0, "12! (factorial)",   _fact(12) & MASK),
    ("*", 65535, 65535, "65535 * 65535", (65535 * 65535) & MASK),
    ("g", 1071, 462, "gcd(1071, 462)",  _gcd(1071, 462)),
    ("+", 0x7FFFFFFF, 1, "0x7FFFFFFF + 1", (0x7FFFFFFF + 1) & MASK),
    ("-", 1000000, 999991, "1000000 - 999991", (1000000 - 999991) & MASK),
]

TITLE = "AgentZero - computed by this CPU, no OS"


def compute(hw):
    """Hand every problem to the old PC's ALU, assert its answer == Python truth.
    Returns (ok, rows) where rows are display-ready 'label = answer' strings."""
    rows = []
    ok = True
    for op, a, b, label, truth in PROBLEMS:
        got = hw.alu(op, a, b)
        match = (got == truth)
        ok &= match
        assert match, ("old PC's ALU got %s wrong: op=%r a=%d b=%d -> %r, expected %d"
                       % (label, op, a, b, got, truth))
        rows.append("%-22s = %-12d  [CPU==truth]" % (label, got))
        print("  %-22s -> %-12d  (truth %-12d) %s"
              % (label, got, truth, "OK" if match else "MISMATCH"))
    return ok, rows


def show(hw, rows):
    """Paint the titled answer panel on the old PC's screen."""
    bar = "=" * 56
    lines = [TITLE, bar]
    lines += ["  " + r for r in rows]
    lines += [bar, "  every answer above was computed on this machine's ALU."]
    hw.disp_clear()
    hw.disp_lines(2, lines)


def run(ip="127.0.0.1"):
    hw = HW(ip)
    vendor = hw.cpuid_vendor()
    print("CPU vendor:", vendor)
    print("asking the old PC's ALU to compute %d problems:" % len(PROBLEMS))
    ok, rows = compute(hw)
    print("all asserts passed -> the old PC's CPU matched Python on every problem."
          if ok else "a problem did not match (should have asserted).")
    show(hw, rows)
    print("painted the answer panel on the old PC's screen.")
    return ok


if __name__ == "__main__":
    a = sys.argv[1:]
    ip = a[0] if a and a[0].count(".") == 3 else "127.0.0.1"
    run(ip)
