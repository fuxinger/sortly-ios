# Notiz für App Review / Notes for App Review

Stand 21.11.2026. In App Store Connect unter „App Review Information → Notes“ einfügen. Englisch
reicht; Deutsch für einen deutschsprachigen Prüfer. Kein Konto, kein Login, kein Server, darum
bleiben „Sign-in required“ und die Demo-Zugangsdaten leer.

Plugin-Prüfung 15.11.2026, K6: Prüfgeräte haben oft nur wenige Fotos ohne Ort, dann gibt es nichts
vorzuschlagen. Seit 16.11. erklärt die Übersicht das und bietet Beispielfotos an.

## Vor dem Einreichen (sonst droht Ablehnung)

- [ ] **Karten-Prototyp entfernen.** Die Prototyp-Seite der Karte erscheint, wenn
      `AppTransaction.environment == .sandbox` ist (TestFlight). Apples Prüfung läuft ebenfalls in
      der Sandbox, der Prüfer würde also eine unfertige Seite sehen (Ablehnung nach 2.1/2.2).
      `MapPrototypeGate`/`MapPrototypeView` in `App/Albumist/Map/Prototype` müssen vor der ersten
      Einreichung raus (steht auch im Kartenstrang).
- [ ] In-App-Kauf `app.albumist.ios.unlock` angelegt, mit Prüf-Screenshot, **an Version 1.0
      angehängt** (`LAUNCH_CHECKLIST.md`).
- [ ] Bildschirmaufnahme nach dem Drehbuch unten gemacht, Link unten eingesetzt.
- [ ] Texte unten mit dem eingereichten Build abgleichen (Knopfnamen, Karte, Einstellungen).
- [ ] Kontaktdaten für Rückfragen (Name, Telefon, E-Mail) im Feld „Contact Information“.

## English (paste this)

Albumist finds the trips, places and other themes in the user's own photo library and creates real
albums for them in the Photos app, after showing a preview; everything can be undone. Everything
runs on the device; there is no account and no server.

**See everything in about one minute**
1. Start the app, tap "Let’s Go", keep the preselected areas and tap "Continue". Allow access to
   **all photos** (albums can only be created with full access). On "Try a test run first?" keep
   "The whole library" and tap "Start Analysis".
2. Review devices usually hold only a few photos without a location, so there is nothing to suggest.
   The overview then says so ("Not Enough Photos Yet" / "No Photos Yet") and offers
   **"Try It with Sample Photos"**. Before anything is added, the app explains that the sample photos
   are really added to the Photos library (only there can it make albums of them). They are drawn by
   the app itself: 78 pictures of everyday life at home and four trips (Rome, Dolomites, Lisbon,
   Copenhagen), each with a date and a place.
3. After a few seconds of analysis the overview shows suggestions. Tap "Review N Suggestions" or the
   starter set "Create N Albums for Free", look at the preview (nothing changes before you confirm)
   and tap "Create Albums Now". The albums appear in Photos under Collections › Albums.
4. "Undo" on the result card takes everything back. The change receipt lists exactly what was done.
5. Settings › "Remove Sample Photos" deletes the sample photos the app added (by their stored
   identifiers, with the system's own delete confirmation; they then stay in "Recently Deleted" for
   30 days) and the albums it made of nothing but them. A sample photo that was edited or put into
   an album of one's own is deleted too; the reviewer's own photos and albums are never touched.
   Removing needs full photo access and no plan in progress (the app says so otherwise).

**Purchase:** the first 10 albums are free. A one-time, non-consumable in-app purchase
("Unlock Albumist") removes the limit; it is submitted together with this version. Restore and offer
codes are in Settings › Full version.

**Privacy:** photos and analysis stay on the device. If "Refine places online" is
on (the default), coordinates and the language for the names are sent to Apple's geocoder
(`CLGeocoder`) to name places; nothing is sent to us. Original photos are
never modified; the app only creates, fills and (on undo) removes its own albums. The only photos it
ever deletes are its own sample photos, when the user taps "Remove Sample Photos" and confirms in the
iOS dialog (they stay 30 days in Recently Deleted).

**Background work and notifications:** a long first analysis may continue after the user leaves
the app as a continued processing task (`BGContinuedProcessingTask`), with the system's progress
on the Lock Screen; it stops when iOS asks. A local "analysis done" notification is sent only if
the user allowed notifications in the app. Nothing runs on a server.

**Map ("Your World"):** the globe and trip replay use the photos' own locations. Map images come
from Apple (MapKit) only for the visible area; Settings › "Use Apple Maps" turns this off. [MAP]

**Siri and Shortcuts:** "Sort new photos with Albumist" starts an analysis of new photos;
Spotlight lists countries and open suggestions.

**Video:** a 60-second recording of the flow with a real photo library: <link>

## Deutsch

Albumist ordnet die eigene Fotomediathek in Alben für Länder und Reisen. Alles läuft auf dem Gerät;
es gibt kein Konto und keinen Server.

**Alles in etwa einer Minute sehen**
1. App starten, „Los geht’s“, Bereiche lassen und „Weiter“. Zugriff auf **alle Fotos** erlauben
   (Alben lassen sich nur mit vollem Zugriff anlegen). Bei „Erst ein Probelauf?“ „Die ganze
   Mediathek“ lassen und „Analyse starten“.
