# Albumist – Fotos automatisch in Alben sortieren

Albumist ist eine native iOS-App, die die Apple-Fotomediathek **vollständig auf dem iPhone**
analysiert und daraus Alben und Ordner vorschlägt: Reisen mit Datum, Länder und Städte,
häufige Orte, Jahre und Monate, Medientypen, Screenshots, Themen und Dokumente.
Vorhandene Alben werden erkannt und ergänzt statt doppelt angelegt. Jede Änderung wird
vorher gezeigt, erst nach Bestätigung ausgeführt und lässt sich rückgängig machen.
Originalfotos werden nie gelöscht, verändert oder kopiert.

## Voraussetzungen
- iOS/iPadOS 26 oder neuer (getestet im Simulator, siehe `docs/TEST_PLAN.md`)
- Zum Bauen: Xcode 27 auf macOS und [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Für die plattformunabhängige Logik reicht Swift 6.2 (auch Linux)

## Installation und Build
```bash
brew install xcodegen
cd App && xcodegen generate
open Sortly.xcodeproj          # Schema „Sortly“, Ziel: iPhone-Simulator
```
Ohne Mac: GitHub Actions baut bei jedem Push auf einem macOS-Runner (`.github/workflows/ci.yml`)
und legt eine Simulator-Version als `Sortly-simulator-app` ab (für Appetize.io).

## Tests
```bash
swift test                     # Kernlogik, Datenbank, Analyse-Pipeline (Linux und macOS)
SORTLY_STRESS_SEEDS=300 swift test --filter RandomLibraryTests   # 300 zufällige Mediatheken
SORTLY_LOAD_TEST=1 swift test --filter LoadTests                  # 20.000 Fotos
cd App && xcodebuild test -project Sortly.xcodeproj -scheme Sortly \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

## Projektstruktur
| Pfad | Inhalt |
|---|---|
| `Sources/SortlyCore` | Plattformunabhängige Logik: Reisen, Orte, Vorschläge, Album-Abgleich, Plan, Ausführung, Rückgängig, Suche, Status |
| `Sources/SortlyStore` | SQLite-Persistenz mit Migrationen |
| `Sources/SortlyWorldMap` | Offline-Weltkarte (Natural Earth, gemeinfrei) |
| `Sources/SortlyEngine` | Fortsetzbare Analyse-Pipeline, Bibliotheksstatus |
| `Sources/SortlyTestSupport` | Fakes und Testdaten (nur für Tests) |
| `App/` | iOS-App (SwiftUI, PhotoKit, Vision, StoreKit 2), Projekt via `App/project.yml` |
| `Tests/` | Swift-Testing-Suites für Kern, Store und Engine |
| `scripts/worldmap` | Generator für die Offline-Karte |
| `docs/` | Produkt-, Architektur- und Testdokumentation; `docs/review/` Anleitung für eine externe Code-Prüfung |
| `tools/` | App-Icon-Generator, `make_review_zip.sh` (Code als ZIP für die Prüfung) |

Weitere Dokumente: [PRODUCT_SPEC](docs/PRODUCT_SPEC.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) ·
[DATA_MODEL](docs/DATA_MODEL.md) · [ALBUM_MATCHING](docs/ALBUM_MATCHING.md) ·
[AI_PIPELINE](docs/AI_PIPELINE.md) · [PRIVACY](docs/PRIVACY.md) · [TEST_PLAN](docs/TEST_PLAN.md) ·
[ROADMAP](docs/ROADMAP.md) · [DECISIONS](docs/DECISIONS.md) ·
[KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md) · [CHANGELOG](docs/CHANGELOG.md)
