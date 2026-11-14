# Ideenliste und Verbesserungen

Lebende Liste. Nach jeder Runde (Expertenprüfung, Nutzertest, Testläufe, Gegenprüfung durch
andere KIs) kommen neue Punkte dazu. Status: ✅ erledigt · 🔜 als Nächstes · 💡 später/Update.
Aufwand: S klein, M mittel, L groß.

Quellen: **E1** Expertenrunde 14.11.2026 (Tempo, Oberfläche, Technik, Produkt) · **U** Nutzer
(Fuchs) · **T** Testläufe.

## Datensicherheit und Zuverlässigkeit

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Rückgängig löscht nie einen Ordner, in dem noch Alben liegen (Fotos würde sie mitlöschen). Ausführung und PhotoKit verweigern das Löschen nicht leerer Ordner. | S | E1 Technik |
| 🔜 | Abgebrochenes Umsetzen (App beendet) beim nächsten Start fortsetzen oder rückgängig machen; Verlauf zeigt auch halbe Pläne; bereits angelegte Alben werden gemerkt. | M | E1 Technik |
| 🔜 | Umsetzen während einer laufenden Analyse: Albenliste vor dem Abgleich neu lesen, damit kein doppeltes Album entsteht. | M | E1 Technik |
| 🔜 | „Ausgewählte Fotos“-Zugriff: vor dem Umsetzen klarer Hinweis „Voller Zugriff nötig“ mit Link zu Einstellungen statt Fehlermeldung. | S | E1 Technik |
| 🔜 | Bereits rückgängig gemachte Pläne nicht nochmal rückgängig machen; Rückgängig-Läufe nicht als eigene Einträge zeigen. | S | E1 Technik |
| 💡 | Fehlender Elternordner (zweites Gerät hat ihn gelöscht): nie oben auf der Mediathek-Ebene anlegen, sondern abbrechen. | S | E1 Technik |
| 💡 | Fotos nur in iCloud: nicht als „erledigt“ markieren, später erneut versuchen. | M | E1 Technik |
| 💡 | Ausgeblendete Fotos in Alben mitzählen, damit Rückgängig nichts Fremdes löscht. | S | E1 Technik |
| 💡 | Beschädigte Datenbank: „Neu aufbauen“-Knopf statt Sackgasse. | S | E1 Technik |
| 💡 | StoreKit: nicht geprüfte Käufe sauber abschließen und Fehlermeldung zeigen. | S | E1 Technik |

## Tempo bei großen Mediatheken

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| 🔜 | Ortsnamen beim ersten Durchgang begrenzt nachschlagen, Rest nachts; Pause wirkt sofort; Orte ohne Ergebnis merken. Erste Vorschläge bis zu einer Stunde früher. | S | E1 Tempo |
| 🔜 | „Nächste 50 Fotos“-Abfrage mit Lesezeichen statt Suche von vorn (17,7 s → 0,3 s bei 100.000 Fotos). | S | E1 Tempo |
| 🔜 | Beim Umsetzen nur das betroffene Album prüfen, nicht jedes Mal die ganze Albenliste (große Pläne: Minuten statt Viertelstunden). | M | E1 Tempo/Technik |
| 💡 | Nach Analyse und Start nichts doppelt von der Platte lesen; Oberfläche sofort zeigen, Rest im Hintergrund. | M | E1 Tempo |
| 💡 | Nur geänderte Fotos neu einlesen (PhotoKit-Änderungsverlauf). | M–L | E1 Tempo |
| 💡 | Bildanalyse in Paketen, Vorschaubilder vorladen, in einer Datenbank-Transaktion schreiben. | M | E1 Tempo |
| 💡 | Analyse mit niedriger Priorität, bei warmem Gerät früher bremsen. | S | E1 Tempo |
| 💡 | Texterkennung bei Screenshots erst schnell, nur bei Bedarf genau. | M | E1 Tempo |
| 💡 | Suche im Hintergrund statt auf dem Haupt-Thread; Vorschaubilder vorladen. | S | E1 Tempo/Oberfläche |
| 💡 | Analyseergebnisse kompakter speichern (152 MB → unter 30 MB bei 100.000 Fotos). | M | E1 Tempo |
| 💡 | CI: Zwischenergebnisse der Mac-Builds speichern (jeder Lauf ein paar Minuten schneller). | S | U |

