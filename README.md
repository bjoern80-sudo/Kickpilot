# Kickpilot – Kickbase-Begleiter für macOS

Kleine native SwiftUI-App für das Fantasy-Spiel Kickbase. Die API-Logik stammt aus
[behretv/kickbase-mcp](https://github.com/behretv/kickbase-mcp), geprüfter Stand: Commit `13832cb`.

## Funktionen
- **Mein Team:** Budget, Teamwert, Marktwertänderung der letzten 24 h, Kader als sortierbare Tabelle
- **Transfermarkt:** Filter nach Position, Suche, Punkte pro Mio. €, Ablaufzeit, Anbieter
- **Gebote:** Doppelklick auf einen Marktspieler, dann Betrag wählen und bestätigen. Das löst eine **echte** Transaktion aus. Eigene offene Gebote lassen sich zurückziehen.
- **Liga:** Tabelle der Manager. Ein Doppelklick öffnet die Kader-Analyse.
- **Kader-Analyse:** Vergleich aller Kader (Wert, Ø-Punkte, Ausfälle, Positionen) und Detailansicht pro Manager
- **Spielerdetails:** Marktwertverlauf der letzten 12 Monate

## Voraussetzungen
- macOS 13 (Ventura) oder neuer
- Xcode oder die Command Line Tools mit Swift 5.9 oder neuer. Prüfen mit `swift --version`, installieren mit `xcode-select --install`.

## Bauen
```bash
cd ~/Claude/KickbaseMac
chmod +x build.sh
./build.sh
open Kickpilot.app
```
Danach kannst du `Kickpilot.app` in den Ordner „Programme“ ziehen.

## Sicherheit
- Die App verbindet sich nur mit `api.kickbase.com`.
- Das Passwort liegt im macOS-Schlüsselbund, wenn „merken“ aktiviert ist.
- Die API ist inoffiziell und kann sich ohne Vorwarnung ändern.
