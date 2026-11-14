# Prüfauftrag: Unabhängige Code-Prüfung von Albumist

## Anleitung für dich (an die KI: diesen Abschnitt überspringen, dein Auftrag beginnt unter der Linie)

Das Prüfpaket ist **eine ZIP-Datei**. Darin liegen dieser Prüfauftrag (`PRUEFAUFTRAG.md`) und
der komplette Code (Ordner `sortly/`).

1. **ZIP herunterladen** (Link aus dem Chat mit Claude; landet auf dem iPhone unter
   Dateien > Downloads). Nicht entpacken.
2. **Neuen Chat öffnen** in ChatGPT oder Gemini. Nimm das stärkste Modell mit
   ausführlichem Nachdenken („Thinking“, „Pro“ oder „Deep Think“, je nachdem was dein Abo anbietet).
3. **ZIP hochladen** und dazu diesen einen Satz schreiben:
   > Entpacke die ZIP, lies die Datei PRUEFAUFTRAG.md und führe den Auftrag darin vollständig aus. Beginne mit Teil 0.

   Falls die KI die ZIP nicht öffnen kann: Öffne `PRUEFAUFTRAG.md` selbst, kopiere alles
   zwischen den beiden Linien und schicke es als Nachricht mit.
4. Die KI arbeitet in Teilen. Wenn sie stoppt, schreibe: **„Weiter mit Teil 3“** (die passende Zahl).
5. Nützliche Nachfragen danach:
   - „Prüfe Befund 1.3 noch einmal: Zitiere den genauen Code und spiele das Szenario Schritt für
     Schritt durch. Ist es wirklich ein Fehler, oder verhindert eine andere Stelle ihn?“
   - „Welche deiner Befunde sind nur Vermutungen? Streiche alles, was du nicht mit Code belegen kannst.“
   - „Fasse alle kritischen und hohen Befunde als Liste zusammen, die ich weitergeben kann.“
6. Bring das Ergebnis zu Claude. Claude prüft jeden Befund gegen den Code, behebt die echten und
   sagt dir bei den anderen, warum sie nicht zutreffen.

Tipp: Lass ChatGPT **und** Gemini prüfen. Was beide unabhängig finden, ist fast immer echt.

---

# Auftrag: Prüfung einer iOS-App vor dem App-Store-Start

## 1. Deine Rolle

Du bist ein unabhängiges Prüfteam, das vor dem Start einer iOS-App ein professionelles Audit
macht. Im Team sind:

- ein **Staff iOS Engineer** (Swift 6 mit strikter Nebenläufigkeitsprüfung, SwiftUI, Observation,
  PhotoKit, Vision, StoreKit 2, BackgroundTasks),
- eine **QA- und Datensicherheits-Expertin**, die gezielt nach Wegen sucht, auf denen Nutzerdaten
  beschädigt werden,
- ein **App-Review-Spezialist**, der die App Review Guidelines und die Datenschutzregeln von Apple
  im Detail kennt,
- eine **Expertin für Barrierefreiheit und Human Interface Guidelines**,
- ein **Performance-Ingenieur** für große Datenmengen, Speicher, Akku und Wärme auf iPhones.

Arbeite **kritisch und gründlich**. Das Ziel ist, echte Fehler zu finden, bevor Kunden sie finden.
Lob, Füllsätze und allgemeine Ratschläge ohne Bezug zum Code sind nicht gefragt.

## 2. Grundregeln (bitte strikt einhalten)

1. **Beweispflicht.** Jeder Befund nennt Datei, Zeilen und ein kurzes Code-Zitat (höchstens
   etwa 10 Zeilen) aus der ZIP-Datei. Der Code liegt im Ordner `sortly/`; Pfade in diesem
   Auftrag sind relativ dazu. Ohne Zitat ist es kein Befund, sondern gehört in den
   Abschnitt „Vermutungen ohne Beleg“.
2. **Sicherheit angeben.** Markiere jeden Befund als **bestätigt** (Code gelesen, Szenario
   vollständig nachvollzogen, keine andere Stelle verhindert es), **wahrscheinlich** oder
   **Vermutung**.
3. **Gegenprobe.** Bevor du einen Befund meldest, suche aktiv nach Code, der ihn verhindert
   (Guards, Filter, Prüfungen in aufrufenden Funktionen, Tests). Nenne, wo du gesucht hast.
