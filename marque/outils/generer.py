"""Génère le logo et le cachet de ScolaGrid (SVG, textes convertis en tracés)."""
import math, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

POLICES = '../app/assets/polices/'
SORTIE = sys.argv[1]
ENCRE = '#0A0A0A'; GRIS = '#737373'; VERT = '#1A8C50'; BLEU = '#1D3F8F'

class Police:
    def __init__(self, f):
        self.t = TTFont(POLICES + f); self.gs = self.t.getGlyphSet(); self.cmap = self.t.getBestCmap()
        self.upm = self.t['head'].unitsPerEm; self.hmtx = self.t['hmtx']
    def avance(self, c, taille, espacement=0):
        return self.hmtx[self.cmap[ord(c)]][0] * taille / self.upm + espacement
    def largeur(self, texte, taille, espacement=0):
        return sum(self.avance(c, taille, espacement) for c in texte) - espacement
    def glyphe(self, c, taille, x, y, angle=0):
        """Chemin d'un caractère : ligne de base en (x, y), tourné de `angle` degrés."""
        pen = SVGPathPen(self.gs)
        k = taille / self.upm; a = math.radians(angle)
        ca, sa = math.cos(a), math.sin(a)
        # unités de la police (y vers le haut) -> SVG (y vers le bas), rotation, translation
        t = (k * ca, k * sa, k * sa, -k * ca, x, y)
        self.gs[self.cmap[ord(c)]].draw(TransformPen(pen, t))
        return pen.getCommands()
    def texte(self, texte, taille, x, y, espacement=0):
        d = []
        for c in texte:
            if c != ' ': d.append(self.glyphe(c, taille, x, y))
            x += self.avance(c, taille, espacement)
        return ' '.join(d)
    def arc(self, texte, taille, cx, cy, r, centre_deg, espacement=0, bas=False):
        """Texte sur un cercle. En haut : lettres vers l'extérieur ; en bas : lisible de gauche à droite."""
        total = self.largeur(texte, taille, espacement)
        span = total / r  # radians
        d = []
        pos = 0.0
        for c in texte:
            w = self.avance(c, taille, espacement)
            milieu = pos + (w - espacement) / 2
            if not bas:
                phi = math.radians(centre_deg) - span / 2 + milieu / r
                rot = math.degrees(phi)
            else:
                phi = math.radians(centre_deg) + span / 2 - milieu / r
                rot = math.degrees(phi) - 180
            px, py = cx + r * math.sin(phi), cy - r * math.cos(phi)
            # point de départ de la lettre : reculer d'une demi-largeur le long de la tangente
            demi = (w - espacement) / 2
            tr = math.radians(rot)
            x0, y0 = px - demi * math.cos(tr), py - demi * math.sin(tr)
            if c != ' ': d.append(self.glyphe(c, taille, x0, y0, rot))
            pos += w
        return ' '.join(d)

GRAS = Police('Inter-Bold.ttf')

# Le « S » dessiné dans une grille de 5 x 5 cases.
S = ['.XXX.', 'X....', '.XXX.', '....X', '.XXX.']
ACCENT = (0, 3)  # première case du S, en vert

def grille(x, y, taille, plein, vide, accent=None, vide_contour=False, arrondi=0.22):
    cote = taille / (5 + 4 * 0.25); ecart = cote * 0.25
    out = []
    for i, ligne in enumerate(S):
        for j, ch in enumerate(ligne):
            cx = x + j * (cote + ecart); cy = y + i * (cote + ecart); rr = cote * arrondi
            if ch == 'X':
                coul = accent if (accent and (i, j) == ACCENT) else plein
                out.append(f'<rect x="{cx:.2f}" y="{cy:.2f}" width="{cote:.2f}" height="{cote:.2f}" rx="{rr:.2f}" fill="{coul}"/>')
            elif vide_contour:
                e = cote * 0.12
                out.append(f'<rect x="{cx+e/2:.2f}" y="{cy+e/2:.2f}" width="{cote-e:.2f}" height="{cote-e:.2f}" rx="{rr:.2f}" fill="none" stroke="{vide}" stroke-width="{e:.2f}"/>')
            else:
                out.append(f'<rect x="{cx:.2f}" y="{cy:.2f}" width="{cote:.2f}" height="{cote:.2f}" rx="{rr:.2f}" fill="{vide}"/>')
    return '\n'.join(out)

