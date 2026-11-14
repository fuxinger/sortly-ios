# SORTLY – Arbeitsstand (Übergabe-Notiz)

Übergabe-Notiz für eine Fortsetzung nach einer Unterbrechung.
Repository: github.com/fuxinger/sortly-ios, Branch `claude/sortly-app`, Draft-PR #1 (nicht mergen).
Arbeitskopie im Projektordner: /mnt/project-files/sortly/ (Sync: /home/user/scripts/sync.sh).

## Rahmenbedingungen
- Fuchs hat keinen Mac und kein Apple-Developer-Konto. iOS-Builds und Tests laufen über
  GitHub Actions (macos-26), unsigniert (`CODE_SIGNING_ALLOWED=NO`), nur im Simulator.
- Mindestens iOS 26, muss auch auf iOS 27 laufen.
- Linux-Toolchain im Container: `export PATH=/home/user/toolchain/swift-6.2.3-RELEASE-ubuntu24.04/usr/bin:$PATH`, Kern-Tests mit `swift test`.
- Selbständig weiterarbeiten, keine Rückfragen. Antworten auf Deutsch, einfache Sprache.

## Entscheidungen
- Design Richtung A „Klar“, Systemschrift SF Pro mit Dynamic Type.
- Offline-Weltkarte (Natural Earth, gemeinfrei) zuerst, Apple-Geocoder nur für Städte, gedrosselt.
- iCloud: Metadaten und lokale Vorschauen für alle Fotos; Originale nur für Screenshots und
  Dokumente, nur WLAN, nur mit Zustimmung; nie Videos.
- Probelauf: Vorschläge zuerst auf ein Jahr oder ein Album beschränkbar.
- Geschäftsmodell (Vorschlag): Gratis-Download, die ersten 10 Alben frei
  (`Purchases.freeAlbumLimit`), danach einmalige Freischaltung `app.sortly.ios.unlock`.
- Ausgeschlossen: Foto-Cleaner, Duplikate löschen, Rückblicke, Fotobücher.

## Aufbau
- `Sources/SortlyCore` – plattformunabhängige Logik (Reisen, Orte, Vorschläge, Abgleich, Plan, Ausführung, Suche, Status)
- `Sources/SortlyStore` – SQLite (Migrationen v1–v2)
- `Sources/SortlyWorldMap` – Offline-Weltkarte (4,8 MB), Generator in `scripts/worldmap/`
- `Sources/SortlyEngine` – fortsetzbare Analyse-Pipeline, Bibliotheksstatus
- `App/` – iOS-App (XcodeGen `project.yml`, SwiftUI, PhotoKit, Vision, StoreKit 2)

## Stand
- [x] Kern, Store, Weltkarte, Engine: 143 Tests grün (Linux und macOS)
- [x] iOS-App: alle Bildschirme geschrieben
- [x] iOS-Build in CI grün
- [x] Simulator-Build als ZIP; Upload zu Appetize, sobald Fuchs das Secret `APPETIZE_TOKEN` anlegt
- [x] Englische Übersetzung (String Catalogs in `App/Sortly/Resources/*.xcstrings`)
- [x] Reise-Atlas im Apple-Stil, Teilen-Bild mit Foto; Foto-Geschichte
- [x] Launch-Texte in `docs/launch/` (Presse und Webseite/Datenschutzerklärung laufen in eigenen Threads)
- [ ] Gesichter/Haustiere (Opt-in), BGContinuedProcessingTask, Verwaltung der angelegten Alben
- [x] Doku nach Prompt §24, App-Store-Texte, Featuring-Nominierung
- Später (Entscheidung Fuchs): Mitteilungen/Live Activity, Widget, Personen/Haustiere (Update 1.1)
