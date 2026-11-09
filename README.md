# deploy-kit – einheitliches Deployment für KOOP-Bremen-Projekte

Stand 2026-11-08 · gilt für **alle neuen Projekte**. Bestehende Projekte werden nach der Liste unten nachgezogen.

## Grundsatz in einem Satz

**Ausgerollt wird nur, was du signiert hast, und das prüft der Server selbst.** GitHub, die CI, `emconlog-web` und
jeder Coding-Agent können ein Release vorbereiten. Freigeben können sie es nicht.

Warum so und nicht über GitHub-Freigaben: Die Organisation läuft im GitHub-Free-Plan. Für private Repos gibt es dort
keine Branch Protection, keine Rulesets und keine Environment-Reviewer. Wer Schreibrechte hat (auch ein Agent auf
`emconlog-web`), kann Workflows ändern und an die Secrets herankommen. Eine Freigabe, die innerhalb von GitHub
stattfindet, ist deshalb nur Dekoration. Der Server vertraut ausschließlich `/etc/deploy-kit/<app>/allowed_signers`.

## Ablauf

```
Entwicklung (emconlog-web, Laptop)        GitHub (oder später Forgejo)            Laptop (du)                  Server
──────────────────────────────────        ───────────────────────────            ───────────                  ──────
git tag v1.4.0 && git push --tags  ──►  release.yml: ci/package.sh
                                         → Release mit <app>-v1.4.0.tar.gz
                                           + SHA256SUMS            ──────►  ops/deploy-sign … --deploy
                                                                            prüft Hash + Commit,
                                                                            signiert (FIDO2-Touch),
                                         ◄────── SHA256SUMS.sig ─────────   startet deploy.yml
                                         deploy.yml: ci/ship.sh
                                         tar | ssh deploy@host ───────────────────────────────────►  deploy-kit-ssh <app>
                                                                                                      → sudo deploy-kit deploy
                                                                                                        Signatur, Hash, Inhalt
                                                                                                        prüfen → releases/v1.4.0
                                                                                                        → Backup → Hook
                                                                                                        → current umschalten
                                                                                                        → Health-Check
                                                                                                        → bei Fehler zurück
```

## Was der Server garantiert

| Eigenschaft | Umsetzung |
|---|---|
| Nur signierte Releases | `ssh-keygen -Y verify`, Namespace `deploy-kit`, Schlüssel nur aus `/etc/deploy-kit/<app>/allowed_signers` |
| Signatur gilt für genau eine App und genau einen Tag | `SHA256SUMS` muss genau eine Zeile `<hash>  <app>-<tag>.tar.gz` haben; `.deploy-kit/RELEASE` im Artefakt muss passen |
| Kein Rückschritt über die Leitung | `deploy` mit älterem Tag → Exit 25. Rückschritt nur `deploy-kit rollback` lokal als root |
| Ein Schlüssel = eine App | `authorized_keys`: `restrict,command="/usr/local/bin/deploy-kit-ssh <app>"` |
| Kein Shell-Zugang für die CI | Forced Command erlaubt nur `deploy <app> <tag>` und `status <app>` |
| Atomar | Release wird vollständig in `releases/.<tag>.new` aufgebaut, dann `mv -T` auf `current` |
| Redaktionsdaten überleben jedes Release und jeden Rollback | `deploy/manifest`: `shared-dir`/`shared-file` liegen in `<base>/shared/` |
| Code für die Laufzeit nur lesbar | Release gehört `root:<run-user>`, `chmod u=rwX,g=rX,o=`; beschreibbar nur `shared/` und `writable` |
| Health-Check mit automatischem Zurückschalten | `HEALTH_URL` (optional `HEALTH_RESOLVE` für die Zeit vor der DNS-Umstellung) |
| Kein gleichzeitiges Deployment | `flock` je App |
| Reproduzierbares Artefakt | `git archive` + feste mtime/Owner + `gzip -n`; in `tests/run.sh` geprüft |

Exit-Codes: 2 Aufruf · 10 Konfiguration · 20 Signatur · 23 kein Schlüssel · 25 Rückschritt · 31 Bündel ·
32 SHA256SUMS · 33 Prüfsumme · 34 Artefakt/Manifest · 35 Tag mit anderem Inhalt · 40 Backup/Hook · 41 Health · 42 Rollback · 60 Sperre.

## Aufbau

