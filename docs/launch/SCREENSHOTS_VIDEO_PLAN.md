# Plan: Bildschirmfotos, Vorschauvideo, Kopfbild

Stand 21.11.2026. **Umsetzung erst, wenn neues Design und Karte im Build sind.** Bis dahin ist
das hier das Drehbuch. Bildtexte DE und EN stehen unten.

## Was Apple vorgibt (gelesen 21.11.2026)

- Bis **10 Bildschirmfotos**; in der Suche sieht man die **ersten drei** (wenn kein Video da ist).
  Sie müssen die App zeigen, wie sie wirklich ist.
- Bis **3 Vorschauvideos**, je **höchstens 30 Sekunden**, nur Aufnahmen vom Gerät, laufen
  **stumm** von selbst und in Schleife. Ein starkes Standbild („poster frame“) wählen.
- **Neu mit iOS 27 (WWDC26, „Enhance your presence on the App Store“, laut Mitschrift; in App
  Store Connect bestätigen, bevor wir darauf bauen):** Produktseiten bekommen
  ein **Kopfbild oder Kopfvideo** („Product Page Header“), das nicht aus der App stammen muss, und
  in der Suche kann statt der Bildschirmfotos ein **eigenes Bild oder Video** stehen. Neue
  „Asset Library“ in App Store Connect; austauschbar ohne neue Prüfung, mit Vorschau-Werkzeug und
  A/B-Test. **Das ist unsere größte Chance**: Der Globus „Deine Welt“ als Kopfvideo.
- Verboten in Bildern und Video: Preise und Rabatte, Webadressen, ©, Auszeichnungen von Apple,
  Logos anderer Plattformen, nicht belegbare Aussagen. Alles 4+.
- Größen: 6,9″-iPhone-Bilder (1320 × 2868 hoch) sind Pflicht, kleinere rechnet Apple herunter.
  Video 6,9″: 886 × 1920, 30 Bilder/s. (Vor dem Hochladen in App Store Connect › Hilfe
  „Screenshot specifications“ und „App preview specifications“ gegenprüfen.)

## Leitidee

**Die Fotos sind der Star, nicht die Knöpfe.** Wie bei Flighty und Halide: wenig Text, ein klarer
Satz pro Bild, das echte Bild der App groß. Hintergrund ruhig (Weiß hell, fast Schwarz dunkel), die
Fotos bringen die Farbe. Gleiche Schrift wie die App (SF Pro, fett), Satz oben, iPhone-Rahmen von
Apple (Design Resources), leicht angeschnitten.

Die ersten drei Bilder müssen allein den Kauf erklären: **(1) was passiert, (2) dass es sicher
ist, (3) der Wow-Moment.**

## Die sieben Bildschirmfotos

Sieben starke statt zehn mittelmäßige (Zweitprüfung: Zugriffsseite und Einstellungen sind keine
Bilder, die verkaufen). Spalte „ohne Karte“ gilt, falls die Karte nicht rechtzeitig fertig ist.

| # | Satz DE | Satz EN | Bildschirm | Ohne Karte |
|---|---|---|---|---|
| 1 | Jede Reise wird ein Album. | Every trip becomes an album. | Vorschläge-Liste im neuen Foto-Look: 4–5 Reisen mit großen Titelfotos, Ort und Monat | gleich |
| 2 | Echte Alben in deiner Fotos-App. | Real albums in your Photos app. | Ergebnis nach dem Anlegen als Raster der neuen Alben mit Titelfoto und Namen, Knopf „Fotos-App öffnen“ | gleich |
| 3 | Deine Welt. | Your world. | Globus mit Bögen und Orten, Länderzahl (dunkel) | Reise-Atlas: „Alle Länder auf einen Blick.“ / „Every country at a glance.“ |
| 4 | Erst ansehen. Dann anlegen. | Look first. Then create. | Vorschau mit Albenliste und „Alben jetzt anlegen“ | gleich |
| 5 | Nichts ist endgültig. | Nothing is final. | Liste der angelegten Alben mit „Rückgängig machen“ | gleich |
| 6 | Erlebe jede Reise noch einmal. | Relive every trip. | Bild aus „Reise abspielen“: Route über Gelände, bestes Foto groß (dunkel) | Suche: „Such einfach: Hunde Italien 2023.“ / „Just search: dogs Italy 2023.“ |
| 7 | Bleibt auf deinem iPhone. | Stays on your iPhone. | Gestaltete Aussage: großes Schild-Symbol über einer Übersicht mit Mosaik, darunter „Keine Fotos hochgeladen · Kein Konto · Kein Abo“ | gleich |

Bild 1–3 sind, was die Suche zeigt: **was passiert, dass es echt ist, das Wow.**
Bilder 3 und 6 dunkel (Globus und Fotos leuchten), sonst hell. **Kein Preis, keine Webadresse,
keine Auszeichnungen im Bild** (Apple verbietet es). Weder die Fotos-App noch der Sperrbildschirm
werden gezeigt: Apple will die eigene App sehen, und so bleibt es einheitlich.

### Mediathek für die Aufnahmen

