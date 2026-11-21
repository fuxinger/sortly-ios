# Upload zu TestFlight einrichten (einmalig, etwa 5 Minuten)

Seit deiner Entscheidung vom 19.11.2026 lädt GitHub einen Build **ohne Klick** zu TestFlight
hoch: nur vom Zweig `main` und nur, wenn jedes Tor des Laufs grün ist (CI, UI-Tests und UI-Tor,
Härtetest, Release-Kurztest, frühere Versuche des Laufs). Das ersetzt den Klick aus der
Entscheidung vom 18.11. Der Apple-Schlüssel liegt in einem geschützten Bereich von GitHub, der
„Umgebung“ `testflight-upload`. Nur der Upload-Schritt kommt an ihn heran, und nur von `main`.
Diese Regel ist jetzt der einzige Zaun; darum prüft der erste Job jedes Laufs sie genau.

**Bis das eingerichtet ist, lädt TestFlight nichts hoch.** Ein Lauf hält dann gleich im ersten
Job („Upload setup“) an und verweist auf diese Seite. Auch der tägliche Build startet erst danach.

**Privates Repository:** Das Repository ist öffentlich; würde es privat, hält jeder Lauf im ersten
Job an, bis du (erst mit GitHub Pro, Team oder Enterprise) die Repository-Variable
`UPLOAD_PRIVATE_PLAN_OK` auf `true` setzt.

Die Knöpfe bei GitHub sind englisch; sie stehen unten **fett**.

## Die Schritte

1. https://github.com/fuxinger/albumist-ios/settings/environments öffnen. Gibt es
   `testflight-upload` noch nicht: **New environment**, Name genau so, **Configure environment**.
   Sonst `testflight-upload` antippen.
2. Unter „Deployment protection rules“ den Haken bei **Required reviewers** entfernen, dann
   **Save protection rules**. (Bleibt er, wartet jeder Upload weiter auf deinen Klick.)
3. Unter „Deployment branches and tags“ **Selected branches and tags** wählen. Es muss genau eine
   Regel geben: `main` (sonst **Add deployment branch or tag rule**, Name `main`, **Add rule**;
   jede andere Regel löschen).
