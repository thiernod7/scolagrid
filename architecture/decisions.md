# Architecture Scolagrid

Choix techniques retenus. Ils suivent le principe « offline-first » décrit dans `contexte-offline-first.md` et illustré dans `visuels/1-architecture.html`.

| Rôle | Outil | Pourquoi |
|---|---|---|
| Application | **Flutter** (`app/`) | Une vraie app Windows (direction, secrétariat) et Android (enseignants) avec un seul code. |
| Base locale | **SQLite**, gérée par PowerSync | L'app lit et écrit uniquement ici, donc elle marche sans réseau. |
| File de sync | **PowerSync** (client) | Garde les écritures faites hors ligne et les envoie dès que le réseau revient. |
| Moteur de sync | **PowerSync**, sur le VPS (`serveur/powersync/`) | Redistribue les changements aux autres postes. Open source, gratuit. |
| Base centrale | **PostgreSQL** via **Supabase**, sur le VPS (`serveur/`) | Supabase ajoute à PostgreSQL les comptes utilisateurs, l'API et un tableau d'administration. Open source, gratuit. |
| Serveur | **VPS** Ubuntu, avec **Docker** et **Caddy** (HTTPS automatique) | Installé et mis à jour par le workflow « VPS - Installer ». |
| Compilation | **GitHub Actions** (`.github/workflows/app.yml`) | Produit l'installable Windows et l'APK Android à chaque modification. |

## Le test « Hello »

L'app actuelle ne contient qu'un écran : un bouton « Dire bonjour » qui écrit dans la base locale.

- Sans cloud configuré, l'app fonctionne en local seulement.
- Avec le cloud, chaque « Bonjour » apparaît sur tous les postes. Hors ligne, il attend dans la file (compteur « En attente d'envoi ») puis part quand le réseau revient.

C'est la preuve que toute la chaîne fonctionne avant d'écrire la vraie gestion scolaire.

## À décider plus tard

- Gestion des conflits (deux postes modifient la même note hors ligne).
- Séparation des écoles (un espace par école) et rôles (direction, secrétariat, enseignant).
- Connexion des utilisateurs : pour le test, la connexion est anonyme.