def svg(l, h, corps, titre):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {l} {h}" width="{l}" height="{h}">\n'
            f'<title>{titre}</title>\n{corps}\n</svg>\n')

def ecrire(nom, contenu):
    open(f'{SORTIE}/{nom}', 'w').write(contenu)

# 1. Symbole (icône d'application) : carré arrondi noir, S blanc, case verte.
ecrire('scolagrid-symbole-grille.svg', svg(512, 512,
    f'<rect width="512" height="512" rx="112" fill="{ENCRE}"/>\n' + grille(96, 96, 320, '#FFFFFF', 'rgba(255,255,255,0.13)', VERT),
    'ScolaGrid'))

# 2. Logo horizontal (fond clair) et 3. sa version pour fond sombre.
def logo(fond_sombre):
    h = 200; m = 200
    corps = [f'<rect x="0" y="0" width="{m}" height="{m}" rx="44" fill="{"#FFFFFF" if fond_sombre else ENCRE}"/>',
             grille(38, 38, 124, ENCRE if fond_sombre else '#FFFFFF',
                    'rgba(10,10,10,0.12)' if fond_sombre else 'rgba(255,255,255,0.13)', VERT)]
    taille = 132; base = 148; x = m + 44
    corps.append(f'<path d="{GRAS.texte("Scola", taille, x, base, -2)}" fill="{"#FFFFFF" if fond_sombre else ENCRE}"/>')
    x2 = x + GRAS.largeur('Scola', taille, -2) - 2
    corps.append(f'<path d="{GRAS.texte("Grid", taille, x2, base, -2)}" fill="{"#A3A3A3" if fond_sombre else GRIS}"/>')
    l = int(x2 + GRAS.largeur('Grid', taille, -2) + 8)
    return svg(l, h, '\n'.join(corps), 'ScolaGrid')
ecrire('scolagrid-logo-grille.svg', logo(False))
ecrire('scolagrid-logo-grille-fond-sombre.svg', logo(True))

# 4. Cachet : anneaux, « SCOLAGRID » en haut, « GESTION SCOLAIRE » en bas, symbole au centre.
def etoile(cx, cy, r, coul):
    pts = []
    for k in range(10):
        a = math.radians(-90 + k * 36); rr = r if k % 2 == 0 else r * 0.42
        pts.append(f'{cx + rr*math.cos(a):.2f},{cy + rr*math.sin(a):.2f}')
    return f'<polygon points="{" ".join(pts)}" fill="{coul}"/>'

def cachet(coul, encre=False):
    c = 300
    corps = [f'<g fill="none" stroke="{coul}">',
             f'<circle cx="{c}" cy="{c}" r="282" stroke-width="12"/>',
             f'<circle cx="{c}" cy="{c}" r="262" stroke-width="3"/>',
             f'<circle cx="{c}" cy="{c}" r="176" stroke-width="3"/>',
             '</g>',
             f'<path d="{GRAS.arc("SCOLAGRID", 56, c, c, 200, 0, 9)}" fill="{coul}"/>',
             f'<path d="{GRAS.arc("GESTION SCOLAIRE", 33, c, c, 232, 180, 4, bas=True)}" fill="{coul}"/>',
             etoile(c - 219, c, 13, coul), etoile(c + 219, c, 13, coul),
             grille(c - 82, c - 112, 164, coul, coul, None, vide_contour=True),
             f'<path d="{GRAS.texte("DEPUIS 2026", 22, c - GRAS.largeur("DEPUIS 2026", 22, 3)/2, c + 102, 3)}" fill="{coul}"/>']
    contenu = '\n'.join(corps)
    if encre:
        # Effet d'encre (léger) pour les aperçus : grain et bords irréguliers.
        defs = ('<defs><filter id="encre" x="-5%" y="-5%" width="110%" height="110%">'
                '<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7" result="bruit"/>'
                '<feDisplacementMap in="SourceGraphic" in2="bruit" scale="2" result="bouge"/>'
                '<feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="3" result="taches"/>'
                '<feColorMatrix in="taches" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.1 1.55" result="masque"/>'
                '<feComposite in="bouge" in2="masque" operator="in"/></filter></defs>')
        contenu = defs + f'<g filter="url(#encre)" opacity="0.92" transform="rotate(-6 300 300)">' + contenu + '</g>'
    return svg(600, 600, contenu, 'Cachet ScolaGrid')
