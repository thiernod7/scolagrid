#!/bin/bash
# Sauvegarde chiffrée de Scolagrid vers le stockage externe, avec restic.
# Installé sur le VPS sous /usr/local/bin/scolagrid-sauvegarder.
#   scolagrid-sauvegarder          sauvegarde maintenant
#   scolagrid-sauvegarder --etat   liste les sauvegardes et vérifie la dernière
# Accès au stockage et mot de passe de chiffrement : /opt/scolagrid/sauvegarde.env

set -euo pipefail
set -a; . /opt/scolagrid/sauvegarde.env; set +a

if [ "${1:-}" = "--etat" ]; then
  restic snapshots --compact
  restic check --read-data-subset=10% 2>&1 | tail -1
  tables=$(restic dump --tag base latest /scolagrid.sql | grep -c '^CREATE TABLE' || true)
  echo "Dernière sauvegarde de la base : $tables tables"
  exit 0
fi

restic cat config >/dev/null 2>&1 || restic init
restic backup --quiet --tag base --stdin-filename scolagrid.sql --stdin-from-command -- \
  docker exec supabase-db pg_dumpall -U supabase_admin --clean --if-exists
restic backup --quiet --tag config /opt/scolagrid/supabase/.env
restic forget --quiet --prune --keep-daily 30 --keep-monthly 12
mkdir -p /var/lib/scolagrid
date -Is > /var/lib/scolagrid/derniere-sauvegarde
echo "Sauvegarde terminée"
