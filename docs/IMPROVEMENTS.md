# Ideenliste und Verbesserungen

Lebende Liste. Nach jeder Runde (Expertenprüfung, Nutzertest, Testläufe, Gegenprüfung durch
andere KIs) kommen neue Punkte dazu. Status: ✅ erledigt · 🔜 als Nächstes · 💡 später/Update.
Aufwand: S klein, M mittel, L groß.

Quellen: **E1** Expertenrunde 14.11.2026 (Tempo, Oberfläche, Technik, Produkt) · **U** Nutzer
(Fuchs) · **T** Testläufe · **B** Bedienungstest 14.11.2026 (5 unabhängige Testpersonen: Gelegenheitsnutzerin, Vielreisender, Senior mit großer Schrift, Fotografin, Vater mit Kinderfotos).

## Datensicherheit und Zuverlässigkeit

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Rückgängig löscht nie einen Ordner, in dem noch Alben liegen (Fotos würde sie mitlöschen). Ausführung und PhotoKit verweigern das Löschen nicht leerer Ordner. | S | E1 Technik |
| ✅ | Abgebrochenes Umsetzen (App beendet): Übersicht bietet beim nächsten Start „Fortsetzen“ oder „Rückgängig machen“; nichts wird doppelt angelegt. | M | E1 Technik |
| ✅ | Verlauf zeigt auch unterbrochene Pläne, mit „Fortsetzen“ und „Rückgängig“. | S | E1 Technik |
| ✅ | Umsetzen während einer laufenden Analyse: Albenliste vor dem Abgleich neu lesen, damit kein doppeltes Album entsteht. | M | E1 Technik |
| ✅ | „Ausgewählte Fotos“-Zugriff: vor dem Umsetzen klarer Hinweis „Voller Zugriff nötig“ mit Link zu Einstellungen statt Fehlermeldung. | S | E1 Technik |
| ✅ | Bereits rückgängig gemachte Pläne nicht nochmal rückgängig machen; Rückgängig-Läufe nicht als eigene Einträge zeigen. | S | E1 Technik |
| ✅ | Fehlender Elternordner (zweites Gerät hat ihn gelöscht): nie oben auf der Mediathek-Ebene anlegen, sondern abbrechen. | S | E1 Technik |
| 💡 | Fotos nur in iCloud: nicht als „erledigt“ markieren, später erneut versuchen. | M | E1 Technik |
| ✅ | Ausgeblendete Fotos in Alben mitzählen, damit Rückgängig nichts Fremdes löscht. | S | E1 Technik |
| ✅ | Beschädigte Datenbank: „Neu aufbauen“-Knopf statt Sackgasse. | S | E1 Technik |
| ✅ | StoreKit: nicht geprüfte Käufe sauber abschließen und Fehlermeldung zeigen; wartende Käufe (Familienfreigabe) erklären. | S | E1 Technik |

