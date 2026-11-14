# Analyse und Bilderkennung

## Verwendete Modelle
Ausschließlich Apples Vision-Framework auf dem Gerät (Lizenz: Teil des iOS SDK):
- `ClassifyImageRequest` – Bildklassifikation (1303 Begriffe im iOS-26-Simulator)
- `RecognizeTextRequest` – Texterkennung (Deutsch, Englisch, Genauigkeitsstufe „accurate“)
- `DetectBarcodesRequest` – QR- und Barcodes auf Tickets und Belegen
Optional, nur wenn das Gerät Apple Intelligence hat und es eingeschaltet ist:
- `FoundationModels` (`SystemLanguageModel`, auf dem Gerät) für zwei Zusatzfunktionen:
  Suche in ganzen Sätzen (Satz → Suchbegriffe, danach die normale Suche) und
  Namensvorschläge für Reisealben (nur auf Knopfdruck, Nutzer übernimmt oder nicht).
  Ohne Apple Intelligence verhält sich die App genauso, nur ohne diese Extras.
Kein eigenes Modell, kein Training, kein Netzwerkzugriff für die Analyse.

## Analyseverfahren
- Klassifikation läuft auf der **lokalen Vorschau** (ca. 512 px), die Fotos auch bei
  „iPhone-Speicher optimieren“ immer auf dem Gerät hat.
- Texterkennung nur für Screenshots und dokumentähnliche Bilder; dafür wird das Original
  verwendet, aus iCloud nur mit Zustimmung und im WLAN. Videos werden nie geladen.
- Ergebnisse werden versioniert gespeichert (`contentVersion`, `textVersion`).

## Kategorien
Die Taxonomie (`ImageTaxonomy` in `ContentClassifiers.swift`) ordnet Vision-Begriffe rund
40 Themen zu (Fahrzeuge, Tiere, Essen, Natur, Sport, Wohnen, Beruf, Weiteres) mit
Ober- und Unterkategorien. Alle verwendeten Begriffe wurden gegen die tatsächlich
unterstützte Liste geprüft (App-Test `taxonomyUsesKnownIdentifiers`).
Screenshots werden über erkannten Text in Bestellungen, Tickets, Rezepte, Chats usw.
eingeteilt; Dokumente in Rechnungen, Verträge, Kassenbons u. a. Sensible Dokumente
(Ausweis, Gesundheit, Bank) erscheinen nur, wenn der Nutzer das einschaltet.

## Zuverlässigkeit
Konfidenz ≥ 0,8 → wahrscheinlich, ≥ 0,55 → möglich, darunter unsicher (pro Kategorie
mindestens 0,35). Themenalben entstehen standardmäßig erst ab 15 Fotos mit Stufe
„wahrscheinlich“. Reisen und Orte beruhen auf GPS und gelten als sicher bzw. wahrscheinlich;
Fotos ohne GPS werden nur zeitlich zugeordnet und als „nur vorgeschlagen“ markiert.

## Trainings- bzw. Beispielstrategie
Kein Training. Die Logik wird mit synthetischen Bibliotheken getestet (`SortlyTestSupport`).
Für spätere Tests mit echten Bildern werden nur frei lizenzierte Bilder (CC0/gemeinfrei)
mit Lizenzliste verwendet.

## Bekannte Grenzen
Klassifikation erkennt Begriffe, keine Bedeutung (ein Spielzeugauto ist auch „Auto“).
Die Vorschau kann bei kleinen Motiven zu grob sein. Gesichter und Haustier-Identitäten sind
noch nicht umgesetzt. Siehe `KNOWN_LIMITATIONS.md`.
