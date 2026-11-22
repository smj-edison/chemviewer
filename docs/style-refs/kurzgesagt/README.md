# Flat style, inspired by Kurzgesagt

The **Flat** style (Inspector > Display > Flat, or `--flat`) is inspired by
the flat illustration style of
[Kurzgesagt – In a Nutshell](https://kurzgesagt.org). It borrows the general
look, not any particular artwork. Any reference images in this folder are for
local use only and are git-ignored.

Display has two independent choices: the theme (Light / Dark) owns the
background, bond palette, accents and UI colours; the style (Cel / Flat) owns
shading, element colours, shadows and atom size. Flat works with both themes.

What Flat takes from Kurzgesagt's look:

- atoms as flat single-colour discs with no outlines or shading bands, plus
  one or two lighter dots of the same hue up and to the right of centre;
- depth shown by fading toward the background colour;
- flat drop shadows a deeper shade of the background, offset down-right;
- chunkier atoms (1.3x).

Colour rules (both themes):

- backgrounds are low-chroma so the molecule carries the colour. Light is a
  pale blue-grey (#DFE7EF, OKLCh 0.925 / 0.014 / 250), dark enough that
  white hydrogens still read;
- Flat's element colours keep the hues chemists know (red O, blue N, green
  halogens, yellow S, orange P, gold Au). Carbon is teal, the one hue CPK
  leaves free (only noble gases use cyan) and VMD's carbon colour;
- bond lightness moves steadily away from the background from no bond to
  triple, so the scale is unambiguous in greyscale and agrees with the
  opacity fade of weak contacts. Light: warm grey -> dusty plum -> deep
  indigo. Dark: warm grey -> mauve -> pale lavender. Low chroma, and no hues
  the atoms own.
