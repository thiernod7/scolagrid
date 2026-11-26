# Évaluations : rendre le tout simple

> **Statut : proposition à valider.** Rien n'est encore codé.
> Point ouvert principal : voir **§ 10 · À décider**.

---

## 1. Le but

Que des personnes peu à l'aise avec l'informatique gèrent les notes de l'école,
**du réglage de l'année jusqu'au bulletin**, sans se perdre et sans formation longue.

Trois idées guident tout :

1. **Les mots de l'école**, pas ceux du logiciel.
2. **Le moins d'étapes possible** : ce que l'app peut deviner, elle le fait.
3. **Toujours savoir où on en est et quoi faire ensuite.**

## 2. Le premier cas concret (demain)

> Le **principal** saisit les notes de l'**évaluation du mois de novembre**,
> déjà passée sur papier, pour toutes ses classes.

Ce cas doit marcher en quelques gestes :
**Saisie des notes → la classe → « Évaluation du mois de novembre » → taper les notes.**

---

## 3. Qui fait quoi

| Qui | Ce qu'il fait |
|---|---|
| **Direction** (principal, directeur des études) | Vérifie les réglages en début d'année. Saisit les notes ou contrôle leur saisie. Sort les bulletins. Décide en fin d'année. |
| **Enseignant** (plus tard) | Saisit les notes de **ses** classes et matières, et rien d'autre. |
| **Professeur principal** (plus tard) | Voit toutes les matières de sa classe et ses bulletins. |
| **Secrétariat** | Peut aider à saisir, selon les droits donnés. |

Pour demain, **seule la direction** utilise les évaluations.

---

## 4. Les mots

| Aujourd'hui dans l'app | Désormais | Exemple |
|---|---|---|
| Période | **Trimestre** au primaire, **Semestre** au collège et au lycée, **Année** en maternelle | 1er semestre |
| Session (mensuelle) | **Évaluation du mois de …** | Évaluation du mois de novembre |
| Session (composition) | **Composition du … semestre** (… trimestre au primaire) | Composition du 1er semestre |
| Évaluation / épreuve | **Épreuve** : une classe, une matière | Maths en 7ème A |
| Type d'évaluation | **Sorte d'évaluation** (réglage seulement) | Évaluation du mois, Composition |
| Calendrier (page) | **Dates des évaluations** | |
| Publier le calendrier | **Annoncer les dates** | |
| Clôturer une session | **Clôturer le mois** (ou la composition) | |
| Clôturer une période | **Clôturer le semestre** (ou le trimestre) | |
| Remettre les notes | **J'ai terminé** (suivi, pas un verrou) | |
| Bulletin de session / de période | **Bulletin du mois** / **Bulletin du semestre** | |

Le mot « session » disparaît de l'écran.

---

## 4 bis. Comment tout s'emboîte

D'après la spécification « Notes & bulletins » (zip du 31/10/2026, `notes_bulletins.md`)
et ce que fait l'app aujourd'hui. Schéma : *Imbrication des notes* (artefact).

```
Année (octobre → juin)
└─ Cycle : il fixe le découpage et le barème
   ├─ Maternelle : 1 période (l'année), des acquis, ni moyenne ni rang
   ├─ Primaire : 3 trimestres, notes sur 10
   └─ Collège / Lycée : 2 semestres, notes sur 20
      └─ Semestre (ou trimestre)
         ├─ Évaluation d'octobre, de novembre… (une par mois)
         └─ Composition (une, en fin de période)
            └─ Classe
               └─ Matière, avec son coefficient
                  └─ Épreuve(s) → une note par élève
                     ├─ au mois : 1 ou 2 épreuves par matière (2 le plus souvent), parfois aucune
                     └─ à la composition : 1 seule
```

Ce qu'il ne faut pas oublier :

- **Le mois est une étiquette, pas le calendrier.** L'évaluation d'octobre passée le
  5 novembre reste celle d'octobre : sa fenêtre peut déborder (05/10 → 07/11).
  Aujourd'hui l'app colle les fenêtres aux mois du calendrier : à revoir.
