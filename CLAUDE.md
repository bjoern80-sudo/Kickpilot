# Kickpilot (Kickbase-Begleiter für macOS) – Projektnotizen für Claude

Native SwiftUI-App (macOS 13+, Swift Package, keine Fremdabhängigkeiten) für das
Bundesliga-Fantasy-Spiel Kickbase. Die API-Logik stammt aus behretv/kickbase-mcp
(geprüfter Stand: Commit 13832cb).

## Bauen & Starten
- Bauen: `swift build` (schnell, zum Prüfen) bzw. `./build.sh` (Release + Kickpilot.app)
- Starten: `open Kickpilot.app`
- Nach jeder Änderung bauen und Fehler beheben, bevor du fertig meldest.

## Aufbau (Sources/KickbaseMac)
- `KickbaseAPI.swift` – actor, alle HTTP-Aufrufe an https://api.kickbase.com (v4).
  Auth: POST /v4/user/login → `tkn` als Cookie `kkstrauth`.
- `Models.swift` – Player, Manager, League, Offer, … + JSON-Helfer `J`
- `AppState.swift` – @MainActor ObservableObject, lädt Daten, hält Caches
- `*View(s).swift` – SwiftUI-Oberfläche (Sidebar: Team, Markt, Liga, Transfers, Kader-Analyse)
- `TransferModels.swift` – Transfer, ManagerTransferStats, TransferPeriod
- `Keychain.swift` – Passwort im macOS-Schlüsselbund

## API-Eigenheiten (inoffizielle API!)
- Feldnamen sind kryptische Kürzel: `i` id, `n` Name, `fn` Vorname, `tid` Verein,
  `pos` 1 TW/2 ABW/3 MIT/4 ST, `st` Status (0 fit, 1 verletzt, 2 angeschlagen, …),
  `mv` Marktwert, `tfhmvt` 24h-Veränderung, `p` Punkte, `ap` Ø-Punkte, `prc` Preis,
  `exs` Ablauf, `uoid` Verkäufer-User-ID, `iotm` auf Transfermarkt, `b` Budget.
- Marktwertverlauf liefert nur mit Zeitraum 365 Daten: `{dt: Tage seit 1970, mv}`.
- Activity-Feed `/v4/leagues/{lid}/activitiesFeed?start=&max=`: `t:15` = Transfer
  (`byr`/`slr`, `trp`), `t:3` = Kickbase listet Spieler, `t:32` = Auto-Verkauf MVP.
- Activity-Feed t:15: `data.t` 1 = Kauf (`byr`), 2 = Verkauf (`slr`) – `byr`/`slr` sind
  Anzeigenamen (keine IDs!), `pi` Spieler, `pn` Nachname, `trp` Preis. 100 Einträge ≈ 4 Tage.
- Manager-Transfers: `/v4/leagues/{lid}/managers/{uid}/transfer?start=0` → `it[]` mit
  `dt, pi, pn, tid, trp, tty` (1 Kauf, 2 Verkauf), 25 pro Seite, `start` += 25.
  Grundlage des Transfers-Bereichs (`Transfer.merge` verbindet Kauf+Verkauf zu M2M).
- Fremder Kader `/managers/{uid}/squad`: Spieler-ID `pi`, Name `pn` (statt `i`/`n`),
  `prc` = Kaufpreis, `mvgl` = MW-Gewinn seit Kauf.
- Spielerdetails `/v4/leagues/{lid}/players/{pid}`: Nachname `ln` (statt `n`),
  Punkte `tp` (statt `p`), dazu `mv`, `tfhmvt`, `pos`, `st`, `ap`, `oui` (Besitzer).
- Aufstellung: eigener Kader `/squad` hat `lo` (0–10 = Startelf-Platz, fehlt = Bank); Formation = Anzahl je
  Position. `/lineup` liefert dasselbe plus `os` = Kürzel des NÄCHSTEN GEGNERS (nicht des eigenen Vereins!).
