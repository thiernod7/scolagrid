#!/usr/bin/env bash
# Télécharge à l'avance les bibliothèques SQLite précompilées du paquet sqlite3
# et les lui fait lire depuis le disque (pubspec.yaml, hooks/user_defines).
#
# Pourquoi : le paquet les télécharge lui-même sans vérifier la réponse de
# GitHub ; quand GitHub refuse la demande (limite de débit des machines de
# compilation), il enregistre la page d'erreur et la compilation échoue sur
# « Hash of downloaded file … ». Ici : nouvelles tentatives, code HTTP affiché.
# Le paquet vérifie toujours l'empreinte de chaque fichier.
#
# Usage (dans app/, après flutter pub get) : bash plateformes/sqlite3_binaires.sh fichier...
set -euo pipefail

version=$(awk '/^  sqlite3:$/{p=1} p && /version:/{gsub(/"/,"",$2); print $2; exit}' pubspec.lock)
[ -n "$version" ] || { echo "Version de sqlite3 introuvable dans pubspec.lock"; exit 1; }

dossier=sqlite3-binaires
mkdir -p "$dossier"
for fichier in "$@"; do
  url="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$version/$fichier"
  ok=
  for essai in 1 2 3 4 5 6; do
    code=$(curl -sSL --retry 3 --retry-all-errors -o "$dossier/$fichier" -w '%{http_code}' "$url" || true)
    if [ "$code" = 200 ]; then ok=1; break; fi
    echo "$fichier : réponse $code (essai $essai), nouvel essai dans $((essai * 10)) s"
    sleep $((essai * 10))
  done
  [ -n "$ok" ] || { echo "Impossible de télécharger $fichier"; exit 1; }
  echo "$fichier : téléchargé ($(wc -c < "$dossier/$fichier") octets)"
done

# Le paquet lit ces fichiers au lieu de les télécharger (empreintes vérifiées).
cat >> pubspec.yaml <<'YAML'

hooks:
  user_defines:
    sqlite3:
      source: test-sqlite3
      directory: sqlite3-binaires/
YAML
echo "sqlite3 $version : bibliothèques lues depuis $dossier/"
