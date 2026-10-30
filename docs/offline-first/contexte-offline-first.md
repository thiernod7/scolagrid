# Contexte : architecture offline-first et onboarding client

Passation depuis une discussion claude.ai (30 octobre 2026).
Projet : application SaaS de gestion scolaire pour un réseau d'écoles en Guinée (Conakry).
Contrainte majeure : connexion internet instable ou absente dans les écoles.

## 1. Principe d'architecture retenu

L'interface ne parle jamais directement au serveur. Elle lit et écrit uniquement dans une base locale ; la synchronisation est un processus de fond séparé.

```
Appareil (poste direction, secrétariat, mobile enseignant)
  Interface  ->  Base locale (SQLite / IndexedDB, chiffrée)
             ->  File de sync (outbox des changements)
                        |  dès que le réseau est disponible
Cloud
  Moteur de sync (fusion, gestion des conflits)
  Base centrale (PostgreSQL)
                        |
  Redistribution des changements aux autres appareils
```

Comportements attendus :
- Hors ligne : l'app reste 100 % utilisable ; les écritures s'accumulent dans la file, avec un compteur visible par l'utilisateur.
- Retour du réseau : la file se vide vers le cloud, qui redistribue aux autres postes concernés.
- Conflits : à traiter dans le moteur de sync (piste évoquée : CRDT ou règles de fusion par type de donnée). Exemple critique : deux postes modifient la même note hors ligne.

## 2. Parcours d'onboarding d'une école cliente (6 étapes)

1. **Créer l'espace école (en ligne)**
   - Formulaire court : nom de l'école, ville, logo.
   - Compte admin validé par code SMS (plus fiable que l'e-mail en Guinée).
   - Création d'un tenant isolé avec identifiant unique.
   - Choix de l'offre et paiement (Orange Money, MoMo).

2. **Configurer l'établissement**
   - Année scolaire, cycles et niveaux, classes et salles, matières et coefficients, frais scolaires en GNF.
   - Modèles préremplis selon le programme guinéen ; import Excel des élèves.
   - Fait en ligne, depuis un endroit bien connecté ; modifiable ensuite même hors ligne.

3. **Inviter les utilisateurs**
   - Lien d'invitation par SMS ou WhatsApp.
   - Rôles et permissions : direction, secrétariat, enseignants (un enseignant ne voit pas la comptabilité).
   - Enseignant rattaché uniquement à ses classes et matières.
   - Désactivation possible à tout moment depuis le cloud.

4. **Activer chaque poste**
   - L'admin génère un QR code d'activation valable 15 minutes.
   - Le poste le scanne et reçoit un identifiant d'appareil unique.
   - Il reçoit un jeton de licence signé par le serveur (ex. JWT, clé privée), valable 30 jours hors ligne, vérifiable localement sans pouvoir être falsifié en changeant la date de l'appareil.
   - Base locale chiffrée ; révocation à distance en cas de vol.

5. **Synchronisation initiale**
   - Le poste ne reçoit que les données de son rôle.
   - Téléchargement par petits lots avec reprise en cas de coupure.
   - Données compressées pour économiser la connexion mobile.
   - Vérification finale de complétude de la base locale.

6. **Travail hors ligne**
   - Notes, absences, paiements : écriture d'abord en local.
   - File de changements visible par l'utilisateur.
   - Au retour du réseau : envoi au cloud et renouvellement automatique de la licence.
   - Alerte quelques jours avant l'expiration de la licence hors ligne.

Recommandation opérationnelle : les étapes 1 à 3 sont faites par l'équipe (ou un responsable local) depuis un lieu bien connecté ; l'activation des postes se fait sur place. L'école n'a besoin du réseau que quelques minutes.

## 3. Visuels animés (dossier `visuels/`)

Fichiers HTML autonomes, sans build : ouvrir `visuels/index.html` dans un navigateur.
Dépendance unique : la police d'icônes Tabler (CDN jsDelivr). Mode clair/sombre automatique.

| Fichier | Contenu | Technique |
|---|---|---|
| `1-architecture.html` | Schéma vertical appareil / cloud, paquets animés, bouton couper/rétablir le réseau, compteur de file | SVG + animations CSS |
| `2-postes-de-travail.html` | Cloud (serveur de sync + base) relié à 3 postes (Direction, Secrétariat, Enseignant). Écritures aléatoires, paquets qui montent puis redescendent vers les autres postes. Toucher un poste le met hors ligne, la file grossit puis se vide à la reconnexion | HTML + icônes Tabler + Web Animations API |
| `3-onboarding-apercu.html` | Stepper automatique des 6 étapes, une scène d'icônes par étape | HTML + Web Animations API |
| `4-onboarding-detaille.html` | Stepper manuel des 6 étapes, chacune avec une animation dédiée (formulaire qui se remplit, checklist, invitations WhatsApp, scan de QR code, barre de sync initiale, cycle hors ligne/en ligne) et 4 points de détail | HTML + Web Animations API |

Conventions graphiques : violet (#534AB7 / #7F77DD) = appareils et local, vert (#1D9E75 / #0F6E56) = cloud et réseau OK, rouge (#E24B4A) = hors ligne. Animations désactivées si `prefers-reduced-motion`.
Note : `sendPrompt()` est un vestige de claude.ai, redéfini ici en simple `console.log` ; on peut le remplacer par l'ouverture d'un panneau de détail.

## 4. Pistes à approfondir

- Détail technique de l'activation : format du QR code, contenu et signature du jeton, sécurité si un poste est volé.
- Stratégie de résolution des conflits par type de donnée (notes, absences, paiements).
- Choix du moteur de sync (solution existante ou développement maison).
- Version partageable des visuels animés (architecture, onboarding) pour l'équipe.
