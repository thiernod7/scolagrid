from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
t = TTFont('/home/user/scolagrid/app/assets/polices/Inter-Bold.ttf'); gs = t.getGlyphSet(); cmap = t.getBestCmap(); upm = t['head'].unitsPerEm
def lettre(ch, taille, cx, base):
    g = cmap[ord(ch)]; w = t['hmtx'][g][0] * taille / upm; k = taille / upm
    pen = SVGPathPen(gs); gs[g].draw(TransformPen(pen, (k, 0, 0, -k, cx - w / 2, base))); return pen.getCommands()
N = '#0A0A0A'; B = '#FFFFFF'; V = '#1A8C50'
fond = f'<rect width="512" height="512" rx="112" fill="{N}"/>'
# A. L'école : un toit, le drapeau vert au sommet, et le « S » de ScolaGrid dessous.
a = fond + f'''
<path d="M128 236 L256 130 L384 236" fill="none" stroke="{B}" stroke-width="34" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M256 132 L256 66" stroke="{B}" stroke-width="10" stroke-linecap="round"/>
<path d="M258 68 L312 84 L258 100 Z" fill="{V}"/>
<path d="{lettre('S', 250, 256, 432)}" fill="{B}"/>'''
# B. La toque : le diplôme, et un pompon vert qui finit en coche (« réglé »).
b = fond + f'''
<path d="M164 250 L164 320 C196 356 316 356 348 320 L348 250 Z" fill="{B}"/>
<path d="M256 140 L420 214 L256 288 L92 214 Z" fill="{B}" stroke="{N}" stroke-width="12" stroke-linejoin="round"/>
<path d="M256 214 L376 236 L376 300" fill="none" stroke="{V}" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M350 330 L374 356 L420 300" fill="none" stroke="{V}" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>'''
# C. Le livre ouvert : le cahier de l'école, ses lignes, et un signet vert.
lignes = ''.join(f'<path d="M{x1} {y} C{x1+40} {y-8} {x2-40} {y-8} {x2} {y+10}" fill="none" stroke="{N}" stroke-opacity=".18" stroke-width="6" stroke-linecap="round"/>'
                 for (x1, x2) in [(132, 232)] for y in (226, 266, 306)) + \
         ''.join(f'<path d="M{x1} {y+10} C{x1+40} {y-8} {x2-40} {y-8} {x2} {y}" fill="none" stroke="{N}" stroke-opacity=".18" stroke-width="6" stroke-linecap="round"/>'
                 for (x1, x2) in [(280, 380)] for y in (226, 266, 306))
c = fond + f'''
<path d="M248 188 C206 156 150 152 104 170 L104 366 C150 350 206 352 248 382 Z" fill="{B}"/>
<path d="M264 188 C306 156 362 152 408 170 L408 366 C362 350 306 352 264 382 Z" fill="{B}"/>
{lignes}
<path d="M332 158 L362 158 L362 262 L347 246 L332 262 Z" fill="{V}"/>'''
def svg(corps, taille=512): return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="{taille}" height="{taille}">{corps}</svg>'
for nom, corps in [('A', a), ('B', b), ('C', c)]:
    open(f'idee-{nom}.svg', 'w').write(svg(corps))
titres = {'A': "A · L'école (toit, drapeau, S)", 'B': 'B · La toque (pompon en coche)', 'C': 'C · Le cahier (signet vert)'}
cartes = ''.join(f'''<div style="background:#fff;border-radius:12px;padding:20px;width:300px;font:600 16px Inter,sans-serif">
<div style="margin-bottom:12px">{titres[n]}</div>{svg(cp, 260)}
<div style="display:flex;gap:12px;align-items:end;margin-top:12px">{svg(cp, 64)}{svg(cp, 40)}{svg(cp, 24)}<span style="font:400 12px sans-serif;color:#737373">tailles réelles d'icône</span></div></div>'''
                 for n, cp in [('A', a), ('B', b), ('C', c)])
open('planche.html', 'w').write(f'<body style="margin:0;padding:24px;background:#eee;display:flex;gap:20px">{cartes}</body>')
