# Serveur Scolagrid

Tout ce qui tourne sur le VPS, installé par le workflow **VPS - Installer** (onglet Actions).

Deux environnements tournent sur le même VPS, chacun avec sa base et ses secrets :

| Environnement | Adresses | Installé depuis |
|---|---|---|
| Production | `https://api.<ip>.sslip.io` et `https://sync.<ip>.sslip.io` | la branche principale |
| Essai | `https://api-essai.<ip>.sslip.io` et `https://sync-essai.<ip>.sslip.io` | toute autre branche |

`api` = Supabase (base, comptes, API, tableau d'administration), `sync` = PowerSync. Seule la production est sauvegardée ; l'essai contient des données jetables.

`<ip>` est l'adresse du VPS avec des tirets (ex. `178-162-254-106`). Quand on aura un nom de domaine, il suffira de changer l'hôte passé à `installer.sh`.

## Fichiers

- `installer.sh` : installe ou met à jour le serveur. Rejouable sans risque.
- `docker-compose.scolagrid.yml` : nos ajouts au `docker-compose.yml` officiel de Supabase.
- `caddy/` : le proxy HTTPS, unique et partagé par les deux environnements (réseau Docker `scolagrid-web`).
- `migrations/` : les changements de la base, numérotés (`001_…`, `002_…`). Chacun est appliqué une seule fois, dans l'ordre, par `appliquer-migrations.sh`. On ne modifie jamais une migration déjà appliquée : on en ajoute une nouvelle. GitHub les teste sur une base jetable avant chaque installation.
- `powersync/` : configuration de la synchronisation.

## Secrets

Générés une seule fois sur le serveur, dans `/opt/scolagrid/supabase/.env`. Ils ne sont jamais dans le repo ni dans les journaux.

Mot de passe du tableau d'administration (utilisateur `admin`) :

```bash
ssh vps "grep DASHBOARD_PASSWORD /opt/scolagrid/supabase/.env"         # production
ssh vps "grep DASHBOARD_PASSWORD /opt/scolagrid/essai/supabase/.env"   # essai
```

## Sauvegardes

Chaque nuit vers 2 h 30, `scolagrid-sauvegarder` copie la base complète (`pg_dumpall`) et le fichier de secrets `.env` vers un stockage externe, chiffrés avec restic. On garde 30 sauvegardes quotidiennes et 12 mensuelles.

- Configuration : 4 secrets GitHub, `SAUVEGARDE_DEPOT`, `SAUVEGARDE_CLE_ID`, `SAUVEGARDE_CLE_SECRETE` et `SAUVEGARDE_MOT_DE_PASSE`. Le workflow « VPS - Installer » les dépose sur le serveur dans `/opt/scolagrid/sauvegarde.env`.
- Vérifier ou sauvegarder tout de suite : workflow « VPS - Sauvegardes ».
- **Le mot de passe de chiffrement doit aussi être gardé hors de GitHub**, par exemple sur papier ou dans un gestionnaire de mots de passe. Sans lui, les sauvegardes sont illisibles, même pour nous.

### Restaurer la base (sur le serveur)

```bash
sudo -i
set -a; . /opt/scolagrid/sauvegarde.env; set +a
restic snapshots                                   # choisir une sauvegarde
restic dump --tag base latest /scolagrid.sql > /tmp/scolagrid.sql
docker exec -i supabase-db psql -U supabase_admin -d postgres < /tmp/scolagrid.sql
```

La restauration complète sur un serveur neuf (secrets compris) sera écrite et testée dans un workflow dédié.

## Surveillance

Le workflow « VPS - Surveiller » vérifie la production toutes les 30 minutes : API et synchronisation joignables, certificat HTTPS, disque, mémoire, services, ancienneté de la dernière sauvegarde. En cas de problème, il échoue et GitHub envoie un e-mail. Le résumé de chaque vérification est visible dans l'onglet Actions.
