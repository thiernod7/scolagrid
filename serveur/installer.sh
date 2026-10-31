#!/bin/bash
# Installe ou met à jour un environnement Scolagrid sur le VPS. Rejouable sans risque.
# Usage : bash installer.sh <hôte> <prod|essai>   (ex. 178-162-254-106.sslip.io prod)
#
# Production : api.<hôte> et sync.<hôte>, dossier /opt/scolagrid/supabase, sauvegardée.
# Essai      : api-essai.<hôte> et sync-essai.<hôte>, dossier /opt/scolagrid/essai/supabase.
# Chaque environnement a sa propre base et ses propres secrets, générés une seule
# fois dans son .env. Le repo est public : ce script n'affiche aucun secret.

set -euo pipefail
HOST="$1"
ENVIRONNEMENT="${2:-prod}"
SRC="$(cd "$(dirname "$0")" && pwd)"
case "$ENVIRONNEMENT" in
  prod)  DIR=/opt/scolagrid/supabase;       PREFIXE="";       SUFFIXE="" ;;
  essai) DIR=/opt/scolagrid/essai/supabase; PREFIXE="essai-"; SUFFIXE="-essai" ;;
  *) echo "Environnement inconnu : $ENVIRONNEMENT (prod ou essai)"; exit 1 ;;
esac
DB="${PREFIXE}supabase-db"
API="api$SUFFIXE.$HOST"
SYNC="sync$SUFFIXE.$HOST"
echo "Environnement : $ENVIRONNEMENT ($API)"
export DEBIAN_FRONTEND=noninteractive
step() { echo; echo "===== $1 ====="; }
dc() { sudo docker compose "$@"; }

step "Paquets"
sudo apt-get update -qq
sudo apt-get install -y -qq docker.io docker-compose-v2 git openssl ufw curl >/dev/null
sudo systemctl enable --now docker >/dev/null 2>&1
sudo docker --version
sudo docker compose version

step "Pare-feu"
sudo ufw allow OpenSSH >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443 >/dev/null
sudo ufw --force enable >/dev/null
sudo ufw status | sed -n '1,12p'

step "Fichiers Supabase officiels"
if [ ! -d "$DIR" ]; then
  tmp=$(mktemp -d)
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase "$tmp"
  git -C "$tmp" sparse-checkout set docker
  sudo mkdir -p "$(dirname "$DIR")"
  sudo cp -r "$tmp/docker" "$DIR"
  sudo chown -R "$(id -un)": "$DIR"   # surtout pas tout /opt/scolagrid : la base de l'autre environnement y vit
  rm -rf "$tmp"
  echo "téléchargés"
else
  echo "déjà présents"
