# Kickbase für macOS – Projektnotizen für Claude

Native SwiftUI-App (macOS 13+, Swift Package, keine Fremdabhängigkeiten) für das
Bundesliga-Fantasy-Spiel Kickbase. Die API-Logik stammt aus behretv/kickbase-mcp
(geprüfter Stand: Commit 13832cb).

## Bauen & Starten
- Bauen: `swift build` (schnell, zum Prüfen) bzw. `./build.sh` (Release + Kickbase.app)
- Starten: `open Kickbase.app`
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
- Spielerdetails `/v4/leagues/{lid}/players/{pid}`: Nachname `ln` (statt `n`),
  Punkte `tp` (statt `p`), dazu `mv`, `tfhmvt`, `pos`, `st`, `ap`, `oui` (Besitzer).
- Antwortformate sind nicht offiziell dokumentiert: bei neuen Endpunkten erst eine
  echte Antwort ansehen (z. B. per kleinem Debug-Aufruf oder MCP-Tool), dann parsen.
  Unbekannte Felder tolerant behandeln (Optionals/Defaults), nie crashen.

## Regeln
- Schreibende Aufrufe (Gebote, Verkäufe, Aufstellung) sind ECHTE Transaktionen:
  in der UI immer mit Bestätigungsdialog; beim Entwickeln niemals selbst auslösen.
- Netzwerkzugriffe nur auf api.kickbase.com.
- Zugangsdaten nie loggen, nie in Dateien schreiben (nur Schlüsselbund).
- UI-Texte auf Deutsch, Beträge im Format `12.345.678 €`.
