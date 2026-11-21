# Featuring-Bewerbung (App Store Connect → Nominierungen)

Stand 21.11.2026. Ersetzt den Entwurf vom 14.11. und den Entwurf in
`/mnt/project-files/sortly-launch/Featuring-Bewerbung-Entwurf.md`.

## Was Apple sagt (gelesen 21.11.2026)

- Wo: App Store Connect → Albumist → **Featuring** → **Nominations** → „+“. Rollen: Kontoinhaber,
  Admin, App Manager, Marketing.
- Typen: **App Launch**, App Enhancements, New Content. Typ ist nach dem Absenden nicht änderbar.
- Wann: mindestens 3 Wochen vorher (Hilfeseite), für mehr Chancen bis zu 3 Monate. Für eine
  „Story“ (Artikel im Heute-Tab) braucht die Redaktion etwa 8 Wochen. Das Datum lässt sich später
  anpassen, also **früh einreichen und Datum nachziehen**.
- Die Redaktion liest jede Woche. Wichtigster Satz aus Apples Gespräch mit Entwicklern: **„We don't
  feature games that we haven't played.“** Darum gehört der öffentliche TestFlight-Link hinein;
  Apple erlaubt ihn ausdrücklich unter „Supplemental Materials“ (bis 5 Links).
- Worauf Apple achtet: Bedienung, Gestaltung, Neuheit, Einzigartigkeit, Barrierefreiheit,
  Sprachen und die Produktseite (Bilder, Video, Texte, Bewertungen). Keine Checkliste.
- „Helpful Details“ ist laut Apple der Platz für Barrierefreiheit, Inklusion, Priorität und
  „unique aspects of your app or team“: hier gehört der persönliche Satz hin.
- Apple nennt keine Zeichengrenzen; der alte Entwurf hielt sich an 60 / 1.000 / 500 Zeichen. Der
  Text unten bleibt darunter, damit er sicher passt.

## Haltung

Albumist ist eine **Ergänzung zur Fotos-App**: Es füllt Apples Fotos-App mit echten Alben. Keine Liste von Apple-Techniken (bewegt keine Redaktion), sondern was Menschen davon haben. Das ist
genau die Art App, die Apples Redaktion gern zeigt (macht ein Apple-Erlebnis besser, nutzt
Apple-Technik, schützt die Privatsphäre). Kein Wort von Konkurrenz zu Apple Fotos.

## Felder

**Nomination Name** (≤ 60)
```
Albumist: every trip becomes a real album in Photos
```
(51)

**Type:** App Launch

**Publish Date:** Starttag (sobald fest; bis dahin realistisches Datum, später anpassen)

**Description** (≤ 1.000)
```
Thousands of photos and not a single album: that is most people's library. Albumist fixes it in an evening, without a single photo leaving the iPhone. It finds your trips, even from a decade ago, and turns each into a real album in Apple Photos, so they appear on Mac and iPad too. Countries, favourite places, screenshots and documents follow.

It is built on trust. Before anything changes, people see every album with its photos and can take photos out or rename trips. Everything can be undone, existing albums are completed instead of duplicated, and people's photos are never edited or deleted.

"Your World" shows a globe of everywhere you have taken photos and replays a trip stop by stop with your best shots. [MAP]

It feels like part of iOS: ask Siri to sort new photos, find a country in Spotlight, search "barbecue at grandma's last summer" with on-device Apple Intelligence, and follow progress on the Lock Screen. No account, no tracking, no ads, no subscription.
```
(978 mit dem Kartenabsatz; ohne Karte den dritten Absatz streichen.)

**Relevant Countries or Regions:** alle (vorausgefüllt lassen)
**Localizations:** German, English
**Platforms:** iOS (iPhone)
**In-App Events:** zum Start keins; für Januar siehe unten.

