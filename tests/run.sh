#!/usr/bin/env bash
# Ende-zu-Ende-Test ohne root, ohne Netz: package → sign → (Pipe statt SSH) → deploy.
# Jede Negativprüfung hat eine Positivkontrolle; gezählt wird, wie viele Prüfungen gelaufen sind.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DEPLOY_KIT_TESTMODE=1 DEPLOY_KIT_ETC="$T/etc" DEPLOY_KIT_LOCKDIR="$T/lock" DEPLOY_KIT_LOGDIR="$T/log" \
       DEPLOY_KIT_HEALTH_SLEEP=0 SOURCE_DATE_EPOCH=1700000000
mkdir -p "$T"/{etc/demo,lock,log,srv/demo,out}
DK="$KIT/server/deploy-kit"
GELAUFEN=0; FEHLER=0
ok()   { GELAUFEN=$((GELAUFEN+1)); echo "PASS $1"; }
nok()  { GELAUFEN=$((GELAUFEN+1)); FEHLER=$((FEHLER+1)); echo "FAIL $1"; }
pruef() { local name="$1"; shift; if "$@"; then ok "$name"; else nok "$name"; fi; }
scheitert() { local name="$1" code="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?
  if [[ $rc -eq $code ]]; then ok "$name (exit $rc)"; else nok "$name (exit $rc, erwartet $code)"; fi; }

# Schlüssel: Freigabe (operator) und ein fremder
ssh-keygen -q -t ed25519 -N '' -C operator -f "$T/op" ; ssh-keygen -q -t ed25519 -N '' -C fremd -f "$T/fremd"
echo "operator $(cat "$T/op.pub")" > "$T/etc/demo/allowed_signers"
cat > "$T/etc/demo/app.conf" <<EOF
BASE=$T/srv/demo
HEALTH_URL=file://$T/srv/demo/current/public/index.html
KEEP=2
EOF

# Beispielprojekt (Kirby-artig)
P="$T/projekt"; mkdir -p "$P"/{public,content/home,deploy/hooks,site/cache}
echo "v-ALT" > "$P/public/index.html"; echo "Startseite" > "$P/content/home/home.txt"
printf 'shared-dir content\nshared-file site/config/.salt\nwritable site/cache\n' > "$P/deploy/manifest"
printf '#!/bin/sh\necho "pre-activate $DEPLOY_KIT_TAG" > "$DEPLOY_KIT_SHARED/hook.log"\n' > "$P/deploy/hooks/pre-activate"
chmod +x "$P/deploy/hooks/pre-activate"
git -C "$P" init -q; git -C "$P" add -A; git -C "$P" -c user.email=t@t -c user.name=t commit -qm init

baue() { # $1 tag, $2 inhalt index.html
  echo "$2" > "$P/public/index.html"; git -C "$P" -c user.email=t@t -c user.name=t commit -qam "$1"
  rm -rf "$T/out/$1"; "$KIT/ci/package.sh" demo "$1" "$P" "$T/out/$1" >/dev/null
  ssh-keygen -q -Y sign -f "$T/op" -n deploy-kit "$T/out/$1/SHA256SUMS"
}
buendel() { tar -C "$T/out/$1" -cf - "${@:2}"; }
alles() { buendel "$1" "demo-$1.tar.gz" SHA256SUMS SHA256SUMS.sig; }
aktiv() { readlink "$T/srv/demo/current"; }

baue v1.0.0 "eins"; baue v1.1.0 "zwei"; baue v1.2.0 "drei"

# 1. Reproduzierbarkeit
cp "$T/out/v1.0.0/SHA256SUMS" "$T/sum1"; git -C "$P" checkout -q HEAD~2
"$KIT/ci/package.sh" demo v1.0.0 "$P" "$T/out/repro" >/dev/null; git -C "$P" checkout -q -
pruef "Artefakt ist reproduzierbar" cmp -s "$T/sum1" "$T/out/repro/SHA256SUMS"

# 2. Negativ: unsigniert, fremd signiert, manipuliert, Zusatzdatei, falscher Tag – bevor irgendetwas aktiv ist
scheitert "ohne .sig abgelehnt" 31 bash -c "$(declare -f buendel); T=$T; buendel v1.0.0 demo-v1.0.0.tar.gz SHA256SUMS | $DK deploy demo v1.0.0"
cp -r "$T/out/v1.0.0" "$T/out/fremd"; rm "$T/out/fremd/SHA256SUMS.sig"
ssh-keygen -q -Y sign -f "$T/fremd" -n deploy-kit "$T/out/fremd/SHA256SUMS"
scheitert "fremder Schlüssel abgelehnt" 20 bash -c "tar -C $T/out/fremd -cf - demo-v1.0.0.tar.gz SHA256SUMS SHA256SUMS.sig | $DK deploy demo v1.0.0"
cp -r "$T/out/v1.0.0" "$T/out/ns"; rm "$T/out/ns/SHA256SUMS.sig"
ssh-keygen -q -Y sign -f "$T/op" -n anderer-namespace "$T/out/ns/SHA256SUMS"
scheitert "falscher Namespace abgelehnt" 20 bash -c "tar -C $T/out/ns -cf - demo-v1.0.0.tar.gz SHA256SUMS SHA256SUMS.sig | $DK deploy demo v1.0.0"
cp -r "$T/out/v1.0.0" "$T/out/manip"; echo x >> "$T/out/manip/demo-v1.0.0.tar.gz"
scheitert "manipuliertes Archiv abgelehnt" 33 bash -c "tar -C $T/out/manip -cf - demo-v1.0.0.tar.gz SHA256SUMS SHA256SUMS.sig | $DK deploy demo v1.0.0"
cp -r "$T/out/v1.0.0" "$T/out/extra"; echo böse > "$T/out/extra/evil.sh"
scheitert "Zusatzdatei im Bündel abgelehnt" 31 bash -c "tar -C $T/out/extra -cf - demo-v1.0.0.tar.gz SHA256SUMS SHA256SUMS.sig evil.sh | $DK deploy demo v1.0.0"
mkdir -p "$T/out/link"; cp "$T/out/v1.0.0/demo-v1.0.0.tar.gz" "$T/out/v1.0.0/SHA256SUMS.sig" "$T/out/link/"
ln -s /etc/passwd "$T/out/link/SHA256SUMS"
scheitert "Symlink im Bündel abgelehnt" 31 bash -c "tar -C $T/out/link -cf - demo-v1.0.0.tar.gz SHA256SUMS SHA256SUMS.sig | $DK deploy demo v1.0.0"
scheitert "Bündel mit anderem Tag abgelehnt" 31 bash -c "tar -C $T/out/v1.0.0 -cf - demo-v1.0.0.tar.gz SHA256SUMS SHA256SUMS.sig | $DK deploy demo v1.1.0"
scheitert "Tag-Injektion abgelehnt" 2 "$DK" deploy demo 'v1.0.0;id'
pruef "nach allen Ablehnungen ist nichts aktiv" test ! -e "$T/srv/demo/current"

