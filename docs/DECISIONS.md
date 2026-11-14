# Entscheidungen

| Entscheidung | Begründung | Geprüfte Alternativen | Auswirkungen |
|---|---|---|---|
| Logik als Swift-Paket, plattformunabhängig | auf Linux testbar, kein Mac nötig | alles im App-Target | Plattformzugriff hinter Protokollen |
| SQLite direkt statt SwiftData/Core Data | Kontrolle über Migrationen, Massendaten, Linux-Tests | SwiftData, GRDB | eigener kleiner Wrapper |
| Offline-Weltkarte (Natural Earth) | schnelle, private Länder-/Regionsbestimmung ohne Netz | nur `CLGeocoder` | +4,8 MB App-Größe |
| Geocoder nur pro Rasterzelle, gedrosselt | Apples Limits, Datenschutz | pro Foto | Stadtnamen erscheinen schrittweise |
| Analyse auf lokalen Vorschauen | kein iCloud-Download nötig | immer Originale | Klassifikation etwas gröber |
| Originale nur für Screenshots/Dokumente, WLAN, Zustimmung | Datenvolumen, Speicher | gar nicht / immer | Texte aus iCloud-Dokumenten kommen später |
| Pläne als geschlossene Operationsmenge ohne Löschen von Medien | Sicherheitsversprechen | freie Operationen | Zusammenführen löscht keine Alben |
| Fingerabdruck-Prüfung vor Ausführung | keine Überschreibung von Nutzeränderungen | blind ausführen | Plan muss ggf. neu erstellt werden |
| Gesichter nur Opt-in, später | DSGVO Art. 9 | Standard an | Bereich in v1 ausgeblendet |
| Design „Klar“, SF Pro | iOS-nah, ruhig, Barrierefreiheit | „Warm“, „Kontrast“ | — |
| Einmalkauf, 10 Alben gratis | fair, kein Abo | Abo, Werbung | `Purchases.freeAlbumLimit` |
| XcodeGen statt eingechecktem Projekt | lesbare Projektdatei, keine Konflikte | .xcodeproj | Build braucht `xcodegen generate` |
| Standardbereiche ohne Jahre/Monate, Medientypen, Messenger | vermeidet Album-Flut; Fotos-App zeigt Datum und Medientypen schon | alles an | Nutzer schaltet diese Bereiche bei Bedarf ein |
| Reise-Atlas im Apple-Stil (Systemfarben, Karten wie in Fotos) | einheitlich mit der App, Featuring | dunkler Neon-Look | Teilen-Bild hell, mit echtem Foto vom Lieblingsziel, vor dem Teilen abschaltbar |
