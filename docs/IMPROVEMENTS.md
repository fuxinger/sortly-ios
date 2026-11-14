# Ideenliste und Verbesserungen

Lebende Liste. Nach jeder Runde (Expertenprüfung, Nutzertest, Testläufe, Gegenprüfung durch
andere KIs) kommen neue Punkte dazu. Status: ✅ erledigt · 🔜 als Nächstes · 💡 später/Update.
Aufwand: S klein, M mittel, L groß.

Quellen: **E1** Expertenrunde 14.11.2026 (Tempo, Oberfläche, Technik, Produkt) · **U** Nutzer
(Fuchs) · **T** Testläufe · **B** Bedienungstest 14.11.2026 (5 unabhängige Testpersonen: Gelegenheitsnutzerin, Vielreisender, Senior mit großer Schrift, Fotografin, Vater mit Kinderfotos) · **G** Gegenprüfung durch ChatGPT/Gemini 14.11.2026 (43 Befunde, alle bewertet in `docs/review/AUDIT_2026-11-14.md`; 16 Produktideen, unten eingeordnet).

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
| ✅ | Fotos nur in iCloud: nicht als „erledigt“ markieren, später erneut versuchen. Fehlversuche werden gezählt und in späteren Läufen wiederholt; Text aus der kleinen Vorschau wird mit dem Original nachgelesen. | M | E1 Technik, G 5.1/2.4 |
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
| ✅ | „Umsetzen“ zeigte nur Zahlen (8 Ordner, 10 Alben), aber nicht, welche Alben entstehen. Die Vorschau listet jetzt jedes Album mit Titelbild, Ordner, Fotoanzahl und „Neu“ oder „Ergänzt“. | S | Fuchs 14.11. |
| ✅ | „Übernommen“ war unklar (ist schon etwas angelegt?). Jetzt durchgehend „auswählen“ und „N ausgewählte Alben anlegen“; Alben, die so bleiben, zählen nicht mehr mit. | S | Fuchs 14.11. |
| ✅ | Reisen wie „Rom · 10.05.–14.05.2024“ wirkten wie Stadt-Alben, weil alle Vorschläge gemischt standen. Die Gesamtliste hat jetzt Abschnitte je Bereich (Länder und Orte, Reisen …), Reisen neueste zuerst. | S | Fuchs 14.11. |
| ✅ | Heimliche Auswahl: „Dein Startpaket – N Alben anlegen“ und „Album anlegen“ wählten Vorschläge aus, die nach „Zurück“ ausgewählt blieben (Fuchs sah 34 ausgewählte, ohne etwas gewählt zu haben). Zurück ohne Anlegen stellt jetzt alles wieder her; „Auswahl aufheben“ in der Vorschau; UI-Test prüft beide Wege. | M | Fuchs 14.11. |
| ✅ | Übersicht zeigte vor dem ersten Schritt „13 von 246 sortiert“ (Screenshots ohne Ort zählten als sortiert). Fotos, für die kein Hauptbereich gilt, zählen jetzt weder als sortiert noch in der Gesamtzahl. | S | Erstnutzer-Durchgang 14.11. |
| ✅ | Vorhandene Alben fehlten im Tab „Alben“: (1) bei „Nur ausgewählte Fotos“ zeigt iOS einer App keine Alben, das steht jetzt dort mit „Alle Fotos erlauben“; (2) in Fotos neu angelegte Alben kamen erst nach „Neu prüfen“. Albumist bemerkt Änderungen in Fotos jetzt selbst und prüft beim Start nach. | M | Fuchs 14.11. |
| ✅ | Städte schon beim Einrichten wählbar: Schalter „Städte als eigene Alben“ unter „Länder und Orte“ (vorher nur in den Einstellungen). | S | Fuchs 14.11. |
| 🔜 | Zahlen passen nicht ganz zusammen: Übersicht „0 von 233 sortiert“ (nur Hauptbereiche), Fertig-Bildschirm „236 Fotos einsortiert“ (auch Screenshots und Dokumente). Erledigt: „0 ergänzt“ und andere Nullen fallen weg. Offen: Fertig-Bildschirm nach Bereichen aufteilen. | S | Erstnutzer-Durchgang 14.11. |
| ✅ | Startpaket-Karte nannte „Island, Rom und Kyoto …“, die Vorschau listete in anderer Reihenfolge (Lissabon, Kyoto …; Planer-Reihenfolge nach ID). Jetzt eine Reihenfolge überall (`inDisplayOrder`): Vorschlagsliste, Startpaket und Vorschau. | S | Erstnutzer-Durchgang 14.11. |
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

