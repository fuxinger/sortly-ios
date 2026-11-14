# Changelog

## 0.1.0 (in Entwicklung)
### Hinzugefügt
- Kernlogik: Reisen, häufige Orte, Orte (Offline-Karte + gedrosselter Geocoder), Chronologie,
  Medientypen, Screenshots, Themen, Dokumente, Messenger-Hinweise, Regeln, Suche, Status.
- Abgleich mit vorhandenen Alben und Erkennung ähnlicher Alben.
- Änderungspläne mit Vorschau, sicherer Ausführung, Wiederanlauf und Rückgängig.
- SQLite-Store mit Migrationen v1–v2.
- Fortsetzbare Analyse-Pipeline mit Probelauf und nächtlicher Verfeinerung.
- iOS-App: Einführung, Übersicht, Vorschläge, Umsetzen, Mediathek, Alben, Suche,
  Einstellungen, Verlauf; Einmalkauf; Kurzbefehl; Datenschutz-Manifest.
- Teilbarer „Reise-Atlas“ im Apple-Stil: Weltkarte der besuchten Länder, Kennzahlen,
  Teilen-Bild mit Vorschau und optionalem Foto vom Lieblingsziel.
- Foto-Geschichte mit Apple Intelligence (Reisen, Jahre, ganze Mediathek), in der App-Sprache.
- Englische Übersetzung (App, Info.plist, Kurzbefehle).
- Optional mit Apple Intelligence: Suche in ganzen Sätzen, Namensvorschläge für Reisen.
- CI: Tests auf Linux und macOS, App-Build im Simulator, Simulator-ZIP und automatischer Upload zu Appetize (mit Secret `APPETIZE_TOKEN`).
### Korrigiert
- Datumswerte verlieren beim Speichern keine Millisekunden mehr.
- Bilderkennungs-Begriffe an die tatsächliche Vision-Liste angepasst.
- Namenskonflikt `Observation` mit Apples Observation-Framework behoben.
### Migrationen
- v2: Spalte `asset_places.precision_m`.
