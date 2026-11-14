# Datenschutz

## Datenverarbeitung
Alle Analysen laufen auf dem Gerät. Albumist lädt keine Fotos hoch, hat keinen Server, kein
Konto, keine Werbung, kein Tracking und keine Analyse-SDKs.

## Speicherorte
Eine SQLite-Datenbank in *Application Support/Albumist* mit Metadaten, Analyseergebnissen,
erkanntem Text (nur für die Suche) und Entscheidungen. Der ganze Ordner ist vom iCloud-Backup
ausgeschlossen und mit iOS-Dateischutz verschlüsselt (`completeUntilFirstUserAuthentication`:
nach einem Neustart unlesbar, bis das iPhone einmal entsperrt wurde; stärker geht nicht, weil
die Analyse auch nachts bei gesperrtem Gerät läuft).

Eine kleine Kopie nur der Entscheidungen liegt in *Application Support/Albumist Backup*
(`decisions.json`, gleicher Dateischutz) und ist Teil des Geräte-Backups: Ausnahmen, Regeln,
Einstellungen, eigene Namen, Reise-Kennungen, die von Albumist angelegten Alben und der Verlauf
(Album- und Foto-Kennungen, Albumtitel). Kein erkannter Text, keine Analyseergebnisse (Orte,
Koordinaten, Bildinhalte), keine Bilder. Sie verlässt das Gerät nur mit dem Backup des Nutzers.
Es werden **keine Bildkopien** gespeichert. Wenige Einstellungen liegen in `UserDefaults`
(Onboarding erledigt, Zahl der Gratis-Alben, Zeitpunkt des letzten Scans).
Für Spotlight und Siri legt Albumist im lokalen Spotlight-Index des iPhones nur Ländernamen mit
Fotoanzahl und die Titel offener Vorschläge ab (kein erkannter Text, keine Bilder, keine
Koordinaten). Der Index wird nach jeder Analyse ersetzt und ist nach „Analyse zurücksetzen“ leer.

### Datensparsamkeit beim erkannten Text
Die Analyse liest den vollen Text, gespeichert wird nur eine verkleinerte Fassung
(`TextMinimizer`):
- Ausweise, Pässe, Führerscheine und medizinische Dokumente: **kein Text** wird gespeichert,
  nur die Einordnung („Dokument, sensibel“). Sie sind deshalb nicht per Volltext suchbar.
- IBANs und gültige Kartennummern (Luhn-Prüfung) werden in allen anderen Texten maskiert.
- „Analyse neu aufbauen“ löscht den gesamten Suchindex.

## Berechtigungen
- Fotos (voll oder ausgewählte Fotos). Ohne Zugriff funktioniert die App nicht.
- Keine Standortberechtigung: Orte stammen aus den GPS-Daten der Fotos.
- Hintergrundverarbeitung (nachts beim Laden) und Fortsetzen der Analyse im Hintergrund mit
  Fortschritt auf dem Sperrbildschirm (`BGContinuedProcessingTask`, vom Nutzer gestartet).
- Mitteilungen (optional, nach dem Onboarding gefragt): nur „Analyse fertig“ mit der Zahl der
  Vorschläge, ohne Fotos, Orte oder Albumnamen auf dem Sperrbildschirm.

## Externe Dienste
- **Apple-Geocoder** (`CLGeocoder`): Für Stadtnamen werden einzelne Koordinaten (eine pro
  Rasterzelle, keine Fotos) an Apple gesendet. Abschaltbar; dann nur Offline-Karte.
- **iCloud-Fotos:** Originale von Screenshots/Dokumenten werden nur mit Zustimmung über
  Apples Fotosystem geladen.
- **App Store (StoreKit):** einmaliger Kauf, abgewickelt von Apple.

## Datenschutzentscheidungen
Gesichtsgruppen sind besondere personenbezogene Daten (DSGVO Art. 9) und werden nur nach
ausdrücklichem Einschalten verarbeitet (noch nicht verfügbar). Ausgeblendete Fotos sind
standardmäßig ausgeschlossen. Sensible Dokumente werden nicht automatisch vorgeschlagen.
Datenschutz-Manifest: `App/Sortly/Resources/PrivacyInfo.xcprivacy` (keine erhobenen Daten).

## Teilen
Das Reise-Atlas-Bild wird auf dem Gerät gerendert und über das iOS-Teilen-Menü weitergegeben.
Es enthält Länder, Zahlen und optional ein Foto vom Lieblingsziel (vor dem Teilen sichtbar und
abschaltbar). Das gerenderte Bild hat keine EXIF- oder GPS-Daten.

## Sicherheitsprüfung (14.11.2026)
| Bereich | Ergebnis |
|---|---|
| Netzwerk | Kein eigener Netzwerkcode (`URLSession` o. ä. kommt nicht vor). Nur Apple-Dienste: Geocoder (abschaltbar), iCloud-Fotos (Zustimmung), StoreKit. |
| Speicherung | Datenbank verschlüsselt (Dateischutz), nicht im Backup, keine Bildkopien, sensible Texte nicht gespeichert, Kontonummern maskiert. Nur die Entscheidungen liegen als kleine Kopie im Geräte-Backup. |
| SQL | Nur gebundene Parameter, keine zusammengesetzten SQL-Texte aus Nutzereingaben. |
| Käufe | Nur von Apple signierte Transaktionen (`.verified`) schalten frei; Test-Freischaltung existiert nur in Debug-Builds. |
| Fotos | Geschlossene Operationsmenge: Alben/Ordner anlegen, ergänzen, umbenennen, verschieben; Mitgliedschaften entfernen. Es gibt keinen Code, der Medien löscht oder verändert. |
| Protokolle | Keine Logausgaben mit Fotodaten oder Texten. |
| Demo-Mediathek | Nur im Simulator enthalten (`#if targetEnvironment(simulator)`), nie in App-Store-Builds. |
| Datenschutz-Manifest | Keine erhobenen Daten, kein Tracking; begründete API-Nutzung: UserDefaults (CA92.1), Dateizeitstempel (C617.1, SQLite). |