## Aus den Testläufen (T)

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | „Ähnliche Alben“ schlug vor, Albumists eigene Alben zusammenzulegen (Land enthält seine Reisen). Eigene Alben und Teil-Alben (Rom in Italien) sind jetzt ausgenommen. | S | T 14.11. |
| ✅ | Sortier-Show: beim schnellen Blättern überlappten sich Alben, der Platzhalter schimmerte durch das Titelbild. | S | T 14.11. (Video) |
| ✅ | UI-Test: Tab-Leiste schrumpfte beim Scrollen und versteckte die Tabs; fehlende Schritte machen jetzt ein Bildschirmfoto. | S | T 14.11. |
| ✅ | Rückgängig fragte iOS für jedes Album einzeln „Albumist darf Album löschen?“ (37 Fragen bei 37 Alben). Alle Alben und Ordner gehen jetzt in einer Anfrage weg: eine Frage. Ordner nur, wenn alles darin mitgeht. | M | T 14.11. |
| ✅ | Menü bei größter Schrift schnitt „Nicht sortiert“ ab. Eigenes Menü-Etikett, das umbricht. | S | T 14.11. |
| ✅ | Land Italien zeigte „Mehrere passende Alben“ mit den eben angelegten Reisen Rom und Florenz und wollte Florenz-Fotos ins Rom-Album legen. Alben anderer Vorschläge und kleinere Alben mit anderem Namen werden bei Ländern nicht mehr ergänzt. | M | Fuchs 14.11. |
| ✅ | „Mehrere passende Alben“ hatte einen ausgegrauten Knopf „Bitte unter „Anpassen“ wählen“. Jetzt aktiver Knopf „Album auswählen“, die Erklärung nennt jedes Album und verspricht nichts, die Wahl wird angezeigt. | S | Fuchs 14.11. |
| ✅ | Mit nur einem freigegebenen Foto zeigte Albumist trotzdem viele Vorschläge (die Beispiel-Mediathek: iOS gibt selbst gespeicherte Fotos frei). Übersicht zeigt bei eingeschränktem Zugriff jetzt, wie viele Fotos Albumist sieht, mit „Auswahl ändern“ und „Alle Fotos erlauben“. | S | Fuchs 14.11. |
| 💡 | Bedienungshilfen-Prüfung meldet zu wenig Kontrast bei den großen Glas-Knöpfen. Gemessen: Weiß auf Petrol 6:1, also bestanden; vermutlich misst die Prüfung den Glas-Effekt mit. Auf echtem Gerät nachprüfen. | S | T 14.11. |

## Aus dem Bedienungstest (B)

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | „Alle sicheren übernehmen“ war im „…“-Menü versteckt (4 von 5 fanden es nicht). Jetzt großer Knopf „N empfohlene übernehmen“ oben in der Liste, mit Erklärung darunter. | S | B |
| ✅ | Nach dem Übernehmen fehlte der Weg zum Umsetzen. Unten in der Liste steht jetzt „N übernommene Vorschläge umsetzen“. | S | B |
| ✅ | Liste sprang nach jedem Übernehmen um. Feste Reihenfolge: Reisen neueste zuerst, sonst nach Größe. | S | B |
| ✅ | „Sicher“, „Wahrscheinlich“ ohne Erklärung. Antippen zeigt jetzt einen Satz, was das heißt. | S | B |
| ✅ | „Für später vormerken“ unklar. Heißt jetzt „Übernehmen und später anlegen“. | S | B |
| ✅ | „Überspringen“ in der Show klang nach „Arbeit abbrechen“. Jetzt „Animation überspringen“ als Glas-Knopf. | S | B |
| ✅ | Großer Fotozähler blieb in der Show stehen (Fotos im Land und in der Reise zählen einmal). Groß zählt jetzt „Alben fertig“, darunter die Fotos. | S | B |
| ✅ | Zurück während des Umsetzens sah wie Abbrechen aus. Zurück-Knopf ist währenddessen weg. | S | B |
| ✅ | „Noch 10 Alben kostenlos“ unklar, ob vor oder nach diesem Plan. Jetzt „Kostenlos. Danach hast du noch N von 10 Gratis-Alben.“ | S | B |
| ✅ | Rückgängig auf dem Fertig-Bildschirm: Hinweis, dass es auch später geht und Fotos bleiben. | S | B |
| ✅ | Suchfeld im Tab „Suchen“ nicht sichtbar (alle 5). Feld ist jetzt beim Öffnen aktiv. | S | B |
| ✅ | „Voller Zugriff“ machte Angst ums Löschen. Zugriffsseite sagt jetzt: Albumist löscht und verändert nie ein Foto. | S | B |
| ✅ | „Erst ein Probelauf?“ verwirrte. Heißt jetzt „Womit soll Albumist anfangen?“. | S | B |
| ✅ | „0 Alben gefunden“ wirkte wie ein Fehler. Nur noch „N davon in deinen Alben“, wenn es welche gibt. | S | B |
| ✅ | Ring zeigte bei größter Schrift „6…“. Ring wächst mit der Schrift, Zahl bleibt lesbar. | S | B |
| ✅ | Zu viele Alben auf einmal: Land + Stadt + Reise ergab schnell 40 Alben. Entscheidung Fuchs 14.11.: standardmäßig nur Länder und Reisen, Städte per Schalter „Städte als eigene Alben“ in den Einstellungen. | S | B (3 von 5) |
| ✅ | Städte schon beim Einrichten wählbar: Schalter „Städte als eigene Alben“ unter „Länder und Orte“ (vorher nur in den Einstellungen). | S | Fuchs 14.11. |
| 💡 | Bereich „Kinder und Familie“ (Gesichter). Mit Personen-Erkennung in Update 1.1. | L | B |
| 💡 | Fertig-Bildschirm mit Collage der neuen Alben statt nur Zahlen. | M | B |
| 💡 | Länderseite im Atlas mit kleiner Karte der Orte. | M | B |
| 💡 | Teilen-Karte im Atlas: standardmäßig mit Foto statt nur Karte. | S | B |
| 💡 | Namensfeld bei Orten ohne Namen deutlicher als Eingabefeld zeigen. | S | B |
| ✅ | Filter-Chips (Mediathek, Atlas-Jahre) liefen bei größter Schrift aus dem Bild. Bei den größten Schriftstufen jetzt ein Menü. | S | B |
| ✅ | Übernommen nur als kleines Häkchen. Zeilen sagen jetzt „Übernommen“ oder „Nicht jetzt“ in Worten. | S | B |
| 💡 | Atlas-Kacheln wachsen bei größter Schrift nicht ganz mit (Zahlen und Untertitel). | S | B |
| ✅ | Albumnamen in der Sortier-Show bei langen Reisen abgekürzt („Paris · 05.10.–07.10…“). Jetzt zwei Zeilen. | S | B |