# 3. Positiv: Erstdeployment
alles v1.0.0 | "$DK" deploy demo v1.0.0 >/dev/null 2>&1; rc=$?
pruef "Erstdeployment erfolgreich (exit $rc)" test $rc -eq 0
pruef "current zeigt auf v1.0.0" test "$(aktiv)" = releases/v1.0.0
pruef "content aus Release erstbefüllt" grep -qx Startseite "$T/srv/demo/shared/content/home/home.txt"
pruef "content ist Symlink auf shared" test -L "$T/srv/demo/releases/v1.0.0/content"
pruef "pre-activate lief" grep -qx "pre-activate v1.0.0" "$T/srv/demo/shared/hook.log"
pruef "VERIFIED mit Signer" grep -qx "signer=operator" "$T/srv/demo/releases/v1.0.0/.deploy-kit/VERIFIED"

# 4. Redaktion ändert Inhalt; neues Release darf ihn nicht überschreiben
echo "Redaktion" > "$T/srv/demo/shared/content/home/home.txt"
alles v1.1.0 | "$DK" deploy demo v1.1.0 >/dev/null 2>&1
pruef "Update aktiv" test "$(aktiv)" = releases/v1.1.0
pruef "Redaktionsinhalt erhalten" grep -qx Redaktion "$T/srv/demo/shared/content/home/home.txt"
pruef "neuer Code ausgeliefert" grep -qx zwei "$T/srv/demo/current/public/index.html"

# 5. Rückschritt über deploy gesperrt, gleicher Tag ist No-op
scheitert "Downgrade über deploy abgelehnt" 25 bash -c "$(declare -f buendel alles); T=$T; alles v1.0.0 | $DK deploy demo v1.0.0"
alles v1.1.0 | "$DK" deploy demo v1.1.0 >/dev/null 2>&1; rc=$?
pruef "gleicher Tag ist No-op (exit $rc)" test $rc -eq 0

# 6. Health-Check scheitert → automatisch zurück
sed -i "s#^HEALTH_URL=.*#HEALTH_URL=file:///gibt/es/nicht#" "$T/etc/demo/app.conf"
scheitert "Health-Fehler meldet Fehler" 41 bash -c "$(declare -f buendel alles); T=$T; alles v1.2.0 | $DK deploy demo v1.2.0"
pruef "nach Health-Fehler wieder v1.1.0" test "$(aktiv)" = releases/v1.1.0
sed -i "s#^HEALTH_URL=.*#HEALTH_URL=file://$T/srv/demo/current/public/index.html#" "$T/etc/demo/app.conf"
alles v1.2.0 | "$DK" deploy demo v1.2.0 >/dev/null 2>&1
pruef "Positivkontrolle: gleiches Release mit gesundem Check aktiv" test "$(aktiv)" = releases/v1.2.0

# 7. Aufräumen (KEEP=2) und Rollback am Server
pruef "KEEP=2 hält aktuell + vorher" test "$(find "$T/srv/demo/releases" -mindepth 1 -maxdepth 1 -name 'v*' | wc -l)" -eq 2
"$DK" rollback demo >/dev/null 2>&1
pruef "rollback ohne Tag → Vorgänger v1.1.0" test "$(aktiv)" = releases/v1.1.0
pruef "Redaktionsinhalt nach Rollback unverändert" grep -qx Redaktion "$T/srv/demo/shared/content/home/home.txt"

# 8. SSH-Wrapper
W="$KIT/server/deploy-kit-ssh"; export DEPLOY_KIT_BIN="$DK"
scheitert "Wrapper: fremde App abgelehnt" 2 env SSH_ORIGINAL_COMMAND="status andere" "$W" demo
scheitert "Wrapper: rollback nicht erlaubt" 2 env SSH_ORIGINAL_COMMAND="rollback demo" "$W" demo
scheitert "Wrapper: Zusatzargumente abgelehnt" 2 env SSH_ORIGINAL_COMMAND="deploy demo v1.0.0 x" "$W" demo
pruef "Wrapper: status erlaubt (Positivkontrolle)" env SSH_ORIGINAL_COMMAND="status demo" "$W" demo

echo "----"; echo "gelaufen: $GELAUFEN, fehlgeschlagen: $FEHLER"
[[ $FEHLER -eq 0 && $GELAUFEN -eq 31 ]] || { echo "ERWARTET: 31 Prüfungen, 0 Fehler"; exit 1; }
