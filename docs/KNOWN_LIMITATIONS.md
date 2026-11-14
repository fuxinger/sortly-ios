# Bekannte Einschränkungen

## iOS
- Fotos-Apps dürfen keine Smart-Alben, geteilten oder synchronisierten Alben verändern.
- Hintergrundarbeit ist nicht garantiert; iOS entscheidet über `BGProcessingTask`. Die
  erste Analyse läuft deshalb im Vordergrund und setzt nach Unterbrechung fort.
- Bei „Ausgewählte Fotos“ sieht Albumist nur diese Auswahl.
- Ortsnamen über `CLGeocoder` sind von Apple begrenzt (Drosselung, gelegentliche Fehler);
  Länder und Regionen kommen immer aus der Offline-Karte.
- `CLGeocoder` ist in iOS 26 als veraltet markiert; der Nachfolger in MapKit ist geplant.

## Bilderkennung
- Begriffe statt Bedeutung, mögliche Fehlzuordnungen; deshalb Schwellen und Bestätigung.
- Analyse auf Vorschaubildern; kleine Motive werden eventuell nicht erkannt.
- Personen- und Haustiergruppen sind noch nicht umgesetzt (Bereich ausgeblendet).

## Messenger-Herkunft
iOS speichert keine verlässliche Quell-App. Albumist nutzt nur klare Hinweise (Messenger-
Screenshots, vorhandene Alben, optional Dateinamen-Muster) und markiert alles andere als
unbekannt.

## Nicht unterstützte Sammlungen
Smart-Alben, geteilte Alben, iCloud-Shared-Library-Besonderheiten, Alben aus anderen Apps
mit eingeschränkten Rechten: nur lesend.

## Offene technische Risiken
- **Nicht auf echten Geräten getestet.** Synthetisch geprüft: 100 000 Fotos (80 % nur in
  iCloud) in 54 s mit 563 MB Spitze auf dem Linux-Rechner der CI, ohne echte Bilderkennung.
  Laufzeit, Wärme und Akku auf iPhones sind ungemessen.
- PhotoKit kennt kein bedingtes Löschen: Zwischen dem letzten Lesen und dem Löschen eines
  leeren Albums kann noch ein Foto hineinkommen (Millisekunden). Albumist liest direkt davor.
- Ein beim Wiederanlauf übernommenes leeres Album bleibt nach Rückgängig stehen (gewollt).
- Nutzerentscheidungen und Verlauf werden noch nicht getrennt gesichert; bei einem Neuaufbau
  der Datenbank bleiben die letzten zwei Stände in der Quarantäne.
- Reiseart (Tagesausflug, Wochenende) richtet sich nach der Zielzeitzone nur, wenn die
  Online-Ortsbestimmung sie geliefert hat; sonst nach dem Gerätekalender.
- Eine Änderung nur der GPS-Genauigkeit eines Fotos wird nicht als Ortsänderung erkannt.
- Verhalten bei sehr großen Alben in einer PhotoKit-Transaktion (Schritte sind auf 500
  Fotos begrenzt).
- Die Apple-Intelligence-Funktionen sind im Cloud-Simulator nicht verfügbar und deshalb
  ungetestet; sie sind abgesichert (bei Fehler oder Nichtverfügbarkeit greift die normale Suche).
- StoreKit-Kauf ist erst mit App-Store-Connect-Eintrag testbar.
- Der sichtbare Name ist Albumist; Ordner, Module und Targets heißen noch „Sortly“ (nur intern).
