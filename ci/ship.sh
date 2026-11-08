#!/usr/bin/env bash
# Überträgt ein signiertes Bündel per SSH an den Forced Command des Zielservers.
#
#   DEPLOY_HOST=… DEPLOY_USER=deploy DEPLOY_PORT=22 DEPLOY_SSH_KEY_FILE=… DEPLOY_KNOWN_HOSTS_FILE=… \
#     ci/ship.sh <app> <tag> <verzeichnis mit Archiv, SHA256SUMS, SHA256SUMS.sig>
#
# Der Host-Schlüssel wird nie zur Laufzeit gelernt (kein ssh-keyscan): known_hosts ist Pflicht.
set -euo pipefail
APP="${1:?app}"; TAG="${2:?tag}"; DIR="${3:?verzeichnis}"
: "${DEPLOY_HOST:?}" "${DEPLOY_SSH_KEY_FILE:?}" "${DEPLOY_KNOWN_HOSTS_FILE:?}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag muss vX.Y.Z sein" >&2; exit 2; }
for f in "$APP-$TAG.tar.gz" SHA256SUMS SHA256SUMS.sig; do
  [[ -f "$DIR/$f" ]] || { echo "$DIR/$f fehlt – ist das Release signiert (ops/deploy-sign)?" >&2; exit 2; }
done
[[ -s "$DEPLOY_KNOWN_HOSTS_FILE" ]] || { echo "known_hosts ist leer" >&2; exit 2; }

tar -C "$DIR" -cf - "$APP-$TAG.tar.gz" SHA256SUMS SHA256SUMS.sig |
  ssh -i "$DEPLOY_SSH_KEY_FILE" -p "${DEPLOY_PORT:-22}" \
      -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$DEPLOY_KNOWN_HOSTS_FILE" \
      "${DEPLOY_USER:-deploy}@$DEPLOY_HOST" "deploy $APP $TAG"
