#!/bin/bash
# Applique, dans l'ordre, les migrations pas encore faites.
# Usage : appliquer-migrations.sh <conteneur postgres> <dossier des migrations>
# Chaque fichier NNN_*.sql est appliqué une seule fois, dans une transaction,
# et noté dans scolagrid.migrations. Une migration appliquée ne se modifie plus :
# pour corriger, on en écrit une nouvelle.

set -euo pipefail
conteneur="$1"; dossier="$2"
psql_admin() { ${SUDO:-} docker exec -i "$conteneur" psql -q -X -v ON_ERROR_STOP=1 -U supabase_admin -d postgres "$@"; }

psql_admin -c "create schema if not exists scolagrid;
  create table if not exists scolagrid.migrations (version text primary key, appliquee_le timestamptz not null default now());"
faites=$(psql_admin -tA -c "select version from scolagrid.migrations")
for f in $(ls "$dossier"/*.sql | sort); do
  v=$(basename "$f" .sql)
  if grep -qx "$v" <<<"$faites"; then echo "déjà faite : $v"; continue; fi
  { echo "begin;"; cat "$f"; echo; echo "insert into scolagrid.migrations (version) values ('$v');"; echo "commit;"; } | psql_admin
  echo "appliquée  : $v"
done
