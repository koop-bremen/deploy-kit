#!/usr/bin/env bash
# Einrichtung auf dem Zielserver – einmalig, als root, über deinen Admin-Zugang (nicht aus der CI).
#
#   sudo server/install.sh kit
#   sudo server/install.sh app <app> --base /srv/<app> --run-user <user> \
#        --ci-key <ci-pubkey-datei> --signer <allowed_signers-datei> \
#        [--reload "systemctl reload php8.4-fpm"] [--health https://…/gesundheit] [--backup "<befehl>"]
#
# Wiederholbar: bestehende Konfigurationen werden nicht überschrieben, nur gemeldet.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "als root ausführen" >&2; exit 1; }
HIER="$(cd "$(dirname "$0")" && pwd)"

install_kit() {
  command -v ssh-keygen >/dev/null || { echo "ssh-keygen fehlt (apt install openssh-client)" >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl fehlt" >&2; exit 1; }
  install -o root -g root -m 0755 "$HIER/deploy-kit" /usr/local/sbin/deploy-kit
  install -o root -g root -m 0755 "$HIER/deploy-kit-ssh" /usr/local/bin/deploy-kit-ssh
  install -d -o root -g root -m 0755 /etc/deploy-kit
  install -d -o root -g root -m 0750 /var/log/deploy-kit
  if ! id deploy >/dev/null 2>&1; then
    # /bin/sh statt nologin: sshd startet den Forced Command über die Login-Shell.
    useradd --system --create-home --home-dir /home/deploy --shell /bin/sh deploy
    passwd -l deploy >/dev/null
  fi
  install -d -o deploy -g deploy -m 0700 /home/deploy/.ssh
  touch /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 0600 /home/deploy/.ssh/authorized_keys
  local sudoers; sudoers="$(mktemp)"
  cat > "$sudoers" <<'EOF'
# deploy-kit: der SSH-Benutzer 'deploy' darf genau diese zwei Unterbefehle (Argumente prüft deploy-kit selbst).
deploy ALL=(root) NOPASSWD: /usr/local/sbin/deploy-kit deploy *, /usr/local/sbin/deploy-kit status *
EOF
  visudo -cf "$sudoers" >/dev/null
  install -o root -g root -m 0440 "$sudoers" /etc/sudoers.d/deploy-kit; rm -f "$sudoers"
  echo "deploy-kit installiert."
}

install_app() {
  local app="$1"; shift
  local base="" run_user="" ci_key="" signer="" reload="" health="" backup=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="$2"; shift 2 ;; --run-user) run_user="$2"; shift 2 ;;
      --ci-key) ci_key="$2"; shift 2 ;; --signer) signer="$2"; shift 2 ;;
      --reload) reload="$2"; shift 2 ;; --health) health="$2"; shift 2 ;; --backup) backup="$2"; shift 2 ;;
      *) echo "unbekannte Option $1" >&2; exit 2 ;;
    esac
  done
  [[ "$app" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ungültiger App-Name" >&2; exit 2; }
  [[ -n "$base" && -n "$run_user" && -f "$ci_key" && -f "$signer" ]] || { echo "--base, --run-user, --ci-key, --signer sind Pflicht" >&2; exit 2; }
  [[ -x /usr/local/sbin/deploy-kit ]] || { echo "zuerst 'install.sh kit'" >&2; exit 1; }

  id "$run_user" >/dev/null 2>&1 || useradd --system --home-dir "$base" --no-create-home --shell /usr/sbin/nologin "$run_user"
  # Webserver liest Code und shared/ über die Gruppe, nie über 'other'.
  if id www-data >/dev/null 2>&1; then usermod -aG "$run_user" www-data; fi
  install -d -o root -g "$run_user" -m 0750 "$base" "$base/releases"
  install -d -o "$run_user" -g "$run_user" -m 0750 "$base/shared"

  local etc="/etc/deploy-kit/$app"
  install -d -o root -g root -m 0755 "$etc"
  if [[ -f "$etc/app.conf" ]]; then
    echo "$etc/app.conf existiert – unverändert gelassen."
  else
    { echo "BASE=$base"; echo "RUN_USER=$run_user"; echo "RELOAD_CMD=$reload"; echo "HEALTH_URL=$health"; echo "HEALTH_RESOLVE="
      echo "HEALTH_RETRIES=5"; echo "KEEP=5"; echo "BACKUP_CMD=$backup"; echo "REQUIRE_SIGNATURE=1"; } > "$etc/app.conf"
    chmod 0644 "$etc/app.conf"
  fi
  install -o root -g root -m 0644 "$signer" "$etc/allowed_signers"
  install -d -o root -g root -m 0750 "/var/log/deploy-kit"

  local zeile; zeile="restrict,command=\"/usr/local/bin/deploy-kit-ssh $app\" $(cat "$ci_key")"
  if grep -qF "deploy-kit-ssh $app\"" /home/deploy/.ssh/authorized_keys; then
    echo "authorized_keys hat bereits einen Eintrag für $app – unverändert gelassen."
  else
    echo "$zeile" >> /home/deploy/.ssh/authorized_keys
  fi
  echo "App $app eingerichtet. Webserver-Root: $base/current/<public-verzeichnis>"
}

case "${1:-}" in
  kit) install_kit ;;
  app) shift; [[ $# -ge 1 ]] || { echo "app <name> …" >&2; exit 2; }; install_app "$@" ;;
  *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
