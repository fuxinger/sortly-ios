# App Store – Deutsch (Produktseite)

Stand 21.11.2026, nach blinder Zweitprüfung (Fable) überarbeitet. Ersetzt den Entwurf vom 14.11.
Zeilen mit **[KARTE]** erst übernehmen, wenn die Karte „Deine Welt“ im eingereichten Build ist;
bis dahin gilt die Zeile **[OHNE KARTE]**. Alle Zeichenzahlen mit Python nachgezählt.

## Leitgedanke (nur intern)

Albumist **ergänzt die Fotos-App**: Alles, was es macht, landet als echtes Album in Apples
Fotos-App, auf dem iPhone und mit iCloud-Fotos auch auf Mac und iPad. Nie „besser als Apple
Fotos“. Vier Wörter tragen den Unterschied: **echte Alben · privat · vorher ansehen ·
rückgängig.** Dazu: einmal zahlen, kein Abo.

Ohne Namen zu nennen (Apple verbietet Namen anderer Apps) heben wir uns ab von:
- Apples Sammlung „Reisen“: zeigt Reisen nur an. → „echte Alben in deiner Fotos-App“
- Themen-Apps im Abo (34,99 €/Jahr) → „Einmal zahlen. Kein Abo.“
- Regel-Apps, in denen man alles selbst einstellt → „findet deine Reisen von selbst“

Regeln für jeden Satz: nichts Absolutes, das die App nicht hält (kein „jede Reise“ im Fließtext:
Reisen brauchen Ort und mindestens 10 Fotos, `TripSettings.minPhotos`); „deine Fotos“ statt „nie
ein Foto“ (die App löscht auf Wunsch ihre eigenen Beispielfotos); keine Fachwörter.

## Felder

**Name (max. 30):** `Albumist – Fotos sortieren` (26)

> Name, Untertitel und Schlüsselwörter sind die einzigen Felder, die Apples Suche liest. Eine
> neue App wird über „Fotos sortieren“ gefunden, nicht über „Albumist“. Flighty macht es genauso
> („Flighty – Live Flight Tracker“). Unter dem Icon steht weiter nur „Albumist“.

**Untertitel (max. 30):** `Echte Alben für jede Reise` (26)

**Kategorie:** Foto & Video (Haupt), Reisen (zweite).

**Werbetext (max. 170, ohne neue Prüfung änderbar). Ohne Preis**, weil derselbe Text auch in
Österreich und der Schweiz (Franken) erscheint und nach der Startwoche sonst falsch wäre:

- Startwoche: `Zum Start günstiger. Einmal zahlen, kein Abo. Albumist findet deine Reisen und macht daraus echte Alben in deiner Fotos-App. Ganz privat auf deinem iPhone.` (155)
- Danach: `Jahre voller Fotos, endlich in Ordnung: Albumist findet deine Reisen und legt echte Alben in deiner Fotos-App an. Erst ansehen, dann anlegen, alles zurücknehmbar.` (162)

**Schlüsselwörter (max. 100, ohne Leerzeichen, nichts aus Name und Untertitel):**
```
urlaub,urlaubsfotos,fotoalbum,reisen,album,ordnen,aufräumen,bilder,weltkarte,länder,screenshots
```
(95 Zeichen, 97 Byte.) Deutsche Suche trennt zusammengesetzte Wörter nicht und erkennt Ein- und
Mehrzahl nicht sicher, darum „urlaubsfotos“, „fotoalbum“, „reisen“ und „album“ eigens. Bewusst
nicht drin: Wörter aus Name und Untertitel, „app“, Namen anderer Apps, „speicher“ oder „löschen“
(locken Leute, die Speicher frei räumen wollen; das macht Albumist nicht).

**Beschreibung:**

