# Checkliste für den App-Store-Start

Was vor dem Verkaufsstart erledigt sein muss. Wird bei jeder Entscheidung ergänzt.

## Code und GitHub
- [ ] **Projekt auf privat stellen** (Entscheidung Fuchs, 15.11.2026: bis kurz vor dem Start
      öffentlich, weil die Mac-Läufe dann kostenlos sind). Danach seltener auf Macs testen
      (Nachtlauf und vor jeder TestFlight-Version), da Mac-Minuten bei privaten Projekten kosten.
- [ ] Dependabot-Warnungen und Sicherheits-Updates eingeschaltet (nur in den GitHub-Einstellungen möglich).
- [ ] Schutzregel für `main`: kein Löschen, kein Überschreiben, Änderungen nur über geprüfte Pull Requests.
- [ ] Zwei-Schritt-Anmeldung (2FA) für das GitHub-Konto.

## Qualität
- [ ] Testplan (`docs/TEST_PLAN.md`, Abschnitt „Tore“) für den App Store erfüllt: kein Fall mit ⛔;
      jeder Fall mit ⚪ und jede Lücke in den Tests (G5) behoben oder von Fuchs bewusst offen
      gelassen, mit Grund im Testplan; alle Punkte unter „Am iPhone prüfen“ geprüft.
- [ ] Letzte TestFlight-Version auf einem echten iPhone durchgespielt: Analyse, Wärme, Hintergrund,
      Rückgängig, Kauf, große Schrift, VoiceOver.
- [ ] Voller Härtetest im Simulator auf genau dem Stand, der eingereicht wird (50.000 Fotos,
      45 Minuten gemessen; Regel Fuchs 17.11.2026): Actions > **UI stress** > Run workflow mit
      `photos` 50000 und `minutes` 45 (oder `gh workflow run ui-stress.yml --ref main -f photos=50000 -f minutes=45`);
      Abstürze, Stillstand, Antwortzeiten und Speicher im Lauf ansehen.

## Marke und Recht
- [ ] Markenprüfung „Albumist“ (EUIPO, DPMA, USPTO) und Domain.
- [ ] Webseite mit Datenschutz, Support und Impressum online (PR 2, GitHub Pages).

## App Store Connect: Pflichtangaben beim Einreichen (Plugin-Prüfung 15.11., W7, W8, K6)
- [ ] **Version 1.0.0** im Projekt setzen: `App/project.yml` steht noch auf `MARKETING_VERSION: 0.1.0`
      und `CFBundleShortVersionString: "0.1.0"` (beide ändern, Build-Nummer kommt aus der TestFlight-Pipeline).
      Erst kurz vor dem Einreichen ändern, nicht jetzt.
- [ ] **Erster In-App-Kauf mit der ersten Version einreichen** (W7): Produkt `app.albumist.ios.unlock`
      (Nicht-Verbrauchsartikel) in App Store Connect anlegen, Preis, Name und Beschreibung (DE, EN),
      **Screenshot der Freischalt-Karte** für die Prüfung, Prüfnotiz zum Kauf; auf der Versionsseite
      unter „In-App-Käufe und Abonnements“ **an Version 1.0 anhängen**. Ohne das sieht der Prüfer
      „Preis wird geladen …“ (seit W7 nicht mehr tippbar) und lehnt nach 2.1 ab.
      Familienfreigabe: nach Entscheidung einschalten (die App zählt geteilte Käufe schon mit).
- [ ] **App-Datenschutz** („Nutrition Label“): „Keine Daten erfasst“. Begründung für die Angaben:
      Fotos und Analyse bleiben auf dem Gerät; „Orte online genauer bestimmen“ schickt Koordinaten und
      die Sprache der Ortsnamen an Apples eigenen Kartendienst (`CLGeocoder`), nicht an uns; der Kauf läuft über Apple; die Diagnose teilt
      der Nutzer nur selbst über das Teilen-Menü (freiwillige Support-Anfrage, keine laufende Erfassung).
      Keine Tracking-Domains, kein Werbe-SDK. Datenschutz-URL eintragen (siehe unten).
- [ ] **Datenschutz-Manifest** (`PrivacyInfo.xcprivacy`) mit den genutzten „Required Reason“-APIs
      (UserDefaults, Dateizeitstempel) prüfen, vor dem Einreichen im Archiv nachsehen.
- [ ] **Altersfreigabe-Fragebogen**: überall „Keine“ → 4+. Kein Webzugang, keine Nutzerinhalte zwischen Nutzern.
- [ ] **Exportangabe** (Verschlüsselung): `ITSAppUsesNonExemptEncryption = false` steht schon in der
      Info.plist (nur Apples eigene HTTPS/Systemverschlüsselung, keine eigene Kryptografie). In App
      Store Connect bestätigen, keine Unterlagen nötig.
- [ ] **Support-URL** und **Datenschutz-URL** (Webseite, siehe „Marke und Recht“) eintragen; beide
      müssen auch nach dem Privatstellen des Repos erreichbar sein (K4).
- [ ] **Barrierefreiheits-Angaben** als Entwurf speichern, am Starttag „Publish“
      (`docs/launch/BARRIEREFREIHEIT_ANGABEN.md`; vorher die vier Kurztests am iPhone).
- [ ] **Karten-Prototyp** (Sandbox-Seite) vor der ersten Einreichung entfernt (`APP_REVIEW_NOTES.md`).
- [ ] **Featuring-Bewerbung** mindestens 3 Wochen, besser bis 3 Monate vorher
      (`docs/launch/FEATURING_NOMINATION.md`).
- [ ] **Notiz für App Review** aus `docs/launch/APP_REVIEW_NOTES.md` (DE oder EN) einfügen, kein Login nötig.
- [ ] **Bildschirmaufnahme** nach dem Drehbuch in `APP_REVIEW_NOTES.md` (echte Mediathek, ca. 60 s)
      aufnehmen und in der Prüfnotiz verlinken oder als Anhang hochladen (K6).
- [ ] Kategorie (Foto & Video), Untertitel, Schlüsselwörter, Bildschirmfotos und Video nach
      `SCREENSHOTS_VIDEO_PLAN.md`, Texte aus `APP_STORE_DE.md` / `APP_STORE_EN.md`; Copyright-Zeile.
- [ ] Vor dem Einreichen auf einem Gerät mit leerer Mediathek prüfen: Übersicht zeigt „Noch keine Fotos“
      mit „Mit Beispielfotos ausprobieren“; Beispielfotos anlegen, Alben anlegen, Beispielfotos wieder
      entfernen (nur die Beispielfotos und ihre Alben verschwinden).
- [ ] Ab dem ersten Update: „Phasenweise Veröffentlichung für automatische Updates“ einschalten, täglich
      Abstürze und Rezensionen ansehen, bei Problemen pausieren (`docs/launch/PHASED_RELEASE.md`). Die
      Bewertungsbitte kommt nur nach neuen Alben ohne Fehler, höchstens einmal je Version
      (`ReviewPromptPolicy`).
