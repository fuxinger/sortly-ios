# Barrierefreiheits-Angaben im App Store (Accessibility Nutrition Labels)

Stand 21.11.2026, geprüft am Code von `main` (1017fae). Für Fuchs, Schritt für Schritt.

## Das Wichtigste in drei Sätzen

1. Apple zeigt seit iOS 26 auf jeder Produktseite einen Kasten „Bedienungshilfen“. Steht dort
   nichts, heißt es „Der Entwickler hat noch keine Angaben gemacht“. Für eine App, die auf
   Featuring hofft, ist ein voller Kasten Pflicht.
2. **Veröffentlichen geht erst, wenn Albumist live im App Store ist** (Apple: „you can only
   publish support for devices that have a live version on the App Store“). Vorher kannst du die
   Antworten als Entwurf speichern. Plan: Entwurf jetzt oder kurz vor dem Einreichen, „Publish“ am
   Starttag.
3. Ein Haken heißt: Man kann **alle üblichen Aufgaben** der App nur mit dieser Hilfe erledigen.
   Bei Albumist sind das: einrichten, Zugriff erlauben, Analyse starten und pausieren, Vorschläge
   ansehen und ändern, Alben anlegen, rückgängig machen, Karte und Suche, Kauf, Einstellungen.
   Ist ein Fehler groß genug, gilt der Haken nicht (Apple: „If bugs are significant enough to
   change your answer … don't indicate support“).

## Wo du klickst

Wer: Kontoinhaber, Admin, App Manager oder Marketing.

1. [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **Albumist**.
2. Links in der Seitenleiste **App Accessibility** (deutsch: „App-Bedienungshilfen“).
3. **Get Started**. Ist noch keine Version live, die Geräte auswählen: nur **iPhone** (Albumist
   gibt es nur fürs iPhone, `TARGETED_DEVICE_FAMILY: "1"` in `App/project.yml`). **Save**.
4. **Add iPhone Support** → **Yes** („unterstützt mindestens eine Hilfe“) → **Next**.
5. Die Haken aus der Tabelle unten setzen → **Next**. Die Antworten liegen jetzt als **Entwurf**.
6. Optional **Add URL**: Link zu einer Seite „Bedienungshilfen“ auf der Albumist-Webseite (gibt
   es noch nicht; Vorschlag: kurzer Abschnitt auf der Support-Seite, siehe unten).
7. Am Starttag, sobald Albumist live ist: **App Accessibility** → **Publish**. Sichtbar für alle
   nach bis zu 24 Stunden.
8. Bei jedem Update: **Edit** neben iPhone → ändern → **Save** → **Publish**. Apple verlangt, die
   Angaben bei jedem Update neu zu prüfen.

## Was du ankreuzt

Legende: ✅ ankreuzen · 🔎 ankreuzen, wenn der kurze Test am iPhone (unten) klappt · ⬜ nicht ankreuzen

| Hilfe (Apple-Name) | Antwort | Beleg im Code und in den Tests |
|---|---|---|
| **VoiceOver** | 🔎 | Beschriftungen für Knöpfe und Bilder (38× `accessibilityLabel`, 39× `accessibilityElement`, 13× Kopfzeilen-Merkmal); jeder UI-Testlauf prüft mit Apples `performAccessibilityAudit` „fehlende oder nutzlose Beschreibung“ und schlägt fehl (`App/AlbumistUITests/AccessibilityUITests.swift`, Zeilen 8–20). Ansagen bei Fortschritt (`AccessibilityNotification`). Der Audit prüft Bildschirm für Bildschirm, nicht einen ganzen Ablauf mit Wischgesten, darum der kurze Test. |
| **Voice Control** (Sprachsteuerung) | 🔎 | Voice Control nutzt dieselben Beschriftungen; jeder Knopf hat einen sichtbaren oder vorgelesenen Namen (eigener Test: kein Knopf ohne Namen, kein Knopf heißt „chevron.right“). Eigene Sprachnamen (`accessibilityInputLabels`) gibt es keine; nötig nur, wenn ein Name lang oder unaussprechlich ist. Darum Test. |
| **Larger Text** (Größerer Text, mind. 200 %) | 🔎 | Dynamic Type überall (Systemschriften, 11× `@ScaledMetric`), eigene Anordnung bei den größten Stufen (16× `isAccessibilitySize`). UI-Test bei größter Schrift, dunkel, „Bewegung reduzieren“ (`test3_LargestTextDarkModeReduceMotion`) und Onboarding bei größter Schrift (`test1`); abgeschnittener Text schlägt fehl. Apples eigener Dynamic-Type-Audit läuft bewusst nicht (`AccessibilityUITests.swift` Z. 56). Feste Größen: Teilen-Bild und Flaggen im Atlas (`Atlas.swift`, 17 Stellen), Flagge in `CountryPhotosView.swift:75`, Symbole in `TripWorkshopView.swift:317` und `PlanReviewView.swift:514` (Schmuck, für VoiceOver ausgeblendet), Fortschrittsring. **Befund:** In der Sortier-Schau steht die Zahl der einsortierten Fotos fest in 56 pt (`SortingShow.swift:100`); sie wächst nicht mit. Vor dem Haken prüfen, ob sie bei größter Schrift woanders lesbar ist, sonst an den App-Strang. |
| **Dark Interface** (Dunkle Oberfläche) | ✅ | Albumist folgt dem Dunkelmodus von iOS (Entscheidung Fuchs 19.11.: kein eigener Schalter), eigene Farben mit Dunkel-Variante in `Theme.swift`; UI-Tests laufen hell und dunkel. Fotos selbst sind Inhalt und zählen nicht. |
| **Differentiate Without Color Alone** (Ohne Farbe unterscheidbar) | 🔎 | Zustände stehen als Text und Symbol da, nicht nur als Farbe (z. B. „Vorhandenes Album wird ergänzt“, „Neues Album“, `Presentation.swift`). Auf der Karte heißt „besucht“ Farbe, aber dieselbe Info steht in der Länderliste mit Zahlen. Test mit dem Graustufen-Filter. |
| **Sufficient Contrast** (Ausreichender Kontrast, 4,5:1 Text, 3:1 Bedienelemente) | 🔎 | UI-Test schlägt bei „Contrast failed“ fehl (Apples Audit), hell und dunkel, dazu ein eigener Test mit „Kontrast erhöhen“ und „Transparenz reduzieren“ (`test5_IncreasedContrastAndReducedTransparency`). Eigene Farben reagieren auf „Kontrast erhöhen“ (`colorSchemeContrast` in `Theme.swift`, `PhotoGlow.swift`). Offen: Apples Systemfarbe für Nebentext liegt hell bei 3,3:1 und wird im Test nur gemeldet (`AccessibilityUITests.swift` Z. 699–721). Apple prüft mit „Kontrast erhöhen“ an; dann wird diese Systemfarbe dunkler. Test 4 unten klärt es. |
| **Reduced Motion** (Bewegung reduzieren) | ✅ | Jede Dauer-Animation fragt die Einstellung ab (42 Stellen): Lichtband über dem Mosaik und auf der Analysekarte aus, Einblenden statt Federn und Vergrößern (`ScanShow.swift`, `AnalysisProgressCard.swift`, `SortingShow.swift`), Atlas ohne Aufbau-Animation. UI-Test läuft mit „Bewegung reduzieren“ an. |
| **Captions** (Untertitel) | ⬜ | Albumist hat keine eigenen Videos und keinen Ton. Eigene Videos des Nutzers sind seine Inhalte. Nicht ankreuzen. |
| **Audio Descriptions** (Audiobeschreibungen) | ⬜ | Wie oben: keine eigenen Videos. Nicht ankreuzen. |

**Ergebnis heute:** 2 sichere Haken, 5 nach einem kurzen Test, 2 bleiben leer (gehören nicht zu
Albumist). Klappen die Tests, sind es 7 von 7 möglichen.

## Wichtig: Karte, „Reise abspielen“ und neues Design kommen noch

Die Haken gelten für die Version, die live geht. Die neue Karte („Deine Welt“, Globus, „Reise
abspielen“) und das neue Design sind noch nicht in `main`. Bevor du „Publish“ drückst, muss für
sie dasselbe gelten. Das ist schon im Plan, hier als Abnahme-Liste:

- **Bewegung reduzieren:** Der Globus dreht sich nicht von selbst; „Reise abspielen“ zeigt statt
  Flug und Kamerafahrt eine ruhige Bilderfolge mit Überblenden (die Diashow-Variante aus dem
  Kartenkonzept). Apple nennt Drehen, Wirbel, Parallaxe und Tiefenunschärfe ausdrücklich als
  Auslöser.
- **VoiceOver:** Globus und Karte bekommen eine vorlesbare Zusammenfassung („32 Länder, zuletzt
  Island“) und die Länder- und Reiseliste als Weg ohne Karte; „Reise abspielen“ hat Pause und
  Weiter als Knöpfe mit Namen.
- **Ohne Farbe:** Reiseroute und besuchte Länder nicht nur über Gold und Farbe; Liste oder Symbol
  daneben.
- **Kontrast und größte Schrift:** Text auf Fotos und auf dem Globus mit Hintergrund-Schleier;
  die neuen Bildschirme kommen in `AccessibilityUITests` dazu (das gilt schon als Regel für jede
  neue Seite).

## Kurzer Test am iPhone (etwa 30 Minuten, mit der letzten TestFlight-Version)

So werden aus den 🔎 echte Haken. Was nicht klappt, schickst du mir als Bildschirmfoto, und es
wird ein Befund mit Test.

1. **VoiceOver** (Einstellungen › Bedienungshilfen › VoiceOver, oder dreimal Seitentaste, wenn so
   eingestellt): Albumist löschen und neu laden, dann nur mit Wischen und Doppeltippen:
   Einrichten → Zugriff erlauben → Analyse starten → pausieren und weiter → einen Vorschlag öffnen
   und ein Foto herausnehmen → Alben anlegen → rückgängig machen → Atlas öffnen → in der Suche
   „Rom“ suchen und ein Foto groß ansehen → eine Reise teilen und wieder verbinden → einen
   Albumnamen ändern → Einstellungen › Vollversion: Kaufblatt öffnen (im TestFlight kostenlos)
   und „Wiederherstellen“ → Beispielfotos anlegen und wieder entfernen. Klappt jeder Schritt und wird alles verständlich
   vorgelesen: Haken.
2. **Voice Control** (Bedienungshilfen › Sprachsteuerung): erst unter Sprachsteuerung › Befehle
   nachsehen, wie die deutschen Befehle heißen (etwa „Namen einblenden“, „Tippe …“), dann
   denselben Weg wie bei VoiceOver per Sprache. Ein Feld per Sprache
   ausfüllen (z. B. Namen für einen häufigen Ort diktieren). Klappt alles: Haken.
3. **Ohne Farbe** (Bedienungshilfen › Anzeige & Textgröße › Farbfilter › Graustufen): Übersicht,
   Vorschläge, Vorschau, Atlas ansehen. Ist überall klar, was neu, ergänzt, fertig oder besucht
   ist: Haken.
4. **Größte Schrift und Kontrast** (Anzeige & Textgröße › Größerer Text ganz nach rechts, dazu
   „Kontrast erhöhen“ an): denselben Weg kurz abgehen, besonders das Anlegen der Alben (Zahl in
   der Sortier-Schau). Alles lesbar, nichts überlappt: beide Haken.

## Vorschlag für die Bedienungshilfen-Seite (optional, kurz)

Für die Support-Seite der Webseite, Abschnitt „Bedienungshilfen“:

> Albumist unterstützt VoiceOver, Sprachsteuerung, große Schrift bis zur größten Stufe, den
> Dunkelmodus, „Kontrast erhöhen“, „Transparenz reduzieren“ und „Bewegung reduzieren“. Jede
> Version wird vor dem Erscheinen automatisch mit Apples Barrierefreiheits-Prüfung getestet.
> Fehlt dir etwas? Schreib uns: [Support-Adresse].

Erst veröffentlichen, wenn die vier Tests oben gemacht sind.

Quellen: Apple, App Store Connect Hilfe, „Overview of Accessibility Nutrition Labels“, „Manage
Accessibility Nutrition Labels“ und die Kriterienseiten je Hilfe
(developer.apple.com/help/app-store-connect/manage-app-accessibility/…), gelesen am 21.11.2026.
