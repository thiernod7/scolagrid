# Mettre le cloud en place

À faire une seule fois. Compter environ 20 minutes. Tout est gratuit.

## 1. Supabase (base centrale)

1. Créer un compte sur [supabase.com](https://supabase.com) puis un projet (région : Europe, la plus proche de la Guinée).
2. Authentication > Sign In / Providers : activer **Allow anonymous sign-ins**.
3. SQL Editor : coller le contenu de `supabase/schema.sql`, remplacer `MOT_DE_PASSE_A_CHANGER`, puis **Run**.
4. Noter l'**URL du projet** et la **clé publique** (Project Settings > API, clé `anon` ou `publishable`).

## 2. PowerSync (synchronisation)

1. Créer un compte sur [powersync.com](https://www.powersync.com), puis une instance.
2. Connexion à la base : utiliser la chaîne de connexion Supabase (Connect > Session pooler), avec l'utilisateur `powersync_role` et le mot de passe choisi à l'étape 1.3.
3. Client Auth : cocher **Use Supabase Auth**, laisser le reste vide.
4. Sync config : coller le contenu de `powersync/sync-config.yaml`, puis déployer.
5. Noter l'**URL de l'instance**.

## 3. Brancher l'application

Dans GitHub : Settings > Secrets and variables > Actions > onglet **Variables**, créer :

| Nom | Valeur |
|---|---|
| `SUPABASE_URL` | URL du projet Supabase |
| `SUPABASE_ANON_KEY` | clé publique Supabase |
| `POWERSYNC_URL` | URL de l'instance PowerSync |

Relancer ensuite le workflow « Compiler l'application » dans l'onglet Actions.