- **Deux bulletins.** Celui du mois (allégé : notes, moyenne, rang) et celui du
  semestre (officiel : + repères de la classe, mention, appréciation du professeur principal).
- **Deux clôtures emboîtées.** Clôturer le mois fige ses notes et permet son bulletin ;
  clôturer le semestre fige tout et permet le bulletin officiel (en ligne seulement).
  Après clôture, une correction est tracée avec son motif. « J'ai terminé » (la remise)
  n'est qu'un suivi.
- **Une case n'est pas toujours une note** : non noté, non concerné, dispensé, absent
  justifié → ne comptent pas ; absent sans justificatif → 0 (réglable).
- **La moyenne du semestre repart de toutes les notes**, jamais des moyennes du mois.
  **Poids** (composition ×2, entre les notes d'une matière) ≠ **coefficient** (entre les matières).
- **Français scindé au collège** (dictée et questions / rédaction : deux matières) ;
  une seule matière au lycée.
- **Examen blanc** : classes d'examen (CEE, BEPC, Bac), ne compte pas par défaut.
- **Barème figé** dès que l'année est en cours.
- **Qui tape ≠ à qui est la note** : saisie par le principal, la note reste celle de la
  matière et de son enseignant.
- **Le calendrier est une prévision** (dates provisoires ; épreuve hors calendrier
  possible, rare). L'app l'a rendu obligatoire : c'est ce qui bloque la saisie directe.

---

## 5. Le déroulé d'une année

```
Rentrée ──► Réglages (déjà pré-remplis, on vérifie)
              │
              ▼
Chaque mois ──► (facultatif) Annoncer les dates
              ──► Saisir les notes de l'évaluation du mois
              │
Fin de semestre (trimestre) ──► Composition ──► Saisir les notes
              ──► Bulletin du semestre (trimestre)
              │
Fin d'année ──► Moyenne annuelle ──► Passage / redoublement
```

---

## 6. Ce qui ne va pas aujourd'hui

1. **Les mots** : « session », « type d'évaluation », « programmer », « publier »
   ne sont pas ceux de l'école.
2. **Des étapes cachées et obligatoires.** Avant de saisir une seule note, il faut avoir :
   - créé les sessions (Paramètres) ;
   - programmé chaque épreuve, classe par classe, matière par matière (Calendrier) ;
   - pour un enseignant : déclaré ses classes et matières (Personnel).

   S'il en manque une : écran vide, ou un renvoi vers « Paramètres › Périodes et sessions ».
3. **Trop de règles visibles d'un coup** : dates libres / en préparation / publiées,
   « à programmer avant le », rouvrir, aucune note avant la date de l'épreuve.
4. **Rien ne dit où on en est** : ni « 34 notes sur 42 en 7ème A », ni « bulletins prêts ».
5. **La saisie dépend du calendrier**, alors que le plus souvent l'évaluation a déjà eu lieu
   et qu'on veut juste entrer les notes.

---

## 7. Ce qu'on change

### 7.1 Le cadre de l'année est pré-rempli

À l'ouverture de l'année, l'app crée seule :

- les **périodes de chaque cycle** : 3 trimestres au primaire, 2 semestres au collège
  et au lycée, l'année entière en maternelle (dates modifiables) ;
- une **Évaluation du mois de …** pour chaque mois de cours ;
- une **Composition** à la fin de chaque trimestre ou semestre ;
- les **règles de calcul guinéennes** (déjà en place : composition qui compte double,
  absent non justifié = 0, absent justifié exclu, coefficients des matières).

Les **matières ne sont pas à ressaisir** : elles existent déjà pour chaque niveau
(Paramètres › Classes et matières, proposées par le modèle guinéen avec leurs coefficients).

### 7.2 Les épreuves se créent toutes seules

Pour chaque évaluation du mois et chaque composition, l'app crée **une épreuve par classe
et par matière**, datée par défaut de la fin du mois (ou de la composition).
On peut en ajouter une seconde dans le mois (le cas le plus courant), ou n'en avoir aucune.

- Si une classe n'a pas encore de matières : la page d'entrée le signale avec le bouton
  **Ajouter les matières**.
- Une matière non évaluée ce mois-là : on peut la **retirer** (voir § 10).

### 7.3 Saisir directement

**Saisie des notes → la classe → l'évaluation → les notes.**

- Plus besoin de passer par « Dates des évaluations » avant.
- Plus de blocage « aucune note avant la date » quand aucune date n'a été annoncée.
- Une fois les notes du mois saisies : **Clôturer le mois** → bulletin du mois.
- Le carnet de notes reste tel qu'il est (élèves en lignes, matières en colonnes,
  enregistrement automatique en quittant).

