# Uncloud brand

- `uncloud-wordmark.svg` — the wordmark "Uncloud", Plus Jakarta Sans ExtraBold (800), tracking −3%, converted to
  outlines (no font needed). `fill="currentColor"`: it takes the surrounding text color. Chosen 2026-10-21.
- Lock-up: the wordmark sits **above** the app icon, centered. Wordmark width ≈ 1.15 × icon width; gap ≈ 12% of the
  icon. Use the ink color (primary text color), never a gradient; the icon carries the color.
- `fonts/PlusJakartaSans[wght].ttf` — the source font, SIL Open Font License 1.1 (`fonts/OFL.txt`).
- `make-wordmark.py` — regenerates the SVG: needs `fonttools` and `uharfbuzz`;
  `python make-wordmark.py "fonts/PlusJakartaSans[wght].ttf" uncloud-wordmark.svg Uncloud 800 -0.03`.
