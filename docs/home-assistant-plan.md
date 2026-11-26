# Plan: Kickbase als Home-Assistant-Integration (Python)

Stand: 26.11.2026 – noch nicht umgesetzt.

## Ziel

Die Transfer-Automatik läuft auf Home Assistant, ohne dass der Mac an ist:
- Zeitpläne berechnen Kauf- und Verkaufsvorschläge.
- Die Vorschläge kommen als Push-Nachricht aufs iPhone.
- Ausgeführt wird erst nach Tippen auf „Bestätigen“.

Die Mac-App bleibt für die ausführliche Analyse (Transfers, Kader-Analyse, Marktwert-Charts).

## Ausgangslage (geprüft am 26.11.2026)

| Punkt | Stand |
|---|---|
| Home Assistant | 2026.11.1, Home Assistant OS, Zeitzone Europe/Berlin |
| Marketplace (früher HACS) | eingebaut, mit GitHub verbunden |
| iPhone | Companion-App vorhanden: `notify.mobile_app_bjoerns_iphone` |
| Zugriff auf Dateien | Apps „Advanced SSH & Web Terminal“ und „File editor“ laufen |
| Fernzugriff | Tailscale läuft, Bestätigen klappt also auch unterwegs |
| Dashboard-Karten | ApexCharts, auto-entities, Bubble Card, button-card sind installiert |

## Aufbau

Neuer Ordner im Repo: `homeassistant/custom_components/kickbase/`

| Datei | Inhalt | Vorlage in der Mac-App |
|---|---|---|
| `manifest.json` | Domain `kickbase`, keine externen Pakete (nur `aiohttp` von HA) | – |
| `config_flow.py` | Einrichtung über die Oberfläche: E-Mail, Passwort, Liga auswählen | `LoginView`, `leagues()` |
| `api.py` | Async-Client für api.kickbase.com v4, Login-Token als Cookie `kkstrauth`, bei 401 einmal neu anmelden | `KickbaseAPI.swift` |
| `models.py` | Player, Manager, Transfer, MVPoint (Kürzel-Felder wie `i`, `n`, `mv`, `pi`, `pn` tolerant lesen) | `Models.swift`, `TransferModels.swift` |
| `planner.py` | AutoRules, TrendEvaluation, BidCheck, Backtest, BidderProfile, AutoPlanner, saleProposals – 1:1 übertragen | `AutoTransfer.swift` |
| `coordinator.py` | Lädt Daten im Zeitplan und berechnet den Plan | `AppState.swift` |
| `sensor.py`, `binary_sensor.py` | Entitäten (siehe unten) | – |
| `services.py`, `services.yaml` | Aktionen (siehe unten) | `executeBuys`, `executeSales` |
| `translations/de.json` | Texte auf Deutsch | – |

### Einstellbarer Rhythmus

Alle Zeiten sind Einstellungen der Integration, keine festen Werte im Code. Du legst sie beim
Einrichten fest und änderst sie jederzeit unter
**Einstellungen → Geräte & Dienste → Kickbase → Konfigurieren** (Options-Flow). Eine Änderung gilt sofort,
ohne Neustart.

| Einstellung | Standard | Bedeutung |
|---|---|---|
| Aktualisierungsintervall | 15 min (5–120) | Budget, Kader, Markt, Tabelle neu laden |
| Tägliche Prüfzeiten | 08:00, 22:45 | Vorschläge berechnen und melden, wenn es welche gibt |
| Prüfzeiten Freitags-Ausgleich | 13:00, 17:00 | Verkaufsvorschläge melden, wenn das Budget nach Geboten < 0 ist |
| Vorwarnzeit vor der Frist | 6 h | ab dann schaltet `binary_sensor.kickbase_ausgleich_noetig` |
| Zeitpunkt Marktwert-Abruf | 22:30 | Transfers und Marktwertverläufe neu laden |
| Gültigkeit einer Bestätigung | 2 h | danach wird eine Bestätigung abgelehnt |
| Benachrichtigungsziele | – (Pflicht) | Mehrfachauswahl aus allen `notify.*`-Diensten, z. B. `notify.mobile_app_bjoerns_iphone` |
| Betriebsart | Halbautomatisch | siehe „Betriebsart“ unten |
| Trockenlauf | an | nur protokollieren, nichts ausführen |

