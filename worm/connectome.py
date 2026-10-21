#!/usr/bin/env python3
"""connectome.py - C. elegans connectome -> the AgentZero "brain image".

Source data: OpenWorm `CElegansNeuronTables.xls` (sheets Connectome /
NeuronsToMuscle / Sensory), MIT licence - see worm/data/SOURCES.md.

Output (worm/data/):
  neurons.csv   index,name,group,class     (302 neurons; CANL/CANR have no wiring)
  synapses.csv  src,dst,kind,n,nt,weight   (chemical / gap / neuromuscular)
  brain.bin     the compact CSR blob the kernel expands into a dense int16 matrix
  brain.inc     the same blob as NASM `db` lines (baked into the WORM kernel)
  brain.json    index tables + parameters (read by wormsim.py / the tests)

Model (shared by the kernel's brain.asm and wormsim.py - keep them identical):
  rows 0..301 neurons, 302..303 pad, 304..399 muscles (MDL01-24, MDR01-24,
  MVL01-24, MVR01-24); columns 0..303 = presynaptic neurons.
  W[row][col] int16 = sum over table entries of n * scale(neurotransmitter).
  Each step: acc = W . s  (int32 wrap)   ->  inp = sat16(acc >> W_SHIFT) +sat ext
             v   = sat16(v - (v >> LEAK_SHIFT) + inp), v = max(v, VMIN)
             fire = v >= THR[row];  s' = SPIKE if fire else 0;  v = RESET if fire
Muscle rows have THR = 0x7FFF (never fire): their v is a leaky integral of motor
neuron spikes = the muscle activation the body model reads.
"""
import csv, json, os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
XLS = os.path.join(DATA, "CElegansNeuronTables.xls")

# ---- fixed geometry (mirrored as equ in brain.asm) ----
NC = 304            # columns: 302 neurons padded to a multiple of 8
NMUSCLE = 96
MUSCLE_ROW0 = 304
NR = MUSCLE_ROW0 + NMUSCLE   # 400 rows
MAGIC = b"WRM1"

# ---- model parameters (tunable; baked into the header) ----
PARAMS = dict(
    leak_shift=2,     # v -= v >> 2 each step (tau ~ 4 steps)
    w_shift=0,        # inp = acc >> w_shift
    reset=-64,        # hyperpolarised reset = refractory period
    vmin=-2000,
    spike=4,          # s value of a firing neuron (input per spike = 4 * weight)
    steps_per_frame=2,
    thr_sensory=64, thr_inter=48, thr_motor=64, thr_muscle=0x7FFF,
    adapt_shift=3,                   # a -= a>>shift each step; inp -= a
    adapt_sensory=40, adapt_inter=20, adapt_motor=24,   # a += inc on spike (per group)
    gi_gain=1, gi_shift=2, gi_max=4000,   # inp -= min((sum s_last_step*gain)>>shift, max) (neurons only)
    norm_target=160,                 # >0: rows whose sum|w| exceeds this are scaled down to it (cap)
    wta=63,                          # reciprocal inhibition forward<->backward command interneurons
)
# neurotransmitter -> weight per contact (cartoon: ACh/Glu +, GABA -, gap +, amines weak +)
NT_SCALE = {
    "Acetylcholine": 2, "Glutamate": 2, "Generic_GJ": 3, "GABA": -3,
    "Serotonin": 1, "Dopamine": 1, "FMRFamide": 1, "FRMFemide": 1, "Octapamine": 1,
    "Serotonin_Acetylcholine": 2, "Acetylcholine_Tyramine": 2, "Serotonin_Glutamate": 2,
    "Serotonin, Acetylcholine": 2, "Acetylcholine, Tyramine": 2, "": 1,
}
WMAX = 63           # 7-bit signed weight in the packed CSR entry
# ---- model assumptions beyond the raw table (documented in SOURCES.md) ----
# 1. Touch receptor neurons (glutamatergic) drive the command interneurons through
#    their gap junctions; their chemical synapses are treated as inhibitory
#    (Chalfie et al. 1985: anterior touch -> AVD/AVA via ALM/AVM gap junctions,
#    while AVM/ALM chemical input suppresses the forward cells AVB/PVC).
TOUCH_CHEM_INHIB = {"ALML", "ALMR", "AVM", "PLML", "PLMR"}
TOUCH_GAP_SCALE = 6     # the touch cells' gap junctions (ALM/AVM-AVD, PLM-PVC) are the escape path
# 2. The forward (AVB, PVC) and backward (AVA, AVD, AVE) command groups are
#    mutually exclusive states; modelled as reciprocal inhibition (kind "model").
FWD_CMD = ["AVBL", "AVBR", "PVCL", "PVCR"]
# 3. The "lost the scent -> pirouette" circuit (Gray, Hill & Bargmann 2005): ASER/AWC
#    (OFF cells, fire when the attractant concentration falls) -> AIB -> RIM -> AVA/AVE.
#    These table entries are scaled up so the pathway wins the WTA (kind stays as in
#    the table; the factor is listed in brain.json["boost"]).
BOOST = [(("ASER", "AWCL", "AWCR"), ("AIBL", "AIBR"), 16),
         (("AIBL", "AIBR"), ("RIML", "RIMR"), 16),
         (("RIML", "RIMR"), ("AVAL", "AVAR", "AVEL", "AVER"), 16)]