4. **Nichts erfinden.** Keine erfundenen Dateien, Funktionen oder Apple-APIs. Wenn du eine Datei
   nicht gelesen hast oder sie fehlt, sag das.
5. **Wissensstand.** Die App baut mit dem iOS-27-SDK und Xcode 27 (Mindestversion iOS 26). Dein
   Trainingswissen endet vielleicht vorher. Melde eine API nicht als „gibt es nicht“, nur weil du
   sie nicht kennst. Schreibe stattdessen „kann ich nicht prüfen“.
6. **Bewusste Entscheidungen respektieren.** Lies zuerst `docs/DECISIONS.md`,
   `docs/KNOWN_LIMITATIONS.md`, `docs/ALBUM_MATCHING.md`, `docs/PRIVACY.md` und
   `docs/ARCHITECTURE.md`. Was dort als Entscheidung oder bekannte Grenze steht, ist kein Fehler.
   Hältst du eine Entscheidung selbst für riskant, führe sie getrennt unter
   „Entscheidungen, die ich hinterfragen würde“ auf.
7. **Kein Rauschen.** Keine Stilfragen, keine Namensdiskussionen, kein „schreib alles mit einer
   anderen Architektur neu“, keine Fremdbibliotheken (die App nutzt bewusst keine).
8. **Tests beachten.** Prüfe, ob ein Test den Fall schon abdeckt (`Tests/`, `App/SortlyTests`,
   `App/SortlyUITests`). Wenn ja und du hältst den Fehler trotzdem für echt, erkläre, warum der Test
   ihn nicht erfasst.
9. **Sprache.** Antworte auf Deutsch, sachlich und präzise. Jeder Befund enthält zusätzlich einen
   Satz in einfacher Sprache für Nicht-Programmierer. Code-Vorschläge dürfen englisch sein.
10. **Ignorieren:** `Sources/SortlyWorldMap/Resources` (Kartendaten), Bilder, `design/`,
    `docs/launch/` und `.build/`.

## 3. Die App

**Albumist** (im Code heißen Ordner, Module und Targets noch nach dem alten Arbeitsnamen
„Sortly“) sortiert die Fotos-Mediathek eines iPhones in echte Alben der Fotos-App, vollständig
auf dem Gerät.

- **Analyse:** erkennt Reisen (mit Zuhause-Erkennung), Länder und optional Städte, häufige Orte,
  Screenshots nach Inhalt, Dokumente, Messenger-Bilder (nur bei klaren Hinweisen), Bildthemen.
  Vision läuft auf Vorschaubildern. Länder kommen aus einer Offline-Weltkarte; genauere Ortsnamen
  optional über Apples Geocoding (nur Koordinaten, abschaltbar).
- **Vorschläge:** Für jeden Bereich schlägt die App Alben vor und gleicht sie mit vorhandenen Alben
  ab (identisch, ergänzen, mehrere passen, Teil eines anderen Albums …).
- **Plan und Vorschau:** Nichts passiert ohne Vorschau. Die Vorschau zeigt jedes Album, das
  angelegt oder ergänzt wird. Erst „Jetzt umsetzen“ ändert die Mediathek.
- **Ausführung und Rückgängig:** Der Plan wird schrittweise und fortsetzbar ausgeführt. Jede
  Ausführung lässt sich rückgängig machen; iOS fragt dabei nur einmal.
- **Weiteres:** Reise-Atlas (Weltkarte mit besuchten Ländern, Statistiken, Teilen-Karte),
  Mediathek-Ansicht mit Sortierstatus je Foto, Suche (optional mit Apple Intelligence auf dem
  Gerät), Siri und Kurzbefehle (App Intents), Spotlight, Mitteilung „Analyse fertig“,
  Live-Fortschritt.
- **Geschäftsmodell:** kostenloser Download, 10 Alben gratis, danach einmaliger Kauf über
  StoreKit 2 (kein Abo, keine Werbung, kein Konto).
- **Technik:** Swift 6 Language Mode, SwiftUI, Observation, keine Fremdbibliotheken. Die
  Fachlogik liegt in einem Swift-Paket, das auch unter Linux baut und getestet wird. iPhone und
  iPad. Sprachen Deutsch und Englisch (`Localizable.xcstrings`). Projekt per XcodeGen
  (`App/project.yml`).
