#!/bin/bash
# Installe ou met à jour Scolagrid sur le VPS. Rejouable sans risque.
# Usage : bash installer.sh <hôte>   (ex. 178-162-254-106.sslip.io)
#
# Le repo est public : ce script n'affiche aucun secret.
# Les secrets sont générés une seule fois dans /opt/scolagrid/supabase/.env.

set -euo pipefail
HOST="$1"
SRC="$(cd "$(dirname "$0")" && pwd)"
DIR=/opt/scolagrid/supabase
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
  sudo chown -R "$(id -un)": /opt/scolagrid
  rm -rf "$tmp"
  echo "téléchargés"
else
  echo "déjà présents"
fi
cd "$DIR"
cp "$SRC/docker-compose.scolagrid.yml" "$SRC/Caddyfile" .
rm -f init.sql
mkdir -p powersync
cp "$SRC"/powersync/* powersync/

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
set_env SCOLAGRID_HOST "$HOST"
set_env SUPABASE_PUBLIC_URL "https://api.$HOST"
set_env API_EXTERNAL_URL "https://api.$HOST/auth/v1"
set_env SITE_URL "https://api.$HOST"
set_env ENABLE_ANONYMOUS_USERS true
set_env DASHBOARD_USERNAME admin
set_env POOLER_TENANT_ID scolagrid
jwt_secret=$(grep '^JWT_SECRET=' .env | cut -d= -f2-)
set_env PS_JWT_K "$(printf %s "$jwt_secret" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
chmod 600 .env

step "Base de données"
dc up -d --quiet-pull db
for i in $(seq 1 60); do
  [ "$(sudo docker inspect -f '{{.State.Health.Status}}' supabase-db)" = healthy ] && break
  sleep 3
done

step "Migrations"
SUDO=sudo bash "$SRC/appliquer-migrations.sh" supabase-db "$SRC/migrations"
pw=$(grep '^PS_POWERSYNC_PASSWORD=' .env | cut -d= -f2-)
sudo docker exec -i supabase-db psql -q -X -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v pw="$pw" \
  <<<"alter role powersync_role with password :'pw';"

step "Services"
dc up -d --quiet-pull db auth rest meta studio api-gw powersync-storage powersync caddy
sleep 20
dc ps --format 'table {{.Name}}\t{{.Status}}'

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
check -H "apikey: $anon" "https://api.$HOST/auth/v1/health"
check "https://sync.$HOST/probes/liveness"

step "Sauvegardes"
if sudo test -f /opt/scolagrid/sauvegarde.env; then
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
echo "SUPABASE_URL=https://api.$HOST"
echo "POWERSYNC_URL=https://sync.$HOST"
# Clé publique par nature : elle est intégrée dans l'application.
echo "SUPABASE_ANON_KEY=$anon"