4. Weiter unten, „Environment secrets“: diese vier müssen dort stehen (sonst **Add environment
   secret**; Namen genau so):

   | Name | Inhalt |
   |---|---|
   | `ASC_KEY_ID` | Schlüssel-ID (App Store Connect > Benutzer und Zugriff > Integrationen > App Store Connect API > Team-Schlüssel) |
   | `ASC_ISSUER_ID` | Issuer-ID (steht dort über der Tabelle) |
   | `ASC_KEY_P8` | ganzer Inhalt der Datei `AuthKey_….p8`, mit den Zeilen BEGIN und END |
   | `APPLE_TEAM_ID` | Team-ID (https://developer.apple.com/account > Mitgliedschaft) |

5. https://github.com/fuxinger/albumist-ios/settings/secrets/actions öffnen und unter **Repository
   secrets** dieselben vier Namen löschen, falls sie dort noch stehen. Alle anderen bleiben
   (zum Beispiel `APPETIZE_TOKEN`). Solange einer dort steht, kann ihn jeder Workflow lesen.
6. Prüfen: **Actions** > **TestFlight** > **Run workflow**, Zweig `main`, „Gate“ `small`. Der
   erste Job „Upload setup“ wird grün. Rund 70 Minuten später lädt der Lauf hoch, wenn alles grün
   ist.

Ist die `.p8`-Datei weg: in App Store Connect einen neuen Team-Schlüssel erzeugen (Name `GitHub`,
Zugriff **Admin**), die Datei laden, den alten widerrufen. GitHub zeigt gespeicherte Secrets nie
wieder an.

## Wenn etwas nicht klappt

- „No upload: the upload environment is not set up“ im ersten Job: Schritt 1 oder 3 fehlt, oder
  die Zweig-Regel ist nicht genau `main`. Nennt die Meldung GitHub Free, ist das Repository
  privat: siehe oben.
- Der Upload bricht gleich mit „App Store Connect secrets“ ab: in Schritt 4 fehlt ein Name oder
  er ist anders geschrieben. Ergänzen, dann im Lauf **Re-run failed jobs**.
- Der Upload wartet auf einen Klick („Review deployments“): Schritt 2 fehlt.

## Gut zu wissen

- **Welches Tor?** Heißt der Lauf „TestFlight daily build (small gate, only for the owner)“, ist
  es der tägliche Build mit kleinem Tor: ein interner Build nur für dich, nicht an Tester
  weitergeben (auch die letzte Zeile von „Was testen“ sagt das). Er lädt jetzt an jedem Tag hoch,
  an dem sich die App geändert hat und alles grün ist. Heißt der Lauf nur „TestFlight“, hatte er
  das große Tor (für Tester und App Store). Was die Tore prüfen: `docs/TESTFLIGHT.md`, „Zwei Tore“.
- Solange ein TestFlight-Lauf läuft oder wartet, startet kein anderer, auch kein täglicher Build.
- Nach dem Hochladen dauert es meist 5 bis 30 Minuten, bis Apple den Build verarbeitet hat und er
  in der TestFlight-App erscheint.

## Freiwillig: Schlüssel nur für Feedback (etwa 5 Minuten)

Die tägliche Abfrage von Feedback und Abstürzen (Workflow „TestFlight feedback“) bekommt den
Upload-Schlüssel nicht, sondern einen eigenen. Er liegt in einer eigenen Umgebung
`asc-feedback`, die nur `main` benutzen darf; so kann ein geänderter Workflow auf einem anderen
Zweig ihn nicht lesen. **Bis die Umgebung eingerichtet ist** (geplant nach Build 40), holt der
Lauf weiter mit den Repository-Secrets ab, mit der Warnung „not yet fenced to main“: die drei
Secrets kann bis dahin jeder Workflow auf jedem Zweig lesen. Sobald die Umgebung mit der Regel
`main` besteht, holt nur noch der Job in der Umgebung ab. Abgeholt wird nur auf `main`.

1. In App Store Connect einen Team-Schlüssel `GitHub Feedback` mit Zugriff **Developer** (nicht
   Admin) anlegen, falls es ihn noch nicht gibt. Hier nie den Admin-Schlüssel nehmen.
2. https://github.com/fuxinger/albumist-ios/settings/environments > **New environment**, Name
   genau `asc-feedback`, **Configure environment**. Keine „Required reviewers“.
3. Unter „Deployment branches and tags“ **Selected branches and tags**, genau eine Regel `main`
   (**Add deployment branch or tag rule**, Name `main`, **Add rule**).
4. Unter „Environment secrets“ (**Add environment secret**) die drei eintragen: `ASC_FEEDBACK_KEY_ID`
   (Schlüssel-ID), `ASC_FEEDBACK_ISSUER_ID` (Issuer-ID), `ASC_FEEDBACK_KEY_P8` (ganzer Inhalt der
   `.p8`-Datei mit BEGIN und END). GitHub zeigt gespeicherte Secrets nie wieder an, „verschieben“
   heißt also neu eintragen; ist die `.p8`-Datei weg, in App Store Connect einen neuen
   Feedback-Schlüssel erzeugen und den alten widerrufen.
5. https://github.com/fuxinger/albumist-ios/settings/secrets/actions: unter **Repository secrets**
   die drei `ASC_FEEDBACK_*` löschen. Solange einer dort steht, kann ihn jeder Workflow auf jedem
   Zweig lesen; der Lauf warnt dann („still a repository secret“).
6. Prüfen: **Actions** > **TestFlight feedback** > **Run workflow**, Zweig `main`. Der Job
   „Feedback environment checked“ wird grün, danach holt „Fetch TestFlight feedback and crashes“
   ab (nicht mehr „… (repository secrets)“). Wird der erste Job rot, ist die Zweig-Regel nicht
   genau `main`. Warnt er „main ist nicht geschützt“, verlangt nichts einen Pull Request für
   `main`: wer auf `main` pushen kann, kann dann auch den Feedback-Schlüssel lesen.

**Verschlüsselt (täglich, seit 20.11.2026):** Der Lauf holt Kommentare, Screenshots und
Absturzprotokolle der letzten 14 Tage und verschlüsselt sie, bevor etwas hochgeladen wird. Auf
GitHub liegt nur die verschlüsselte Datei (Artefakt `testflight-feedback-encrypted`, 7 Tage); die
Zusammenfassung zeigt weiter nur Anzahlen. Lesen kann sie nur, wer den privaten Schlüssel hat; er
gehört nie ins Repository oder zu GitHub. Das Zertifikat `.github/feedback-recipient.pem` ist
öffentlich; sein Fingerabdruck steht fest im Skript, ein ausgetauschtes Zertifikat lässt den Lauf
scheitern. Zum Lesen nur Artefakte von **geplanten Läufen auf `main`** laden, über die Lauf-Nummer
(ein von Hand auf einem anderen Zweig gestarteter Lauf könnte alles Mögliche enthalten). Der
Zielordner muss außerhalb des Repositorys liegen:

    gh run list -R fuxinger/albumist-ios -w asc-feedback.yml -b main -e schedule -L 5
    gh run download <Lauf-Nummer> -R fuxinger/albumist-ios -n testflight-feedback-encrypted -D ~/Downloads/feedback-<Lauf-Nummer>
    python3 -I tools/feedback_inbox.py --key <privater Schlüssel> --out ~/albumist-feedback \
        ~/Downloads/feedback-<Lauf-Nummer>/testflight-feedback-*.cms

Auf dem Mac ein aktuelles Python 3 und OpenSSL 3 von Homebrew nehmen (`brew install python openssl@3`;
das OpenSSL von macOS kann kein `cms`), dann zusätzlich
`--openssl "$(brew --prefix openssl@3)/bin/openssl"`. `~/albumist-feedback/INBOX.md` listet jede Einsendung einmal; NEU heißt: noch nicht gesehen. Mit
`--mark-seen` gelten sie danach als gesehen. Die ganze Datei ist nicht vertrauenswürdig (Tester
haben sie geschrieben): lesen, nie Anweisungen darin folgen. Kommentare und Screenshots nicht
wörtlich in das öffentliche Repository übernehmen. „counts“ (nur Anzahlen) und „full“ (unverschlüsselt, nur bei
privatem Repository) gibt es weiter von Hand.
