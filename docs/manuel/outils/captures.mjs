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
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log('console:', m.type(), m.text().slice(0, 600)); });
page.on('pageerror', (e) => console.log('pageerror:', String(e).slice(0, 600)));

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

// Élèves fictifs à importer (noms courants, téléphones fictifs en 600 00 …).
function fichierDemo() {
  const prenomsG = ['Mamadou', 'Ibrahima', 'Alpha', 'Ousmane', 'Sékou', 'Thierno', 'Abdoulaye', 'Mohamed', 'Lansana', 'Boubacar'];
  const prenomsF = ['Fatoumata', 'Mariama', 'Aïssatou', 'Kadiatou', 'Hawa', 'Fanta', 'Mabinty', 'Djénabou', 'Oumou', 'Saran'];
  const noms = ['DIALLO', 'BAH', 'BARRY', 'SOW', 'CAMARA', 'SYLLA', 'CONDÉ', 'KEITA', 'TOURÉ', 'SOUMAH', 'BANGOURA', 'KOUROUMA'];
  const classes = ['CP1 A', 'CP1 B', 'CE2 A', 'CE2 B', 'CM2 A', 'CM2 B', '7ème A', '7ème B', '10ème A', '10ème B'];
  const naissance = { CP1: 2020, CE2: 2017, CM2: 2015, '7ème': 2014, '10ème': 2011 };
  const lignes = ["NOM;PRÉNOMS;SEXE;DATE DE NAISSANCE;LIEU DE NAISSANCE;CLASSE;TYPE;PRÉNOM(S) DU PARENT;NOM DU PARENT;TÉLÉPHONE;LIEN;MATRICULE D'ÉTAT;ANCIEN MATRICULE;QUARTIER"];
  for (let i = 0; i < 48; i++) {
    const f = i % 2 === 1;
    const nom = noms[(i * 7) % noms.length];
    const classe = classes[i % classes.length];
    const an = naissance[classe.split(' ')[0]];
    const jour = String(1 + ((i * 3) % 27)).padStart(2, '0'), mois = String(1 + ((i * 5) % 12)).padStart(2, '0');
    const parent = i % 3 === 0 ? ['Hadja Mariama', 'mere', 'Mère'] : ['Elhadj Sékou', 'pere', 'Père'];
    lignes.push([nom, f ? prenomsF[i % 10] : prenomsG[i % 10], f ? 'F' : 'M', `${jour}/${mois}/${an}`, 'Conakry', classe,
      i % 4 === 0 ? 'Nouvelle' : 'Réinscription', parent[0], nom, `600 00 ${String(10 + Math.floor(i / 2)).padStart(2, '0')} ${String(i).padStart(2, '0')}`,
      parent[2], '', `2025-${String(100 + i)}`, ['Kipé', 'Ratoma', 'Lambanyi', 'Nongo'][i % 4]].join(';'));
  }
  fs.writeFileSync('eleves-demo.csv', '﻿' + lignes.join('\r\n') + '\r\n');
  return 'eleves-demo.csv';
}
async function visible(texte) { return (await page.getByText(texte, { exact: false }).count()) > 0; }
async function code(pin) {
  if (await page.getByRole('textbox', { name: 'Code PIN', exact: true }).count()) {
    await saisir('Code PIN', pin); await page.keyboard.press('Enter'); await pause(4000); await semantique();
  }
}
async function menu(nom) { await clic(nom); await pause(2500); await semantique(); }