BWD_CMD = ["AVAL", "AVAR", "AVDL", "AVDR", "AVEL", "AVER"]
# tonic drive (ext added every step by the worm environment): forward command
# interneurons are tonically active in a crawling worm.
BIAS = {"AVBL": 110, "AVBR": 110, "PVCL": 44, "PVCR": 44}
# neurons the environment stimulates (fixed slots in the header)
STIM_SLOTS = ["ALML", "ALMR", "AVM", "PLML", "PLMR", "ASEL", "ASER",
              "AWCL", "AWCR", "AWAL", "AWAR", "ASHL", "NSML", "NSMR", "MCL", "MCR"]
# slots 12..15: pharyngeal neurons driven while the worm sits on food (NSM = serotonergic
# "food here, slow down" cells; MC = pharyngeal pumping pacemakers)

PHARYNX = {"I1L", "I1R", "I2L", "I2R", "I3", "I4", "I5", "I6", "M1", "M2L", "M2R",
           "M3L", "M3R", "M4", "M5", "MCL", "MCR", "MI", "NSML", "NSMR"}
HEAD_D = ["RMDDL", "RMDDR", "SMDDL", "SMDDR", "SMBDL", "SMBDR", "RMED"]
HEAD_V = ["RMDVL", "RMDVR", "SMDVL", "SMDVR", "SMBVL", "SMBVR", "RMEV"]


def _num(s):
    m = re.search(r"(\d+)$", s)
    return int(m.group(1)) if m else 0


def load_tables():
    import xlrd
    wb = xlrd.open_workbook(XLS)
    conn = [r for r in (wb.sheet_by_name("Connectome").row_values(i)
                        for i in range(1, wb.sheet_by_name("Connectome").nrows))]
    n2m = [r for r in (wb.sheet_by_name("NeuronsToMuscle").row_values(i)
                       for i in range(1, wb.sheet_by_name("NeuronsToMuscle").nrows))]
    sens = [wb.sheet_by_name("Sensory").row_values(i)[0]
            for i in range(1, wb.sheet_by_name("Sensory").nrows)]
    return conn, n2m, sens


def classify(conn, n2m, sens):
    names = set(r[0] for r in conn) | set(r[1] for r in conn) | set(r[0] for r in n2m)
    names |= {"CANL", "CANR"}          # the two neurons with no reported synapses
    assert len(names) == 302, len(names)
    sensory = sorted(n for n in names if n in sens)
    muscle_src = set(r[0] for r in n2m)
    motor_all = [n for n in names if n in muscle_src and n not in sens and n not in PHARYNX]

    def cls(n):
        for c in ("DA", "DB", "DD", "VA", "VB", "VD", "AS", "VC"):
            if re.fullmatch(c + r"\d+", n):
                return c
        if n in HEAD_D:
            return "HD"
        if n in HEAD_V:
            return "HV"
        return "MO"
    order = {"DA": 0, "VA": 1, "DB": 2, "VB": 3, "DD": 4, "VD": 5, "AS": 6, "VC": 7,
             "HD": 8, "HV": 9, "MO": 10}
    motor = sorted(motor_all, key=lambda n: (order[cls(n)], _num(n), n))
    inter = sorted(n for n in names if n not in sensory and n not in motor)
    # pharyngeal neurons go at the end of the interneuron block
    inter = [n for n in inter if n not in PHARYNX] + sorted(PHARYNX)
    rows = [(n, "sensory", "S") for n in sensory] + \
           [(n, "inter", "P" if n in PHARYNX else "I") for n in inter] + \
           [(n, "motor", cls(n)) for n in motor]
    assert len(rows) == 302
    return rows