Die Integration plant die Prüfungen selbst (`async_track_time_change`) und löst danach das Event
`kickbase_vorschlaege` aus. Die Automationen in HA reagieren nur auf dieses Event und enthalten
deshalb keine Uhrzeiten. Wer die Zeiten ändert, muss keine Automation anfassen.

Zusätzlich gibt es den Schalter `switch.kickbase_automatik`: aus = keine geplanten Prüfungen und keine Nachrichten.

### Betriebsart: halb- oder vollautomatisch

Einstellung im Options-Flow, getrennt für Gebote und Verkäufe:

| Einstellung | Werte | Standard |
|---|---|---|
| Betriebsart Gebote | Halbautomatisch / Vollautomatisch | Halbautomatisch |
| Betriebsart Verkäufe (Freitags-Ausgleich) | Halbautomatisch / Vollautomatisch | Halbautomatisch |

- **Halbautomatisch:** Zu den Prüfzeiten kommt eine Push-Nachricht mit den Vorschlägen. Ausgeführt wird
  erst nach dem Tippen auf „Bestätigen“.
- **Vollautomatisch:** Zu den Prüfzeiten führt die Integration die Vorschläge selbst aus. Danach kommt eine
  Push-Nachricht mit dem Ergebnis („✓ Gebot 8.431.111 € für Wirtz …“).

Die Betriebsart ist zusätzlich als Auswahl-Entität `select.kickbase_betriebsart_gebote` bzw.
`select.kickbase_betriebsart_verkaeufe` auf dem Dashboard umschaltbar.

Schutz im Vollautomatik-Modus:
1. **Bewusst einschalten:** Beim Umschalten auf „Vollautomatisch“ im Options-Flow muss ein Häkchen
   „Ich weiß, dass echte Transaktionen ohne Rückfrage ausgeführt werden“ gesetzt werden.
2. **Erst nach dem Trockenlauf:** Solange der Trockenlauf an ist, protokolliert auch die Vollautomatik nur.
3. **Grenzen (einstellbar):** höchstens X Gebote pro Prüfung (Standard 3), höchstens Y € Gebotssumme pro Tag
   (Standard 20 Mio. €), höchstens Z Verkäufe pro Freitag (Standard 3). Darüber hinaus wird nicht automatisch
   ausgeführt, sondern wie im halbautomatischen Modus gefragt.
4. **Ligaregeln bleiben hart:** max. 18 Spieler, max. 3 pro Verein, Mindestbesetzung (1 TW, 3 ABW, 1 ST),
   Minus-Grenze −30 % des Teamwerts und Budget ≥ 0 am Freitag 19:00 prüft der Planer weiterhin vor jeder Aktion.
5. **Notbremse:** `switch.kickbase_automatik` aus stoppt sofort alles. Nach 2 Fehlern in Folge (z. B. API
   geändert) schaltet sich die Vollautomatik selbst auf Halbautomatisch zurück und meldet das.
6. **Protokoll:** Jede automatische Aktion steht im Logbuch und kommt als Push-Nachricht.

Hinweis: In CLAUDE.md steht für die Mac-App „Automatik nie ohne Bestätigungsdialog ausführen“. Für die
HA-Integration gilt künftig: Standard ist halbautomatisch, Vollautomatik nur nach ausdrücklichem
Einschalten durch den Nutzer. Diese Regel wird bei der Umsetzung in CLAUDE.md ergänzt.

### Laden der Daten

