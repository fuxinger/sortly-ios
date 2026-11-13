# Datenschutz

## Datenverarbeitung
Alle Analysen laufen auf dem Gerät. SORTLY lädt keine Fotos hoch, hat keinen Server, kein
Konto, keine Werbung, kein Tracking und keine Analyse-SDKs.

## Speicherorte
Eine SQLite-Datenbank in *Application Support/SORTLY* mit Metadaten, Analyseergebnissen,
erkanntem Text (nur für die Suche) und Entscheidungen. Vom iCloud-Backup ausgeschlossen.
Es werden **keine Bildkopien** gespeichert. Wenige Einstellungen liegen in `UserDefaults`.

## Berechtigungen
- Fotos (voll oder ausgewählte Fotos). Ohne Zugriff funktioniert die App nicht.
- Keine Standortberechtigung: Orte stammen aus den GPS-Daten der Fotos.
- Hintergrundverarbeitung (nachts beim Laden).

## Externe Dienste
- **Apple-Geocoder** (`CLGeocoder`): Für Stadtnamen werden einzelne Koordinaten (eine pro
  Rasterzelle, keine Fotos) an Apple gesendet. Abschaltbar; dann nur Offline-Karte.
- **iCloud-Fotos:** Originale von Screenshots/Dokumenten werden nur mit Zustimmung über
  Apples Fotosystem geladen.
- **App Store (StoreKit):** einmaliger Kauf, abgewickelt von Apple.

## Datenschutzentscheidungen
Gesichtsgruppen sind besondere personenbezogene Daten (DSGVO Art. 9) und werden nur nach
ausdrücklichem Einschalten verarbeitet (noch nicht verfügbar). Ausgeblendete Fotos sind
standardmäßig ausgeschlossen. Sensible Dokumente werden nicht automatisch vorgeschlagen.
Datenschutz-Manifest: `App/Sortly/Resources/PrivacyInfo.xcprivacy` (keine erhobenen Daten).
