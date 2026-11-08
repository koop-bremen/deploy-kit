# Update- und Lieferketten-Strategie

Stand 2026-11-08 · gilt für alle Projekte mit npm-, Composer- oder Python-Abhängigkeiten.

## Ausgangslage (gemessen über alle 2026 aktiven Repos)

| | Anzahl |
|---|---|
| Repos mit Lockfile (npm/pnpm, Composer, Python) | 16 |
| davon mit Update-Bot (Dependabot oder Renovate) | 2 (golden-system, colonialfootprints-backend) |
| davon mit Schwachstellenprüfung in der CI | 1 (weatherapp) |
| davon mit `ignore-scripts` für npm | 1 (sar-audit) |

Bei 14 von 16 Projekten erfährst du von einer Lücke heute nur zufällig. Das ist das eigentliche Problem,
nicht fehlende Automatisierung beim Einspielen.

## Vier Ebenen

### 1. Erkennen – täglich, auch wenn niemand am Projekt arbeitet

- **Dependabot-Alerts und -Security-Updates** in jedem Repo einschalten (Settings → Code security). Im Free-Plan auch für private Repos verfügbar.
- **`deps-audit.yml`** (wiederverwendbar, täglich und bei jedem PR) prüft unabhängig von GitHub:
  - OSV-Datenbank (`osv-scanner`, deckt npm, Composer, PyPI ab, nicht nur GitHub-Advisories),
  - jede `package.json` hat ein committetes Lockfile,
  - jedes npm-Paket kommt aus `registry.npmjs.org` (keine Git-URLs, keine Tarball-Links),
  - `npm audit signatures`: Registry-Signaturen und Provenance-Attestierungen sind gültig.

### 2. Aktualisieren – gebündelt, mit Wartezeit

`templates/project/.github/dependabot.yml`:

- Versionsupdates **einmal pro Woche**, Patch+Minor **in einem PR je Ökosystem** statt dreißig Einzel-PRs.
- **Wartezeit** (`cooldown`): Patch 3 Tage, Minor 7, Major 30. Die meisten kompromittierten npm-Versionen werden
  innerhalb von Stunden bis wenigen Tagen entdeckt und zurückgezogen. Wer nicht am ersten Tag aktualisiert,
  ist gegen genau diese Welle geschützt.
- **Sicherheitsupdates ignorieren die Wartezeit** und kommen sofort als eigener PR.
- GitHub Actions werden mit aktualisiert; sie sind Abhängigkeiten mit Zugriff auf deine Secrets.

### 3. Mergen – automatisch nur, was klein ist und getestet wurde

`dependabot-automerge.yml` mergt nach grüner CI automatisch:

- Patch-Updates,
- Minor-Updates von Entwicklungs- und indirekten Abhängigkeiten.

Nie automatisch: Major-Updates, Minor-Updates direkter Produktionsabhängigkeiten, PRs, in die jemand (oder ein Agent)
eigene Commits geschoben hat. **Ohne Testsuite wird kein Automerge eingerichtet**: Dann ist „CI grün“ keine Aussage.

### 4. Ausrollen – bewusst nicht vollautomatisch

Ein Merge nach `main` rollt nichts aus. Produktion braucht weiterhin Tag + deine Signatur. Das ist der Punkt, an dem
ein kompromittiertes Update, das durch alle Prüfungen gerutscht ist, noch gestoppt werden kann. Vollautomatische
Produktionsupdates würden genau diese Sicherung entfernen.

Rhythmus, der ohne neue Werkzeuge auskommt:

| Fall | Ablauf |
|---|---|
| normale Woche | Montag Dependabot-PRs → Automerge der kleinen → einmal Patch-Release taggen, signieren, ausrollen |
| Sicherheitslücke, ausnutzbar | Alert → PR sofort mergen → Patch-Release noch am selben Tag |
| Sicherheitslücke, nicht erreichbar (z. B. nur Dev-Tooling) | im Wochenrhythmus mitnehmen; in `osv-scanner.toml` mit Begründung und Ablaufdatum unterdrücken, wenn sie blockiert |
| Major-Update | eigener Branch, manuell, mit Staging |

## Lieferkette: npm und Co. gezielt absichern