**Supplemental Materials** (≤ 5 Links), in dieser Reihenfolge:
1. Öffentlicher TestFlight-Link (Kauf ist dort kostenlos; die Redaktion kann alles ausprobieren). Ist TestFlight noch nicht öffentlich, das Video an erste Stelle.
2. Vorschauvideo, 30 Sekunden (siehe `SCREENSHOTS_VIDEO_PLAN.md`), als nicht gelisteter Link
3. Webseite mit Datenschutz und Bedienungshilfen
4. Pressemappe (nach der Überarbeitung, nicht die vom 14.11.)
5. frei lassen oder: Ordner mit Bildschirmfotos und dem Teilen-Bild „Deine Welt“

**Helpful Details** (≤ 500)
```
[PERSÖNLICHER SATZ] Privacy is the core: photos and analysis never leave the iPhone. Before every TestFlight build it runs a stress test with a simulated library of 10,000 photos and Apple's accessibility audit at the largest text size, in dark mode and with Reduce Motion.
```
(Ohne den persönlichen Satz 254 Zeichen; Platz für gut 240 Zeichen Geschichte.)

## Der persönliche Satz: drei Vorschläge (Fuchs wählt)

Nur aus dem, was wir wissen; **Fuchs prüft, ob jede Zahl stimmt** (die 14.000 stammt aus seinem
Gerätetest vom 15.11.: 14.356 Fotos).

- **A – die Mediathek:** „I built Albumist for my own library: 14,000 photos, years of trips, and not a single album.“ (91)
  *DE: Ich habe Albumist für meine eigene Mediathek gebaut: 14.000 Fotos, Jahre voller Reisen und kein einziges Album.*
- **B – die Herkunft:** „I'm an independent developer from Zwiesel in the Bavarian Forest. Albumist started with my own 14,000 unsorted photos.“ (118)
  *DE: Ich bin ein unabhängiger Entwickler aus Zwiesel im Bayerischen Wald. Albumist begann mit meinen eigenen 14.000 unsortierten Fotos.*
- **C – der Grund:** „I didn't want another app to look at my photos in. I wanted my trips as real albums in Photos, so I built Albumist.“ (115)
  *DE: Ich wollte keine weitere App, um Fotos anzusehen. Ich wollte meine Reisen als echte Alben in Fotos, also habe ich Albumist gebaut.*

Empfehlung: **B + C zusammen** (234 Zeichen; zusammen 489): Herkunft macht
den Einzelentwickler greifbar, der Grund sagt in einem Satz, warum Albumist zur Fotos-App passt.

## Weitere Nominierungen (Plan)

| Wann | Typ | Thema |
|---|---|---|
| Sofort, wenn TestFlight öffentlich und Startdatum grob fest | App Launch | dieser Text |
| Ab dem ersten Jahreswechsel nach dem Start (Events brauchen eine App, die schon live ist) | In-App Event „Ordnung fürs neue Jahr“ (Badge: Special Event) + Nominierung New Content | Das alte Jahr in Alben, Rückblick mit „Deine Welt“ |
| Vor den Sommerferien (Mai) | App Enhancements | erstes großes Update (z. B. Widget, Neue-Reise-Mitteilung) |

## Vor dem Absenden prüfen

- [ ] Jede Aussage stimmt im eingereichten Build (Karte, „Reise abspielen“, Sperrbildschirm,
      Spotlight, Voice Control nach dem Test aus `BARRIEREFREIHEIT_ANGABEN.md`).
- [ ] Öffentlicher TestFlight-Link funktioniert ohne Einladung.
- [ ] Produktseite fertig (Bilder, Video), denn die Redaktion schaut sie an.
- [ ] Barrierefreiheits-Angaben als Entwurf gespeichert.
- [ ] Typ und Datum noch einmal ansehen; Typ ist danach fest.

Quellen: developer.apple.com/app-store/getting-featured, App Store Connect Hilfe „Nominate your app
for featuring“, „Meet with Apple“ Sitzung 249 (gelesen 21.11.2026).