- **Tests:** über 200 automatische Tests (Swift Testing), ein Stresstest mit zufälligen
  Mediatheken (Analyse, Plan, Ausführung, Rückgängig), App-Tests und ein UI-Test, der die ganze
  App im Simulator durchgeht. Nicht auf echten Geräten getestet (siehe `KNOWN_LIMITATIONS.md`).

## 4. Zusagen an die Nutzer (Invarianten)

Diese Zusagen darf **kein** Weg im Code brechen. Ein Bruch ist immer „kritisch“.

| Nr. | Zusage |
|---|---|
| **Z1** | Fotos und Videos werden **nie gelöscht oder verändert** (kein Löschen von Assets, keine Bearbeitung, keine Änderung von Datum, Ort, Favorit, Ausgeblendet). Erlaubte Operationen stehen in `PlannedOperation` (`Planning/ChangePlan.swift`): Ordner/Album anlegen, Fotos zu Alben hinzufügen, Sammlungen umbenennen/verschieben, Album-Zugehörigkeiten entfernen, Album- oder Ordner-Container löschen. |
| **Z2** | **Alben des Nutzers** werden nie umbenannt, verschoben, geleert oder gelöscht, außer der Nutzer hat genau das für dieses Album in der Vorschau bestätigt. Löschen beim Rückgängigmachen betrifft nur Container, die Albumist selbst angelegt hat, und Ordner nur, wenn nichts Fremdes darin liegt. |
| **Z3** | **Hand-Änderungen in Fotos werden respektiert:** Ein Foto, das der Nutzer aus einem Albumist-Album entfernt hat, kommt nicht wieder hinein. Ein gelöschtes Album wird nicht neu angelegt. (`Status/ManagedAlbumTracker.swift`, Overrides im Planer) |
| **Z4** | **Rückgängig** entfernt genau das, was Albumist hinzugefügt oder angelegt hat, auch nach Neustart der App und wenn der Nutzer inzwischen eigene Fotos in ein Albumist-Album gelegt hat. |
| **Z5** | **Nichts ohne Bestätigung:** Keine Änderung an der Mediathek ohne Vorschau und Tippen auf „Jetzt umsetzen“. Eine Vorschau hinterlässt keine Auswahl, die der Nutzer nicht selbst getroffen hat (`AppModel.selectForPreview` / `endPreview`). |
| **Z6** | **Alles auf dem Gerät:** Keine eigenen Server, kein Tracking, keine Analyse-SDKs. Netz nur für Apples Geocoding (nur Koordinaten, abschaltbar), iCloud-Downloads und StoreKit. |
| **Z7** | **Sparsam mit Daten:** Originale werden nur für Screenshots und Dokumente geladen, standardmäßig nur im WLAN, **nie Videos**. Ausgeblendete Fotos sind standardmäßig ausgeschlossen. |
| **Z8** | **Große Mediatheken** (100.000+ Fotos, großteils nur in iCloud) funktionieren: Analyse ist fortsetzbar, blockiert nicht die Oberfläche, achtet auf Wärme, Akku und Stromsparmodus. |

## 5. Dateikarte

