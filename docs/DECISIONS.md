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
| Navigation nur mit Ziel-Links (`NavigationLink { Ziel } label:`) | Wert-Links in per Ziel-Link geöffneten Bildschirmen führten ins Leere (tote Zeilen, gelbes Warndreieck) | `NavigationLink(value:)` + `navigationDestination` | CI bricht bei `NavigationLink(value:` und bei SwiftUI-Navigationswarnungen ab |
| Von Albumist angelegte Alben werden gemerkt (welche Fotos Albumist hinzugefügt hat) | sicheres Entfernen, manuelles Löschen/Umbenennen in Fotos wird respektiert | nichts merken | gelöschte Alben werden nicht erneut vorgeschlagen |
| Wiederanlauf übernimmt nur ein einzelnes leeres gleichnamiges Album, als „übernommen“ markiert (Gegenprüfung 1.1) | Absturz direkt nach dem Anlegen soll kein doppeltes Album erzeugen; ein fremdes Album mit Fotos wird nie übernommen | nie übernehmen (Prüftest), jedes gleichnamige übernehmen | übernommenes Album wird von Rückgängig nicht gelöscht; zwei Kandidaten oder gefülltes Album: Schritt scheitert mit Hinweis |
| Ausführungsjournal mit echten Änderungen je Schritt (Gegenprüfung 1.3) | Rückgängig und Verwaltung dürfen nur nehmen, was Albumist wirklich getan hat | geplante Änderungen verwenden | Absicht wird vor jeder Änderung gespeichert, Ergebnis danach |
| Dateidetails (Typ, RAW, Name) nur für Fotos lesen, die der Store noch nicht kennt oder die sich geändert haben (Gegenprüfung 2.3) | schnell bei 100.000 Fotos und trotzdem richtig nach Neuaufbau der Datenbank | Zeitstempel in den Einstellungen | Zeitstempel `photokit.lastResourceScan` entfällt |
| Nicht lesbare Fotos und Text aus der Vorschau: bis zu 3 Versuche in späteren Läufen, Text im Abstand von einer Stunde (Gegenprüfung 5.1, 2.4) | iCloud-Fotos kommen oft später; endlose Wiederholungen kosten Akku | sofort aufgeben, immer wiederholen | Text aus der Vorschau wird nur mit erlaubtem Netz nachgelesen |
| Mediathek und Suche blättern (3.000 bzw. 2.000 je Seite) statt alles auf einmal (Gegenprüfung 5.5, 7.1) | flüssig bei großen Mediatheken, jedes Foto erreichbar | feste Obergrenze, alles auf einmal | „Als Album anlegen“ nimmt immer alle Treffer |
| Änderungsbeleg zählt nur nachgeprüfte Schritte (I01); Rückgängig sitzt im Beleg statt in der Verlaufszeile | eine Zahl, die die Mediathek nicht bestätigt hat, wäre eine Behauptung; vor dem Rückgängigmachen sieht man, was zurückgenommen wird | geplante Zahlen zeigen, Rückgängig-Knopf in der Zeile | unbestätigte Schritte stehen getrennt unter „Nicht erledigt“; Originale-Zeilen sind per Bauart 0 (es gibt keine Operation dafür) |
| Entscheidungen als eigene kleine Datei im Geräte-Backup, Datenbank bleibt draußen (I12) | Analyse ist rekonstruierbar, Entscheidungen nicht; Datenbank mit erkanntem Text soll nicht ins Backup | ganze Datenbank ins Backup, keine Sicherung | Zeilen werden roh kopiert (unabhängig von Modelländerungen); Wiederherstellen nur in eine Datenbank ohne Entscheidungen; Alben und Verlauf nur, wenn mindestens die Hälfte der verwalteten Alben in der Mediathek existiert; solange das ohne Fotozugriff offen ist, wird die Datei nicht überschrieben |
