const { chromium } = require('playwright');
const fs = require('fs');
const dir = process.argv[2];
const sorties = [
  ['scolagrid-symbole.svg', 1024, 'transparent'],
  ['scolagrid-symbole-grille.svg', 1024, 'transparent'],
  ['scolagrid-logo-grille.svg', 1600, 'transparent'],
  ['scolagrid-logo-grille-fond-sombre.svg', 1600, 'transparent'],
  ['scolagrid-logo.svg', 1600, 'transparent'],
  ['scolagrid-logo-fond-sombre.svg', 1600, 'transparent'],
  ['scolagrid-cachet.svg', 1200, 'transparent'],
  ['scolagrid-cachet-encre.svg', 1200, 'transparent'],
  ['scolagrid-cachet-plein.svg', 1200, 'transparent'],
];
(async () => {
  const b = await chromium.launch();
  for (const [f, largeur] of sorties) {
    const s = fs.readFileSync(`${dir}/${f}`, 'utf8');
    const [, w, h] = s.match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/).map(Number);
    const hauteur = Math.round(largeur * h / w);
    const p = await b.newPage({ viewport: { width: largeur, height: hauteur } });
    await p.setContent(`<html><body style="margin:0;background:transparent">${s.replace(/width="[\d.]+" height="[\d.]+"/, `width="${largeur}" height="${hauteur}"`)}</body></html>`);
    await p.screenshot({ path: `${dir}/${f.replace('.svg', '.png')}`, omitBackground: true, clip: { x: 0, y: 0, width: largeur, height: hauteur } });
    await p.close();
  }
  await b.close();
})();