Das Risiko liegt weniger in bekannten Lücken als in **frisch kompromittierten Paketen** (Shai-Hulud-Wellen 2025/26):
Ein Maintainer-Token wird gestohlen, eine neue Version mit `postinstall`-Skript veröffentlicht, das beim Installieren
Tokens und SSH-Schlüssel abgreift und sich über die gestohlenen Zugänge weiterverbreitet. Dagegen hilft kein Audit,
weil es zu dem Zeitpunkt noch keine Meldung gibt.

| Maßnahme | wogegen | wo |
|---|---|---|
| `ignore-scripts=true` | Code-Ausführung beim Installieren | `templates/project/.npmrc`, CI, **und auf jedem Rechner, auf dem installiert wird** |
| `min-release-age=7` (npm ≥ 11.10) | frisch veröffentlichte, noch unentdeckte Schadversionen | `.npmrc`; pnpm: `minimumReleaseAge` (Minuten), Yarn 4.10+: `npmMinimalAgeGate` |
| Lockfile Pflicht, `npm ci` statt `npm install` | stille Versionssprünge | `deps-audit.yml`, `ci/package.sh` |
| nur `registry.npmjs.org` im Lockfile | Abhängigkeiten aus Git-Repos und beliebigen URLs | `deps-audit.yml` |
| `npm audit signatures` | manipulierte Pakete auf dem Transportweg, gefälschte Provenance | `deps-audit.yml`, `ci/package.sh` |
| kein Build auf Produktionsservern | Schadcode auf dem System mit Kundendaten | deploy-kit (ohnehin) |
| Cooldown im Update-Bot | dasselbe wie `min-release-age`, für PRs | `dependabot.yml` |

Pakete, die wirklich ein Install-Skript brauchen (esbuild, sharp, Prisma, Playwright …), werden im Build gezielt mit
`npm rebuild <paket>` ausgeführt. Damit ist die Ausnahme sichtbar und klein, statt dass jedes Paket Skripte ausführen darf.

**Der wichtigste Einzelpunkt betrifft nicht die Projekte, sondern `emconlog-web`.** Dort laufen Coding-Agenten mit
GitHub-Schreibrechten und führen `npm install` aus. Ein einziges kompromittiertes Paket mit `postinstall` hätte dort
Zugriff auf diese Tokens und könnte in alle Repos pushen. Deshalb auf diesem Host global:

```bash
npm config set ignore-scripts true --location=user
npm config set min-release-age 7 --location=user
# pnpm 10.16+:   pnpm config set --location global minimum-release-age 10080
```

Und mittelfristig: GitHub-Token der Agenten auf einzelne Repos und auf „Contents: read/write, keine Workflows“
einschränken (fine-grained), damit ein gestohlener Token keine Workflows ändern und so nicht an Deploy-Secrets kommen kann.

**Weitergehend, wenn gewünscht** (nicht Teil des Standards):

- **Socket.dev** analysiert neue Paketversionen auf verdächtiges Verhalten (Netzwerkzugriffe, Install-Skripte,
  verschleierter Code), bevor es eine CVE gibt. GitHub-App, für kleine Organisationen kostenlos nutzbar. Ein externer
  Dienst mit Lesezugriff auf deine Repos – das ist abzuwägen.
- **Eigener Registry-Proxy** (Verdaccio, Sonatype Nexus) mit Freigabeliste. Bei deinem Umfang Aufwand ohne Gegenwert.

## Python und Composer

- Python: `uv.lock` bzw. `requirements.txt` mit Hashes (`pip install --require-hashes`); `osv-scanner` prüft beides.
- Composer: `composer audit` (seit Composer 2.4) zusätzlich zu OSV; Composer kennt keine Install-Skripte von
  Abhängigkeiten, nur die des Root-Pakets, daher dort deutlich geringeres Risiko.

## Einführung je Projekt

```bash
cp deploy-kit/templates/project/.github/dependabot.yml <projekt>/.github/      # nicht genutzte Ökosysteme löschen
cp deploy-kit/templates/project/.github/workflows/deps-audit.yml <projekt>/.github/workflows/
cp deploy-kit/templates/project/.npmrc <projekt>/                                # nur Node-Projekte
# nur wenn es eine Testsuite gibt:
cp deploy-kit/templates/project/.github/workflows/dependabot-automerge.yml <projekt>/.github/workflows/
```

Nach `ignore-scripts=true` einmal lokal `npm ci && npm run build && npm test` – was bricht, braucht ein gezieltes
`npm rebuild <paket>` im Build.
