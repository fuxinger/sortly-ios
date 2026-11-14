# Changelog

## 0.1.0 (in Entwicklung)
### Hinzugefügt
- Kernlogik: Reisen, häufige Orte, Orte (Offline-Karte + gedrosselter Geocoder), Chronologie,
  Medientypen, Screenshots, Themen, Dokumente, Messenger-Hinweise, Regeln, Suche, Status.
- Abgleich mit vorhandenen Alben und Erkennung ähnlicher Alben.
- Änderungspläne mit Vorschau, sicherer Ausführung, Wiederanlauf und Rückgängig.
- SQLite-Store mit Migrationen v1–v2.
- Fortsetzbare Analyse-Pipeline mit Probelauf und nächtlicher Verfeinerung.
- iOS-App: Einführung, Übersicht, Vorschläge, Umsetzen, Mediathek, Alben, Suche,
  Einstellungen, Verlauf; Einmalkauf; Kurzbefehl; Datenschutz-Manifest.
- Teilbarer „Reise-Atlas“ im Apple-Stil: Weltkarte der besuchten Länder, Kennzahlen,
  Teilen-Bild mit Vorschau und optionalem Foto vom Lieblingsziel.
- Foto-Geschichte mit Apple Intelligence (Reisen, Jahre, ganze Mediathek), in der App-Sprache.
- Englische Übersetzung (App, Info.plist, Kurzbefehle).
- Optional mit Apple Intelligence: Suche in ganzen Sätzen, Namensvorschläge für Reisen.
- CI: Tests auf Linux und macOS, App-Build im Simulator, Simulator-ZIP und automatischer Upload zu Appetize (mit Secret `APPETIZE_TOKEN`).
- Atlas: Land antippen zeigt seine Fotos, nach Jahren, mit den meistfotografierten Orten und
  dem passenden Albumvorschlag.
- „Album passt nicht“: ein vorgeschlagenes vorhandenes Album lässt sich ausschließen; unter
  „Anpassen“ ist jedes bearbeitbare Album wählbar.
- Siri, Kurzbefehle und Spotlight: „Fotos aus Italien in Albumist“, „Offene Vorschläge“,
  Vorschlag öffnen; Spotlight findet Länder und offene Vorschläge.
- iOS-26-Glasknöpfe (`glassProminent`/`glass`), Vibration beim Fertigwerden und bei Fehlern.
- Logiktest des ganzen Entscheidungs-Ablaufs (übernehmen, umsetzen, rückgängig, löschen,
  ablehnen, 40 zufällige Abläufe mit Invarianten).
- Anleitung und Skript für eine unabhängige Code-Prüfung (`docs/review/`, `tools/make_review_zip.sh`).
- Sicherung der Entscheidungen (I12): Regeln, Ausnahmen, Einstellungen, eigene Namen, die Alben
  von Albumist und der Verlauf liegen zusätzlich als kleine Datei im Geräte-Backup. Nach einem
  Neuaufbau der Datenbank oder auf einem neuen iPhone kommen sie zurück; Alben und Verlauf nur,
  wenn die Sicherung zur Mediathek passt. Hinweiskarte in der Übersicht, Stand unter „Verlauf“.
  „Neu aufbauen“ nach einem Startfehler startet die Analyse jetzt sofort.
- Änderungsbeleg (I01): jede Zeile im Verlauf und das Ergebnis nach dem Umsetzen öffnen eine
  Seite mit dem, was Albumist wirklich geändert hat (nur nachgeprüfte Schritte), jedem Album,
  „0 Originale gelöscht, bearbeitet, kopiert“, nicht Erledigtem und dem Rückgängigmachen.
  Als Text teilbar. Englisch „Verschoben“ heißt jetzt „Moved“ (war „Postponed“).
- Geführte Reparatur (I16): ein unterbrochenes Umsetzen bietet „Fortsetzen“, „Rückgängig machen“
  und „So lassen“; Fehler stehen im Änderungsbeleg in Klartext, mit „Fehlendes erneut versuchen“
  (legt nur an, was fehlt). „Diagnose teilen“ in den Einstellungen und im Beleg: Zustände, Zahlen
  und Fehlercodes, keine Fotos, Namen oder Orte.
### Korrigiert
- Gegenprüfung 14.11.2026 (43 Befunde, `docs/review/AUDIT_2026-11-14.md`): Ausführungsjournal
  mit echten Änderungen, sicherer Wiederanlauf und Rückgängig, geschützte Löschungen, eine
  Ausführung zur Zeit, Abschluss in einer Transaktion, Reisen behalten ihre Identität, alte
  Orte und Texte nach Änderungen verworfen, iCloud-Fotos später erneut gelesen, WLAN je Foto
  geprüft, schnellerer Abgleich und Ortsgruppen, Mediathek und Suche ohne Obergrenze,
  Lasttest mit 100 000 Fotos.
- Reise-Erkennung: Wer zu Hause wenig fotografiert, bekam nur eine Reise; das Zuhause
  braucht jetzt Fotos über mindestens drei Wochen verteilt.
- Umgesetzte Vorschläge kamen als „mehrere passende Alben“ zurück, wenn zwei Alben dieselben
  Fotos hatten, oder wenn zwei Vorschläge in ein Album gingen. Beides bleibt jetzt erledigt.
- Die Wahl unter „Anpassen“ wurde beim Übernehmen durch die Empfehlung ersetzt.
- Deutsche Einzahl („1 Reise“ statt „1 Reisen“) über Pluralformen im Katalog.
- Bereichsfarben haben im Dunkelmodus hellere Varianten (Kontrast).
- Kleine Vorschaubilder von Screenshots und Dokumenten wirkten abgeschnitten; Hochformat-Raster.
- Datumswerte verlieren beim Speichern keine Millisekunden mehr.
- Bilderkennungs-Begriffe an die tatsächliche Vision-Liste angepasst.
- Namenskonflikt `Observation` mit Apples Observation-Framework behoben.
### Migrationen
- v2: Spalte `asset_places.precision_m`.