| Bereich | Dateien |
|---|---|
| Domäne | `Sources/SortlyCore/Domain/*` (Assets, Sammlungen, IDs, Bereiche) |
| Reisen | `Sources/SortlyCore/Trips/TripDetector.swift`, `Geo/GeoClusterer.swift`, `Geo/GeoMath.swift` |
| Orte und Atlas | `Sources/SortlyCore/Places/*` (Offline-Karte, Ortsauflösung, häufige Orte, Atlas) |
| Analyse | `Sources/SortlyCore/Analysis/*`, `Sources/SortlyEngine/AnalysisPipeline.swift` (actor, fortsetzbar), `FactsAssembler.swift`, `LibraryStatus.swift` |
| Vorschläge | `Sources/SortlyCore/Proposals/ProposalEngine.swift`, `AlbumProposal.swift`, `OrganizationSettings.swift`, `ProposalOrder.swift`, `PreviewPicker.swift` |
| Abgleich mit vorhandenen Alben | `Sources/SortlyCore/Matching/AlbumMatcher.swift` (+ `docs/ALBUM_MATCHING.md`) |
| Plan | `Sources/SortlyCore/Planning/OrganizationPlanner.swift`, `ChangePlan.swift`, `PlanPreview.swift` |
| Ausführung, Rückgängig | `Sources/SortlyCore/Execution/ChangeExecutor.swift` (inkl. `UndoPlanner`, `deleteBatch`) |
| Status, Fortschritt | `Sources/SortlyCore/Status/ManagedAlbumTracker.swift`, `OrganizationStatusResolver.swift` |
| Regeln, Suche, Namen, Zeit | `Rules/RuleEngine.swift`, `Search/Search.swift`, `Naming/*`, `Time/Chronology.swift`, `Similarity/Similarity.swift` |
| Speicher | `Sources/SortlyStore/SQLiteDatabase.swift`, `SortlyStore.swift`, `Migrations.swift` |
| App-Zustand | `App/Sortly/Model/AppModel.swift` (@MainActor, @Observable) |
| Plattform | `App/Sortly/Platform/PhotoKitLibrary.swift`, `VisionAnalyzer.swift`, `BackgroundWork.swift`, `ContinuedAnalysis.swift`, `LibraryChangeWatcher.swift`, `Purchases.swift`, `SystemServices.swift`, `SmartAssistant.swift`, `DemoLibrary.swift`, `UITestSupport.swift` |
| Einstieg, Siri, Spotlight | `App/Sortly/App/*` |
| Oberfläche | `App/Sortly/Views/*`, `App/Sortly/DesignSystem/*` |
| Ressourcen | `App/Sortly/Resources/Localizable.xcstrings`, `PrivacyInfo.xcprivacy`, `App/project.yml` (Info.plist-Werte, Hintergrundmodi) |
| Tests | `Tests/SortlyCoreTests`, `Tests/SortlyEngineTests`, `Tests/SortlyStoreTests`, `App/SortlyTests`, `App/SortlyUITests`, Testhilfen in `Sources/SortlyTestSupport` |
| Build | `.github/workflows/ci.yml`, `.github/workflows/ui.yml`, `.github/scripts/*`, `Package.swift` |

## 6. Zuletzt geändert (bitte besonders genau prüfen)

- **Rückgängig in einem Schritt:** Alle Alben und Ordner eines Plans werden in einer
  PhotoKit-Anfrage gelöscht; ein Ordner nur, wenn alles darin mitgeht
  (`ChangeExecutor.deleteBatch`, `PhotoKitLibrary.deleteCollections`, `UndoPlanner`).
- **Städte optional:** Standard sind Länder und Reisen; Städte per Schalter beim Einrichten und in
  den Einstellungen (`PlaceSettings.includesCities`).
- **Abgleich bei Ländern:** Ein Land wird nie mit einem kleineren, anders benannten Album
  („Rom · 2024“ in Italien) oder mit dem Album eines anderen aktuellen Vorschlags abgeglichen
  (`AlbumMatcher.isPart`, `claimedByOthers`). Passen mehrere Alben, wählt der Nutzer.
- **Keine heimliche Auswahl:** „Dein Startpaket“ und „Album anlegen“ wählen Vorschläge nur für die
  Vorschau aus. Wer zurückgeht, hat nichts ausgewählt (`selectForPreview` / `endPreview`).
- **Vorschau-Liste:** `ChangePlan.albumPreview` listet jedes Album mit Ordnerpfad und Anzahl, in
  derselben Reihenfolge wie die Vorschlagsliste (`inDisplayOrder`).
- **Änderungen in Fotos:** `LibraryChangeWatcher` startet nach Änderungen außerhalb der App eine
  Analyse (3 Sekunden Entprellung), dazu eine beim Start. Bitte auf Endlosschleifen (eigene
  Änderungen lösen neue Analyse aus), doppelte Läufe und Last bei großen Mediatheken prüfen.
- **Eingeschränkter Fotozugriff:** Hinweise in Übersicht und Tab „Alben“, „Auswahl ändern“ über
  `presentLimitedLibraryPicker`.
- **Fortschritt:** Fotos, für die kein Hauptbereich gilt, zählen weder als sortiert noch in der
  Gesamtzahl (`OrganizationStatusResolver.progress`).

## 7. Prüfauftrag in neun Teilen

Arbeite die Teile **der Reihe nach** ab. Lies für jeden Teil zuerst die genannten Dateien
vollständig. Die Fragen sind Mindestumfang, keine abschließende Liste.

### Teil 0: Überblick (kurz)
- Welche Dateien hast du gelesen? Fehlt etwas Wichtiges in der ZIP?
- Beschreibe in höchstens 12 Zeilen, wie Analyse, Vorschläge, Plan, Ausführung und Rückgängig
  zusammenspielen. (Daran sieht man, ob du den Code richtig verstanden hast.)