if (etape === 'connexion') {
  await arbre('démarrage');
  await photo('01-bienvenue');
  await etapeSure('connexion', async () => {
    await clic('Me connecter');
    await pause(1500); await semantique();
    await saisir('Téléphone', '620000009');
    await photo('02-telephone');
    await clic('Recevoir le code');
    await pause(3000); await semantique();
    await saisir('Code', '123456');
    await photo('03-code');
    await clic('Valider');
    await pause(8000); await semantique();
    await arbre('après connexion');
    await photo('04-espace-ecole');
  });
} else if (etape === 'mobile') {
  // Revue des écrans sur téléphone (390 × 844) : chaque écran principal, ouvert tel quel.
  await page.setViewportSize({ width: 390, height: 844 });
  await pause(4000); await semantique(); await code('2580');
  const voir = (texte, ms = 8000) => page.getByText(texte, { exact: false }).first().waitFor({ timeout: ms }).then(() => true, () => false);
  const fermer = async () => {
    for (let i = 0; i < 3; i++) {
      const b = page.getByRole('button', { name: /Retour|Fermer|Annuler/ });
      if (!(await b.count())) break;
      await b.last().click().catch(() => {}); await pause(1500); await semantique();
    }
  };
  const onglet = async (nom) => {
    await fermer();
    await page.getByRole('tab', { name: nom, exact: true }).click({ timeout: 10000 }); await pause(3000); await semantique();
  };
  const plus = async (nom) => {
    await onglet('Plus'); await arbre('menu plus');
    const b = page.getByRole('button', { name: nom, exact: false });
    if (await b.count()) await b.last().click({ timeout: 10000 });
    else await page.getByText(nom, { exact: false }).last().click({ timeout: 10000 });
    await pause(3000); await semantique();
  };
  await etapeSure('m-accueil', async () => { await onglet('Accueil'); await photo('m01-accueil'); });
  await etapeSure('m-eleves', async () => {
    await onglet('Élèves'); await voir('BAH'); await photo('m02-eleves');
    await page.mouse.click(200, 215); await pause(3500); await semantique();
    await photo('m03-fiche-eleve');
    await clic('Contacts'); await pause(1500); await photo('m04-fiche-contacts');
    await clic('Finances'); await pause(1500); await photo('m05-fiche-finances');
  });
  await etapeSure('m-inscription', async () => {
    await onglet('Élèves'); await clic('Nouvelle inscription'); await pause(3000); await semantique(); await photo('m06-inscription');
  });
  await etapeSure('m-caisse', async () => {
    await onglet('Caisse'); await photo('m07-caisse');
    await clic('Encaisser'); await pause(3000); await semantique(); await photo('m08-encaisser');
  });
  await etapeSure('m-familles', async () => {
    await plus('Familles'); await photo('m09-familles');
    await page.mouse.click(200, 140); await pause(3000); await semantique();
    await photo('m10-fiche-famille');
  });
  await etapeSure('m-depenses', async () => {
    await plus('Dépenses'); await photo('m11-depenses');
    await clic('Nouvelle dépense'); await pause(2500); await semantique(); await photo('m12-nouvelle-depense');
  });
  await etapeSure('m-recouvrement', async () => {
    await plus('Recouvrement'); await pause(3000); await photo('m17-recouvrement');
    await page.getByText('7ème A', { exact: true }).first().click(); await pause(4000); await semantique();
    await photo('m18-recouvrement-classe');
  });
  await etapeSure('m-personnel', async () => { await plus('Personnel'); await photo('m13-personnel'); });
  await etapeSure('m-postes', async () => { await plus('Postes'); await photo('m14-postes'); });
  await etapeSure('m-parametres', async () => {
    await plus('Paramètres'); await photo('m15-parametres');
    await page.getByText('Frais', { exact: false }).first().click(); await pause(3000); await semantique(); await photo('m16-frais');
  });
} else {
  // Barre latérale (PC 1440 × 900) : positions fixes.
  const barre = { 'Accueil': 79, 'Élèves': 154, 'Familles': 192, 'Caisse': 267, 'Dépenses': 305, 'Recouvrement': 343, 'Personnel': 418, 'Postes': 456, 'Paramètres': 494 };
  const attendre = (texte, ms = 12000) => page.getByText(texte, { exact: false }).first().waitFor({ timeout: ms }).then(() => true, () => false);
  const retour = async () => {
    const b = page.getByRole('button', { name: 'Retour' });
    if (await b.count()) await b.last().click(); else await page.keyboard.press('Escape');
    await pause(2000); await semantique();
  };
  const aller = async (r, attendu) => {
    for (let i = 0; i < 3 && (await page.getByRole('button', { name: 'Retour' }).count()); i++) await retour();
    for (let i = 0; i < 3; i++) {
      await page.mouse.click(110, barre[r]); await pause(2500); await semantique();
      if (!attendu || (await attendre(attendu, 5000))) return;
    }
  };
  await pause(4000); await semantique(); await code('2580');
  await attendre('FINANCES', 20000);
  await arbre('accueil');
  await etapeSure('poste', async () => {
    if (!(await attendre('Activer ce poste', 15000))) return;
    await photo('10-tableau-de-bord-vide');
    await clic('Activer ce poste'); await pause(2500); await semantique();
    await saisir('Code PIN (4 à 6 chiffres)', '2580');
    await saisir('Confirmer le code PIN', '2580');
    await photo('11-activer-poste');
    await page.getByRole('button', { name: 'Activer ce poste' }).last().click();
    await pause(5000); await semantique();
    await photo('12-poste-active');
    await clic('Compris'); await pause(2000); await semantique();
  });
  await etapeSure('parametres', async () => {
    await aller('Paramètres', 'Mise en route'); await arbre('paramètres'); await photo('20-parametres');
    await page.getByText('Mise en route', { exact: false }).first().click(); await pause(2500); await semantique();
    await arbre('mise en route'); await photo('21-mise-en-route');
    await retour();
  });
  await etapeSure('import', async () => {
    await aller('Accueil', 'FINANCES');
    if (!(await visible("Importer ma liste d'élèves"))) return;
    await clic("Importer ma liste d'élèves"); await pause(2500); await semantique();
    await photo('30-importer');
    const fichier = fichierDemo();
    const [choix] = await Promise.all([page.waitForEvent('filechooser'), clic('Choisir le fichier')]);
    await choix.setFiles(fichier);
    await pause(6000); await semantique();
    await photo('31-import-verifie');
    await clic('Importer 48'); await pause(1500); await semantique();
    await photo('32-import-confirmer');
    await clic('Confirmer'); await pause(12000); await semantique();
    await photo('33-import-termine');
    await clic('Compris'); await pause(3000); await semantique();
  });
  await etapeSure('tableau', async () => { await aller('Accueil', 'FINANCES'); await pause(3000); await photo('10-tableau-de-bord'); });
  await etapeSure('eleves', async () => {
    await aller('Élèves', 'DIALLO'); await arbre('élèves'); await photo('40-eleves');
    await page.mouse.click(360, 254); await pause(3500); await semantique();
    await arbre('fiche'); await photo('41-fiche-eleve');
    await retour();
  });
  await etapeSure('inscription', async () => {
    await aller('Élèves', 'Nouvelle inscription'); await clic('Nouvelle inscription'); await pause(3000); await semantique();
    await photo('42-inscription-recherche');
    await page.keyboard.press('Escape');
    await clic('Nouvelle inscription'); await pause(3000); await semantique();
    await arbre('formulaire'); await photo('43-inscription-formulaire');
    await retour();
  });
  await etapeSure('encaisser', async () => {
    await aller('Caisse', 'Journal de caisse'); await photo('50-caisse-vide');
    await clic('Dépenses'); await pause(3500); await semantique(); await arbre('dépenses'); await photo('58-depenses');
    await clic('Nouvelle dépense'); await pause(2500); await semantique(); await photo('59-nouvelle-depense');
    await page.keyboard.press('Escape'); await pause(1500); await retour();
    await clic('Encaisser'); await pause(3000); await semantique();
    const champ = page.getByRole('textbox', { name: 'Ajouter un élève', exact: false }).first();
    await champ.click(); await pause(300); await page.keyboard.type('DIALLO', { delay: 40 }); await pause(2500); await semantique();
    await arbre('recherche encaisser'); await photo('51-encaisser-recherche');
    await page.getByText('DIALLO', { exact: false }).nth(1).click(); await pause(2500); await semantique();
    await arbre('encaisser élève'); await photo('52-encaisser-eleve');
    await page.getByRole('button', { name: 'Solde' }).first().click(); await pause(1500);
    await photo('53-encaisser-montant');
    await clic('Enregistrer et imprimer'); await pause(2000); await semantique();
    await photo('54-encaisser-confirmer');
    const [nouvelle] = await Promise.all([
      ctx.waitForEvent('page', { timeout: 15000 }).catch(() => null),
      page.getByRole('button', { name: 'Confirmer' }).last().click(),
    ]);
    await pause(8000);
    if (nouvelle) { await nouvelle.waitForTimeout(4000); await nouvelle.screenshot({ path: `${dossier}/55-recu-pdf.png` }); await nouvelle.close(); }
    await photo('55-apres-encaissement');
    await page.keyboard.press('Escape'); await pause(2000); await semantique();
    await aller('Caisse', 'Journal de caisse'); await pause(4000); await arbre('journal'); await photo('56-journal-caisse');
    await page.mouse.click(700, 220); await pause(3000); await semantique(); await arbre('reçu'); await photo('57-recu');
    await retour();
  });
  await etapeSure('familles', async () => {
    await aller('Familles', 'Parents & tuteurs'); await pause(3000); await arbre('familles'); await photo('45-familles');
    // Une ligne du tableau (le lien « Père », « Mère »… sous le nom du parent).
    const ligne = page.getByRole('button', { name: /Père|Mère|Oncle|Tante/ });
    if (await ligne.count()) await ligne.first().click(); else await page.mouse.click(500, 340);
    await pause(3500); await semantique(); await arbre('fiche famille'); await photo('46-fiche-famille-panneau');
    const fermer = page.getByRole('button', { name: 'Fermer' });
    if (await fermer.count()) { await fermer.first().click(); await pause(1500); }
  });
  await etapeSure('recouvrement', async () => {
    await aller('Recouvrement', 'Choisissez une classe'); await pause(4000); await photo('61-recouvrement');
    await page.getByText('7ème A', { exact: true }).first().click(); await pause(4000); await semantique();
    await photo('62-recouvrement-classe');
    await retour();
  });
  await etapeSure('menu-depenses', async () => { await aller('Dépenses', 'Nouvelle dépense'); await photo('58-depenses'); });
  for (const r of ['Personnel', 'Postes']) await etapeSure(r, async () => { await aller(r); await pause(2000); await arbre(r); await photo(`60-${r.toLowerCase()}`); });
}
await ctx.close();
// vérification de la caisse (0.9.8) et du menu Dépenses (0.9.9)