## Tempo bei großen Mediatheken

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Ortsnamen beim ersten Durchgang begrenzt nachschlagen (60), Rest nachts; Pause wirkt sofort. Erste Vorschläge bis zu einer Stunde früher. | S | E1 Tempo |
| ✅ | Orte ohne Ergebnis (See, Meer, Wildnis) werden gemerkt und nicht jede Nacht erneut nachgeschlagen. | S | E1 Tempo |
| ✅ | „Nächste 50 Fotos“-Abfrage mit Lesezeichen statt Suche von vorn (17,7 s → 0,3 s bei 100.000 Fotos). | S | E1 Tempo |
| ✅ | Beim Umsetzen nur das betroffene Album prüfen, nicht jedes Mal die ganze Albenliste (große Pläne: Minuten statt Viertelstunden). | M | E1 Tempo/Technik |
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
| ✅ | „Nicht jetzt“ ist umkehrbar: später doch anlegen geht; in den Einstellungen „Abgelehnte Vorschläge wieder zeigen“. | M | E1 Oberfläche |
| ✅ | Bibliothek und Atlas aktualisieren sich zuverlässig (Zwischenspeicher meldet Änderungen). | S | E1 Oberfläche |
| ✅ | Nach „Rückgängig“ eine passende Meldung statt „Fertig, 0 neue Alben“. | S | E1 Oberfläche |
| ✅ | Vorschau-Fotos über die ganze Zeitspanne verteilt, nach Datum; Antippen zeigt alle Fotos; einzelne Fotos aus dem Vorschlag entfernen. | M | E1 Oberfläche/Produkt |
| 💡 | Schönstes Foto als Titelbild (Bildqualität aus der Analyse nutzen). | S | E1 Produkt |
| ✅ | Ein Fortschrittsbalken über alle Schritte statt Neustart bei jeder Stufe („Schritt 4 von 7“), auch auf dem Sperrbildschirm. | S | E1 Oberfläche |
| ✅ | Zoom-Übergang vom Vorschaubild ins Foto. | S | E1 Oberfläche, U |
| 💡 | Kontextmenüs und Wischaktionen. | M | E1 Oberfläche |
| ✅ | Suche: Treffer antippbar (mit Zoom), für VoiceOver lesbar, „Als Album anlegen“. | S | E1 Oberfläche |
| 💡 | „Analyse aktuell“ nur anzeigen, wenn es stimmt; neue Fotos beim Öffnen erkennen. | M | E1 Oberfläche |
| ✅ | Einheitliche Wörter: überall „sortiert“ statt „organisiert“. „Umsetzen“ bleibt für das Anlegen eines ganzen Plans. | S | E1 Oberfläche |
| 💡 | iPad: Inhalte nicht über die ganze Breite ziehen, Liste und Detail nebeneinander. | M | E1 Oberfläche |
| 💡 | Erhöhter Kontrast: eigene Farbvarianten. | S | E1 Oberfläche |