### Teil 1: Datensicherheit und Rückgängig (wichtigster Teil, Z1 bis Z5)
Dateien: `Execution/ChangeExecutor.swift`, `Planning/*`, `Status/ManagedAlbumTracker.swift`,
`App/Sortly/Platform/PhotoKitLibrary.swift`, Ausführungs- und Rückgängig-Teile in `AppModel.swift`,
`Sources/SortlyStore/*` (Journal), `Sources/SortlyTestSupport/InMemoryPhotoLibrary.swift`.
Spiele mindestens diese Szenarien durch:
1. Die App wird **mitten in der Ausführung** beendet (Absturz, iOS beendet sie, Akku leer). Wird
   beim nächsten Start sauber fortgesetzt? Entstehen doppelte Alben oder doppelte Einträge?
   Sind Schritte idempotent?
2. Ein **Schritt schlägt fehl** (PhotoKit-Fehler, Album inzwischen gelöscht, keine Rechte). Bleibt
   der Rest konsistent, und stimmt das Journal für ein späteres Rückgängig?
3. Der Nutzer **ändert Alben in Fotos**, während ein Plan offen ist oder läuft (Album gelöscht,
   umbenannt, Foto entfernt). Wird mit veraltetem Stand geschrieben?
4. **Rückgängig** nach Neustart, nach mehreren Ausführungen, nach Hand-Änderungen des Nutzers, wenn
   der Nutzer eigene Fotos in ein Albumist-Album gelegt hat, wenn ein Ordner fremde Alben enthält.
   Kann Rückgängig jemals ein Nutzer-Album oder einen Nutzer-Ordner löschen?
5. Kann irgendein Code-Weg ein **Nutzer-Album umbenennen, verschieben oder leeren**, ohne dass genau
   das in der Vorschau bestätigt wurde (zum Beispiel beim Zusammenführen)?
6. **Eingeschränkter Zugriff** („Ausgewählte Fotos“), **geteilte Alben**, **Smart-Alben**,
   **iCloud-Fotos, die nicht geladen sind**, **geteilte iCloud-Mediathek**, **zwei Geräte** mit
   derselben Mediathek (Sync-Konflikte, doppelt angelegte Alben).
7. **Z3:** Wird ein vom Nutzer entferntes Foto wirklich nie wieder hinzugefügt, und wird ein
   gelöschtes Album nie neu angelegt, auch nach „Analyse neu aufbauen“?
8. **Z5:** Gibt es einen Weg, auf dem eine Auswahl oder ein Plan ohne ausdrückliche Bestätigung
   ausgeführt wird (Siri/Kurzbefehle, Hintergrundarbeit, Wiederaufnahme nach Neustart)?

### Teil 2: Fachlogik
Dateien: `Trips/*`, `Geo/*`, `Places/*`, `Proposals/*`, `Matching/AlbumMatcher.swift`, `Naming/*`,
`Time/Chronology.swift`, `Status/OrganizationStatusResolver.swift`, `Search/Search.swift`,
`Rules/RuleEngine.swift`.
- Reisen: Zeitzonen, Sommerzeit, Datumsgrenze, Fotos ohne Ort innerhalb einer Reise,
  Zuhause-Erkennung bei Umzug, direkt aufeinanderfolgende Reisen, Tagesausflüge, Reisen über
  Jahreswechsel, Kamera mit falscher Uhrzeit.
- Orte: Grenznähe, Meer, Koordinate (0,0), umstrittene Gebiete, Länder ohne Städte,
  Geocoding-Fehler und Drosselung.
- Abgleich: Schwellen (Reinheit, Abdeckung, Namensähnlichkeit), Gleichstand zwischen Alben,
  leere Alben, sehr große Alben, Alben mit gleichem Namen in verschiedenen Ordnern.
- Namen und Formate: Datumsformate Deutsch/Englisch, Sonderzeichen, sehr lange Namen,
  doppelte Namen.
- Randfälle der Mediathek: leer, ein Foto, nur Screenshots, alles ohne Ort, alles an einem Tag,
  Fotos ohne Datum, Videos, Live Photos.
- Fortschritt und Status: Stimmen Zahlen in Übersicht, Vorschau und Ergebnis überein?

