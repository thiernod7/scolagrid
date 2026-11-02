"""Icônes de l'application (Android, Windows, web) et images du logo pour l'app,
à partir du logo validé. À lancer depuis marque/ : python3 outils/icones_app.py"""
import importlib.util, os, subprocess, sys, json
sys.argv = ['generer', '.']
spec = importlib.util.spec_from_file_location('generer', 'outils/generer.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)

APP = '../app'
TMP = 'outils/_icones'; os.makedirs(TMP, exist_ok=True)
N, B = g.ENCRE, '#FFFFFF'

def svg(corps): return g.svg(512, 512, corps, 'ScolaGrid')
def centre(corps, k):  # réduit un dessin autour du centre du carré
    return f'<g transform="translate(256 256) scale({k}) translate(-256 -256)">{corps}</g>'

sources = {
    # Icône de l'application en version claire (choisie) : fond blanc, dessin noir, drapeau vert.
    # Icône complète, carré plein (Android ancien format, masque web) : le système arrondit.
    'carre-plein': svg(f'<rect width="512" height="512" fill="{B}"/>' + centre(g.ecole_icone(N), 0.92)),
    # Icône aux coins arrondis (Windows, onglet du navigateur).
    'carre-arrondi': svg(f'<rect width="512" height="512" rx="112" fill="{B}" stroke="#E5E5E5" stroke-width="6"/>' + g.ecole_icone(N)),
    # Avant-plan de l'icône adaptative Android : dessin seul, dans la zone sûre (66/108).
    'avant-plan': svg(centre(g.ecole_icone(N), 0.70)),
    # Dans l'app : icône du menu (thème clair / sombre) et logo de l'écran de bienvenue.
    'icone': svg(f'<rect width="512" height="512" rx="112" fill="{N}"/>' + g.ecole_icone(B)),
    'icone-sombre': svg(f'<rect width="512" height="512" rx="112" fill="{B}"/>' + g.ecole_icone(N)),
    'logo-clair': svg(g.ecole_nom(N, g.GRIS)),
    'logo-sombre': svg(g.ecole_nom(B, '#A3A3A3')),
}
for nom, contenu in sources.items():
    open(f'{TMP}/{nom}.svg', 'w').write(contenu)

sorties = []  # (source, taille, chemin)
res = f'{APP}/plateformes/android'
for dossier, legacy, fg in [('mdpi', 48, 108), ('hdpi', 72, 162), ('xhdpi', 96, 216), ('xxhdpi', 144, 324), ('xxxhdpi', 192, 432)]:
    sorties += [('carre-plein', legacy, f'{res}/mipmap-{dossier}/ic_launcher.png'),
                ('avant-plan', fg, f'{res}/mipmap-{dossier}/ic_launcher_foreground.png')]
web = f'{APP}/plateformes/web'
sorties += [('carre-arrondi', 32, f'{web}/favicon.png'),
            ('carre-arrondi', 192, f'{web}/icons/Icon-192.png'), ('carre-arrondi', 512, f'{web}/icons/Icon-512.png'),
            ('carre-plein', 192, f'{web}/icons/Icon-maskable-192.png'), ('carre-plein', 512, f'{web}/icons/Icon-maskable-512.png'),
            ('carre-arrondi', 256, f'{TMP}/windows-256.png')]
for nom, t in [('icone', 192), ('icone-sombre', 192), ('logo-clair', 512), ('logo-sombre', 512)]:
    sorties.append((nom, t, f'{APP}/assets/marque/{nom}.png'))
for _, _, chemin in sorties:
    os.makedirs(os.path.dirname(chemin), exist_ok=True)
json.dump([[f'{TMP}/{s}.svg', t, c] for s, t, c in sorties], open(f'{TMP}/liste.json', 'w'))
subprocess.run(['node', '-e', '''
const { chromium } = require("playwright"); const fs = require("fs");
const liste = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
(async () => { const b = await chromium.launch();
  for (const [src, t, out] of liste) {
    const p = await b.newPage({ viewport: { width: t, height: t } });
    const s = fs.readFileSync(src, "utf8").replace(/width="[\\d.]+" height="[\\d.]+"/, `width="${t}" height="${t}"`);
    await p.setContent(`<html><body style="margin:0;background:transparent">${s}</body></html>`);
    await p.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: t, height: t } }); await p.close(); }
  await b.close(); })();''', f'{TMP}/liste.json'], check=True)

# Android : icône adaptative (fond noir + dessin), et nom de couleur.
os.makedirs(f'{res}/mipmap-anydpi-v26', exist_ok=True)
open(f'{res}/mipmap-anydpi-v26/ic_launcher.xml', 'w').write(
    '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/scolagrid_fond_icone"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n</adaptive-icon>\n')
os.makedirs(f'{res}/values', exist_ok=True)
open(f'{res}/values/scolagrid_couleurs.xml', 'w').write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="scolagrid_fond_icone">#FFFFFF</color>\n</resources>\n')

# Windows : un .ico à plusieurs tailles.
from PIL import Image
os.makedirs(f'{APP}/plateformes/windows', exist_ok=True)
Image.open(f'{TMP}/windows-256.png').save(f'{APP}/plateformes/windows/app_icon.ico',
                                          sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print('icônes prêtes')
