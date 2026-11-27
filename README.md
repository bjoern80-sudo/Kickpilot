<p align="center">
  <img src="branding/icon.svg" alt="Kickpilot-Logo" width="140">
</p>

<h1 align="center">Kickpilot</h1>

<p align="center">
  <b>Dein Kickbase-Copilot für Home Assistant.</b><br>
  Budget, Kader und Transfermarkt im Blick, Kauf- und Verkaufsvorschläge per Push-Nachricht,
  Bestätigung mit einem Tipp.
</p>

<p align="center">
  <a href="https://my.home-assistant.io/redirect/hacs_repository/?owner=bjoern80-sudo&repository=Kickpilot&category=integration">
    <img src="https://my.home-assistant.io/badges/hacs_repository.svg" alt="In HACS öffnen">
  </a>
</p>

---

Kickpilot verbindet dein [Kickbase](https://www.kickbase.com)-Konto mit Home Assistant. Die Integration
lädt regelmäßig Budget, Kader, Transfermarkt und Ligatabelle. Daraus berechnet sie, welche Spieler sich
gerade zum Kaufen lohnen und wen du vor der Freitagsfrist verkaufen solltest. Die Vorschläge kommen als
Nachricht aufs Handy. Ausgeführt wird erst, wenn du auf **Bestätigen** tippst.

Dazu gibt es die **Kickpilot-Karte** fürs Dashboard: Kennzahlen, Vorschläge, offene Gebote, deine
Startelf auf dem Spielfeld und die Ersatzbank.

> [!WARNING]
> **Inoffizielles Projekt.** Kickpilot gehört nicht zu Kickbase und nutzt die nicht dokumentierte
> Kickbase-API. Ändert Kickbase etwas, kann die Integration ausfallen.
> Gebote und Verkäufe sind **echte Transaktionen** in deiner Liga. Die Nutzung erfolgt auf eigenes Risiko.

## Inhalt

- [Funktionen](#funktionen)
- [So entscheidet Kickpilot](#so-entscheidet-kickpilot)
- [Installation in Home Assistant](#installation-in-home-assistant)
- [Einrichtung](#einrichtung)
- [Einstellungen](#einstellungen)
- [Dashboard-Karte](#dashboard-karte)
- [Entitäten, Aktionen und Events](#entitäten-aktionen-und-events)
- [Empfohlener Start](#empfohlener-start)
- [Mac-App](#mac-app)
- [Sicherheit und Datenschutz](#sicherheit-und-datenschutz)
- [Entwicklung](#entwicklung)

## Funktionen

| Bereich | Was Kickpilot macht |
|---|---|
| **Überblick** | Sensoren für Budget, Teamwert, Budget nach offenen Geboten, Minus-Grenze, Gebotsrahmen bis Freitag, Platz in der Liga und Kadergröße. HA speichert den Verlauf, damit siehst du Budget und Teamwert über Wochen. |
| **Kaufvorschläge** | Zu festen Prüfzeiten sucht Kickpilot Spieler auf dem Transfermarkt, deren Marktwert voraussichtlich steigt, und schlägt ein passendes Gebot vor. |
| **Freitags-Ausgleich** | Ist dein Budget vor Freitag 19:00 Uhr im Minus, schlägt Kickpilot Verkäufe vor. Schwache Spieler mit gutem Wertzuwachs gehen zuerst, deine Top 11 zuletzt. |
| **Push-Nachrichten** | Vorschläge, Warnungen und Ergebnisse gehen an die Benachrichtigungsziele, die du auswählst, z. B. die Companion-App auf dem iPhone. Bestätigen und Ablehnen geht direkt aus der Nachricht. |
| **Halb- oder vollautomatisch** | Standard ist halbautomatisch: nichts passiert ohne deine Bestätigung. Die Vollautomatik musst du ausdrücklich einschalten, und sie hat Grenzen pro Prüfung und Tag. |
| **Trockenlauf** | Zum Ausprobieren: Kickpilot schreibt nur ins Logbuch, was es tun würde, und führt nichts aus. |
| **Kickpilot-Karte** | Eigene Dashboard-Karte, ohne zusätzliche Installation. Wahlweise im dunklen Kickpilot-Design oder im Look deines HA-Themes. |

## So entscheidet Kickpilot

### Gebote

Ein Spieler kommt nur dann als Kaufvorschlag in Frage, wenn alles davon zutrifft:

- Er ist fit.
- Sein Marktwert steigt stabil (an mindestens 4 der letzten 5 Tage), **oder** es gibt eine Trendumkehr:
  nach mindestens 5 % Rückgang ein Boden in den letzten 6 Tagen, seitdem mindestens 2 Tage in Folge gestiegen.
- Der Marktwert liegt noch unter seinem letzten Hochpunkt.
- Der erwartete Verkaufswert nach 3 Tagen liegt mindestens 5 % (mindestens 100.000 €) über dem Gebot.
- Das Angebot läuft **heute** ab. Erst dann ist sicher genug, ob der Marktwert wie geschätzt steigt.

Die Gebotshöhe richtet sich nach dem Verhalten deiner Mitspieler: Marktwert plus der Aufpreis, den der
stärkste Konkurrent in deiner Liga üblicherweise zahlt (75-%-Perzentil), plus 1 Prozentpunkt.

### Ligaregeln

Diese Regeln prüft Kickpilot vor jedem Vorschlag und vor jeder Ausführung:

| Regel | Wert |
|---|---|
| Spieler im Kader | höchstens 18 |
| Spieler pro Verein | höchstens 3 |
| Mindestbesetzung | 1 Torhüter, 3 Abwehrspieler, 1 Stürmer |
| Budget am Freitag 19:00 Uhr | mindestens 0 € |
| Alle Gebote zusammen | Budget höchstens bis −30 % des Teamwerts |

> [!NOTE]
> Die Regeln stammen aus der Liga des Entwicklers und sind derzeit fest eingebaut. Spielt deine Liga mit
> anderen Regeln, passen die Vorschläge eventuell nicht. Ein [Issue](https://github.com/bjoern80-sudo/Kickpilot/issues)
> hilft, sie einstellbar zu machen.

## Installation in Home Assistant

**Voraussetzungen**

- Home Assistant 2025.1 oder neuer
- [HACS](https://hacs.xyz) (in neueren HA-Versionen auch „Marketplace“ genannt)
- Ein Kickbase-Konto mit E-Mail und Passwort
- Für Push-Nachrichten: die [Companion-App](https://companion.home-assistant.io) oder ein anderer `notify`-Dienst

### Über HACS (empfohlen)

1. Klicke auf den Knopf **„In HACS öffnen“** oben. Oder manuell: HACS → Menü ⋮ → **Benutzerdefinierte
   Repositories** → `https://github.com/bjoern80-sudo/Kickpilot` eintragen, Typ **Integration**.
2. **Kickbase** suchen und **Herunterladen** wählen.
3. Home Assistant neu starten.

Updates kommen danach wie bei jeder anderen HACS-Integration.

### Manuell

1. Den Ordner `custom_components/kickbase/` aus diesem Repository nach `/config/custom_components/kickbase/`
   auf deinem Home Assistant kopieren.
2. Home Assistant neu starten.

## Einrichtung

<a href="https://my.home-assistant.io/redirect/config_flow_start/?domain=kickbase">
  <img src="https://my.home-assistant.io/badges/config_flow_start.svg" alt="Integration hinzufügen">
</a>

1. **Einstellungen → Geräte & Dienste → Integration hinzufügen → Kickbase**
2. Mit E-Mail und Passwort deines Kickbase-Kontos anmelden.
3. Liga auswählen. Spielst du in mehreren Ligen, richtest du die Integration einfach mehrmals ein.
4. Unter **Konfigurieren** mindestens ein **Benachrichtigungsziel** auswählen, z. B.
   `notify.mobile_app_dein_iphone`.

## Einstellungen

Alles lässt sich später unter **Einstellungen → Geräte & Dienste → Kickbase → Konfigurieren** ändern.
Änderungen gelten sofort, ohne Neustart.

| Einstellung | Standard | Bedeutung |
|---|---|---|
| Aktualisierungsintervall | 15 min | Budget, Kader, Markt und Tabelle neu laden (5–120 min) |
| Tägliche Prüfzeiten | 00:05, 08:00, 22:45 | Kaufvorschläge berechnen und melden |
| Prüfzeiten Freitags-Ausgleich | 13:00, 17:00 | Prüfen, ob bis Freitag 19:00 Uhr verkauft werden muss |
| Vorwarnzeit vor der Frist | 6 h | Ab dann warnt Kickpilot bei negativem Budget |
| Zeitpunkt Marktwert-Abruf | 22:30 | Transfers und Marktwertverläufe laden (Kickbase aktualisiert gegen 22 Uhr) |
| Benachrichtigungsziele | – | `notify`-Dienste für Vorschläge, Warnungen und Ergebnisse |
| Betriebsart Gebote / Verkäufe | Halbautomatisch | Vollautomatisch nur mit Pflicht-Häkchen |
| Höchstens Gebote pro Prüfung | 3 | Nur Vollautomatik, weitere Vorschläge kommen zum Bestätigen |
| Höchste Gebotssumme pro Tag | 20.000.000 € | Nur Vollautomatik |
| Höchstens Verkäufe pro Freitag | 3 | Nur Vollautomatik |
| Gültigkeit einer Bestätigung | 2 h | Ältere Bestätigungen werden abgelehnt |
| Trockenlauf | an | Nur protokollieren, nichts ausführen |
| Design des Dashboards | App-Design | Aussehen der Kickpilot-Karte |

**Notbremse:** Der Schalter **Automatik aktiv** stoppt alle geplanten Prüfungen und Nachrichten.
Nach zwei Fehlern in Folge schaltet sich die Vollautomatik selbst auf halbautomatisch zurück und meldet das.

## Dashboard-Karte

Die Karte wird von der Integration mitgeliefert. Du musst keine Ressource anlegen.
Dashboard bearbeiten → **Karte hinzufügen** → **Kickpilot**, oder per YAML:

```yaml
type: custom:kickpilot-card
```

| Option | Bedeutung |
|---|---|
| `title` | Eigene Überschrift (Standard: „Kickpilot“) |
| `design` | `app` (dunkles Kickpilot-Design) oder `ha` (folgt deinem Theme). Ohne Angabe gilt die Einstellung der Integration. |
| `device_id` | Nur nötig, wenn du mehrere Ligen eingerichtet hast |

Die Karte zeigt Kennzahlen, Kauf- und Verkaufsvorschläge, offene Gebote, den Stand der Automatik, deine
Startelf auf dem Spielfeld und die Ersatzbank. Die ⓘ-Zeichen erklären die einzelnen Werte.
Gebote und Verkäufe aus der Karte heraus fragen immer erst nach.

## Entitäten, Aktionen und Events

**Sensoren:** Budget · Teamwert · Budget nach Geboten · Offene Gebote · Minus-Grenze · Gebotsrahmen bis
Freitag · Nächste Frist · Platz · Kader · Kaufvorschläge · Verkaufsvorschläge · Datenstand Transfers und Marktwerte

**Weitere:** Binärsensor *Ausgleich nötig* · Schalter *Automatik aktiv* · Auswahl *Betriebsart Gebote* und
*Betriebsart Verkäufe*

Die Vorschlags-Sensoren enthalten die Details (Spieler, Gebot, erwarteter Gewinn, Ablauf) als Attribute.

**Aktionen**

| Aktion | Wirkung |
|---|---|
| `kickbase.plan_aktualisieren` | Daten laden und Vorschläge neu berechnen. Führt nichts aus. |
| `kickbase.vorschlaege_senden` | Aktuelle Vorschläge (`art: kaeufe` oder `verkaeufe`) mit Bestätigen-Knopf verschicken |
| `kickbase.vorschlaege_ausfuehren` | **Echte Transaktionen**, außer der Trockenlauf ist an. Optional `auftrag` (Kennung aus der Nachricht) und `art`. |

**Events** für eigene Automationen:

- `kickbase_vorschlaege`: neue Vorschläge (`art`, `plan_id`, `anzahl`, `spieler`, …)
- `kickbase_ausgefuehrt`: Ergebnis einer Ausführung (`art`, `quelle`, `trockenlauf`, `protokoll`)

Eigene Automationen brauchst du nicht. Nachrichten und Bestätigungen erledigt die Integration selbst.

## Empfohlener Start

1. Integration einrichten. Der **Trockenlauf ist an**, es passiert also nichts Echtes.
2. Eine Woche lang die Nachrichten und das Logbuch beobachten: Passen die Vorschläge zu deiner Einschätzung?
3. Erst dann den Trockenlauf ausschalten und halbautomatisch weiterspielen.
4. Vollautomatik nur, wenn du den Vorschlägen wirklich vertraust, und mit niedrigen Grenzen.

## Mac-App

Kickpilot gibt es auch als native macOS-App. Sie eignet sich für die ausführliche Analyse am Schreibtisch:

- **Mein Team:** Budget, Teamwert, 24-h-Marktwertänderung, sortierbare Kadertabelle
- **Transfermarkt:** Filter, Suche, Punkte pro Mio. €, Ablaufzeiten, Gebote abgeben und zurückziehen
- **Liga und Kader-Analyse:** alle Kader im Vergleich, Details pro Manager
- **Transfers:** Käufe, Verkäufe und Gewinne aller Manager
- **Automatik:** dieselben Vorschläge wie in Home Assistant, mit Backtest über 120 Tage
- **Spielerdetails:** Marktwertverlauf der letzten 12 Monate

**Voraussetzungen:** macOS 13 (Ventura) oder neuer, Swift 5.9 oder neuer
(`xcode-select --install` installiert die Command Line Tools).

```bash
git clone https://github.com/bjoern80-sudo/Kickpilot.git
cd Kickpilot
./build.sh
open Kickpilot.app
```

Danach kannst du `Kickpilot.app` in den Ordner „Programme“ ziehen. Das Passwort liegt im
macOS-Schlüsselbund, wenn du „merken“ aktivierst.

## Sicherheit und Datenschutz

- Kickpilot verbindet sich nur mit `api.kickbase.com`. Es gibt keinen eigenen Server, kein Tracking.
- **Home Assistant:** Die Zugangsdaten liegen in der HA-Konfiguration auf deinem Gerät und sind damit
  auch in deinen HA-Backups enthalten.
- **Mac-App:** Das Passwort liegt im macOS-Schlüsselbund.
- Schreibende Aktionen (Gebote, Verkäufe) gibt es nur mit Bestätigung, im Trockenlauf gar nicht.
  Die Vollautomatik ist standardmäßig aus.
- Einige schreibende API-Aufrufe sind aus [kickbase-mcp](https://github.com/behretv/kickbase-mcp)
  übernommen und noch nicht in jeder Situation getestet. Deshalb ist der Trockenlauf am Anfang an.

## Entwicklung

```
custom_components/kickbase/   Home-Assistant-Integration (Python)
  planner.py                  Regeln und Vorschläge – 1:1 aus AutoTransfer.swift übertragen
  frontend/kickpilot-card.js  Dashboard-Karte (Web Component, ohne Build-Schritt)
  brand/                      Logos für HA
Sources/KickbaseMac/          macOS-App (SwiftUI, keine Fremdabhängigkeiten)
branding/                     Logo-Quelle (generate_logo.py) und PNG-Erzeugung
docs/                         Planung der HA-Integration
```

Regeländerungen müssen immer in `planner.py` **und** `AutoTransfer.swift` nachgezogen werden.
Fehler und Ideen gerne als [Issue](https://github.com/bjoern80-sudo/Kickpilot/issues).

## Danke

Die Kenntnisse über die Kickbase-API stammen aus [behretv/kickbase-mcp](https://github.com/behretv/kickbase-mcp).

„Kickbase“ ist eine Marke ihres Inhabers. Dieses Projekt steht in keiner Verbindung zu Kickbase und
wird von Kickbase weder unterstützt noch geprüft.