### Teil 3: Speicher und Persistenz
Dateien: `Sources/SortlyStore/*`, Speicherzugriffe in `AppModel.swift` und `AnalysisPipeline.swift`.
- Transaktionen, Migrationen von älteren Schemas, Verhalten bei beschädigter Datenbank oder vollem
  Speicher, gleichzeitiger Zugriff aus mehreren Tasks, Datenschutzklasse der Datei, was beim
  Neuinstallieren und bei iCloud-Backup passiert, Speicherwachstum über Monate.

### Teil 4: Swift 6 und Nebenläufigkeit
Dateien: `AppModel.swift`, `AnalysisPipeline.swift`, `Platform/*`, `SortlyApp.swift`.
- Datenrennen, falsche `Sendable`-Annahmen, `nonisolated(unsafe)`, `@unchecked Sendable`.
- Actor-Wiedereintritt: Zustand, der nach einem `await` veraltet ist.
- Tasks, die nie enden, nie abgebrochen werden oder doppelt laufen; Continuations, die nicht genau
  einmal fortgesetzt werden.
- PhotoKit-Callbacks (Change Observer, Bildanfragen) auf fremden Threads; `LibraryChangeWatcher`:
  Endlosschleife durch eigene Änderungen, Analyse während Ausführung.
- `BGProcessingTask`: Ablauf-Handler, sauberes Beenden, Zustand nach Abbruch.
- Arbeit auf dem Main Thread, die die Oberfläche spürbar blockiert.

### Teil 5: Leistung, Speicher, Akku (Z7, Z8)
Dateien: `PhotoKitLibrary.swift`, `VisionAnalyzer.swift`, `AnalysisPipeline.swift`,
`AlbumMatcher.swift`, `GeoClusterer.swift`, `TripDetector.swift`, `Views/*`, `AppModel.swift`.
Rechne mit 100.000 Fotos, davon 80 % nur in iCloud:
- Algorithmen mit quadratischem oder schlechterem Aufwand, wiederholte Berechnungen.
- Speicherspitzen (alle Assets im Speicher, große Sets, Bilder), Autorelease in Schleifen.
- PhotoKit: Abfragen in Schleifen, Laden von Originalen statt Vorschauen, Netzwerkzugriff bei
  Videos oder im Mobilfunknetz.
- Vision: Anfragen pro Bild, Wiederverwendung, Abbruch bei Wärme und Stromsparmodus.
- SwiftUI: teure Berechnungen in `body`, zu grobe Beobachtung des `@Observable`-Modells (eine
  Änderung zeichnet alles neu), große Listen ohne Lazy-Container.
- SQLite: Abfragen ohne Index, viele kleine Transaktionen.

### Teil 6: Datenschutz und App-Store-Prüfung
Dateien: `App/project.yml`, `PrivacyInfo.xcprivacy`, `Purchases.swift`, `UITestSupport.swift`,
`DemoLibrary.swift`, `SystemServices.swift`, `SmartAssistant.swift`, `App/Sortly/App/*`,
`docs/PRIVACY.md`.
- App Review Guidelines, besonders 2.1 (Vollständigkeit), 2.3 (genaue Angaben), 2.5.1 (nur
  öffentliche APIs), 2.5.4 (Hintergrundmodi begründet), 3.1.1 und 3.1.2 (In-App-Kauf,
  Wiederherstellen, keine Umgehung), 4.0 (Design), 5.1.1 und 5.1.2 (Datenerhebung, Zweckangaben).
- Privacy Manifest: Sind alle „Required Reason APIs“ deklariert (zum Beispiel `UserDefaults`,
  Dateizeitstempel, freier Speicher, Systemstartzeit)? Stimmt „Keine Daten erhoben“?
- Texte für Berechtigungen (Fotos, Mitteilungen) in beiden Sprachen: verständlich und ehrlich?
- Test- und Demo-Code: Sind `UITestSupport`, `Purchases.unlockedForUITests` und `DemoLibrary` in
  einem Release-Build sicher unerreichbar? Kann ein Nutzer die Bezahlschranke umgehen?
- StoreKit 2: Prüfung von Transaktionen, `Transaction.updates`, Rückerstattung, Familienfreigabe,
  „Kauf wiederherstellen“, Verhalten offline.
- Exportkonformität, Apple-Intelligence-Nutzung, Siri/App Intents (Beschreibungen, keine
  Aktionen ohne Bestätigung).

### Teil 7: Oberfläche, Bedienung, Barrierefreiheit
Dateien: `App/Sortly/Views/*`, `DesignSystem/*`, `Localizable.xcstrings`.
- Erster Start aus Sicht eines neuen Nutzers: Ist jeder Bildschirm ohne Erklärung verständlich?
  Ändert irgendein Knopf heimlich einen Zustand?