```
server/deploy-kit        Serverseite (/usr/local/sbin), root
server/deploy-kit-ssh    Forced Command für den SSH-Benutzer deploy (/usr/local/bin)
server/install.sh        Ersteinrichtung: 'kit' einmal je Server, 'app' einmal je App
ci/package.sh            baut <app>-<tag>.tar.gz + SHA256SUMS aus dem committeten Stand
ci/ship.sh               überträgt das Bündel an den Forced Command (known_hosts ist Pflicht)
ops/deploy-sign          deine Freigabe: prüfen, signieren, hochladen, Deploy starten
.github/workflows/       wiederverwendbare Workflows: release, deploy, deps-audit, dependabot-automerge
templates/project/       Vorlagen für ein Projekt-Repo (Workflows, deploy/manifest, dependabot.yml, .npmrc)
docs/UPDATES.md          Update- und Lieferketten-Strategie (Dependabot, OSV, npm-Härtung)
tests/run.sh             Ende-zu-Ende-Test (31 Prüfungen, ohne root, ohne Netz)
tests/package.sh         Regressionstest ci/package.sh: App an der Wurzel und im Unterverzeichnis (18 Prüfungen)
```

Serverlayout je App:

```
/srv/<app>/
  current -> releases/v1.4.0      Webserver-Root zeigt auf current/<public-verzeichnis>
  releases/v1.3.0/  v1.4.0/       höchstens KEEP Stück, aktuell und vorheriges werden nie gelöscht
  shared/                         gehört <run-user>; Redaktionsinhalte, Uploads, .env, Sessions
/etc/deploy-kit/<app>/app.conf, allowed_signers
/var/log/deploy-kit/<app>.log
```

`app.conf` (wird nicht per `source` geladen, nur diese Schlüssel):

```
BASE=/srv/dokuplus
RUN_USER=dokuplus
RELOAD_CMD=systemctl reload php8.4-fpm
HEALTH_URL=https://dokuplus.example/gesundheit
HEALTH_RESOLVE=dokuplus.example:443:127.0.0.1
HEALTH_RETRIES=5
KEEP=5
BACKUP_CMD=
REQUIRE_SIGNATURE=1
```

## Neues Projekt anbinden

**Einmalig auf deinem Laptop – Signierschlüssel:**

```bash
ssh-keygen -t ed25519-sk -C operator -f ~/.ssh/id_ed25519_sk      # FIDO2-Token, Touch je Signatur
echo "operator $(cat ~/.ssh/id_ed25519_sk.pub)" > allowed_signers
```

**Einmalig je Server** (über deinen Admin-Zugang, nie aus der CI):

```bash
git clone https://github.com/koop-bremen/deploy-kit && cd deploy-kit
sudo server/install.sh kit
```

**Je App:**

```bash
# 1. CI-Schlüssel nur für diese App (bleibt nicht auf dem Laptop liegen)
ssh-keygen -t ed25519 -N '' -C ci-dokuplus -f ci-dokuplus

# 2. auf dem Server
sudo server/install.sh app dokuplus --base /srv/dokuplus --run-user dokuplus \
     --ci-key ci-dokuplus.pub --signer allowed_signers \
     --reload "systemctl reload php8.4-fpm" --health https://dokuplus.example/gesundheit

# 3. im Projekt-Repo: Vorlagen kopieren, APP_NAME ersetzen, deploy/manifest ausfüllen
cp -r deploy-kit/templates/project/. <projekt>/

# 4. Secrets und Variablen. Den Host-Key NICHT per ssh-keyscan aus dem Netz übernehmen, sondern
#    auf dem Server ablesen (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) und vergleichen.
gh secret set DEPLOY_SSH_KEY     -R koop-bremen/<projekt> < ci-dokuplus
gh secret set DEPLOY_KNOWN_HOSTS -R koop-bremen/<projekt> < known_hosts_eintrag
gh variable set DEPLOY_HOST -R koop-bremen/<projekt> -b <host>
gh variable set DEPLOY_PORT -R koop-bremen/<projekt> -b 22
shred -u ci-dokuplus

# 5. Release
git tag v0.1.0 && git push origin v0.1.0
ops/deploy-sign koop-bremen/<projekt> dokuplus v0.1.0 --deploy
```

Der SSH-Port des Servers muss für GitHub-Runner erreichbar sein. Für DokuPlus ist das eine bewusste Abweichung von
„SSH nur über den Jumphost“; die Absicherung liegt im Forced Command, nicht in der Firewall.

## Regeln für Projekte

1. **Auf dem Server wird nicht gebaut.** Kein `git pull`, kein `composer install`, kein `npm run build` auf Produktion.
2. **Migrationen sind abwärtskompatibel** (expand/contract). `pre-activate` migriert, *bevor* umgeschaltet wird; der
   alte Code läuft so lange gegen das neue Schema. Ein Rollback setzt nur den Code zurück, nie die Datenbank.