ecrire('scolagrid-cachet.svg', cachet(BLEU))
ecrire('scolagrid-cachet-encre.svg', cachet(BLEU, encre=True))
print('ok')

# 5. Cachet « plein », dans le style des cachets d'école guinéens : disque foncé,
# inscription sur presque tout le tour, le nom en bas, deux étoiles, texte au centre.
BLEU_CACHET = '#1E50B4'
def cachet_plein():
    c = 300
    bleu = BLEU_CACHET
    corps = [f'<circle cx="{c}" cy="{c}" r="292" fill="#FFFFFF"/>',
             f'<g fill="none" stroke="{bleu}">',
             f'<circle cx="{c}" cy="{c}" r="288" stroke-width="8"/>',
             f'<circle cx="{c}" cy="{c}" r="272" stroke-width="3"/>',
             f'<circle cx="{c}" cy="{c}" r="190" stroke-width="3"/>',
             '</g>',
             f'<path d="{GRAS.arc("LOGICIEL DE GESTION SCOLAIRE · GUINÉE", 31, c, c, 222, 0, 2)}" fill="{bleu}"/>',
             f'<path d="{GRAS.arc("SCOLAGRID", 40, c, c, 254, 180, 7, bas=True)}" fill="{bleu}"/>',
             etoile(c + 232 * math.sin(math.radians(122)), c - 232 * math.cos(math.radians(122)), 12, bleu),
             etoile(c + 232 * math.sin(math.radians(238)), c - 232 * math.cos(math.radians(238)), 12, bleu),
             grille(c - 52, c - 112, 104, bleu, 'rgba(30,80,180,0.16)', VERT)]
    for i, (ligne, taille) in enumerate([('LA', 30), ('DIRECTION', 34)]):
        y = c + 40 + i * 40
        corps.append(f'<path d="{GRAS.texte(ligne, taille, c - GRAS.largeur(ligne, taille, 1)/2, y, 1)}" fill="{bleu}"/>')
    return svg(600, 600, '\n'.join(corps), 'Cachet ScolaGrid')
ecrire('scolagrid-cachet-plein.svg', cachet_plein())


# 6. Symbole principal : une maman tient la main de sa fille, qui porte son
# cartable (vert) ; de profil, elles marchent vers l'école, légèrement inclinées.
def scene(c, vert):
    """Maman (foulard, robe) tenant la main de sa fille (cartable), de profil, marchant vers la droite."""
    return f'''
<g transform="rotate(-6 256 300) translate(-14 0)" fill="{c}" stroke="{c}" stroke-linecap="round" stroke-linejoin="round">
  <g transform="translate(120 0)">
  <!-- Maman -->
  <path stroke="none" d="M184 92 C176 62 214 50 236 66 C252 78 248 98 238 104 L188 106 Z"/>
  <circle stroke="none" cx="172" cy="88" r="14"/>
  <circle stroke="none" cx="216" cy="118" r="30"/>
  <path stroke="none" d="M243 116 L254 126 L242 130 Z"/>
  <rect stroke="none" x="204" y="140" width="20" height="22" rx="6"/>
  <path stroke="none" d="M194 160 C206 152 226 152 238 160 C248 210 262 290 266 352 L160 352 C168 290 182 210 194 160 Z"/>
  <path fill="none" stroke-width="18" d="M214 176 C196 214 176 256 152 284"/>
  <path fill="none" stroke-width="17" d="M226 350 L252 434"/>
  <path fill="none" stroke-width="17" d="M192 350 L170 434"/>
  <path fill="none" stroke-width="13" d="M252 436 L272 436"/>
  <path fill="none" stroke-width="13" d="M170 436 L188 436"/>
  </g>
  <g transform="translate(-125 0)">
  <!-- Fille -->
  <circle stroke="none" cx="334" cy="238" r="25"/>
  <circle stroke="none" cx="312" cy="222" r="11"/>
  <circle stroke="none" cx="306" cy="242" r="9"/>
  <path stroke="none" d="M357 236 L366 244 L356 247 Z"/>
  <rect stroke="none" x="325" y="258" width="16" height="16" rx="5"/>
  <path stroke="none" d="M318 270 C328 264 344 264 352 270 L360 330 C362 344 362 352 364 360 L306 360 C308 346 310 330 312 314 Z"/>
  <path fill="none" stroke-width="13" d="M340 286 C358 300 376 296 394 286"/>
  <path fill="none" stroke-width="13" d="M323 358 L314 432"/>
  <path fill="none" stroke-width="13" d="M347 358 L362 430"/>
  <path fill="none" stroke-width="10" d="M314 434 L330 434"/>
  <path fill="none" stroke-width="10" d="M362 432 L377 430"/>
  <!-- Cartable -->
  <rect stroke="none" fill="{vert}" x="288" y="272" width="30" height="50" rx="9"/>
  <path fill="none" stroke="{vert}" stroke-width="5" d="M300 274 C304 262 316 262 322 270"/>
  </g>
</g>'''