- **Im Aktualisierungsintervall (Standard 15 min):** Budget, eigener Kader, Markt, Tabelle der Liga.
- **Einmal am Tag (Standard 22:30, nachdem Kickbase die Marktwerte aktualisiert hat):**
  Transfers aller Manager (4 Seiten je Manager) und Marktwertverläufe (365 Tage).
  Diese Daten werden mit `helpers.storage.Store` gespeichert, damit nach einem Neustart
  nicht alles neu geladen werden muss. Höchstens 4 Anfragen gleichzeitig, wie in der Mac-App.
- **Nach jedem Laden:** Der Plan wird neu berechnet. Das liest nur und führt nie etwas aus.

### Entitäten

| Entität | Wert | Attribute |
|---|---|---|
| `sensor.kickbase_budget` | Budget in € | – |
| `sensor.kickbase_teamwert` | Summe der Marktwerte im Kader | – |
| `sensor.kickbase_budget_nach_geboten` | Budget minus offene Gebote, die vor der Frist enden | – |
| `sensor.kickbase_gebotsrahmen` | Spielraum bis Freitag | Minus-Grenze (−30 % des Teamwerts), Reserve |
| `sensor.kickbase_naechste_frist` | Zeitpunkt: Freitag 19:00 | – |
| `sensor.kickbase_kaufvorschlaege` | Anzahl | Liste: Spieler, Gebot, erwarteter Gewinn, Ende der Auktion, Muster |
| `sensor.kickbase_verkaufsvorschlaege` | Anzahl | Liste: Spieler, Erlös, Gewinn in % |
| `sensor.kickbase_plan_id` | Kurzer Hash des aktuellen Plans | Zeitpunkt der Berechnung |
| `sensor.kickbase_platz` | Platz in der Liga | Punkte |
| `binary_sensor.kickbase_ausgleich_noetig` | an, wenn Budget < 0 und weniger als 6 h bis zur Frist | – |

Nebeneffekt: HA speichert den Verlauf dieser Sensoren. Budget und Teamwert lassen sich dann
mit ApexCharts über Wochen anzeigen, was die Mac-App bisher nicht kann.

### Aktionen

| Aktion | Wirkung |
|---|---|
| `kickbase.plan_aktualisieren` | Daten laden und Plan neu berechnen (liest nur) |
| `kickbase.vorschlaege_ausfuehren` | **Echte Transaktionen.** Parameter: `plan_id` (Pflicht), `art` (`kaeufe`, `verkaeufe` oder `alle`), `trockenlauf` (Standard: `true`) |

Schutz in `vorschlaege_ausfuehren`:
1. Es wird nur ausgeführt, wenn `plan_id` zum aktuellen Plan passt. Hat sich der Plan seit der
   Nachricht geändert, passiert nichts, und es kommt eine neue Nachricht.
2. Eine Bestätigung gilt höchstens 2 Stunden.
3. Vor jedem Gebot wird der Markt neu geladen. Ist der Spieler nicht mehr auf dem Markt oder hast du
   schon geboten, wird er übersprungen.
4. `trockenlauf: true` schreibt nur ins Logbuch, was passieren würde. Das ist am Anfang wichtig,
   weil die schreibenden Endpunkte noch nie getestet wurden.
5. Jede Aktion wird im Logbuch festgehalten. Das Ergebnis kommt als zweite Push-Nachricht („✓ Gebot … / ✗ …“).

Im halbautomatischen Modus ist die Bestätigung der Tipp auf die Nachricht. Im vollautomatischen Modus
ruft die Integration dieselbe Funktion intern auf, mit denselben Prüfungen 1–5 plus den Grenzen aus
„Betriebsart“.

## Benachrichtigungen (in der Integration, nicht als Automation)