2. Prüfgeräte haben meist nur wenige Fotos ohne Ort, dann gibt es nichts vorzuschlagen. Die Übersicht
   sagt das („Noch zu wenige Fotos“ / „Noch keine Fotos“) und bietet **„Mit Beispielfotos
   ausprobieren“** an. Vorher erklärt die App, dass die Beispielfotos wirklich in der Fotos-Mediathek
   angelegt werden (nur dort kann sie Alben daraus machen). Die Bilder zeichnet die App selbst:
   78 Bilder aus dem Alltag zu Hause und von vier Reisen (Rom, Dolomiten, Lissabon, Kopenhagen), jedes
   mit Datum und Ort.
3. Nach wenigen Sekunden Analyse zeigt die Übersicht Vorschläge. „Vorschläge prüfen“ oder das
   Startpaket „… Alben kostenlos anlegen“ antippen, die Vorschau ansehen (vor dem Bestätigen ändert
   sich nichts) und „Alben jetzt anlegen“. Die Alben stehen in Fotos unter Sammlungen › Alben.
4. „Rückgängig machen“ auf der Ergebniskarte nimmt alles zurück; der Änderungsbeleg zeigt genau, was
   passiert ist.
5. Einstellungen › „Beispielfotos wieder entfernen“ löscht die Beispielfotos, die die App angelegt
   hat (anhand der gespeicherten Kennungen, mit der Löschabfrage von iOS; danach liegen sie 30 Tage
   unter „Zuletzt gelöscht“), und die Alben, die sie nur aus ihnen gemacht hat. Auch ein bearbeitetes
   oder in ein eigenes Album gelegtes Beispielfoto wird gelöscht; eigene Fotos und Alben bleiben
   unberührt. Entfernen braucht vollen Fotozugriff und kein laufendes Umsetzen (sonst sagt die App das).

**Kauf:** Die ersten 10 Alben sind kostenlos. Ein einmaliger Kauf („Albumist freischalten“,
Nicht-Verbrauchsartikel) hebt die Grenze auf; er wird mit dieser Version eingereicht. Wiederherstellen
und Code einlösen unter Einstellungen › Vollversion.

**Datenschutz:** Fotos und Analyse bleiben auf dem Gerät. Ist „Orte online genauer bestimmen“ an
(ab Werk), gehen Koordinaten und die Sprache der Ortsnamen an Apples Kartendienst (`CLGeocoder`),
um Orte zu benennen; an uns geht nichts. Originalfotos werden nie
verändert; die App legt nur eigene Alben an, füllt sie und entfernt sie beim Rückgängigmachen. Fotos löscht
sie nur, wenn es ihre eigenen Beispielfotos sind: nach „Beispielfotos wieder entfernen“ und der Bestätigung im
iOS-Dialog (sie liegen dann 30 Tage unter „Zuletzt gelöscht“).

**Hintergrund und Mitteilungen:** Eine lange erste Analyse kann nach dem Verlassen der App als
fortgesetzte Aufgabe (`BGContinuedProcessingTask`) weiterlaufen, mit dem Fortschritt von iOS auf
dem Sperrbildschirm; sie endet, sobald iOS es verlangt. Die Mitteilung „Analyse fertig“ kommt nur,
wenn Mitteilungen in der App erlaubt wurden.

**Karte („Deine Welt“):** Globus und „Reise abspielen“ nutzen die Aufnahmeorte der Fotos.
Kartenbilder kommen von Apple (MapKit), nur für den sichtbaren Ausschnitt; abschaltbar unter
Einstellungen › „Apples Karte verwenden“. [KARTE]

**Siri und Kurzbefehle:** „Neue Fotos sortieren mit Albumist“ startet die Analyse neuer Fotos;
Spotlight findet Länder und offene Vorschläge.

**Video:** 60 Sekunden Ablauf mit echter Mediathek: <Link>

## Drehbuch für die Bildschirmaufnahme (ca. 60 Sekunden, echte Mediathek)

Aufnahme mit der iOS-Bildschirmaufnahme (Kontrollzentrum), Hochformat, ohne Ton oder mit kurzem
Sprechertext. Ein iPhone mit echter Mediathek (einige Hundert Fotos mit Reisen). Vorher: Albumist
löschen und neu installieren, Nicht-Stören an, keine privaten Fotos im Bild, die man nicht zeigen will
(am besten eine Mediathek mit Reise- und Landschaftsfotos).

| Zeit | Bild | Was zu sehen sein muss |
|---|---|---|
| 0–8 s | Start, „Los geht’s“, Bereiche, „Weiter“ | Das Versprechen: Fotos bleiben auf dem Gerät |
| 8–15 s | Zugriff „Alle Fotos erlauben“, Probelauf, „Analyse starten“ | Der iOS-Dialog für vollen Zugriff |
| 15–30 s | Übersicht während der Analyse | Fortschritt, die eigenen Fotos im Mosaik |
| 30–40 s | „Vorschläge prüfen“, eine Reise öffnen, Fotos wischen | Echte Reisen mit Ort und Datum |
| 40–50 s | Startpaket oder Auswahl, Vorschau, „Alben jetzt anlegen“ | Vorschau vor jeder Änderung, Fotos fliegen in Alben |
| 50–55 s | „Fotos-App öffnen“, Sammlungen › Alben | Die neuen Alben in Fotos |
| 55–60 s | Zurück, „Rückgängig machen“ | Alles lässt sich zurücknehmen |

Mit Karte: nach 50 s zusätzlich 10 s „Deine Welt“ (Globus drehen, eine Reise abspielen); das
Video darf dann 70 s lang sein, die Prüfnotiz hat keine Grenze.

Danach: Video in App Store Connect bei der Prüfnotiz anhängen (oder als nicht gelisteten Link
eintragen) und den `<link>` oben ersetzen.
