# Data sources and licences

## C. elegans connectome: `CElegansNeuronTables.xls`

- Origin: OpenWorm project, file `CElegansNeuronTables.xls`
  (https://github.com/openworm/CElegansNeuroML, last changed in commit 99eb18f, 2014-01-21;
  the identical file - same SHA-256 e6e2d51c...56d74 - is shipped by
  https://github.com/openworm/c302 under `c302/data/`).
- Licence: the OpenWorm repositories (OpenWorm, c302) are MIT licensed
  ("Copyright (c) OpenWorm"). The table itself is a formatted copy of the published
  hermaphrodite wiring diagram: White et al. 1986 (Phil. Trans. R. Soc. B 314:1-340),
  as corrected/compiled by Chen, Hall & Chklovskii 2006 (PNAS 103:4723) and
  Varshney et al. 2011 (PLoS Comput. Biol. 7:e1001066), distributed by WormAtlas
  (https://www.wormatlas.org). Neuron names follow the WormAtlas convention.
- Sheets used:
  - `Connectome`  (Origin, Target, Type = Send | GapJunction, Number of Connections,
    Neurotransmitter): 2279 chemical and 1084 gap-junction rows, 300 neurons.
  - `NeuronsToMuscle` (Neuron, Muscle, Number of Connections, Neurotransmitter):
    565 neuromuscular rows onto the 96 body-wall muscles MDL/MDR/MVL/MVR 01-24
    (plus MANAL, dropped).
  - `Sensory` (neuron list with function): used to tag the 86 sensory neurons.
- CANL / CANR carry no synapses in this dataset; they are included as unwired rows
  so the model has all 302 neurons.

## What we add on top (ours, MIT like the rest of AgentZero)

`connectome.py` turns the tables into a fixed-point integrate-and-fire network:
weight = contacts x per-neurotransmitter sign/scale (ACh, glutamate, gap +; GABA -;
amines/peptides weak +), clipped to 7 bits, packed as a CSR blob (`brain.bin`,
`brain.inc`). This is a *qualitative cartoon* of the worm's nervous system, not a
biophysical model: the connectivity is real, the dynamics are simplified.
