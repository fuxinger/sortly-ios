# Architektur

## Überblick
```
App (SwiftUI, @Observable AppModel)
 ├─ Platform: PhotoKitLibrary · VisionAnalyzer · SystemGeocoder · DeviceConditions · BackgroundWork · Purchases
 └─ SortlyEngine: AnalysisPipeline (actor) · FactsAssembler · LibraryStatus
       ├─ SortlyCore  (reine Logik, keine Apple-Frameworks außer Foundation)
       ├─ SortlyStore (SQLite)
       └─ SortlyWorldMap (Ressource world.sortlymap)
```
Die gesamte Fachlogik liegt in `SortlyCore` und ist auf Linux testbar. Plattformzugriffe
stehen hinter Protokollen (`PhotoLibraryReading`, `PhotoLibraryWriting`, `ContentAnalyzing`,
`ReverseGeocoding`, `AnalysisConditions`), die in Tests durch Fakes ersetzt werden.

## Module
| Modul | Aufgabe |
|---|---|
| Domain | `AssetSnapshot`, `CollectionSnapshot`/`CollectionInventory`, Identitäten |
| Trips | Reiseerkennung relativ zu einem zeitlich gleitenden Heimatbereich |
| Places | Offline-Karte, `PlaceResolutionService` (Drosselung, Cache, Verfeinerung), häufige Orte |
| Analysis | Klassifikations-Taxonomie, Screenshot-/Dokument-/Messenger-Auswertung, Medientypen |
| Proposals | `ProposalEngine` erzeugt `AlbumProposal`s je Bereich |
| Matching | `AlbumMatcher` (Mengenvergleich), `AlbumOverlapAnalyzer` (ähnliche Alben) |
| Planning | `OrganizationPlanner` → `ChangePlan` (reine Funktion) |
| Execution | `ChangeExecutor` (idempotente Schritte, Wiederanlauf), `UndoPlanner` |
| Status | Organisationsstatus je Foto, Inbox-Buckets, verwaltete Alben |
| Rules / Search / Naming / Time | Regeln, Suche, Titel und Datumsbereiche, Chronologie |

## Datenfluss
1. **Inventar:** PhotoKit → `AssetSnapshot` (nur Metadaten) und Album-Inventar → Store.
2. **Muster:** Reisen und häufige Orte aus Zeit und GPS.
3. **Orte:** Offline-Karte für Land/Region; Städte über den Apple-Geocoder pro Rasterzelle,
   priorisiert (Reisen zuerst), gedrosselt (40 Anfragen/min) und gecacht.
4. **Inhalte:** Vision-Klassifikation auf lokalen Vorschaubildern.
5. **Text:** OCR und Barcodes nur für Screenshots und Dokumente.
6. **Vorschläge:** `FactsAssembler` bündelt alles zu `AssetFacts` → `ProposalEngine` →
   `AlbumMatcher` → `ProposalSnapshot` (gespeichert).
7. **Plan:** Nutzerentscheidungen → `OrganizationPlanner` → `ChangePlan` (Vorschau).
8. **Ausführung:** `ChangeExecutor` prüft Fingerabdrücke der betroffenen Alben, führt
   Schritte einzeln aus, speichert den Zustand nach jedem Schritt.

Jede Etappe speichert ihren Fortschritt (`analysis_progress`), pausiert an Stapelgrenzen und
setzt beim nächsten Lauf fort. Ergebnisse tragen eine Versionsnummer, damit verbesserte
Analysen gezielt neu laufen.

## Framework-Entscheidungen
SwiftUI (iOS 26, Liquid Glass über Systemleisten), PhotoKit, Vision (neue Swift-API:
`ClassifyImageRequest`, `RecognizeTextRequest`, `DetectBarcodesRequest`), CoreLocation
(`CLGeocoder`), BackgroundTasks (`BGProcessingTask` nachts beim Laden), StoreKit 2,
App Intents. Keine Drittanbieter-Abhängigkeiten.

## Persistenz
Eine SQLite-Datei in *Application Support/SORTLY* (vom Backup ausgeschlossen, da aus der
Mediathek rekonstruierbar). Schema und Migrationen: `DATA_MODEL.md`. Es werden keine Bilder
gespeichert; Vorschaubilder kommen jedes Mal frisch aus PhotoKit.

## Nebenläufigkeit
Swift 6 mit strikter Prüfung. `AnalysisPipeline`, `PlaceResolutionService` und `SortlyStore`
sind Actors; die UI-Schicht ist `@MainActor`.