- Vereinsnamen: `/v4/competitions/1/table` → `it[]` mit `tid`, `tn` (Kurzname, z. B. „M'gladbach“).
  Die Karte ordnet `tn` Kürzel + Vereinsfarben zu (`CLUBS` in `kickpilot-card.js`, keine Logos – Urheberrecht).
- Antwortformate sind nicht offiziell dokumentiert: bei neuen Endpunkten erst eine
  echte Antwort ansehen (z. B. per kleinem Debug-Aufruf oder MCP-Tool), dann parsen.
  Unbekannte Felder tolerant behandeln (Optionals/Defaults), nie crashen.

- Schreibende Endpunkte (aus kickbase-mcp, NICHT selbst getestet): Gebot POST
  `/market/{pid}/offers` `{price}`; Listen POST `/market/` `{pi, prc}`; Sofortverkauf an
  Kickbase POST `/market/{pid}/sell` `{}` (Spieler muss gelistet sein); Annehmen DELETE
  `/market/{pid}/offers/{oid}/accept`. Fremde Gebote sind nicht sichtbar, nur `ofc` (Anzahl).
- Eigenes Gebot zurückziehen: DELETE `/market/{pid}/offers/{offerId}`. Kickbase liefert KEINE
  Gebots-ID (Marktliste `ofs` ohne `i`, GET `/market/{pid}` und `/offers` → 405). Die App nutzt
  die eigene User-ID als offerId – vom Nutzer am 26.11.2026 erfolgreich getestet (Gebot verschwand
  danach aus der Marktliste).

## Ligaregeln & Transfer-Automatik (`AutoTransfer.swift`, `AutoTransferView.swift`)
- Max. 18 Spieler im Kader, max. 3 Spieler pro Verein (`AutoRules`).
- Immer mindestens 1 Torhüter, 3 Abwehrspieler und 1 Stürmer im Kader (`AutoRules.minPerPosition`);
  Verkaufsvorschläge dürfen das nie unterschreiten.
- Budget muss jeden Freitag 19:00 Uhr (Europe/Berlin) ≥ 0 sein.
  Käufe, die ab Freitag 20:00 Uhr zustande kommen, zählen erst für die Folgewoche.
- Alle Gebote zusammen: Budget darf höchstens auf −30 % des Teamwerts fallen (Wert vom
  Nutzer „glaube ich“ – `AutoRules.maxDebtShareOfTeamValue`).
- Automatik = Vorschläge + Sammelbestätigung; nie ohne Bestätigungsdialog ausführen.
- Gebote: Gebot = MW × (1 + 75-%-Perzentil des Aufpreises des stärksten Konkurrenten + 1 Pp.).
  Nur wenn: fit, stabiler Anstieg (≥ 4 von 5 Tagen gestiegen) ODER Trendumkehr (Boden in den
  letzten 6 Tagen nach ≥ 5 % Rückgang, seitdem ≥ 2 Tage in Folge gestiegen), MW unter dem letzten Hochpunkt (Maximum vor der
  aktuellen Steigphase), erwarteter Verkaufswert nach 3 Tagen (Trend fortgeschrieben, gedeckelt
  am Hochpunkt) − Gebot ≥ max(5 % des Gebots, 100.000 €). Hochpunkt = Maximum der 30 Tage vor der
  aktuellen Steigphase. Heutiger MW wird nur angehängt, wenn er sich geändert hat (Update ~22 Uhr). Backtest über 120 Tage in der Ansicht.
  Gebotsrahmen = Budget + 100 % des MW aller Spieler außerhalb der Top 11 (Ø-Punkte).
  Kaufvorschlag erst am Ablauftag des Angebots (`exs`, gleicher Kalendertag Europe/Berlin) – dann ist
  sicherer, ob der Marktwert wie geschätzt steigt.
- Verkauf an Kickbase bringt immer 100 % des Marktwerts (vom Nutzer bestätigt).
- Freitags-Ausgleich: schwächste Spieler (Ø-Punkte) mit bestem Wertzuwachs zuerst, Top 11 zuletzt.

## Home-Assistant-Integration (`custom_components/kickbase/`)
- Python-Port für Home Assistant, Plan in `docs/home-assistant-plan.md`.
- `planner.py` ist eine 1:1-Übertragung von `AutoTransfer.swift`: Regeländerungen immer in BEIDEN
  Dateien nachziehen.
- Installieren beim Entwickeln: per SSH (`hassio@homeassistant.local`, mit `sudo tar`) nach
  `/config/custom_components/kickbase/` kopieren, dann HA neu starten (Module werden nur beim Start geladen).
- Dashboard-Karte `frontend/kickpilot-card.js` (`type: custom:kickpilot-card`, Vanilla-Web-Component ohne
  Build-Schritt): wird von `async_setup` unter `/kickbase/kickpilot-card.js?v=<hash>` ausgeliefert und per
  `add_extra_js_url` geladen. Findet Entitäten über `hass.entities` (platform `kickbase` + translation_key).
  Design `app`/`ha` kommt aus der Option „Design des Dashboards“ (Attribut `design` am Automatik-Schalter).
  Schreibaktionen in der Karte immer mit eigenem Bestätigungsdialog.
- Logo (Fußball mit Pilotenschwingen): Quelle `branding/generate_logo.py` (SVG), PNGs für HA mit
  `branding/make_brand.sh` nach `custom_components/kickbase/brand/` (icon, logo, dark_logo, je @2x).
- Standard ist halbautomatisch; Vollautomatik nur nach ausdrücklichem Einschalten im Options-Flow
  (mit Pflicht-Häkchen), Trockenlauf standardmäßig an.

## Regeln
- Schreibende Aufrufe (Gebote, Verkäufe, Aufstellung) sind ECHTE Transaktionen:
  in der UI immer mit Bestätigungsdialog; beim Entwickeln niemals selbst auslösen.
- Netzwerkzugriffe nur auf api.kickbase.com.
- Zugangsdaten nie loggen, nie in Dateien schreiben (nur Schlüsselbund).
- UI-Texte auf Deutsch, Beträge im Format `12.345.678 €`.
