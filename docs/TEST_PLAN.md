# Testplan

## Strategie
- **Kernlogik** (`SortlyCore`, `SortlyStore`, `SortlyEngine`): Swift-Testing-Suites, laufen
  bei jedem Push auf Linux und macOS. Plattformzugriffe sind durch Fakes ersetzt
  (`SortlyTestSupport`: In-Memory-Mediathek, Fake-Geocoder, Fake-Analyse, steuerbare Zeit).
- **App** (`App/SortlyTests`): Abbildung von PhotoKit-Typen, Prüfung der Bilderkennungs-
  Begriffe gegen Vision, Texte. Läuft im iOS-26-Simulator auf GitHub Actions (macos-26).
- **Kein Test auf echten Geräten** bisher: Es steht weder ein Mac noch ein iPhone mit
  Entwicklerzugang zur Verfügung. Das wird in TestFlight nachgeholt.

## Abnahmeszenarien (automatisiert)
| Szenario | Test |
|---|---|
| Reise mit Datumsbereich, Rückkehr, Tagesausflug | `TripTests` |
| Wiederkehrende Orte, Umzug | `GeoTests`, `TripTests` |
| Vorhandenes Album vollständig / ergänzbar / größere Sammlung / Namenskonflikt | `MatchingTests` |
| Plan ohne zerstörende Operationen, Wiederanlauf, Rückgängig | `PlanningExecutionTests` |
| Vom Nutzer entfernte Fotos werden nicht erneut hinzugefügt | `PlanningExecutionTests` |
| Analyse pausiert und setzt fort, inkrementell, Probelauf | `PipelineTests` |
| Offline-Karte: Grenzregionen, Inseln, Meer | `OfflineWorldMapTests` |
| Drosselung, Backoff, Cache, Verfeinerung der Ortsbestimmung | `PlaceResolutionTests` |
| Suche, Statusberechnung, Empfehlungen | `ProposalAndSearchTests`, `StatusAndDecisionTests` |
| Migrationen, Massendaten | `StoreTests` |

## Testdaten
Synthetische Bibliotheken (Koordinaten, Zeitstempel, Alben) in `Fixtures.swift`.
Echte Testbilder nur mit freier Lizenz (CC0/gemeinfrei) und Lizenzliste.

## Gemessene Ergebnisse (Stand 2026-11-13)
- 143 Kern-Tests grün (Linux, Swift 6.2.3; macOS, Xcode 26).
- App-Build und App-Tests grün im iOS-26-Simulator.
- 20 000 Fotos in die Datenbank schreiben: 0,33 s (Linux-Container).
- 500 Offline-Kartenabfragen: ca. 0,6 s.
- Vision kennt im Simulator 1303 Begriffe; alle Begriffe der Taxonomie sind darin enthalten.

## Offen
Messung der Analysezeit auf echten Geräten mit 15 000+ Fotos, Speicherverbrauch,
Wärmeverhalten, iCloud-Downloads, VoiceOver-Durchgang.
