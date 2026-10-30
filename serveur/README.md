# Serveur Scolagrid

Tout ce qui tourne sur le VPS, installé par le workflow **VPS - Installer** (onglet Actions).

| Adresse | Service |
|---|---|
| `https://api.<ip>.sslip.io` | Supabase : base de données, comptes, API, tableau d'administration |
| `https://sync.<ip>.sslip.io` | PowerSync : synchronisation avec les postes |

`<ip>` est l'adresse du VPS avec des tirets (ex. `178-162-254-106`). Quand on aura un nom de domaine, il suffira de changer l'hôte passé à `installer.sh`.

## Fichiers

- `installer.sh` : installe ou met à jour le serveur. Rejouable sans risque.
- `docker-compose.scolagrid.yml` : nos ajouts au `docker-compose.yml` officiel de Supabase.
- `Caddyfile` : HTTPS et redirection vers les services.
- `init.sql` : tables et droits de la base.
- `powersync/` : configuration de la synchronisation.

## Secrets

Générés une seule fois sur le serveur, dans `/opt/scolagrid/supabase/.env`. Ils ne sont jamais dans le repo ni dans les journaux.

Mot de passe du tableau d'administration (utilisateur `admin`) :

```bash
ssh vps "grep DASHBOARD_PASSWORD /opt/scolagrid/supabase/.env"
```
