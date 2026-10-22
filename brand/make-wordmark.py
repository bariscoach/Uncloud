import sys, uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
src, out, text, weight, track = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
font = instantiateVariableFont(TTFont(src), {"wght": weight})
upem = font["head"].unitsPerEm
blob = hb.Blob.from_file_path(src); face = hb.Face(blob); hfont = hb.Font(face)
hfont.set_variations({"wght": weight})
buf = hb.Buffer(); buf.add_str(text); buf.guess_segment_properties()
hb.shape(hfont, buf, {"kern": True, "liga": True})
gs = font.getGlyphSet(); order = font.getGlyphOrder()
x = 0; d = []
tr = track * upem
for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
    name = order[info.codepoint]
    pen = SVGPathPen(gs)
    gs[name].draw(TransformPen(pen, (1, 0, 0, -1, x + pos.x_offset, 0)))
    d.append(pen.getCommands())
    x += pos.x_advance + tr
x -= tr
asc = font["OS/2"].sCapHeight; desc = 0
# tight box: cap height to baseline, plus descender room for none (Uncloud has no descenders)
from fontTools.pens.boundsPen import BoundsPen
bp = BoundsPen(gs); xx = 0
for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
    gs[order[info.codepoint]].draw(TransformPen(bp, (1,0,0,1,xx+pos.x_offset,0))); xx += pos.x_advance + tr
xmin, ymin, xmax, ymax = bp.bounds
pad = 0
vb = f"{xmin-pad:.0f} {-ymax-pad:.0f} {xmax-xmin+2*pad:.0f} {ymax-ymin+2*pad:.0f}"
svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="{text}"><title>{text}</title><path fill="currentColor" d="{" ".join(d)}"/></svg>\n'
open(out, "w").write(svg)
print(vb, len(svg))