## Aus der Gegenprüfung (G): Produktideen

Einordnung der 16 Vorschläge. Leitlinie bleibt: wenige verlässliche Abläufe statt langer
Funktionsliste; nichts, was Fotos löscht oder ohne Bestätigung ändert.

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| 🔜 | **I01 Änderungsbeleg:** pro Plan eine Seite „Das hat Albumist geändert“ mit echten Zahlen aus dem neuen Ausführungsjournal und „Originale unverändert“. Grundlage ist jetzt da (Journal mit echten Änderungen). | M | G I01 |
| 🔜 | **I12 Sicherung der Entscheidungen:** abgelehnte Vorschläge, verwaltete Alben und Verlauf zusätzlich in einer kleinen Datei, die das iPhone-Backup mitnimmt; Wiederherstellen nach Neuaufbau der Datenbank. Schließt die Restlücke von Befund 3.2. | M | G I12 |
| 🔜 | **I16 Geführte Reparatur:** bei unterbrochenen oder fehlgeschlagenen Plänen ein klarer Weg „Fortsetzen / Rückgängig / so lassen“ plus Diagnose-Export ohne Fotos und Namen. | M | G I16 |
| 💡 | **I04 Lebende Alben:** neue Fotos einer Reise oder eines Themas als kleine Ergänzung vorschlagen statt neu zu sortieren. Passt zum Wochenhinweis für 1.1. | L | G I04 |
| 💡 | **I07 Reise-Werkstatt:** Reisen teilen und zusammenlegen in der Oberfläche (der Kern kann es schon: `TripCorrections`, Reise-Identität bleibt jetzt erhalten). | L | G I07 |
| 💡 | **I02 Sortier-Kompass:** beim Start zwei, drei Fragen („wenige große Alben“ oder „viele genaue“), die Bereiche und Schwellen setzen. Erweitert die Bereichsauswahl. | M | G I02 |
| 💡 | **I06 Album-Gesundheitscheck:** „Ähnliche Alben“ ausbauen: leere Alben, fast gleiche Alben, Alben ohne Titelbild, nur lesend mit Vorschlag. | M | G I06 |
| 💡 | **I09 Ähnliche Fotos:** „Mehr wie dieses“ über die schon berechneten Bild-Merkmale (Feature Print), nur lesend. | L | G I09 |
| 💡 | **I08 Gespeicherte Suchen:** eine Suche als Sammlung merken, ohne echtes Album. | M | G I08 |
| 💡 | **I11 Atlas 2.0:** Jahresrückblick der Reisen im Atlas, direkt mit Album-Vorschlag. | M | G I11 |
| 💡 | **I13 Analyse-Assistent:** vor der ersten Analyse ehrlich sagen, wie lange es dauert und was iCloud braucht; Teile davon gibt es schon (erste Ergebnisse früh, Pause bei Wärme je Foto). | M | G I13 |
| 💡 | **I03 Lernschleife:** aus abgelehnten und angepassten Vorschlägen Regeln vorschlagen, sichtbar und abschaltbar. | L | G I03 |
| 💡 | **I05 Regelstudio:** Regeln (gibt es im Kern) mit einfacher Oberfläche und Vorschau „würde 120 Fotos betreffen“. | M | G I05 |
| 💡 | **I10 Beleg-Assistent:** Felder aus Rechnungen (Händler, Betrag, Datum) prüfbar anzeigen und suchen. | L | G I10 |
| 💡 | **I14 Personen und Haustiere:** nur bestätigte Gruppen, Opt-in; schon für 1.1 geplant. | XL | G I14 |
| 💡 | **I15 Widget und Kurzbefehle:** Widget „offene Vorschläge“, Kurzbefehl „neue Fotos sortieren“; Widget ist für 1.1 geplant. | M | G I15 |

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
