# Architektur

## Überblick
```
App (SwiftUI, @Observable AppModel)
 ├─ Platform: PhotoKitLibrary · VisionAnalyzer · SystemGeocoder · DeviceConditions · BackgroundWork · Purchases
 └─ AlbumistEngine: AnalysisPipeline (actor) · FactsAssembler · LibraryStatus
       ├─ AlbumistCore  (reine Logik, keine Apple-Frameworks außer Foundation)
       ├─ AlbumistStore (SQLite)
       └─ AlbumistWorldMap (Ressource world.albumistmap)
```
Die gesamte Fachlogik liegt in `AlbumistCore` und ist auf Linux testbar. Plattformzugriffe
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
SwiftUI (iOS 27, Mindestversion 26; Liquid Glass über Systemleisten), PhotoKit, Vision (neue Swift-API:
`ClassifyImageRequest`, `RecognizeTextRequest`, `DetectBarcodesRequest`), CoreLocation
(`CLGeocoder`), BackgroundTasks (`BGProcessingTask` nachts beim Laden), StoreKit 2,
App Intents. Keine Drittanbieter-Abhängigkeiten.

## Persistenz
Eine SQLite-Datei in *Application Support/Albumist* (vom Backup ausgeschlossen, da aus der
Mediathek rekonstruierbar). Schema und Migrationen: `DATA_MODEL.md`. Es werden keine Bilder
gespeichert; Vorschaubilder kommen jedes Mal frisch aus PhotoKit.

Was nicht rekonstruierbar ist (Ausnahmen, Regeln, Einstellungen außer `analysis.*` und
`execution.*`, verwaltete Alben, Pläne), kopiert `SafetyBackup` als rohe Zeilen in
*Application Support/Albumist Backup/decisions.json*, die im Geräte-Backup liegt (Nutzdaten als
JSON-Text, auf Apple-Geräten mit LZFSE komprimiert, damit die Kopie auch bei großen Mediatheken klein bleibt). Geschrieben
wird zwei Sekunden nach einer Entscheidung, nach jeder Analyse und beim Wechsel in den
Hintergrund. Beim Start einer leeren Datenbank kommen die Entscheidungen sofort zurück, Alben und
Verlauf erst, wenn die Mediathek passt (mindestens die Hälfte der verwalteten Alben existiert).

## Nebenläufigkeit
Swift 6 mit strikter Prüfung. `AnalysisPipeline`, `PlaceResolutionService` und `AlbumistStore`
sind Actors; die UI-Schicht ist `@MainActor`.

<!-- rename:keep-begin: tools/rename_albumist.py leaves this section as it is -->
## Umbenennung des Arbeitsnamens „Sortly“ in Albumist
Sichtbar heißt die App Albumist (Bundle-ID `app.albumist.ios`); intern tragen Paket, Module,
Ordner, Targets, Schemata, Typen, Test-Schalter, Skripte und Dokumente noch den Arbeitsnamen
„Sortly“. `tools/rename_albumist.py` benennt das in einem Schritt um (Tests:
`.github/scripts/tests/test_rename_albumist.py`):

    python3 tools/rename_albumist.py                          # Plan: Verschiebungen, Ersetzungen je Datei, Ausnahmen
    python3 tools/rename_albumist.py --apply                  # git mv und Ersetzungen, nur auf sauberem Arbeitsbaum
    python3 tools/rename_albumist.py --apply --repo-renamed   # erst nach dem Umbenennen des Repositorys

Sortly → Albumist, sortly → albumist, SORTLY → ALBUMIST, auch in längeren Namen (`SortlyID` →
`AlbumistID`); jede andere Schreibweise hält das Skript an. Danach erzeugt es `docs/CODEMAP.md`
neu. Ein zweiter Lauf nach dem Commit findet nichts mehr.

Gespeicherte Namen dürfen sich nicht still ändern, sonst verliert ein Update Daten:
- Datenbankdatei: `DatabaseFile` (Store-Modul) zieht `sortly.sqlite` mit `-wal` und `-shm` einmal
  auf den neuen Namen um, in `AppModel.databaseURL()` bevor die Datenbank öffnet. Gibt es die neue
  Datei schon, bleibt alles, wie es ist; ältere Dateien daneben (etwa nach einem älteren Build, der
  noch einmal lief) bleiben und stehen im Diagnosebericht. Scheitert ein Schritt, wandert alles
  zurück, auch ein Log, das ein früherer Start schon verschoben hatte, und die alte Datei öffnet
  mit ihrem Log unter ihrem Namen (nie eine leere neue Datenbank daneben, nie eine ohne ihr Log);
  scheitert auch der Rückweg, scheitert der Start (Startfehler-Seite), gelöscht wird nichts. Ein
  Log unter beiden Namen: das unter dem neuen Namen ist veraltet und kommt nach
  `Quarantine/<Zeit>-stray/` (verschoben, nicht gelöscht; SQLite spielte es sonst über neuere
  Zeilen; „Neu aufbauen“ behält davon die zwei neuesten, getrennt von den zwei neuesten
  beiseitegelegten Datenbanken), dann
  zieht die Datenbank um; „Neu aufbauen“ nimmt solche Logs beider Namen mit in die Quarantäne. Bis zur Umbenennung sind beide
  Namen gleich und nichts zieht um.
- JSON-Schlüssel `addedBySortly` und `createdBySortly` der verwalteten Alben (Datenbank,
  Sicherungskopie): feste Rohwerte in `ManagedAlbumState.CodingKeys`; nur die Swift-Namen ändern sich.
- Alle anderen gespeicherten Namen tragen den alten Namen nicht: UserDefaults-Schlüssel,
  Schlüsselbund-Dienst, Hintergrund-Aufgaben, Mitteilungen, Kauf-ID, Ordner `Albumist` in
  *Application Support*.

Bewusst nicht umbenannt (Liste mit Gründen: `EXCLUSIONS` im Skript, der Plan zeigt jede Stelle):
der alte Zweig `claude/sortly-app`, die Appetize-Notiz `sortly-ci` (eine neue Notiz hieße eine
neue Appetize-App mit neuem Testlink), Ordner früherer Prüfungen `sortly-review/`, Sätze über den
früheren Namen. Die Repository-Adressen (`fuxinger/sortly-ios`, `fuxinger.github.io/sortly-ios`)
ändern sich nur mit `--repo-renamed`: GitHub leitet die alte Repository-Adresse weiter, die alte
Pages-Adresse nicht. Datenschutz-Link der App und die URLs in App Store Connect wechseln deshalb im
selben Schritt wie die Umbenennung. Erledigt: Das Repository heißt seit 21.11.2026 `albumist-ios`,
der Lauf mit `--repo-renamed` ist gemacht.

Danach auf dem Mac: Xcode-Projekt neu erzeugen (`xcodegen` in `App/`), das alte, ignorierte
`App/Sortly.xcodeproj` und DerivedData löschen. Target, Schema und Programmdatei heißen dann
Albumist; die Bundle-ID bleibt, ein Update ersetzt die App wie bisher.
<!-- rename:keep-end -->
