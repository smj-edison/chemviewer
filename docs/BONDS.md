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

The table lives in `src/core/elements.zig` and is meant to be edited.
**The values were transcribed without the papers at hand.** Main-group
elements are well established, but the transition-metal, lanthanide and
actinide entries (and every triple-bond radius) should be checked against the
original tables.

A per-pair override table (for specific pairs where the additive model is poor,
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

Colours are defined in **OKLCh** (the polar form of Ottosson's OKLab), so
lightness is *perceived* lightness. Each theme has its own palette
(`src/core/color.zig`). Contrast against the background, |L − L_bg|, strictly
increases with bond character, so on the light theme higher orders get darker
and on the dark theme they get brighter:

| character | light theme L | dark theme L | look (light / dark) |
|---|---|---|---|
| 0 | 0.925 (= bg) | 0.228 (= bg) | invisible, fully transparent |
| 0.5 | 0.72 | 0.43 | faint warm grey |
| 1 | 0.58 | 0.57 | warm grey (single) |
| 2 | 0.44 | 0.73 | dusty plum / mauve (double) |
| 3 | 0.28 | 0.89 | deep indigo / pale lavender (triple) |

The stop at 0.5 front-loads the change, so thermally stretched bonds just
below single (C–H in MD frames) still stand clear of the background. Chroma
stays low so atoms carry the colour, and the bond hues avoid the hues atoms
use (teal C, blue N, red O, gold Au, yellow S). Because
lightness moves monotonically away from the background, the scale also reads
correctly in greyscale.

Weak contacts fade *into* the background, both in lightness and in opacity, and
higher bond orders always look more intense. Interpolation happens in OKLCh,
taking the short way around the hue circle. Colours outside the sRGB gamut lose
chroma, never lightness, so the lightness ramp survives gamut mapping. A unit
test checks that rendered contrast is monotonic in bond character for both
themes.

### Snapping

Before colouring, bond character passes through a soft staircase:

```
snap(b) = n + x + k · (smoothstep(x) − x),   n = ⌊b⌋, x = b − n
```

With `k = 0` this is linear. With `k = 1` it has flat plateaus at whole bond
orders. The default `k = 0.7` gives a gentle slope near each integer (0.3× the
linear slope) and a steeper one in between. Bonds near a whole order read as
that order, while genuinely intermediate bonds (aromatic C–C ≈ 1.7, stretched
TS bonds) still look different. The same snapped value drives opacity and
thinning below single-bond character. `k` is the "Snap" slider in the inspector.

With cel shading, each bond's outline is weighted by
`smoothstep((s − 0.3) / 0.7)` of its snapped character `s`. The weight scales
both outline width and outline opacity, so a forming bond's outline grows in
gradually instead of switching on at single-bond character.

"Element" colouring (element colours on each half) is also available. It keeps
opacity and thinning from the snapped character.

## Neighbour search

Uniform spatial hash with cell size = the largest possible cut-off among the
elements present. Each atom only checks the 27 surrounding cells, so the search
is O(N) in practice. Periodic images (minimum image convention) are planned.