def muscle_index(name):
    # MDL01.. MDR01.. MVL01.. MVR01..  -> 0..95 ; MANAL (anal depressor) is dropped
    m = re.fullmatch(r"M([DV])([LR])(\d\d)", name)
    if not m:
        return None
    side = {"DL": 0, "DR": 1, "VL": 2, "VR": 3}[m.group(1) + m.group(2)]
    return side * 24 + int(m.group(3)) - 1


def build():
    conn, n2m, sens = load_tables()
    rows = classify(conn, n2m, sens)
    idx = {n: i for i, (n, _, _) in enumerate(rows)}
    syn = []                       # (src_col, dst_row, kind, n, nt, w)
    boost = {}
    for srcs, dsts, k in BOOST:
        for a in srcs:
            for b_ in dsts:
                boost[(a, b_)] = k
    for o, t, ty, n, nt in conn:
        w = int(n) * NT_SCALE[nt] * boost.get((o, t), 1)
        if o in TOUCH_CHEM_INHIB:
            w = -abs(w) if ty != "GapJunction" else w * TOUCH_GAP_SCALE
        syn.append((idx[o], idx[t], "gap" if ty == "GapJunction" else "chem", int(n), nt, w))
    for o, m, n, nt in n2m:
        mi = muscle_index(m)
        if mi is None:
            continue
        w = int(n) * NT_SCALE.get(nt, 1)
        syn.append((idx[o], MUSCLE_ROW0 + mi, "nmj", int(n), nt, w))
    # merge duplicates (same src,dst) and clip to the 7-bit packed range
    merged = {}
    for s, d, k, n, nt, w in syn:
        key = (s, d)
        if key in merged:
            merged[key][3] += n; merged[key][5] += w
        else:
            merged[key] = [s, d, k, n, nt, w]
    syn = sorted(merged.values(), key=lambda e: (e[0], e[1]))
    if PARAMS["norm_target"]:
        tot = {}
        for e in syn:
            tot[e[1]] = tot.get(e[1], 0) + abs(e[5])
        for e in syn:
            e[5] = int(round(e[5] * PARAMS["norm_target"] / max(tot[e[1]], 1)))
    for e in syn:
        e[5] = max(-WMAX - 1, min(WMAX, e[5]))
    if PARAMS["wta"]:
        for a in FWD_CMD:
            for b in BWD_CMD:
                syn.append([idx[a], idx[b], "model", 0, "model_WTA", -PARAMS["wta"]])
                syn.append([idx[b], idx[a], "model", 0, "model_WTA", -PARAMS["wta"]])
        syn.sort(key=lambda e: (e[0], e[1]))
    ncontacts = sum(int(n) for _, _, _, n, _ in conn) + sum(int(r[2]) for r in n2m)
    # ---- CSR by source column ----
    offs = [0] * (NC + 1)
    for e in syn:
        offs[e[0] + 1] += 1
    for j in range(NC):
        offs[j + 1] += offs[j]
    assert offs[NC] == len(syn) and len(syn) < 65536
    entries = [((e[5] & 0x7F) << 9) | e[1] for e in syn]   # dst 9 bits | w 7 bits signed
    # ---- groups / ranges ----
    g_sens_end = sum(1 for r in rows if r[1] == "sensory")
    g_inter_end = g_sens_end + sum(1 for r in rows if r[1] == "inter")
    classes = [r[2] for r in rows]

    def rng(*cs):
        ii = [i for i, c in enumerate(classes) if c in cs]
        assert ii == list(range(ii[0], ii[-1] + 1)), cs
        return ii[0], ii[-1] + 1
    bwd = rng("DA", "VA")
    fwd = rng("DB", "VB")
    P = PARAMS
    hdr = bytearray(128)
    struct.pack_into("<4sHHHHHH", hdr, 0, MAGIC, NR, NC, 302, NMUSCLE, len(syn), min(ncontacts, 65535))
    struct.pack_into("<HHhhhH", hdr, 16, P["leak_shift"], P["w_shift"], P["reset"], P["vmin"],
                     P["spike"], P["steps_per_frame"])
    struct.pack_into("<HHHH", hdr, 28, fwd[0], fwd[1], bwd[0], bwd[1])
    struct.pack_into("<HHHH", hdr, 36, g_sens_end, g_inter_end, 302, MUSCLE_ROW0)
    struct.pack_into("<hhhh", hdr, 44, P["thr_sensory"], P["thr_inter"], P["thr_motor"], P["thr_muscle"])
    bias = sorted((idx[n], v) for n, v in BIAS.items())
    struct.pack_into("<H", hdr, 52, len(bias))
    struct.pack_into("<HhHHh", hdr, 54, P["adapt_shift"], 0, P["gi_gain"], P["gi_shift"], P["gi_max"])
    struct.pack_into("<hhh", hdr, 120, P["adapt_sensory"], P["adapt_inter"], P["adapt_motor"])
    assert len(bias) <= 6
    for k, (i, v) in enumerate(bias[:6]):
        struct.pack_into("<Hh", hdr, 96 + 4 * k, i, v)
    for k, n in enumerate(STIM_SLOTS):
        struct.pack_into("<H", hdr, 64 + 2 * k, idx[n])
    blob = bytes(hdr)
    blob += struct.pack("<%dH" % (NC + 1), *offs) + b"\0\0"      # 610 B + pad -> 612
    blob += struct.pack("<%dH" % len(entries), *entries)
    os.makedirs(DATA, exist_ok=True)
    with open(os.path.join(DATA, "brain.bin"), "wb") as f:
        f.write(blob)
    with open(os.path.join(DATA, "brain.inc"), "w") as f:
        f.write("; generated by worm/connectome.py - C. elegans brain image (CSR), %d bytes\n" % len(blob))
        f.write("brain_blob:\n")
        for i in range(0, len(blob), 32):
            f.write("    db " + ",".join(str(b) for b in blob[i:i + 32]) + "\n")
        f.write("brain_blob_end:\n")
    with open(os.path.join(DATA, "neurons.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["index", "name", "group", "class"])
        for i, (n, g, c) in enumerate(rows):
            w.writerow([i, n, g, c])
    with open(os.path.join(DATA, "synapses.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["src", "dst", "kind", "n", "nt", "weight"])
        for e in syn:
            w.writerow(e)
    meta = dict(NR=NR, NC=NC, nneurons=302, nmuscle=NMUSCLE, muscle_row0=MUSCLE_ROW0,
                nsyn=len(syn), ncontacts=ncontacts, params=P, fwd=fwd, bwd=bwd,
                groups=dict(sensory_end=g_sens_end, inter_end=g_inter_end),
                stim_slots=STIM_SLOTS, bias=BIAS, names=[r[0] for r in rows],
                boost=[(list(a), list(b), k) for a, b, k in BOOST],
                touch_chem_inhib=sorted(TOUCH_CHEM_INHIB), touch_gap_scale=TOUCH_GAP_SCALE,
                wta=dict(fwd=FWD_CMD, bwd=BWD_CMD, w=PARAMS["wta"]),
                classes=classes, blob_bytes=len(blob), header=128, offs_at=128,
                entries_at=128 + 612)
    with open(os.path.join(DATA, "brain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("neurons 302 (sensory %d, inter %d, motor %d)  muscles %d" %
          (g_sens_end, g_inter_end - g_sens_end, 302 - g_inter_end, NMUSCLE))
    print("synapse entries %d (contacts %d)  fwd rows %s  bwd rows %s" % (len(syn), ncontacts, fwd, bwd))
    print("brain.bin %d bytes (%d sectors)" % (len(blob), (len(blob) + 511) // 512))
    return meta


if __name__ == "__main__":
    build()
