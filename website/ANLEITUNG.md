# Website: Datenschutz, Support und Startseite

Hier liegt die kleine Website zur App. Apple verlangt im App Store Connect
eine **Datenschutz-URL** und eine **Support-URL**. Beide sind hier dabei,
auf Deutsch und Englisch, dazu eine Startseite und ein Impressum.

Die Website ist kostenlos. Sie läuft über **GitHub Pages** direkt aus diesem
Repository. Du brauchst dafür keinen Mac und kein Programm, nur den Browser.

## Was drin ist

| Seite | Deutsch | Englisch |
|---|---|---|
| Startseite | `de/index.html` | `en/index.html` |
| Hilfe & Kontakt (Support-URL) | `de/support.html` | `en/support.html` |
| Datenschutz (Datenschutz-URL) | `de/datenschutz.html` | `en/privacy.html` |
| Impressum | `de/impressum.html` | `en/imprint.html` |

Die Hauptadresse leitet automatisch auf Deutsch oder Englisch weiter,
je nach Sprache des Browsers.

## In 3 Schritten online

**1. Deine Daten eintragen (einmal)**
Öffne auf github.com die Datei `website/EINSTELLUNGEN.txt`, klicke oben
rechts auf den Stift und ersetze alles in `[eckigen Klammern]`: Name,
Anschrift, E-Mail. Danach unten auf **Commit changes**.
Deine Daten stehen nur in dieser einen Datei. Sie werden beim
Veröffentlichen automatisch in alle Seiten eingesetzt.

**2. GitHub Pages einschalten (einmal)**
Im Repository: **Settings › Pages**. Bei **Source** wählst du
**GitHub Actions**. Mehr ist nicht nötig.

**3. Fertig**
Sobald die Website-Dateien auf dem Branch `main` liegen, baut GitHub die
Seite automatisch (zu sehen unter **Actions › Website**, dauert etwa
1 Minute). Danach ist sie hier erreichbar:

- Start: `https://fuxinger.github.io/sortly-ios/`
- Support-URL: `https://fuxinger.github.io/sortly-ios/de/support.html`
- Datenschutz-URL: `https://fuxinger.github.io/sortly-ios/de/datenschutz.html`
  (für die englische App-Store-Seite: `.../en/privacy.html`)

Diese Adressen trägst du in **App Store Connect** ein: Datenschutz-URL
unter *App-Datenschutz*, Support-URL und Marketing-URL bei der jeweiligen
Sprache der App-Version.

Jede spätere Änderung in `website/` wird automatisch neu veröffentlicht.

## App-Namen ändern

Der Name „SORTLY“ ist im App Store schon vergeben. Wenn der neue Name
feststeht, änderst du nur die Zeile `APP_NAME=` in `EINSTELLUNGEN.txt`.
Alle Seiten übernehmen ihn.

Tipp: Die Adresse enthält den Namen des Repositorys (`sortly-ios`).
Wenn dich das stört, gibt es zwei Wege:
- Repository umbenennen (Settings › General). Die Adresse ändert sich mit.
- Eine eigene Domain kaufen (etwa 1 € im Monat) und unter Settings › Pages
  bei *Custom domain* eintragen.

## Wichtig zu wissen

- **Deine Anschrift wird öffentlich.** Das Impressum ist in Deutschland
  Pflicht, sobald du die App verkaufst. Ein Postfach reicht nicht. Wer
  seine Wohnadresse nicht zeigen will, kann eine „Impressum-Adresse“ bei
  einem Dienstleister mieten (einige Euro im Monat).
- **Händler-Angaben bei Apple:** Apple fragt in App Store Connect nach
  deinem Status als Händler (EU-Gesetz über digitale Dienste). Wer eine
  App verkauft, ist in der Regel Händler. Dann zeigt Apple deine Anschrift,
  Telefonnummer und E-Mail auf der App-Store-Seite an. Die Daten müssen zu
  denen im Impressum passen.
- **Steuer:** Gewerbe anmelden und das Finanzamt informieren, bevor die
  ersten Verkäufe kommen. Als Kleinunternehmer brauchst du keine
  Umsatzsteuer-ID; dann bleibt `VAT_ID=` leer.
- **Datenschutz aktuell halten:** Wenn die App neue Funktionen bekommt, die
  Daten senden (zum Beispiel Gesichter, Widgets mit Online-Daten), muss die
  Datenschutzerklärung angepasst werden. Sag einfach Bescheid.
- Die Texte sind sorgfältig nach den Fakten der App geschrieben, ersetzen
  aber keine Rechtsberatung. Wer ganz sicher gehen will, lässt sie einmal
  prüfen oder vergleicht mit einem Generator wie e-recht24.de.

## Für Technik-Interessierte

- `pages/de/…` und `pages/en/…`: die Inhalte der Seiten
- `layout.html`: Kopf- und Fußzeile für alle Seiten
- `assets/style.css`: Aussehen (Farbe Petrol `#0a6e7a`, heller und dunkler Modus)
- `build.py`: setzt alles zusammen. Lokal testen mit `python3 website/build.py`,
  Ergebnis liegt dann in `_site/`.
- `.github/workflows/pages.yml`: veröffentlicht die Seite automatisch.

Die Website setzt keine Cookies und lädt nichts von fremden Servern.
Darum braucht sie auch keinen Cookie-Banner.
