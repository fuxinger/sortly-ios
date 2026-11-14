# Albumist auf dem eigenen iPhone: TestFlight einrichten

Mit TestFlight läuft Albumist als echte App auf dem iPhone, mit der echten Mediathek und ohne
Zeitlimit. Jede neue Version kommt danach von selbst: GitHub baut sie, signiert sie und lädt sie
zu TestFlight hoch (`.github/workflows/testflight.yml`). Alles hier geht vom Windows-PC im
Browser oder vom iPhone aus; ein Mac ist nicht nötig.

## 1. Apple Developer Program beitreten (einmalig, 99 € im Jahr)

- Am einfachsten auf dem iPhone mit der App **Apple Developer** (App Store): Konto > Jetzt
  registrieren. Alternativ im Browser: https://developer.apple.com/programs/enroll/
- Als **Einzelperson** anmelden. Dann steht dein Name im App Store als Anbieter. Für einen
  Firmennamen braucht Apple eine D-U-N-S-Nummer, das dauert länger.
- Apple prüft deinen Ausweis. Die Freischaltung dauert meist ein bis zwei Tage.

## 2. Bundle-ID und App anlegen

1. https://developer.apple.com/account/resources/identifiers/list öffnen, **+** > App IDs > App.
   - Beschreibung: `Albumist`
   - Bundle ID: **Explicit**, `app.albumist.ios`
   - Keine besonderen Funktionen ankreuzen. Speichern.
2. https://appstoreconnect.apple.com > Apps > **+** > Neue App.
   - Plattform iOS, Name `Albumist`, Primärsprache Deutsch,
     Bundle-ID `app.albumist.ios`, SKU `albumist-ios`, Zugriff: Vollzugriff.

## 3. Schlüssel für GitHub erzeugen

1. App Store Connect > Benutzer und Zugriff > **Integrationen** > App Store Connect API >
   Team-Schlüssel > **+**.
2. Name `GitHub`, Zugriff **Admin** (nur damit kann GitHub das Verteilungszertifikat in der
   Cloud verwenden).
3. **Schlüssel laden** (`AuthKey_XXXXXXXXXX.p8`). Das geht nur ein einziges Mal; Datei gut
   aufheben.
4. Notieren: **Schlüssel-ID** (in der Tabelle) und **Issuer-ID** (über der Tabelle).
5. Team-ID: https://developer.apple.com/account > Mitgliedschaft > **Team-ID** (10 Zeichen).

## 4. Vier Secrets in GitHub eintragen

https://github.com/fuxinger/sortly-ios/settings/secrets/actions > **New repository secret**:

| Name | Inhalt |
|---|---|
| `ASC_KEY_ID` | Schlüssel-ID |
| `ASC_ISSUER_ID` | Issuer-ID |
| `ASC_KEY_P8` | Inhalt der .p8-Datei (mit Editor öffnen, alles kopieren, auch die Zeilen BEGIN und END) |
| `APPLE_TEAM_ID` | Team-ID |

Danach baut GitHub bei jeder neuen Version automatisch einen TestFlight-Build.

## 5. Auf dem iPhone installieren

1. App Store Connect > Albumist > **TestFlight** > Interne Tests > Gruppe anlegen (zum Beispiel
   „Ich“) und dich selbst hinzufügen.
2. App **TestFlight** aus dem App Store laden und mit derselben Apple-ID anmelden.
3. Albumist erscheint dort, sobald Apple den ersten Build verarbeitet hat (meist 5 bis
   30 Minuten nach dem Hochladen).

Käufe in TestFlight kosten nichts (Testumgebung von Apple). Damit „Freischalten“ funktioniert,
braucht es in App Store Connect einen In-App-Kauf vom Typ „Nicht verbrauchbar“ mit der
Produkt-ID `app.albumist.ios.unlock`.

## Gut zu wissen

- Interne Tester (bis 100 Personen aus dem eigenen Team) brauchen keine Prüfung durch Apple.
  Externe Tester per Link brauchen eine kurze Beta-Prüfung beim ersten Build.
- Ein TestFlight-Build läuft 90 Tage.
- Die Bundle-ID `app.albumist.ios` lässt sich nach dem ersten Hochladen nicht mehr ändern.
