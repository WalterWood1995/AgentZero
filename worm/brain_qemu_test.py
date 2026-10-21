#!/usr/bin/env python3
"""brain_qemu_test.py - bit-exact check of the kernel's brain step against wormsim.

Boots the default (network) kernel in QEMU (pxe_brain_dev.img: `OUT=brain_dev bash
build.sh`), loads worm/data/brain.bin into the compute window with the L command,
sends nI (expand), then for N steps: loads the step's EXT vector (L), sends nS0001
and compares v[] / spike bitmap / gi with the Python reference. Both kernel paths
are checked: SSE2 dense (nM0) and scalar sparse (nM1).

Usage: QEMU=<qemu-system-i386> python worm/brain_qemu_test.py [steps]
"""
import os, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BM = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(BM, "organism"))
UDP_PORT = int(os.environ.get("WORM_UDP_PORT", "50031"))
QMP_PORT = int(os.environ.get("WORM_QMP_PORT", "55581"))
os.environ["AGENTZERO_PORT"] = str(UDP_PORT)       # hw.py reads it at construction

from qemu_dev import QemuKernel
from hw import HW
from wormsim import Brain

BR_BLOB, BR_V, BR_S, BR_EXT, BR_A = 0x100000, 0x104800, 0x104C00, 0x105000, 0x105400


def stim_for(b, t):
    """A deterministic stimulus schedule that exercises every path: tonic bias,
    head touch, tail touch, chemo OFF cells, and quiet stretches."""
    e = b.bias_ext()
    def add(slot, val):
        e[b.stim[slot]] = np.int16(min(32767, int(e[b.stim[slot]]) + val))
    if 20 <= t < 50:
        add(0, 300); add(1, 300); add(2, 300)
    if 80 <= t < 110:
        add(3, 300); add(4, 300)
    if 140 <= t < 180:
        add(6, 150 + (t % 7) * 20); add(7, 100); add(8, 100)
    if t % 13 == 0:
        add(11, 50)
    return e


def run(hw, steps, mode):
    b = Brain()
    r = hw._raw(b"nI")
    assert r and r[:2] == b"nI", "nI failed: %r" % r
    assert int.from_bytes(r[2:4], "little") == b.nsyn, "nsyn mismatch"
    r = hw._raw(("nM%d" % mode).encode())
    assert r == b"nM", "nM failed: %r" % r
    maxdiff = 0
    worst = None
    t0 = time.time()
    for t in range(steps):
        e = stim_for(b, t)
        b.ext = e
        assert hw.load(BR_EXT, e.astype("<i2").tobytes(), chunk=800, verify=False), "L ext failed at step %d" % t
        b.step()
        r = hw._raw(b"nS0001")
        assert r and len(r) == b.NR * 2 + b.NR // 8 + 2, "nS reply %r" % (r and len(r))
        kv = np.frombuffer(r[:b.NR * 2], dtype="<i2")
        bits = np.unpackbits(np.frombuffer(r[b.NR * 2:b.NR * 2 + b.NR // 8], dtype=np.uint8), bitorder="little")
        kgi = int.from_bytes(r[-2:], "little", signed=True)
        d = int(np.abs(kv.astype(np.int32) - b.v.astype(np.int32)).max())
        sd = int(np.abs(bits.astype(np.int32) - (b.s != 0).astype(np.int32)).max())
        gd = abs(kgi - b.gi)
        m = max(d, sd, gd)
        if m > maxdiff:
            maxdiff = m
            worst = (t, d, sd, gd, int(np.argmax(np.abs(kv.astype(np.int32) - b.v.astype(np.int32)))))
        if m and worst and worst[0] == t and t < 3:
            print("  step %d: v diff %d sd %d gi %d (kernel gi %d ref %d)" % (t, d, sd, gd, kgi, b.gi))
    dt = time.time() - t0
    fired = int((b.s != 0).sum())
    print("mode %d (%s): %d steps in %.1fs, maxdiff=%d%s, ref fired last step %d, gi %d"
          % (mode, "SSE2 dense" if mode == 0 else "scalar sparse", steps, dt, maxdiff,
             "" if worst is None else " worst@%s" % (worst,), fired, b.gi))
    return maxdiff


def main():
    steps = int(sys.argv[1]) if len(sys.argv) > 1 else 240
    ok = True
    with QemuKernel(udp_port=UDP_PORT, qmp_port=QMP_PORT, img="pxe_brain_dev.img", boot_wait=12.0) as k:
        hw = HW("127.0.0.1", port=UDP_PORT, timeout=3.0)
        assert hw.cpuid_vendor(), "kernel not answering"
        blob = open(os.path.join(HERE, "data", "brain.bin"), "rb").read()
        assert hw.load(BR_BLOB, blob, chunk=512), "L blob failed"
        print("loaded brain.bin (%d B) at 0x%X" % (len(blob), BR_BLOB))
        for mode in (0, 1):
            md = run(hw, steps, mode)
            ok &= (md == 0)
        # the dense path must also agree with the sparse path on the same state: run
        # 50 more steps alternating the mode every step
        b = Brain()
        hw._raw(b"nI")
        for t in range(50):
            hw._raw(("nM%d" % (t & 1)).encode())
            e = stim_for(b, t + 20); b.ext = e
            hw.load(BR_EXT, e.astype("<i2").tobytes(), chunk=800, verify=False)
            b.step()
            r = hw._raw(b"nS0001")
            kv = np.frombuffer(r[:b.NR * 2], dtype="<i2")
            if int(np.abs(kv.astype(np.int32) - b.v.astype(np.int32)).max()):
                ok = False; print("alternating modes: mismatch at step", t); break
        else:
            print("alternating SSE2/scalar every step: 50 steps, maxdiff=0")
    print("ALL PASS (maxdiff=0)" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
