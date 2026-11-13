# Datenmodell

SQLite, Version über `PRAGMA user_version`, Migrationen in `Sources/SortlyStore/Migrations.swift`.

## Tabellen
| Tabelle | Schlüssel | Inhalt |
|---|---|---|
| `assets` | `id` (PhotoKit localIdentifier) | Metadaten, Fingerabdruck, `analysis_version` |
| `collections` | `id` | Alben und Ordner: Titel, Art, Rechte, Eltern, Kinder |
| `collection_members` | (`collection_id`, `asset_id`) | Album-Mitgliedschaften |
| `place_cache` | `cell` (Rasterzelle) | aufgelöste Ortsnamen je Zelle |
| `asset_places` | `asset_id` | Ort je Foto, Quelle, `precision_m` (v2) |
| `analysis_results` | (`asset_id`, `kind`) | versionierte Analyseergebnisse (JSON) |
| `text_plain` / `text_fts` | `asset_id` | erkannter Text; FTS5 falls verfügbar |
| `analysis_progress` | `stage` | Fortschritt und Cursor je Etappe |
| `overrides` | `id` | Nutzerentscheidungen (ignorieren, ablehnen, entfernte Fotos) |
| `rules` | (`id`, `version`) | Regeln mit Versionsverlauf |
| `managed_albums` | `album_id` | von SORTLY angelegte/ergänzte Alben |
| `plans` | `id` | Änderungspläne mit Schrittstatus (Verlauf, Wiederanlauf) |
| `settings` | `key` | Einstellungen, Entscheidungen, Vorschlags-Schnappschuss |

## Beziehungen und Indizes
`collection_members`, `asset_places`, `analysis_results`, `text_plain` hängen per
`ON DELETE CASCADE` an `assets` bzw. `collections`. Indizes: Aufnahmedatum, Analyseversion,
Koordinaten, Eltern-Ordner, Mitgliedschaft nach Foto, Ergebnis-Art, Plan-Status, Quelle
verwalteter Alben.

## Identitäten
Fotos und Alben werden über PhotoKit-`localIdentifier` angesprochen. Vorschläge haben
stabile `SortlyID`s, abgeleitet aus Bereich und Inhalt (Reise-ID, Ortsschlüssel, Kategorie),
damit Entscheidungen neue Analyseläufe überleben. Planschritte haben deterministische
Idempotenzschlüssel (Plan-ID + Index + Inhalts-Hash).

## Migrationen
- v1: Grundschema.
- v2: `asset_places.precision_m` für den nächtlichen Verfeinerungslauf.
Migrationen laufen nur vorwärts, jede in einer Transaktion.