ecrire('scolagrid-symbole-famille.svg', svg(512, 512, f'<rect width="512" height="512" rx="112" fill="{ENCRE}"/>' + scene('#FFFFFF', VERT), 'ScolaGrid'))

def logo_famille(fond_sombre):
    h = 200; m = 200
    fond, trait = ('#FFFFFF', ENCRE) if fond_sombre else (ENCRE, '#FFFFFF')
    corps = [f'<g transform="scale({m/512})"><rect width="512" height="512" rx="112" fill="{fond}"/>{scene(trait, VERT)}</g>']
    taille = 132; base = 148; x = m + 44
    corps.append(f'<path d="{GRAS.texte("Scola", taille, x, base, -2)}" fill="{"#FFFFFF" if fond_sombre else ENCRE}"/>')
    x2 = x + GRAS.largeur('Scola', taille, -2) - 2
    corps.append(f'<path d="{GRAS.texte("Grid", taille, x2, base, -2)}" fill="{"#A3A3A3" if fond_sombre else GRIS}"/>')
    l = int(x2 + GRAS.largeur('Grid', taille, -2) + 8)
    return svg(l, h, '\n'.join(corps), 'ScolaGrid')
ecrire('scolagrid-logo-famille.svg', logo_famille(False))
ecrire('scolagrid-logo-famille-fond-sombre.svg', logo_famille(True))


# 7. Symbole retenu : l'école — un toit, le drapeau vert au sommet, le « S » de ScolaGrid.
def ecole(trait):
    return (f'<path d="M128 236 L256 130 L384 236" fill="none" stroke="{trait}" stroke-width="34" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
            f'<path d="M256 132 L256 66" stroke="{trait}" stroke-width="10" stroke-linecap="round"/>'
            f'<path d="M258 68 L312 84 L258 100 Z" fill="{VERT}"/>'
            f'<path d="{GRAS.glyphe("S", 250, 256 - GRAS.avance("S", 250) / 2, 432)}" fill="{trait}"/>')

ecrire('scolagrid-symbole.svg', svg(512, 512, f'<rect width="512" height="512" rx="112" fill="{ENCRE}"/>' + ecole('#FFFFFF'), 'ScolaGrid'))

def logo_ecole(fond_sombre):
    h = 200; m = 200
    fond, trait = ('#FFFFFF', ENCRE) if fond_sombre else (ENCRE, '#FFFFFF')
    corps = [f'<g transform="scale({m/512})"><rect width="512" height="512" rx="112" fill="{fond}"/>{ecole(trait)}</g>']
    taille = 132; base = 148; x = m + 44
    corps.append(f'<path d="{GRAS.texte("Scola", taille, x, base, -2)}" fill="{"#FFFFFF" if fond_sombre else ENCRE}"/>')
    x2 = x + GRAS.largeur('Scola', taille, -2) - 2
    corps.append(f'<path d="{GRAS.texte("Grid", taille, x2, base, -2)}" fill="{"#A3A3A3" if fond_sombre else GRIS}"/>')
    l = int(x2 + GRAS.largeur('Grid', taille, -2) + 8)
    return svg(l, h, '\n'.join(corps), 'ScolaGrid')
ecrire('scolagrid-logo.svg', logo_ecole(False))
ecrire('scolagrid-logo-fond-sombre.svg', logo_ecole(True))