## Oberfläche und Bedienung

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Vorschlag-Bildschirm kompakter, Knöpfe ohne Scrollen sichtbar. | S | U |
| ✅ | „Fotos fliegen in Alben“ beim Umsetzen. | M | U |
| 🔜 | „Nicht jetzt“ ist umkehrbar; ein abgelehnter Vorschlag lässt sich später doch anlegen; „Nicht mehr ignorieren“. | M | E1 Oberfläche |
| 🔜 | Bibliothek und Atlas aktualisieren sich zuverlässig (Zwischenspeicher meldet Änderungen). | S | E1 Oberfläche |
| 🔜 | Nach „Rückgängig“ eine passende Meldung statt „Fertig, 0 neue Alben“. | S | E1 Oberfläche |
| 🔜 | Vorschau-Fotos nach Datum, schönstes Foto als Titelbild; alle Fotos ansehen und einzelne entfernen. | M | E1 Oberfläche/Produkt |
| 🔜 | Ein Fortschrittsbalken über alle Schritte statt Neustart bei jeder Stufe. | S | E1 Oberfläche |
| 💡 | Zoom-Übergang vom Vorschaubild ins Foto, Kontextmenüs, Wischaktionen. | M | E1 Oberfläche, U |
| 💡 | Suche: Treffer antippbar, für VoiceOver lesbar, „Als Album anlegen“. | S | E1 Oberfläche |
| 💡 | „Analyse aktuell“ nur anzeigen, wenn es stimmt; neue Fotos beim Öffnen erkennen. | M | E1 Oberfläche |
| 💡 | Einheitliche Wörter: „Auswählen“ und „Alben anlegen“, überall „sortiert“. | S | E1 Oberfläche |
| 💡 | iPad: Inhalte nicht über die ganze Breite ziehen, Liste und Detail nebeneinander. | M | E1 Oberfläche |
| 💡 | Erhöhter Kontrast: eigene Farbvarianten. | S | E1 Oberfläche |

## Produkt und App Store

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Name Albumist, neues Icon „Glass Stack“. | S | U |
| ✅ | Berechtigungstext sagt „Gerät“ statt „iPhone“ (iPad). | S | E1 Produkt |
| ✅ | Builds und Tests mit Xcode 27 auf iOS 27 (aktuelles iOS). | S | U |
| 🔜 | Erstes Ergebnis nach etwa einer Minute: Reisen, Länder und Atlas sofort nach den Offline-Schritten zeigen. | M | E1 Produkt/Oberfläche |
| 🔜 | Startpaket: „Deine 10 besten Alben“ vorausgewählt, ein Knopf „10 Alben anlegen, kostenlos“; bei großen Plänen „Die ersten N jetzt anlegen“. | M | E1 Produkt |
| 🔜 | Kauf-Knopf in den Einstellungen; Gratis-Zähler gibt nach Rückgängig zurück. | S | E1 Produkt |
| 🔜 | Datenschutz-Link in der App und in App Store Connect. | S | E1 Produkt |
| 🔜 | Namensvorschläge für Reisen in der eingestellten Sprache (bisher immer Deutsch). | S | E1 Produkt |
| 💡 | „Album aktuell halten“: neue Fotos nachts automatisch in bestätigte Alben. Hauptthema für Update 1.1. | M | E1 Produkt |
| 💡 | Entscheidungen ins Backup, damit sie einen Gerätewechsel überstehen. | S–M | E1 Produkt |
| 💡 | Atlas-Widget und In-App-Event „Dein Reisejahr“ im Dezember/Januar. | M | E1 Produkt |
| 💡 | Siri-Antwort mit Knöpfen „Anlegen / Nicht jetzt“ statt App öffnen. | M | E1 Produkt |
| 💡 | Familienfreigabe für den Kauf, Small Business Program (15 % statt 30 %). | S | E1 Produkt |
| 💡 | Produktseite: Bildschirmfoto 1 beantwortet „Warum nicht einfach Fotos?“ (echte Alben überall); keine Zahl zeigen, die nicht stimmt. | S | E1 Produkt |

## Wow-Ideen

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Fotos fliegen in Alben. | M | U |
| 🔜 | Erster Scan als Show: Mosaik aus eigenen Fotos, gefundene Reisen springen als Karten auf. | M | U |
| 🔜 | Farben aus den Fotos: jede Reise mit eigenem weichen Farbverlauf. | S | U |
| 🔜 | Zoom-Übergang ins Foto. | S | U |
| 💡 | 3D-Globus im Atlas. | L | U |
| 💡 | Zeitreise-Regler durch die Jahre. | M | U |
| 💡 | Reise als Postkarte teilen (umdrehbar). | M | U |
| 💡 | Album-Stapel mit Tiefe beim Neigen. | S | U |
| 💡 | Widget „Heute vor 3 Jahren“. | M | U |