Damit auch andere Nutzer die Integration ohne eigene Automationen verwenden können, verschickt die
Integration die Nachrichten selbst an die eingestellten Benachrichtigungsziele und wertet die Knöpfe
(Event `mobile_app_notification_action`, Aktionen `KICKBASE_CONFIRM_<plan_id>` / `KICKBASE_REJECT_<plan_id>`)
selbst aus. Zusätzlich löst sie die Events `kickbase_vorschlaege` und `kickbase_ausgefuehrt` aus, falls
jemand eigene Automationen darauf bauen will.

Die frühere Idee mit Automationen in HA entfällt damit. Zur Einordnung, was sie getan hätten:

1. **Kaufvorschläge melden:** Event `kickbase_vorschlaege` mit `art: kaeufe` (zu den eingestellten
   Prüfzeiten) → Nachricht mit Aktionen „Gebote bestätigen“ / „Ablehnen“ ans iPhone.
2. **Freitags-Ausgleich:** Event `kickbase_vorschlaege` mit `art: verkaeufe` → Nachricht mit den
   Verkaufsvorschlägen und „Verkäufe bestätigen“.
3. **Warnung zur Frist:** `binary_sensor.kickbase_ausgleich_noetig` schaltet auf an → kritische Nachricht.
4. **Bestätigung auswerten:** Event `mobile_app_notification_action` → `vorschlaege_ausfuehren` mit der
   `plan_id` aus der Aktion.

## Installation und Updates

- **Beim Entwickeln:** Dateien per SSH vom Mac nach `/config/custom_components/kickbase/` kopieren,
  dann HA neu starten (das kann ich über die HA-Verbindung selbst). Dafür braucht die App
  „Advanced SSH & Web Terminal“ deinen SSH-Schlüssel vom Mac.
- **Später:** Das Repo auf GitHub als eigenes Repository im Marketplace eintragen. Updates kommen dann
  wie bei den anderen Integrationen.

## Phasen und Aufwand

| Phase | Inhalt | Aufwand | Fertig, wenn |
|---|---|---|---|
| 1 | Gerüst, Einrichtung über die Oberfläche, API-Client, Sensoren für Budget, Teamwert und Platz | 1 Sitzung | Die Werte in HA stimmen mit der Mac-App überein |
| 2 | Planner übertragen, Transfers und Marktwertverläufe mit Cache, Sensoren für die Vorschläge | 1 Sitzung | Dieselben Vorschläge wie in der Mac-App (Abgleich am selben Tag) |
| 3 | Aktionen mit Plan-ID und Trockenlauf, Betriebsart halb-/vollautomatisch mit Grenzen, Push-Nachrichten, Automationen | 1–1½ Sitzungen | Ein ganzer Ablauf im Trockenlauf über eine Woche |
| 4 | Dashboard (Vorschläge, Kader, Budget-Verlauf) | optional, ½–1 Sitzung | – |

Den Trockenlauf schaltest du erst selbst ab, wenn die Woche gut gelaufen ist.

## Risiken

- **Zwei Codebasen:** Die Regeln stehen dann in Swift und in Python. Bei einer Regeländerung beide
  anpassen. In CLAUDE.md kommt dazu ein Hinweis.
- **Zugangsdaten:** Sie liegen in der HA-Konfiguration (`.storage`) auf dem HA-Rechner, nicht im
  Schlüsselbund. Sie gehen auch in HA-Backups ein.
- **Gleichzeitige Anmeldung:** Ob Kickbase Mac-App und HA gleichzeitig angemeldet lässt, ist nicht
  geprüft. Das wird in Phase 1 getestet.
- **Inoffizielle API:** Ändert Kickbase etwas, fällt die Integration aus. Die Sensoren werden dann
  „nicht verfügbar“, und es wird nichts ausgeführt.

## Entscheidungen

1. Repo kommt privat auf GitHub; Installation und Updates über den Marketplace
   (`custom_components/kickbase/` und `hacs.json` im Wurzelverzeichnis des Repos).
2. Benachrichtigungsziele sind einstellbar, damit auch andere Nutzer die Integration verwenden können.
