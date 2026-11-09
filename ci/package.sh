#!/usr/bin/env bash
# Baut das Release-Artefakt einer App – forge-unabhängig (GitHub Actions, Forgejo, Woodpecker, lokal).
#
#   ci/package.sh <app> <tag> <quellverzeichnis> <ausgabeverzeichnis>
#
# Ergebnis in <ausgabe>: <app>-<tag>.tar.gz und SHA256SUMS (genau eine Zeile).
# Quelle ist ausschließlich der committete Stand (git archive), nie das Arbeitsverzeichnis.
#
# Erwartet im Quellverzeichnis (alles optional außer dem Manifest):
#   deploy/manifest         shared-dir/shared-file/writable-Zeilen (siehe templates/project/deploy/manifest)
#   deploy/build.sh         eigener Build-Schritt; läuft im Staging-Verzeichnis (cwd)
#   deploy/exclude          zusätzlich zu entfernende Pfade, eine pro Zeile
#   deploy/hooks/pre-activate  läuft auf dem Server als Laufzeitbenutzer vor der Umschaltung
set -euo pipefail
APP="${1:?app}"; TAG="${2:?tag}"; SRC="${3:?quelle}"; OUT="${4:?ausgabe}"
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ungültiger App-Name" >&2; exit 2; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag muss vX.Y.Z sein" >&2; exit 2; }
[[ -f "$SRC/deploy/manifest" ]] || { echo "$SRC/deploy/manifest fehlt" >&2; exit 2; }

SRC="$(cd "$SRC" && pwd)"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
PREFIX="$(git -C "$SRC" rev-parse --show-prefix)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$SRC" log -1 --format=%ct)}"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
# Von der Repo-Wurzel aus: Im Unterverzeichnis würde git archive zusätzlich nach $PREFIX filtern,
# den es im Baum HEAD:$PREFIX nicht gibt – das Archiv wäre leer.
TOP="$(git -C "$SRC" rev-parse --show-toplevel)"
git -C "$TOP" archive --format=tar "HEAD:$PREFIX" | tar -x -C "$STAGE"
cd "$STAGE"

if [[ -x deploy/build.sh ]]; then
  ./deploy/build.sh
else
  if [[ -f composer.json ]]; then
    composer install --no-dev --prefer-dist --no-interaction --no-progress --optimize-autoloader
  fi
  if [[ -f package-lock.json ]]; then
    # Install-Skripte laufen nur, wenn das Projekt sie nicht per .npmrc (ignore-scripts=true) abschaltet.
    # 'npm audit signatures' bricht ab, wenn ein Paket eine ungültige Registry-Signatur oder Provenance hat.
    npm ci --no-audit --no-fund && npm audit signatures && npm run build && rm -rf node_modules
  fi
fi

mkdir -p .deploy-kit
cp deploy/manifest .deploy-kit/manifest
if [[ -d deploy/hooks ]]; then cp -r deploy/hooks .deploy-kit/hooks; chmod -R a+rx .deploy-kit/hooks; fi
if [[ -f deploy/exclude ]]; then
  while read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    [[ "$p" != /* && "$p" != *..* ]] || { echo "unzulässiger Pfad in deploy/exclude: $p" >&2; exit 2; }
    rm -rf "./$p"
  done < deploy/exclude
fi
rm -rf .git .github deploy .env .env.*

# Harte Sperre: Geheimnisse und Datenbanken gehören nie ins Artefakt.
VERBOTEN="$(find . \( -name '.env' -o -name '.env.*' -o -name '*.sqlite' -o -name '*.sqlite3' \
  -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '*.pem' -o -name '*.key' -o -name '.license' -o -name '.salt' \) -print)"
if [[ -n "$VERBOTEN" ]]; then echo "verbotene Dateien im Artefakt:" >&2; echo "$VERBOTEN" >&2; exit 3; fi

printf 'app=%s\ntag=%s\ncommit=%s\nsource_date_epoch=%s\n' "$APP" "$TAG" "$COMMIT" "$SOURCE_DATE_EPOCH" > .deploy-kit/RELEASE

ARCHIV="$APP-$TAG.tar.gz"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -cf - . | gzip -n -9 > "$OUT/$ARCHIV"
(cd "$OUT" && sha256sum "$ARCHIV" > SHA256SUMS)
echo "Artefakt: $OUT/$ARCHIV"
cat "$OUT/SHA256SUMS"
