# SORTLY – Arbeitsstand (Übergabe-Notiz)

Diese Datei ist die Übergabe-Notiz für eine Fortsetzung nach einer Unterbrechung.
Repository: github.com/fuxinger/sortly-ios (verbunden, Arbeitsbranch siehe unten).
Arbeitskopie im Projektordner: /mnt/project-files/sortly/

## Rahmenbedingungen
- Fuchs hat keinen Mac. iOS-Builds laufen später über GitHub Actions (macOS-Runner).
- Linux-Swift-Toolchain (6.2.3) im Container: `export PATH=/home/user/toolchain/swift-6.2.3-RELEASE-ubuntu24.04/usr/bin:$PATH`
  (Download von download.swift.org ist in der Cloud-Umgebung freigegeben). Kern-Tests: `swift test`.
- Keine Rückfragen an Fuchs, selbständig weiterarbeiten. Antworten auf Deutsch, einfache Sprache.

## Plan
1. [in Arbeit] SortlyCore (plattformunabhängige Logik) + Tests
2. [offen] SortlyStore (SQLite-Persistenz, Migrationen) + Tests
3. [offen] iOS-App (App/, XcodeGen project.yml, SwiftUI, PhotoKit, Vision, MapKit)
4. [offen] Dokumentation (docs/*.md laut Master-Prompt §24) + Art Direction
5. [offen] CI (.github/workflows) für Linux-Tests und macOS-iOS-Build
6. [offen] Visueller Design-Entwurf als Artifact (3 Richtungen, Prompt §28.15)

## Zuletzt erledigt
- Paketstruktur, Domain-Typen, Geo-Clustering, häufige Orte.
