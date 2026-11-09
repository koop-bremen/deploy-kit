#!/usr/bin/env bash
# Regressionstest für ci/package.sh: App an der Repo-Wurzel und App in einem Unterverzeichnis (Monorepo).
# Ohne root, ohne Netz. Jede Negativprüfung hat eine Positivkontrolle; gezählt wird, wie viele Prüfungen gelaufen sind.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$KIT/ci/package.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SOURCE_DATE_EPOCH=1700000000
GELAUFEN=0; FEHLER=0
ok()   { GELAUFEN=$((GELAUFEN+1)); echo "PASS $1"; }
nok()  { GELAUFEN=$((GELAUFEN+1)); FEHLER=$((FEHLER+1)); echo "FAIL $1"; }
pruef() { local name="$1"; shift; if "$@"; then ok "$name"; else nok "$name"; fi; }
scheitert() { local name="$1" code="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?
  if [[ $rc -eq $code ]]; then ok "$name (exit $rc)"; else nok "$name (exit $rc, erwartet $code)"; fi; }
commit() { [[ -d "$1/.git" ]] || git -C "$1" init -q; git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -qm "${2:-c}"; }
inhalt() { tar -tzf "$1" | sed 's#^\./##' | grep -v '/$' | grep -v '^$' | sort; }  # Dateiliste ohne Verzeichnisse
app() { # $1 Zielverzeichnis: minimale App mit Manifest, Hook und eigenem .env (wird beim Paketieren entfernt)
  mkdir -p "$1"/{public,deploy/hooks}
  echo "hallo" > "$1/public/index.html"
  printf 'writable site/cache\n' > "$1/deploy/manifest"
  printf '#!/bin/sh\ntrue\n' > "$1/deploy/hooks/pre-activate"; chmod +x "$1/deploy/hooks/pre-activate"
  echo "GEHEIM=1" > "$1/.env"
}

# 1. App an der Repo-Wurzel (bisheriges Verhalten)
R="$T/root"; app "$R"; commit "$R"
"$PKG" demo v1.0.0 "$R" "$T/out/root" >/dev/null 2>&1; rc=$?
pruef "Wurzel: Artefakt gebaut (exit $rc)" test $rc -eq 0
inhalt "$T/out/root/demo-v1.0.0.tar.gz" > "$T/root.lst" 2>/dev/null
pruef "Wurzel: Anwendung enthalten" grep -qx public/index.html "$T/root.lst"
pruef "Wurzel: Manifest und Hook übernommen" grep -qx .deploy-kit/hooks/pre-activate "$T/root.lst"
pruef "Wurzel: deploy/ und .env entfernt" bash -c "! grep -qE '^(deploy/|\.env)' '$T/root.lst'"

# 2. App im Unterverzeichnis, Aufruf wie in release.yml (cwd = Repo-Wurzel, relativer source_dir)
M="$T/mono"; app "$M/dokuplus-standalone"
mkdir -p "$M/anderes"; echo "nicht ausliefern" > "$M/anderes/datei.txt"; echo "x" > "$M/README.md"
echo "x" > "$M/anderes/db.sqlite"   # verbotene Datei AUSSERHALB der App darf den Build nicht stören
commit "$M"
echo "nicht committet" > "$M/dokuplus-standalone/public/lokal.txt"
(cd "$M" && "$PKG" dokuplus v1.0.0 dokuplus-standalone "$T/out/sub1") >/dev/null 2>&1; rc=$?
pruef "Unterverzeichnis: Artefakt gebaut (exit $rc)" test $rc -eq 0
inhalt "$T/out/sub1/dokuplus-v1.0.0.tar.gz" > "$T/sub.lst" 2>/dev/null
pruef "Unterverzeichnis: Anwendung liegt an der Archivwurzel" grep -qx public/index.html "$T/sub.lst"
pruef "Unterverzeichnis: Manifest übernommen" grep -qx .deploy-kit/manifest "$T/sub.lst"
pruef "Unterverzeichnis: keine Dateien außerhalb der App" \
  bash -c "! grep -qE '^(dokuplus-standalone/|anderes/|README\.md)' '$T/sub.lst'"
pruef "Unterverzeichnis: nur committeter Stand" bash -c "! grep -qx public/lokal.txt '$T/sub.lst'"
pruef "Unterverzeichnis: deploy/ und .env entfernt" bash -c "! grep -qE '^(deploy/|\.env)' '$T/sub.lst'"
pruef "Unterverzeichnis: gleiche (nicht leere) Dateiliste wie Wurzel-App" \
  bash -c "test -s '$T/sub.lst' && cmp -s '$T/root.lst' '$T/sub.lst'"
rm "$M/dokuplus-standalone/public/lokal.txt"

# 3. Reproduzierbarkeit im Unterverzeichnis (zweiter Lauf, absoluter Pfad, anderes cwd)
"$PKG" dokuplus v1.0.0 "$M/dokuplus-standalone" "$T/out/sub2" >/dev/null 2>&1
pruef "Unterverzeichnis: Artefakt ist reproduzierbar" cmp -s "$T/out/sub1/SHA256SUMS" "$T/out/sub2/SHA256SUMS"
pruef "Unterverzeichnis: SHA256SUMS hat genau eine Zeile" test "$(wc -l < "$T/out/sub1/SHA256SUMS")" -eq 1

# 4. Verbotene Dateien in der App werden auch im Unterverzeichnis erkannt
for f in site/config/.salt content/daten.sqlite; do
  mkdir -p "$M/dokuplus-standalone/$(dirname "$f")"; echo x > "$M/dokuplus-standalone/$f"; commit "$M" "+$f"
  scheitert "Unterverzeichnis: $f abgelehnt" 3 "$PKG" dokuplus v1.0.1 "$M/dokuplus-standalone" "$T/out/verboten"
  git -C "$M" rm -q "dokuplus-standalone/$f"; commit "$M" "-$f"
done
"$PKG" dokuplus v1.0.1 "$M/dokuplus-standalone" "$T/out/sauber" >/dev/null 2>&1; rc=$?
pruef "Positivkontrolle: ohne verbotene Datei wieder gebaut (exit $rc)" test $rc -eq 0
mkdir -p "$M/dokuplus-standalone/site"; echo "secret" > "$M/dokuplus-standalone/site/geheim.key"; commit "$M" "key"
scheitert "Unterverzeichnis: *.key ohne deploy/exclude abgelehnt" 3 "$PKG" dokuplus v1.0.2 "$M/dokuplus-standalone" "$T/out/key"
echo "site/geheim.key" > "$M/dokuplus-standalone/deploy/exclude"; commit "$M" "exclude"
"$PKG" dokuplus v1.0.2 "$M/dokuplus-standalone" "$T/out/exclude" >/dev/null 2>&1; rc=$?
pruef "Unterverzeichnis: deploy/exclude entfernt Pfad vor der Sperre (exit $rc)" test $rc -eq 0

echo "----"; echo "gelaufen: $GELAUFEN, fehlgeschlagen: $FEHLER"
[[ $FEHLER -eq 0 && $GELAUFEN -eq 18 ]] || { echo "ERWARTET: 18 Prüfungen, 0 Fehler"; exit 1; }
