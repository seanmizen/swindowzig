# Text requirements — `REQ-TEXT-*`

The shaping, the measuring and the caret geometry of the text that
`libs/sw_text` draws.

## REQ-TEXT-001 — Arabic letters take their joined forms before reordering

- **Status:** active
- **Source:** sean
- **Origin:** #63
- **Type:** functional
- **Priority:** P3
- **Statement:** When a line has Arabic letters, sw_text shall replace each
  letter with the presentation form (U+FB50 to U+FEFF) that the joining types
  of its neighbours in logical order select, before the bidirectional
  algorithm reorders the line.
- **Rationale:** Without shaping, each Arabic letter draws in its isolated
  form, and a word is a row of separate letters. The joining types come from
  `ArabicShaping.txt` (Unicode 16.0.0), through the generator
  `libs/sw_text/tools/gen_shaping_tables.py`. Shaping must use the logical
  order, because the neighbours of a letter change when the line is
  reordered.
- **Verification:**
  - Test — `libs/sw_text/src/shape.zig` › "beh takes each of its four forms"
  - Test — `libs/sw_text/src/bidi.zig` › "Arabic letters are shaped before
    the line is reordered"
- **Relations:** none

## REQ-TEXT-002 — Lam followed by alef is one ligature

- **Status:** active
- **Source:** sean
- **Origin:** #63
- **Type:** functional
- **Priority:** P3
- **Statement:** When an alef follows a lam, sw_text shall replace the
  two letters with the isolated or final lam-alef ligature.
- **Rationale:** The lam-alef ligature is mandatory in Arabic writing. The
  number of code points does not change: the alef changes to
  `shape.ligature_part`, which has no glyph and no width. So each byte offset
  of the text still maps to one code point (REQ-TEXT-005).
- **Verification:** Test — `libs/sw_text/src/shape.zig` › "lam followed by
  alef is the lam-alef ligature"
- **Relations:** refines REQ-TEXT-001

## REQ-TEXT-003 — Measuring uses the shaped text

- **Status:** active
- **Source:** sean
- **Origin:** #63
- **Type:** functional
- **Priority:** P3
- **Statement:** The `measure`, `measureWrapped` and `caretLayout` functions
  of `TextRenderer` shall give the width of the shaped text that `draw`
  draws.
- **Rationale:** A presentation form can have a different width from its
  letter. If the measured width is not the drawn width, a UI cuts or
  misaligns Arabic text.
- **Verification:** Test — `libs/sw_text/src/text.zig` › "measure, draw and
  the caret layout agree on shaped Arabic text"
- **Relations:** depends-on REQ-TEXT-001

## REQ-TEXT-004 — A missing presentation form draws as its letter

- **Status:** active
- **Source:** agent:SWZ-63
- **Origin:** #63
- **Type:** functional
- **Priority:** P3
- **Statement:** If no face of the font chain has a presentation form, then
  sw_text shall draw and measure the letter of that form in its nominal form,
  and lam then alef for a lam-alef ligature.
- **Rationale:** Many fonts have the Arabic letters but not all the
  presentation forms. The nominal letter is legible, but it does not join. An
  empty box is not legible. sw_text searches the chain for the form first, so a
  later face that has the form draws it.
- **Verification:** Test — `libs/sw_text/src/text.zig` › "a font that lacks
  a presentation form draws the letter"
- **Relations:** refines REQ-TEXT-001

## REQ-TEXT-005 — The caret maps back to the text in shaped text

- **Status:** active
- **Source:** sean
- **Origin:** #63
- **Type:** functional
- **Priority:** P3
- **Statement:** The caret layout of shaped text shall give a caret position
  for each code point boundary of the original text.
- **Rationale:** A text field edits the original text by byte offset. Each
  letter of a lam-alef ligature gets half of the ligature glyph, so the caret
  can go between the lam and the alef.
- **Verification:** Test — `libs/sw_text/src/caret.zig` › "caret: shaped
  Arabic text keeps a position for each byte offset"
- **Relations:** depends-on REQ-TEXT-002

## REQ-TEXT-006 — Diacritics do not break a join

- **Status:** active
- **Source:** sean
- **Origin:** #63
- **Type:** functional
- **Priority:** P3
- **Statement:** When a code point with joining type T (such as a
  diacritic, general category Mn) is between two letters, sw_text shall
  select the forms of the two letters as if the code point were not there.
- **Rationale:** Arabic text puts vowel marks between the letters of a
  word. If a mark breaks the join, a word with vowel marks draws as separate
  letters.
- **Verification:** Test — `libs/sw_text/src/shape.zig` › "a diacritic in a
  word does not break the join"
- **Relations:** refines REQ-TEXT-001

## REQ-TEXT-007 — Text with no Arabic letters is unchanged

- **Status:** active
- **Source:** sean
- **Origin:** #63
- **Type:** constraint
- **Priority:** P3
- **Statement:** When a text has no letter with presentation forms, sw_text
  shall draw and measure the code points of the text unchanged.
- **Rationale:** Most text has no Arabic letters. The shaper returns each
  code point below U+0620 after one comparison, and `draw` keeps the fast
  path that skips the bidirectional algorithm for left-to-right text.
- **Verification:**
  - Test — `libs/sw_text/src/shape.zig` › "text with no Arabic letters is
    unchanged"
  - Test — `libs/sw_text/src/text.zig` › "Latin text is not shaped and keeps
    the fast path"
- **Relations:** none
