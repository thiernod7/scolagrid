// Captures d'écran du manuel, sur l'application d'ESSAI, avec l'école de démonstration
// (données fictives). Usage : node captures.mjs <url> <etape> <dossier>
import { chromium } from 'playwright';
import fs from 'node:fs';

const [url, etape, dossier = 'captures'] = process.argv.slice(2);
fs.mkdirSync(dossier, { recursive: true });
const ctx = await chromium.launchPersistentContext('profil', {
  viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, locale: 'fr-FR', colorScheme: 'light',
});
const page = ctx.pages()[0] ?? (await ctx.newPage());
page.on('console', (m) => { if (m.type() === 'error') console.log('console:', m.text().slice(0, 200)); });

const pause = (ms) => page.waitForTimeout(ms);
async function semantique() {
  // Flutter web : l'arbre d'accessibilité donne des rôles et des noms aux boutons et champs.
  const p = page.locator('flt-semantics-placeholder');
  if (await p.count()) { await p.evaluate((e) => e.click()).catch(() => {}); await pause(800); }
}
async function arbre(titre) {
  const noms = await page.evaluate(() => [...document.querySelectorAll('flt-semantics [role], flt-semantics [aria-label], flt-semantics')]
    .map((e) => `${e.getAttribute('role') ?? ''}:${(e.getAttribute('aria-label') ?? e.textContent ?? '').trim().slice(0, 60)}`)
    .filter((x) => x.length > 1));
  console.log(`--- ${titre} : ${[...new Set(noms)].slice(0, 120).join(' | ')}`);
}
async function photo(nom) { await pause(2500); await page.screenshot({ path: `${dossier}/${nom}.png` }); console.log('capture', nom); }
async function clic(nom, options = {}) {
  const r = page.getByRole('button', { name: nom, exact: false }).first();
  if (await r.count()) return r.click(options);
  return page.getByText(nom, { exact: false }).first().click(options);
}
async function saisir(label, texte) {
  const c = page.getByRole('textbox', { name: label, exact: false }).first();
  await c.click();
  await pause(300);
  await page.keyboard.type(texte, { delay: 30 });
}
async function etapeSure(nom, f) {
  try { await f(); } catch (e) { console.log(`ÉCHEC ${nom} : ${e.message.split('\n')[0]}`); await page.screenshot({ path: `${dossier}/erreur-${nom}.png` }); await arbre(`après échec ${nom}`); }
}

await page.goto(url, { waitUntil: 'networkidle' });
await pause(6000);
await semantique();

if (etape === 'connexion') {
  await arbre('démarrage');
  await photo('01-bienvenue');
  await etapeSure('connexion', async () => {
    await clic('Me connecter');
    await pause(1500); await semantique();
    await saisir('Téléphone', '620000004');
    await photo('02-telephone');
    await clic('Recevoir le code');
    await pause(3000); await semantique();
    await saisir('Code', '123456');
    await photo('03-code');
    await clic('Valider');
    await pause(8000); await semantique();
    await arbre('après connexion');
    await photo('04-apres-connexion');
  });
} else {
  await arbre('accueil');
  await photo('10-accueil');
  for (const r of ['Élèves', 'Caisse', 'Personnel', 'Postes', 'Paramètres']) {
    await etapeSure(r, async () => { await clic(r); await pause(2000); await arbre(r); await photo(`20-${r}`); });
  }
}
await ctx.close();