## Produkt und App Store

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Name Albumist, neues Icon „Glass Stack“. | S | U |
| ✅ | Berechtigungstext und alle anderen Texte sagen „Gerät“ statt „iPhone“ (iPad). | S | E1 Produkt |
| ✅ | Builds und Tests mit Xcode 27 auf iOS 27 (aktuelles iOS). | S | U |
| ✅ | Erstes Ergebnis früh: Reisen, Länder und Orte erscheinen beim ersten Durchgang vor der Bildanalyse (statt nach Stunden). | M | E1 Produkt/Oberfläche |
| ✅ | Startpaket: „Dein Startpaket“ mit den besten Alben (Reisen und Orte zuerst), ein Knopf „10 Alben kostenlos anlegen“; bei großen Plänen „Die ersten N jetzt kostenlos anlegen“. | M | E1 Produkt |
| ✅ | Kauf-Knopf in den Einstellungen; Gratis-Zähler gibt nach Rückgängig zurück. | S | E1 Produkt |
| ✅ | Datenschutz-Seite in der App (offline lesbar). Für App Store Connect fehlt noch eine öffentliche Adresse. | S | E1 Produkt |
| ✅ | Namensvorschläge für Reisen in der eingestellten Sprache (bisher immer Deutsch). | S | E1 Produkt |
| 💡 | „Album aktuell halten“: neue Fotos nachts automatisch in bestätigte Alben. Hauptthema für Update 1.1. | M | E1 Produkt |
| 💡 | Entscheidungen ins Backup, damit sie einen Gerätewechsel überstehen. | S–M | E1 Produkt |
| 💡 | Atlas-Widget und In-App-Event „Dein Reisejahr“ im Dezember/Januar. | M | E1 Produkt |
| 💡 | Siri-Antwort mit Knöpfen „Anlegen / Nicht jetzt“ statt App öffnen. | M | E1 Produkt |
| 💡 | Familienfreigabe für den Kauf, Small Business Program (15 % statt 30 %). | S | E1 Produkt |
| 💡 | „Alle Fotos dieses Albums verbessern“: Apples automatische Verbesserung (Core Image) für viele Fotos auf einmal, mit Vorher/Nachher, in Fotos jederzeit umkehrbar. Erst nach dem Start (Update 1.2), weil es das Versprechen „Fotos bleiben unverändert“ aufweicht; Apples KI-Bereinigen ist für Apps nicht verfügbar. | M | U |
| 💡 | Produktseite: Bildschirmfoto 1 beantwortet „Warum nicht einfach Fotos?“ (echte Alben überall); keine Zahl zeigen, die nicht stimmt. | S | E1 Produkt |

## Wow-Ideen

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Fotos fliegen in Alben. | M | U |
| ✅ | Erster Scan als Show: Mosaik aus eigenen Fotos mit wanderndem Licht, gefundene Reisen springen als Karten auf. | M | U |
| ✅ | Farben aus den Fotos: jeder Vorschlag und jedes Land im Atlas mit eigenem weichen Farbverlauf aus dem Titelbild. | S | U |
| ✅ | Zoom-Übergang ins Foto (Mediathek und Atlas-Länder). | S | U |
| 💡 | 3D-Globus im Atlas. | L | U |
| 💡 | Zeitreise-Regler durch die Jahre. | M | U |
| 💡 | Reise als Postkarte teilen (umdrehbar). | M | U |
| 💡 | Album-Stapel mit Tiefe beim Neigen. | S | U |
| 💡 | Widget „Heute vor 3 Jahren“. | M | U |
