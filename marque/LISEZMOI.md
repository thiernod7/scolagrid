# Marque ScolaGrid

- `scolagrid-symbole` : le symbole seul (icône d'application) — un « S » dessiné
  dans une grille de 5 × 5 cases, la première case en vert.
- `scolagrid-logo` : symbole + nom, pour fond clair ; `scolagrid-logo-fond-sombre` pour fond sombre.
- `scolagrid-cachet` : cachet rond, encre bleue, net (documents numériques) ;
  `scolagrid-cachet-encre` : même cachet avec un effet d'encre (aperçus, présentations) ;
  `scolagrid-cachet-plein` : cachet sur fond blanc, textes et cercles bleus, dans le style des
  cachets d'école guinéens (inscription sur le pourtour, nom en bas, deux étoiles).
- `apercu.png` : planche de toutes les versions.

Couleurs : noir `#0A0A0A`, gris `#737373`, vert `#1A8C50`, bleu cachet `#1D3F8F`, bleu du cachet plein `#1E50B4`.
Police : Inter Bold, textes convertis en tracés (aucune police à installer).

Régénérer (depuis `marque/`) : `python3 outils/generer.py .` puis `node outils/export_png.js .`
