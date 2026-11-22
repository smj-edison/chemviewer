# Kurzgesagt-inspired flat theme

The experimental `kurzgesagt` theme (`--kurzgesagt`, or Inspector > Display >
Kurzgesagt) is inspired by the flat illustration style of
[Kurzgesagt – In a Nutshell](https://kurzgesagt.org). It borrows the general
look, not any particular artwork. Any reference images in this folder are for
local use only and are git-ignored.

What the theme takes from that style:

- a solid background with no gradient or texture. It is a pale, low-chroma
  blue-grey (#DFE7EF, OKLCh 0.925 / 0.014 / 250) so the atoms carry the
  colour, and dark enough that white hydrogens still read;
- atoms as flat single-colour discs with no outlines or shading bands, plus
  one or two lighter dots of the same hue up and to the right of centre;
- depth shown by fading toward the background colour;
- flat drop shadows a deeper shade of the background, offset down-right.

Where chemistry wins over style:

- element colours keep the hues chemists know (red O, blue N, green
  halogens, yellow S, orange P, gold Au). Carbon is teal, the one hue CPK
  leaves free (only noble gases use cyan) and VMD's carbon colour;
- bonds get darker steadily from no bond to triple (warm grey -> dusty plum
  -> deep indigo), so the scale is unambiguous in greyscale and agrees with
  the opacity fade of weak contacts.