### 7.4 « Dates des évaluations » devient facultative

Elle sert à **annoncer les dates à l'avance** (aux enseignants, aux familles, en version
imprimée). Si l'école ne l'utilise pas, rien n'est bloqué.

Les réglages avancés (date limite pour fixer les dates, rouvrir après annonce)
restent possibles mais sont rangés dans Paramètres, pas affichés d'emblée.

### 7.5 Une page d'entrée « Évaluations » en 4 étapes

La première chose qu'on voit en ouvrant les évaluations :

| Étape | État affiché | Bouton |
|---|---|---|
| **1. Réglages de l'année** | Faits ✔ / à vérifier | Vérifier |
| **2. Dates du mois** *(facultatif)* | Annoncées / non annoncées | Annoncer les dates |
| **3. Notes** | « Novembre : 34 / 42 notes en 7ème A » (par classe) | Saisir |
| **4. Bulletins** | Du mois : clôturé ou non · Du semestre : prêt ou non | Clôturer le mois / Préparer les bulletins |

Le mois en cours est choisi d'office ; on peut changer de mois.

### 7.6 Jamais d'écran vide

Chaque fois qu'il manque quelque chose, l'écran dit **quoi faire**, avec **le bouton qui y
mène** directement. Exemples :

- « La 7ème A n'a pas encore de matières. → **Ajouter les matières** »
- « Aucun élève inscrit en 7ème A. → **Inscrire des élèves** »
- « Toutes les notes de novembre sont saisies. → **Préparer les bulletins** »

---

## 8. Le menu

```
ÉVALUATIONS
  Évaluations            ← nouvelle page d'entrée (les 4 étapes)
  Saisie des notes
  Dates des évaluations  ← ancien « Calendrier », facultatif
  Bulletins
  Fin d'année
```

Les réglages restent dans **Paramètres › Évaluations**
(périodes, sortes d'évaluation, calcul et mentions).

---

## 9. Ordre de réalisation

1. **Pour demain**
   - Les épreuves de chaque évaluation créées automatiquement (une par classe et matière).
   - Saisie possible sans passer par les dates.
   - Les nouveaux mots (§ 4).
2. **Ensuite**
   - La page d'entrée en 4 étapes.
   - Les messages « quoi faire » à la place des écrans vides.
3. **Plus tard**
   - Les enseignants et le professeur principal (déjà prévus côté serveur).
   - Réglages avancés des dates rangés dans Paramètres.

---

## 10. À décider

Tranché : primaire en trimestres, collège et lycée en semestres (comme la spécification).

1. **À l'évaluation du mois, toutes les matières sont-elles évaluées dans chaque classe ?**
   - Oui → une épreuve par matière d'office.
   - Non → il faut pouvoir en retirer (ou choisir les matières du mois).
2. **Les fenêtres des mois** : collées au calendrier (1er → 31) ou débordantes comme dans
   la spécification (05/10 → 07/11) ?
3. **Le bulletin du mois** : les écoles le distribuent-elles vraiment chaque mois ?
4. **Le nom du menu** « Dates des évaluations » te convient-il ?