fi
cd "$DIR"
cp "$SRC/docker-compose.scolagrid.yml" .
rm -f init.sql Caddyfile
mkdir -p powersync
cp "$SRC"/powersync/* powersync/
# PowerSync ne relit pas sa configuration : on note celle qu'il a chargée.
PS_CONFIG=$(cat powersync/* | sha256sum | cut -c1-16)
[ "$(cat .powersync-chargee 2>/dev/null)" = "$PS_CONFIG" ] && PS_CHANGE=non || PS_CHANGE=oui

step "Secrets"
set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
if [ ! -f .env ]; then
  cp .env.example .env
  sh utils/generate-keys.sh --update-env >/dev/null
  rm -f .env.old
  set_env PS_POWERSYNC_PASSWORD "$(openssl rand -hex 24)"
  set_env PS_STORAGE_PASSWORD "$(openssl rand -hex 24)"
  echo "générés"
else
  echo "conservés"
fi
set_env COMPOSE_FILE docker-compose.yml:docker-compose.scolagrid.yml
if [ "$ENVIRONNEMENT" = essai ]; then set_env COMPOSE_PROJECT_NAME scolagrid-essai; fi
set_env SCOLAGRID_ENV "$ENVIRONNEMENT"
set_env PREFIXE "$PREFIXE"
set_env SCOLAGRID_HOST "$HOST"
set_env SUPABASE_PUBLIC_URL "https://$API"
set_env API_EXTERNAL_URL "https://$API/auth/v1"
set_env SITE_URL "https://$API"
if [ "$ENVIRONNEMENT" = essai ]; then
  # Numéros de test : code fixe, aucun SMS envoyé. Publics, donc réservés à l'essai.
  set_env ENABLE_PHONE_SIGNUP true
  set_env ENABLE_PHONE_AUTOCONFIRM true
  set_env SMS_TEST_OTP "224620000001:123456,224620000002:123456,224620000003:123456,224620000004:123456,224620000005:123456"
  set_env ENABLE_ANONYMOUS_USERS false
elif sudo test -f /opt/scolagrid/sms.env; then
  # Production avec NimbaSMS : les codes partent par le crochet scolagrid.envoyer_sms.
  set_env ENABLE_PHONE_SIGNUP true
  set_env ENABLE_PHONE_AUTOCONFIRM true
  set_env SMS_TEST_OTP ""
  set_env SMS_HOOK_ENABLED true
  set_env SMS_HOOK_URI "pg-functions://postgres/scolagrid/envoyer_sms"
  set_env ENABLE_ANONYMOUS_USERS false
else
  # Production : téléphone fermé tant que les secrets NimbaSMS ne sont pas fournis.
  set_env ENABLE_PHONE_SIGNUP false
  set_env SMS_TEST_OTP ""
  set_env SMS_HOOK_ENABLED false
  set_env ENABLE_ANONYMOUS_USERS true   # app « Bonjour » de test
fi
set_env DASHBOARD_USERNAME admin
set_env POOLER_TENANT_ID scolagrid
jwt_secret=$(grep '^JWT_SECRET=' .env | cut -d= -f2-)
set_env PS_JWT_K "$(printf %s "$jwt_secret" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
chmod 600 .env

step "Réseau partagé avec Caddy"
sudo docker network inspect scolagrid-web >/dev/null 2>&1 || sudo docker network create scolagrid-web >/dev/null
echo "scolagrid-web prêt"

step "Base de données"
dc up -d --quiet-pull db
for i in $(seq 1 60); do
  [ "$(sudo docker inspect -f '{{.State.Health.Status}}' "$DB")" = healthy ] && break
  sleep 3
done
# Le dossier de données doit appartenir à postgres dans le conteneur
# (répare un changement de propriétaire accidentel, sans effet sinon).
sudo docker exec -u root "$DB" chown -R postgres:postgres /var/lib/postgresql/data

step "Migrations"
SUDO=sudo bash "$SRC/appliquer-migrations.sh" "$DB" "$SRC/migrations"
pw=$(grep '^PS_POWERSYNC_PASSWORD=' .env | cut -d= -f2-)
sudo docker exec -i "$DB" psql -q -X -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v pw="$pw" \
  <<<"alter role powersync_role with password :'pw';"
if [ "$ENVIRONNEMENT" = prod ] && sudo test -f /opt/scolagrid/sms.env; then
  # Identifiants NimbaSMS rangés dans la base, lus seulement par le crochet d'envoi.
  # Passés par variables psql : jamais affichés.
  ( set -a; eval "$(sudo cat /opt/scolagrid/sms.env)"; set +a
    sudo docker exec -i "$DB" psql -q -X -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
      -v sid="$NIMBA_SERVICE_ID" -v tok="$NIMBA_SECRET_TOKEN" -v exp="$NIMBA_EXPEDITEUR" <<'SQL'
insert into scolagrid.reglages (cle, valeur) values
  ('nimba_service_id', :'sid'), ('nimba_secret_token', :'tok'), ('nimba_expediteur', :'exp')
on conflict (cle) do update set valeur = excluded.valeur;
-- Expéditeur facultatif : vide, la demande part sans nom d'expéditeur.
delete from scolagrid.reglages where cle = 'nimba_expediteur' and trim(valeur) = '';
SQL
  ) && echo "NimbaSMS configuré pour l'envoi des codes"
fi

step "Services"
dc up -d --quiet-pull --remove-orphans db auth rest meta studio api-gw powersync-storage powersync
sleep 20
PS="${PREFIXE}scolagrid-powersync"
if [ "$PS_CHANGE" = oui ]; then
  sudo docker restart "$PS" >/dev/null && echo "PowerSync redémarré (configuration modifiée)"
  echo "$PS_CONFIG" > .powersync-chargee
  sleep 15
  erreurs=$(sudo docker logs --since 30s "$PS" 2>&1 | grep -iE '"level":"error"|sync config' | tail -5)
  [ -z "$erreurs" ] || { echo "Messages de PowerSync :"; echo "$erreurs"; }
fi
projet=$([ "$ENVIRONNEMENT" = essai ] && echo scolagrid-essai || echo supabase)
for c in $(sudo docker ps --filter "label=com.docker.compose.project=$projet" --filter health=unhealthy --format '{{.Names}}'); do
  sudo docker restart "$c" >/dev/null && echo "redémarré (était en mauvaise santé) : $c"
done
dc ps --format 'table {{.Name}}\t{{.Status}}'

step "Proxy HTTPS (Caddy, partagé)"
# L'ancien Caddy faisait partie de la production ; il est remplacé par celui-ci.
ancien=$(sudo docker ps -aq --filter name='^scolagrid-caddy$' --filter label=com.docker.compose.project=supabase)
[ -z "$ancien" ] || sudo docker rm -f $ancien >/dev/null
sudo mkdir -p /opt/scolagrid/caddy /opt/scolagrid/web/prod /opt/scolagrid/web/essai
sudo cp "$SRC/caddy/docker-compose.yml" "$SRC/caddy/Caddyfile" /opt/scolagrid/caddy/
echo "SCOLAGRID_HOST=$HOST" | sudo tee /opt/scolagrid/caddy/.env >/dev/null
( cd /opt/scolagrid/caddy && sudo docker compose up -d --quiet-pull )
sudo docker exec scolagrid-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
echo "en place"

step "Vérification en ligne"
anon=$(grep '^ANON_KEY=' .env | cut -d= -f2-)
check() {
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$@" || true)
    [ "$code" = 200 ] && { echo "OK   ${*: -1}"; return; }
    sleep 5
  done
  echo "ÉCHEC ${*: -1} (code $code)"
}
check -H "apikey: $anon" "https://$API/auth/v1/health"
check "https://$SYNC/probes/liveness"
# Le navigateur doit être autorisé à appeler l'API depuis le site web (CORS).
cors=$(curl -s -o /dev/null -D - -X OPTIONS -H "Origin: https://app$SUFFIXE.$HOST" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: apikey,content-type" \
  "https://$API/auth/v1/otp" | grep -i '^access-control-allow-origin' || true)
if [ -n "$cors" ]; then echo "OK   API autorisée depuis le site web"; else echo "ÉCHEC API non autorisée depuis le site web (CORS)"; fi
if [ "$ENVIRONNEMENT" = essai ]; then
  # Parcours réel : code par téléphone, jeton, puis lecture protégée par les règles.
  # Numéro de test n°5, réservé à ce contrôle (les n°1 à 4 sont libres pour les essais à la main).
  curl -s -o /dev/null -H "apikey: $anon" -H "Content-Type: application/json" \
    -d '{"phone":"224620000005"}' "https://$API/auth/v1/otp" || true
  jeton=$(curl -s -H "apikey: $anon" -H "Content-Type: application/json" \
    -d '{"phone":"224620000005","token":"123456","type":"sms"}' "https://$API/auth/v1/verify" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  if [ -n "$jeton" ]; then
    echo "OK   connexion par téléphone (numéro de test)"
    auth=(-H "apikey: $anon" -H "Authorization: Bearer $jeton" -H "Content-Type: application/json")
    check "${auth[@]}" "https://$API/rest/v1/organisations?select=id"
    if [ "$(curl -s "${auth[@]}" "https://$API/rest/v1/organisations?select=id")" = "[]" ]; then
      org=$(curl -s "${auth[@]}" -d '{"nom_groupe":"Groupe scolaire de contrôle","ville":"Conakry","nom_site":"Site de contrôle","nom_complet":"Contrôle automatique"}' \
        "https://$API/rest/v1/rpc/creer_espace_ecole")
      echo "Espace école de contrôle créé : $org"
    fi
    nb=$(curl -s "${auth[@]}" "https://$API/rest/v1/sites?select=id" | grep -o '"id"' | wc -l)
    if [ "$nb" -ge 1 ]; then echo "OK   espace école visible avec ses droits ($nb site(s))"; else echo "ÉCHEC espace école introuvable"; fi
  else
    echo "ÉCHEC connexion par téléphone (numéro de test)"
  fi
fi

step "Sauvegardes"
if [ "$ENVIRONNEMENT" != prod ]; then
  echo "pas de sauvegarde pour l'essai (données jetables)"
elif sudo test -f /opt/scolagrid/sauvegarde.env; then
  sudo apt-get install -y -qq restic >/dev/null
  sudo install -m 755 "$SRC/sauvegarde/sauvegarder.sh" /usr/local/bin/scolagrid-sauvegarder
  sudo install -m 644 "$SRC/sauvegarde/scolagrid-sauvegarde.service" "$SRC/sauvegarde/scolagrid-sauvegarde.timer" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now scolagrid-sauvegarde.timer >/dev/null 2>&1
  echo "programmées chaque nuit vers 2 h 30 ($(restic version | cut -d' ' -f1-2))"
  if ! sudo find /var/lib/scolagrid/derniere-sauvegarde -mmin -1440 2>/dev/null | grep -q .; then
    if sudo systemctl start scolagrid-sauvegarde.service; then echo "première sauvegarde faite"
    else echo "ÉCHEC de la sauvegarde :"; sudo journalctl -u scolagrid-sauvegarde -n 15 --no-pager -o cat; fi
  fi
  sudo scolagrid-sauvegarder --etat || echo "ÉCHEC de la vérification"
else
  echo "non configurées : secrets SAUVEGARDE_* absents dans GitHub"
fi

step "Adresses pour l'application"
echo "SUPABASE_URL=https://$API"
echo "POWERSYNC_URL=https://$SYNC"
# Clé publique par nature : elle est intégrée dans l'application.
echo "SUPABASE_ANON_KEY=$anon"