- Human Interface Guidelines: Navigation, Zurück-Verhalten, Bestätigungen vor destruktiven
  Aktionen, Leer- und Fehlerzustände, Ladezustände.
- VoiceOver: Beschriftungen, Traits, Reihenfolge, gruppierte Elemente, Ansagen bei
  Fortschritt.
- Dynamic Type bis zur größten Barrierefreiheitsstufe, abgeschnittene Texte, Dunkelmodus und
  Kontrast, „Bewegung reduzieren“ bei Animationen (`ScanShow`, `SortingShow`), iPad und Querformat.
- Übersetzungen: fehlende oder falsche Pluralformen, hart codierte Texte, Datums- und
  Zahlenformate.

### Teil 8: Tests, Build und Wartbarkeit
Dateien: `Tests/*`, `App/SortlyTests`, `App/SortlyUITests`, `.github/workflows/*`,
`.github/scripts/*`, `Package.swift`, `App/project.yml`.
- Welche Zusagen Z1 bis Z8 sind **nicht** durch Tests abgesichert? Schlage die wichtigsten
  fehlenden Tests konkret vor (Name, Aufbau, erwartetes Ergebnis).
- Unzuverlässige Tests (Zeitabhängigkeit, Zufall ohne festen Seed, Wartezeiten im UI-Test).
- Absturzgefahren im Produktivcode: `!`, `try!`, `fatalError`, `precondition`, Index-Zugriffe
  ohne Prüfung.
- CI: Umgang mit Secrets, Abhängigkeit von Runner-Images, Warnungen.

## 8. Schweregrade

| Schwere | Bedeutung |
|---|---|
| **Kritisch** | Bruch einer Zusage Z1 bis Z7, Datenverlust, Datenschutzverstoß, sichere Ablehnung im App Store, Absturz im Hauptweg. |
| **Hoch** | Falsches Ergebnis in häufigen Fällen, Absturz in Randfällen, wahrscheinliche Ablehnung, deutliche Leistungsprobleme bei großen Mediatheken (Z8). |
| **Mittel** | Seltene Fehler, verwirrende Bedienung, deutlich eingeschränkte Barrierefreiheit. |
| **Niedrig** | Kleine Ungenauigkeiten ohne spürbare Folgen. |

## 9. Antwortformat

Für jeden Teil:

```
### Teil N: Titel
Gelesene Dateien: …
Nicht gelesen oder nicht gefunden: …

**[N.1] Kurzer Titel**
Schwere: Kritisch | Hoch | Mittel | Niedrig   ·   Sicherheit: bestätigt | wahrscheinlich | Vermutung
Ort: `Pfad/Datei.swift:Zeile–Zeile`
Code:
  (Zitat, höchstens 10 Zeilen)
Szenario: 1. … 2. … → Ergebnis: …
Warum das falsch ist: …
Gegenprobe: Wo ich nach einer Absicherung gesucht habe und warum sie nicht greift.
Für Nutzer bedeutet das: (ein Satz in einfacher Sprache)
Behebung: (konkret, gern als Code-Skizze)
Absichernder Test: (Name und Idee)

Vermutungen ohne Beleg: (kurze Liste, je ein Satz)
```

Sortiere innerhalb eines Teils nach Schwere. Höchstens 15 Befunde pro Teil; lieber weniger und
dafür belegt. Wenn ein Teil keine echten Befunde hat, schreibe das ausdrücklich.

**Länge:** Wenn deine Antwort zu lang wird, höre nach einem **vollständigen** Teil auf und
schreibe als letzte Zeile: „Schreibe »Weiter mit Teil N«“.

**Nach Teil 8** folgt das Gesamtergebnis:

1. **Tabelle aller Befunde:** Nr. · Schwere · Sicherheit · Datei · Kurztitel
2. **Die 5 Dinge, die vor dem Start unbedingt behoben werden müssen**, mit Begründung
3. **Entscheidungen, die ich hinterfragen würde** (aus `DECISIONS.md` oder dem Code)
4. **Startreife als Ampel** (Rot / Gelb / Grün) mit drei Sätzen Begründung
5. **Offene Fragen an das Entwicklerteam** (was du aus dem Code nicht klären konntest)

Beginne jetzt mit Teil 0.

---