- Eine **eigene Demo-Mediathek mit echten Reisefotos**, für die wir die Rechte haben: Fotos von
  Fuchs (echte Reisen, Menschen höchstens von hinten, keine Kennzeichen). Gemeinfreie Bilder wirken
  wie Archivfotos; nur als Lückenfüller. Die gezeichneten Beispielfotos der App
  sind für die Prüfung gedacht, nicht schön genug für die Produktseite.
- Reisen mit Wiedererkennung: Island, Toskana, Lissabon, New York, Japan, Dolomiten.
  Ländersumme realistisch (z. B. 18), nicht übertrieben.
- Uhrzeit 9:41, volle Balken, voller Akku (Statusleiste wie bei Apple), Deutsch und Englisch je
  eine eigene Aufnahme (Ortsnamen und Monate in der Sprache).

### Wie die Bilder entstehen

1. Ein UI-Test „StoreShots“ (neue Testgruppe, nur von Hand gestartet) lädt die Demo-Mediathek in
   den Simulator, stellt 9:41 ein (`xcrun simctl status_bar … override`), geht die sieben Bildschirme
   ab und speichert Bilder in 1320 × 2868, je DE und EN, hell und dunkel. So sind die Bilder bei
   jeder neuen Version mit einem Klick neu.
2. Ein kleines Skript setzt Satz, Rahmen und Hintergrund (Vorlage als HTML, gerendert im Browser),
   damit kein Designprogramm nötig ist. Fuchs sieht alle 14 Bilder (DE und EN) als Kontaktbogen
   und gibt frei.

## Vorschauvideo (30 Sekunden, stumm verständlich)

Aufnahme am iPhone mit der Demo-Mediathek (Bildschirmaufnahme), geschnitten auf 30 s, ruhige
Übergänge (Apple: keine schnellen Schnitte). Kurze Einblendungen statt Ton.

| Zeit | Bild | Einblendung DE / EN |
|---|---|---|
| 0–4 s | **Standbild = Vorschläge mit Titelfotos**, Reisen erscheinen eine nach der anderen | Jede Reise wird ein Album. / Every trip becomes an album. |
| 4–10 s | Einen Vorschlag öffnen, Fotos wischen, ein Foto herausnehmen | Du entscheidest. / You decide. |
| 10–15 s | Vorschau, „Alben jetzt anlegen“, Fotos fliegen in Alben | Echte Alben. / Real albums. |
| 15–19 s | Raster der neuen Alben, Knopf „Fotos-App öffnen“ (Albumists eigener Bildschirm; Vorschauvideos sollen nur die App zeigen) | In deiner Fotos-App. / In your Photos app. |
| 19–27 s | Globus „Deine Welt“, dann „Reise abspielen“: Route über Island, bestes Foto groß | Erlebe sie noch einmal. / Relive it. |
| 27–30 s | Zurück zu den Vorschlägen (Schleife wirkt nahtlos) | Albumist |

Ohne Karte: 19–27 s Reise-Atlas und Suche „Hunde Italien 2023“.
Die ersten Sekunden zeigen die eigentliche Veränderung, nicht den Globus: In der Suche spielt
Apple nur den Anfang stumm ab.

Zweites Video (optional, später): 15 s nur „Reise abspielen“, für Werbung und Kopfvideo.

## Kopfbild/Kopfvideo und Suchbild (iOS 27)

- **Kopfvideo:** Globus „Deine Welt“ in Dunkel, langsame Drehung, Bögen leuchten nacheinander auf,
  am Ende Schriftzug „Albumist“. 10–15 s, nahtlose Schleife. Darf aus der App gerendert sein
  (Apple verlangt hier keine Bildschirmaufnahme).
- **Suchbild:** dasselbe Motiv als Standbild mit dem Satz „Jede Reise wird ein Album.“ Apple rät,
  Kopf, Icon und Suchbild als eine Gestalt zu bauen.
- Varianten für einen A/B-Test (Produktseiten-Optimierung) nach dem Start: Globus gegen
  Fotos-Mosaik.

## Eigene Produktseiten (nach dem Start)

| Seite | Für wen | Erstes Bild |
|---|---|---|
| Reisealben | Suchanzeigen „Reisealben“, „Urlaubsfotos sortieren“ | Bild 1 |
| Deine Welt | Videos auf Instagram/TikTok mit dem Globus | Bild 3 |
| Aufräumen | „Fotos ordnen“, Neujahr | Vorher/Nachher Übersicht |

## Reihenfolge der Arbeit (nach Design und Karte)

1. Demo-Mediathek zusammenstellen (Fuchs liefert Reisefotos oder gibt CC0-Auswahl frei).
2. UI-Test „StoreShots“ bauen, Bilder erzeugen, Kontaktbogen an Fuchs.
3. Rahmen und Sätze setzen, Fuchs gibt frei.
4. Video am iPhone aufnehmen (Fuchs, nach einer Schritt-Liste) und schneiden; Kopfvideo aus der
   App rendern.
5. Alles hochladen erst mit der Einreichung.

Realistisch: 2–3 Arbeitstage nach dem Build mit Design und Karte, plus Fuchs' Freigaben und eine
Aufnahme am iPhone.