```
Tausende Fotos und kein einziges Album? Albumist findet deine Reisen und legt sie als echte Alben in deiner Fotos-App an. Du siehst alles vorher. Kein Foto verlässt dein iPhone.

REISEN WERDEN ALBEN
Albumist erkennt Reisen und Ausflüge von selbst, auch die von vor zehn Jahren, und trennt sie vom Alltag zu Hause. Jede bekommt ein Album mit Ort und Zeit, etwa „Gardasee, August 2026“. Die Alben stehen in Apples Fotos-App, mit iCloud-Fotos auch auf Mac und iPad.

ERST ANSEHEN, DANN ANLEGEN
Bevor sich etwas ändert, zeigt dir Albumist jedes Album mit seinen Fotos. Nimm Fotos heraus, ändere Namen, teile oder verbinde Reisen. Erst wenn du „Alben jetzt anlegen“ tippst, passiert etwas.

ALLES LÄSST SICH ZURÜCKNEHMEN
Eine Liste zeigt genau, was angelegt wurde, und mit „Rückgängig machen“ ist alles wieder wie vorher. Deine Fotos löscht und verändert Albumist nie. Hast du schon Alben, ergänzt Albumist sie, statt sie doppelt anzulegen.

[KARTE] DEINE WELT
Ein Globus mit allen Orten, an denen du fotografiert hast. Spiel eine Reise noch einmal ab, Station für Station, mit deinen besten Fotos, und teile deine Welt als Bild.
[OHNE KARTE] DEIN REISE-ATLAS
Eine Weltkarte mit allen Ländern, in denen du fotografiert hast, mit Zahlen und Flaggen. Als Bild zum Teilen.

SUCHEN, WIE DU SPRICHST
Tippe „Hunde Italien 2023“, und Albumist zeigt dir die Fotos. Aus den Treffern wird auf Wunsch ein Album.

MEHR ALS REISEN
• Länder, auf Wunsch auch Städte
• Orte, an denen du oft bist. Den Namen gibst du selbst
• Screenshots nach Inhalt: Bestellungen, Tickets, Rezepte
• Dokumente wie Rechnungen und Kassenbons
• Themen wie Hunde, Strand oder Essen
• Monate und Jahre, wenn du magst

PRIVAT AUF DEINEM IPHONE
• Die ganze Analyse läuft auf deinem iPhone
• Kein Konto, kein Tracking, keine Werbung
• Nur für Ortsnamen fragt iOS bei Apple nach, mit dem Aufnahmeort und ohne Foto. Abschaltbar.
[KARTE] • Kartenbilder kommen von Apple, nur für die Gegend, die du ansiehst. Auch abschaltbar.
• Gemacht für VoiceOver, große Schrift, Dunkelmodus und „Bewegung reduzieren“

LÄUFT IM HINTERGRUND WEITER
Große Mediatheken brauchen Zeit. Du kannst Albumist verlassen: Solange iOS es erlaubt, sortiert es weiter und zeigt den Fortschritt auf dem Sperrbildschirm. Neue Fotos sortierst du später mit einem Tipp oder mit Siri.

EINMAL ZAHLEN, KEIN ABO
Die ersten 10 Alben sind kostenlos. Danach schaltest du Albumist einmal frei, ohne Abo.

Fragen oder Ideen? Schreib uns über die Support-Seite. Wir lesen jede Nachricht.
```

Prüfvermerke (vor dem Einreichen abhaken):
- [ ] Erster Absatz (sichtbar vor „mehr“) mit dem eingereichten Build gegenlesen.
- [ ] „Sprachsteuerung“ erst in die Zeile „Gemacht für …“, wenn der Test aus
      `BARRIEREFREIHEIT_ANGABEN.md` bestanden ist.
- [ ] Familienfreigabe ist heute **aus** (`App/StoreKit/Albumist.storekit`: `"familyShareable":
      false`). Wird sie eingeschaltet (in App Store Connect danach nicht mehr ausschaltbar), unter
      EINMAL ZAHLEN ergänzen: „Mit der Familienfreigabe für alle in deiner Familie.“
- [ ] „Hunde Italien 2023“ ist das Beispiel der App selbst (`SearchView.swift`), „Als Album
      anlegen“ der Knopf bei den Treffern. Vor dem Einreichen mit der Demo-Mediathek ausprobieren.
- [ ] Datumsbeispiel = Vorlage ab Werk (`NamingTemplate.tripDefault`, `NamingTests.swift` Z. 28).
- [ ] Siri: Kurzbefehl „Neue Fotos sortieren mit Albumist“ (`Shortcuts.swift`).

**Neuerungen (Version 1.0):**
> Das erste Albumist. Viel Freude mit deinen Reisen. Erzähl uns, was dir fehlt: Wir lesen jede Nachricht.

**In-App-Kauf** (`app.albumist.ios.unlock`, Nicht-Verbrauchsartikel):
- Anzeigename (max. 35): `Albumist freischalten` (21)
- Beschreibung (max. 55): `Unbegrenzt Alben anlegen. Einmal zahlen, kein Abo.` (50)

**Copyright:** `2026 [Name von Fuchs oder Firma]` (ohne ©, Apple setzt es selbst).
