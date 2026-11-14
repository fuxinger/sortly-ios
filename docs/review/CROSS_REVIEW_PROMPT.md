# Master-Prompt für eine unabhängige Code-Prüfung (ChatGPT, Gemini o. ä.)

So benutzt du ihn: Lade die ZIP-Datei mit dem Code hoch und kopiere alles ab der Linie
unten als erste Nachricht in den Chat. Wenn die KI nur einen Teil schafft, schreibe danach
„Weiter mit Schritt 2“ usw.

---

Du bist ein erfahrener iOS-Entwickler (Swift 6, SwiftUI, PhotoKit, Vision, App Store Review)
und prüfst den beigefügten Code einer fertigen iOS-App, bevor sie in den App Store geht.
Antworte auf Deutsch, in einfacher Sprache, damit auch ein Nicht-Programmierer die
Ergebnisse versteht. Code-Beispiele für Korrekturen dürfen auf Englisch sein.

## Die App

**Albumist** (Arbeitsname) sortiert die Fotos-Mediathek eines iPhones in Alben, vollständig auf
dem Gerät. Sie erkennt Reisen, Länder und Orte, Screenshots, Dokumente und Messenger-Bilder,
schlägt dafür Alben vor, vergleicht mit vorhandenen Alben und legt Alben erst nach Vorschau
und Bestätigung an. Dazu gibt es einen Reise-Atlas (Weltkarte mit besuchten Ländern),
Suche, Siri/Kurzbefehle und Spotlight.

Feste Versprechen an die Nutzer, die der Code nie brechen darf:
1. Es werden **nie Fotos gelöscht oder verändert**. Albumist legt nur Alben/Ordner an und fügt
   Fotos zu Alben hinzu; jede Änderung lässt sich rückgängig machen.
2. Alles passiert **auf dem Gerät**. Keine Server, kein Tracking, keine Analyse-SDKs.
3. Alben, die der Nutzer selbst angelegt hat, werden nie umbenannt oder geleert. Was der
   Nutzer in Fotos von Hand ändert (Foto aus Album genommen, Album gelöscht), wird respektiert.
4. Große Mediatheken (100.000+ Fotos, viel in iCloud) müssen funktionieren, ohne das Gerät
   zu überhitzen oder Datenvolumen zu verbrauchen.

Rahmen: aktuelles iOS 27 mit Xcode 27 (Mindestversion iOS 26), Swift 6 mit strikter Nebenläufigkeitsprüfung,
keine Fremdbibliotheken. Die Fachlogik liegt in einem Swift-Paket und läuft auch auf Linux.
Es gibt 180+ automatische Tests (Swift Testing) und einen UI-Test im Simulator.

## Aufbau des Codes

| Ordner | Inhalt |
|---|---|
| `Sources/SortlyCore` | reine Logik: Reisen (`Trips`), Orte und Atlas (`Places`), Vorschläge (`Proposals`), Album-Abgleich (`Matching`), Plan (`Planning`), Ausführung und Rückgängig (`Execution`), Status, Suche, Benennung |
| `Sources/SortlyStore` | SQLite-Speicher mit Migrationen |
| `Sources/SortlyEngine` | fortsetzbare Analyse-Pipeline (`AnalysisPipeline`, actor) |
| `Sources/SortlyWorldMap` | Offline-Weltkarte für Länder (Daten in der ZIP weggelassen) |
| `App/Sortly` | iOS-App: `Model/AppModel.swift` (Zustand), `Views/`, `Platform/` (PhotoKit, Vision, StoreKit, Hintergrundarbeit), `App/` (Einstieg, Siri, Spotlight) |
| `Tests/`, `App/SortlyTests`, `App/SortlyUITests` | Tests |
| `docs/` | Architektur, Entscheidungen (`DECISIONS.md`), bekannte Grenzen (`KNOWN_LIMITATIONS.md`), Testplan |

Lies zuerst `docs/ARCHITECTURE.md`, `docs/DECISIONS.md` und `docs/KNOWN_LIMITATIONS.md`.
Was dort als bewusste Entscheidung oder bekannte Grenze steht, ist kein Fehler.

## Prüfauftrag, in dieser Reihenfolge

**Schritt 1: Datensicherheit (wichtigster Teil).**
Kann irgendein Weg im Code die Versprechen 1 bis 3 brechen? Prüfe besonders
`Execution/ChangeExecutor.swift`, `Planning/`, `Status/ManagedAlbumTracker.swift`,
`App/Sortly/Platform/PhotoKitLibrary.swift` und das Rückgängigmachen. Denk an:
App wird mitten in der Ausführung beendet, Nutzer ändert Alben in Fotos währenddessen,
eingeschränkter Fotozugriff („ausgewählte Fotos“), geteilte Alben, iCloud-Fotos, die noch
nicht geladen sind, zwei Geräte mit derselben iCloud-Mediathek.

**Schritt 2: Logikfehler.**
Reiseerkennung (`Trips/TripDetector.swift`), Abgleich mit vorhandenen Alben
(`Matching/AlbumMatcher.swift`), Vorschläge (`Proposals/ProposalEngine.swift`),
Zeitzonen und Datumsgrenzen, leere oder riesige Mediatheken, Fotos ohne Datum oder Ort.

**Schritt 3: Swift 6 und Nebenläufigkeit.**
Datenrennen, Actor-Wiedereintritt (Zustand nach einem `await` veraltet), Aufgaben, die nie
enden oder nie abgebrochen werden, Arbeit auf dem Main Thread, die die Oberfläche blockiert.

**Schritt 4: Leistung bei 100.000 Fotos.**
Speicherverbrauch, wiederholte Berechnungen in SwiftUI-Views, SQLite-Abfragen ohne Index,
PhotoKit-Abfragen in Schleifen, Vision-Analyse und Wärme/Akku.

**Schritt 5: App-Store-Prüfung und Datenschutz.**
Risiken für eine Ablehnung (App Review Guidelines, besonders 2.1, 2.3, 2.5, 3.1, 5.1),
`PrivacyInfo.xcprivacy`, Texte für Berechtigungen, StoreKit-2-Kauf und Wiederherstellen.

**Schritt 6: Oberfläche und Barrierefreiheit.**
Apple Human Interface Guidelines, VoiceOver-Beschriftungen, Dynamic Type bis zur größten
Stufe, Kontrast im Dunkelmodus, iPad-Darstellung.

## Wie du antwortest

- Nur echte Probleme, keine Stilfragen und keine Umbauten der ganzen Architektur.
- Für jedes Problem: **Schwere** (kritisch / hoch / mittel / niedrig), **Datei und Zeile**,
  **konkretes Szenario** („Wenn der Nutzer A tut und dann B passiert, dann …“),
  **Vorschlag zur Behebung** (kurz, gern mit Code).
- Kennzeichne, ob du dir **sicher** bist oder es nur **vermutest**. Wenn du eine Datei nicht
  gelesen hast, sag das, statt zu raten.
- Sortiere nach Schwere, das Wichtigste zuerst. Höchstens 25 Punkte pro Schritt.
- Zum Schluss: eine kurze Gesamteinschätzung in drei Sätzen und die drei Dinge, die du
  vor dem Start unbedingt beheben würdest.