3. **Alles, was Redaktion oder Nutzer erzeugen, steht im Manifest.** Was nicht drinsteht, ist beim nächsten Release weg.
4. **Erstbefüllung ist einmalig.** Ein `shared-dir`, das in `shared/` fehlt, wird beim ersten Deployment aus dem Release
   kopiert. Danach gewinnt `shared/`; Änderungen an diesem Pfad im Git erreichen die Produktion nicht mehr.
5. **Keine Geheimnisse im Artefakt.** `ci/package.sh` bricht bei `.env`, `*.sqlite`, Schlüsseln, `.salt`, `.license` ab.
   Geheimnisse liegen als `shared-file` auf dem Server.
6. **Staging ist eine eigene App** (`<app>-staging`) mit eigenem Schlüssel, eigenem `allowed_signers` und optional
   `REQUIRE_SIGNATURE=0`. Staging-Schlüssel erreichen nie die Produktions-App.
7. **deploy-kit selbst wird nicht über deploy-kit aktualisiert**, sondern per Admin-Zugang (`git pull && sudo server/install.sh kit`).

## Bewusst nicht abgedeckt

- **Kompromittierte CI**, die ein manipuliertes Artefakt zum richtigen Commit baut. `deploy-sign` prüft Hash und
  Commit, baut aber nicht lokal nach. Das Artefakt ist reproduzierbar; der Nachbau-Vergleich ist der nächste Schritt.
- **Backups von Redaktionsdaten und Datenbanken.** `BACKUP_CMD` läuft vor jeder Aktivierung, ersetzt aber kein
  regelmäßiges Backup.
- **Serverkonfiguration** (nginx, PHP-FPM-Pools, Zertifikate). Das bleibt Ersteinrichtung bzw. Ansible.
- **Shared Hosting ohne root** (z. B. anwaltskanzlei-adam.de auf sh23032). Dort ist deploy-kit nicht einsetzbar.
- **Inhalte veröffentlichen.** Dass Kirby- oder CMS-Inhalte live gehen, ist Sache der Anwendung, nicht des Deployments.

## Wechsel zu Forgejo/Codeberg

Die Vertrauenskette hängt nicht an GitHub. Bei einem Wechsel ändern sich nur die zwei dünnen Workflow-Hüllen
(`.github/workflows/*` → `.forgejo/workflows/*`, weitgehend gleiche Syntax) und die `gh`-Aufrufe in
`ops/deploy-sign` (→ `tea` oder API). `ci/package.sh`, `ci/ship.sh` und die gesamte Serverseite bleiben unverändert.

## Repo-Sichtbarkeit

Dieses Repo sollte **öffentlich** sein. Es enthält keine Geheimnisse, die Sicherheit liegt im Schlüssel, nicht im
Code. Öffentlich funktionieren die wiederverwendbaren Workflows aus jedem privaten Projekt-Repo, und Branch
Protection gibt es im Free-Plan nur für öffentliche Repos. Bleibt es privat, muss unter
*Settings → Actions → General → Access* der Zugriff für die Organisation freigegeben werden (ob das im Free-Plan
verfügbar ist, ist nicht geprüft). Andernfalls wird `ci/` pro Projekt kopiert.

## Bestehende Projekte – Migrationsreihenfolge

| Prio | Repo | Heute | Grund |
|---|---|---|---|
| 1 | emconlog | `rsync --delete`, `ssh-keyscan` zur Laufzeit, kein Rollback | schwächstes Deployment im Bestand |
| 2 | far-right-europe | Staging per rsync, Produktion manuell | kein reproduzierbarer Produktionsweg |
| 3 | golden-system | signierte Freigabe + rsync, Pull-Agent nicht installiert | Forced Command + Serverprüfung schließt das selbst dokumentierte Restrisiko R-06 |
| 4 | customer-invoicing | signiert, aber `git checkout` im laufenden Verzeichnis | nicht atomar; SQLite-Sicherung → `BACKUP_CMD` |
| 5 | postly-website | baut in Branch `build`, README beschreibt rsync | Doku und Code widersprechen sich |
| 6 | radio-agha, weatherapp | atomar, Forced Command bzw. Freigabe vorhanden | einheitlich machen, kein akuter Mangel |
| – | ai-news-digest | läuft produktiv auf `emconlog-web` | zuerst vom Agenten-Host herunter, dann anbinden |
| – | anwaltskanzlei-adam.de | Shared Hosting ohne root | nicht anwendbar |

## Test

```bash
tests/run.sh      # erwartet: "gelaufen: 31, fehlgeschlagen: 0"
tests/package.sh  # erwartet: "gelaufen: 18, fehlgeschlagen: 0"
```
