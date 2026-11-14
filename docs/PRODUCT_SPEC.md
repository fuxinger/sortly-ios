# Produktspezifikation

## Ziel
Eine große, gewachsene Fotomediathek ohne manuelle Arbeit in eine verständliche Album- und
Ordnerstruktur bringen – privat, nachvollziehbar und umkehrbar.

## Nutzerabläufe
1. **Erster Start:** Versprechen (lokal, keine Originale verändert, alles prüfbar, vorhandene
   Alben werden erkannt) → Bereiche wählen → Fotozugriff (voll / begrenzt / abgelehnt mit
   Weg in die Einstellungen) → optionaler **Probelauf** auf ein Jahr → Analyse startet.
2. **Analyse:** läuft im Vordergrund in Etappen (Inventar, Reisen, Orte, Inhalte, Text,
   Gruppen, Vorschläge), pausiert bei Wärme, Stromsparmodus oder niedrigem Akku und setzt
   genau dort fort. Nachts beim Laden verfeinert ein Hintergrundlauf Orte und Texte.
3. **Vorschläge prüfen:** Liste je Bereich; Detail mit Vorschaubildern, Begründung,
   Zuverlässigkeit und Abgleich mit vorhandenen Alben. Aktionen: übernehmen (je nach Lage
   „Album anlegen“, „X Fotos ergänzen“, „Album so lassen“), anpassen (Name, anderes
   Album) oder „Nicht jetzt“. „Alle sicheren übernehmen“ nimmt nur wahrscheinliche,
   nicht sensible Vorschläge ohne Namenspflicht.
4. **Umsetzen:** Zusammenfassung (neue Ordner/Alben, ergänzte Alben, betroffene Fotos,
   Zuordnungen), Garantie „0 Originale gelöscht, 0 Kopien“, Konflikte. Ausführung mit
   Fortschritt, danach Ergebnis und **Rückgängig**.
5. **Mediathek:** Fotos nach Status (nicht sortiert, Vorschläge, unsicher, sortiert,
   ignoriert, alle); Fotos können ignoriert werden.
6. **Alben:** vorhandene Ordner und Alben; Hinweis auf sehr ähnliche Alben mit Plan zum
   Zusammenführen (das größte Album wird ergänzt, keine Alben werden gelöscht).
7. **Suche:** natürliche Eingabe („Strand 2024“, „Rechnungen“, „Italien“) inkl. Text auf
   Screenshots.
8. **Einstellungen:** Bereiche, Hauptbereiche, Sprache der Albumnamen, Hauptordner,
   Datenschutz (ausgeblendete Fotos, Online-Ortsbestimmung, iCloud-Downloads, Mobilfunk),
   Verlauf mit Rückgängig, Analyse neu aufbauen, Vollversion.

## Funktionsumfang (Version 1)
Länder und Orte, Reisen, häufige Orte (vom Nutzer benannt), Jahre und Monate, Medientypen,
Screenshots nach Inhalt, Themen (Bildklassifikation), Dokumente (Text und Barcodes),
Messenger-Herkunft nur mit klaren Hinweisen, Abgleich mit vorhandenen Alben, Regeln und
Nutzerentscheidungen, Suche, Kurzbefehl „Neue Fotos sortieren“, teilbarer Reise-Atlas,
optional Apple Intelligence (Suche in Sätzen, Namensvorschläge für Reisen), einmalige Freischaltung
(die ersten 10 Alben kostenlos).

## Nicht-Ziele
Foto-Cleaner, Duplikate löschen, Rückblicke/Memories, Fotobücher, Cloud-Upload,
Bearbeiten von Originalen. Personen- und Haustiergruppen folgen in einer späteren Version
(Opt-in, siehe ROADMAP).

## Abnahmekriterien
- Keine Operation kann Originale löschen, verändern oder kopieren (geschlossene
  Operationsmenge in `PlannedOperation`, Test `PlanningExecutionTests`).
- Ohne Bestätigung ändert Albumist nichts an der Mediathek.
- Jeder ausgeführte Plan ist rückgängig machbar, soweit der Nutzer die Alben seitdem
  nicht selbst geändert hat (dann wird nichts überschrieben).
- Vorhandene passende Alben werden ergänzt statt dupliziert (Szenarien in `MatchingTests`).
- Analyse ist unterbrechbar und fortsetzbar (`PipelineTests`).
- Keine Daten verlassen das Gerät außer Koordinaten für die optionale Ortsbestimmung.
