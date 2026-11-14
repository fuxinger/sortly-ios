# Featuring-Check (Stand 14.11.2026)

Womit Apple Apps für Empfehlungen im App Store auswählt (laut Apple: Gestaltung,
Bedienbarkeit, Barrierefreiheit, Lokalisierung, Einzigartigkeit, aktuelle Apple-Technik,
gute Produktseite) und wie Albumist dasteht.

## Erledigt

| Bereich | Stand |
|---|---|
| iOS-27-Design | Systemleisten in Liquid Glass, Tab-Leiste schrumpft beim Scrollen, Suche als eigener Tab, Glasknöpfe (`glassProminent`/`glass`), iPad als Seitenleiste |
| Apple-Technik | SwiftUI, Vision (neue Swift-API), Foundation Models auf dem Gerät (Foto-Geschichte, Namen, Suche in Sätzen), App Intents, Spotlight (`IndexedEntity`), BackgroundTasks mit Fortschritt auf dem Sperrbildschirm, StoreKit 2 |
| Siri und Kurzbefehle | „Neue Fotos sortieren“, „Fotos aus Italien in Albumist“, „Offene Vorschläge“, Vorschlag öffnen |
| Spotlight | Länder („Italien, 120 Fotos“) und offene Vorschläge, Antippen öffnet sie |
| Barrierefreiheit | VoiceOver-Beschriftungen, Dynamic Type bis zur größten Stufe mit eigenem Layout, Dunkelmodus mit eigenen Farbvarianten, Bewegung reduzieren im Atlas, Tippflächen mindestens 44 pt, automatischer Barrierefreiheits-Audit in jedem UI-Testlauf |
| Haptik | Vibration bei Erfolg und Fehler beim Umsetzen |
| Datenschutz | alles auf dem Gerät, keine Daten erhoben, Datenschutz-Manifest, keine Fremdbibliotheken |
| Geschäftsmodell | Einmalkauf, kein Abo, keine Werbung (kommt bei Apple-Redaktionen gut an) |
| Teilen | Reise-Atlas als Teilen-Bild im Apple-Stil (Weiterempfehlung) |
| Sprachen | Deutsch und Englisch, vollständig |
| Qualität | 180+ automatische Tests, UI-Durchlauf mit Screenshots bei jedem Stand |

## Offen, braucht einen Mac oder das Entwicklerkonto

| Was | Warum | Wer |
|---|---|---|
| App-Icon im Icon-Composer-Format (`.icon`, Glas-Ebenen) | iOS 26 zeigt Icons in Glas, Klar und Getönt; Apple achtet bei Empfehlungen darauf | Mac mit Xcode 26 (heutige PNG-Icons mit Dunkel/Getönt funktionieren, sind aber nicht „Glas“) |
| Endgültiger App-Name | „Sortly“ ist vergeben; 13 freie Namen gefunden | Fuchs |
| Test auf echten iPhones (TestFlight) | Tempo und Wärme bei 50.000+ Fotos, iCloud-Mediatheken | Entwicklerkonto |
| Nominierung in App Store Connect | 6 bis 12 Wochen vor dem Start (Text liegt in `FEATURING_NOMINATION.md`) | Entwicklerkonto |
| Barrierefreiheits-Angaben („Accessibility Nutrition Labels“) | VoiceOver, Sprachsteuerung, größerer Text, Dunkelmodus, ausreichender Kontrast, Bewegung reduzieren: alles unterstützt, nur noch eintragen | App Store Connect |
| Produktseite | Screenshots für 6,9″ und iPad 13″, kurzes Vorschauvideo, Werbetext | Vorlagen aus den UI-Screenshots |

## Sinnvoll für ein Update (erhöht die Chancen weiter)

- Widget für Home- und Sperrbildschirm („3 neue Reisen gefunden“) und ein Kontrollzentrum-Schalter.
- Live Activity für die erste große Analyse.
- Weitere Sprachen: Französisch, Spanisch, Italienisch, Japanisch (der Katalog ist vorbereitet).
- In-App-Event zum Jahreswechsel („Ordnung für das neue Jahr“).
