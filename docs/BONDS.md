# Bond character model

Most viewers decide "bonded / not bonded" with one cut-off, then guess a bond
order from it. That hides exactly what you usually want to see in a structure
that's distorted, mid-reaction, or a transition state.

chemviewer never decides. For every pair of atoms close enough to *possibly* be
bonded, it draws a link and colours it by a continuous **bond character** `b`:

| `b` | meaning |
|---|---|
| 0   | at the cut-off: barely interacting (link fully faded) |
| 1   | typical single-bond length for this pair |
| 2   | typical double-bond length for this pair |
| 3   | typical triple-bond length for this pair (and anything shorter) |

## Reference lengths per pair

The reference lengths come from **Pyykkö's additive covalent radii**, which
exist separately for single, double and triple bonds:

- single: P. Pyykkö, M. Atsumi, *Chem. Eur. J.* **15**, 186 (2009)
- double: P. Pyykkö, M. Atsumi, *Chem. Eur. J.* **15**, 12770 (2009)
- triple: P. Pyykkö, S. Riedel, M. Patzschke, *Chem. Eur. J.* **11**, 3511 (2005)

For a pair A–B, `r_n(A,B) = r_n(A) + r_n(B)` for n = 1, 2, 3. So C–C, C–N and
C–O each get their own scale. If an element has no double or triple radius
(e.g. H), the pair simply tops out at the highest order both atoms support.

The table lives in `src/core/elements.zig` and is meant to be edited. A
per-pair override table (for specific pairs where the additive model is poor,
e.g. some metal–ligand bonds) is planned.

## Distance → character

With `r1 > r2 > r3` and the cut-off `rc = f · r1` (default `f = 1.25`):

```
d >= rc            → not drawn
r1 <= d < rc       → b = (rc - d) / (rc - r1)          ∈ (0, 1]
r2 <= d < r1       → b = 1 + (r1 - d) / (r1 - r2)      ∈ (1, 2]
r3 <= d < r2       → b = 2 + (r2 - d) / (r2 - r3)      ∈ (2, 3]
d < r3             → b = 3
```

The function is piecewise-linear in distance between the reference points, so
it's continuous and monotonic. Bonds that lengthen smoothly during a trajectory
change colour smoothly too.

## Display

`b` indexes a colour gradient (default: a faint grey at 0, then neutral at 1,
then increasingly saturated toward 3). Opacity and radius also scale with `b`
below 1, so weak contacts fade out instead of popping. A "half-bond" mode
(element colours on each half, with the gradient only on the radius) is also
available.

## Neighbour search

Uniform spatial hash with cell size = the largest possible cut-off among the
elements present. Each atom only checks the 27 surrounding cells, so the search
is O(N) in practice. Periodic images (minimum image convention) are planned.
