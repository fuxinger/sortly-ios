# Abgleich mit vorhandenen Alben

Quelle: `Sources/SortlyCore/Matching/AlbumMatcher.swift`, Tests: `Tests/SortlyCoreTests/MatchingTests.swift`.

## Verfahren
Für jeden Vorschlag P wird jedes vorhandene Album A über die **Inhalte** verglichen, nicht über
den Namen. Ein invertierter Index (Foto → Alben) macht das auch bei großen Mediatheken in
einem Durchgang möglich. Namen dienen nur als Gleichstand-Entscheider und zum Erkennen von
Namenskonflikten.

## Metriken
| Metrik | Formel | Bedeutung |
|---|---|---|
| Abdeckung | \|P∩A\| / \|P\| | Wie viel des Vorschlags ist schon im Album |
| Reinheit | \|P∩A\| / \|A\| | Wie viel des Albums gehört zum Vorschlag |
| Jaccard | \|P∩A\| / \|P∪A\| | Gesamtähnlichkeit |
| fehlend | \|P \ A\| | Fotos, die ergänzt würden |
| zusätzlich | \|A \ P\| | Fotos im Album, die bleiben, aber nicht dazugehören |

## Schwellen (Standard)
Kandidat ab Reinheit oder Abdeckung ≥ 0,5 und mindestens 3 gemeinsamen Fotos.
**Vollständig**: Abdeckung ≥ 0,98 und Reinheit ≥ 0,9. **Ergänzbar**: Reinheit ≥ 0,8 und
Abdeckung ≥ 0,25. **Größere Sammlung**: ≥ 20 % des Albums gehören zu Geschwister-Vorschlägen
derselben Familie (z. B. ein Album „Italien“ über mehrere Italienreisen). Liegen zwei Kandidaten
weniger als 0,15 Punkte auseinander, gilt „mehrere passende Alben“.

## Status
| Status | Empfohlene Aktion |
|---|---|
| Schon vollständig vorhanden | Album so lassen (zählt als sortiert) |
| Vorhandenes Album wird ergänzt | fehlende Fotos hinzufügen |
| Vorhandenes Album passt vermutlich | ergänzen, Nutzer sieht die Begründung |
| Mehrere passende Alben | Nutzer wählt unter „Anpassen“ |
| Gleicher Name, anderer Inhalt | neues Album, Konflikt wird angezeigt |
| Neues Album | anlegen im Ordner unter dem Hauptordner |
| Nicht eindeutig | Nutzer entscheidet |
| Album nicht bearbeitbar | (z. B. geteiltes Album) neues Album |

## Konfliktstrategien
- Fotos, die der Nutzer selbst aus einem Album entfernt hat, werden nie wieder hinzugefügt.
- Vor der Ausführung werden Fingerabdrücke aller betroffenen Alben verglichen; hat sich ein
  Album seit der Vorschau geändert, wird der Plan blockiert und neu vorgeschlagen.
- Doppelte neue Titel im selben Ordner blockieren; ein fremdes Album mit gleichem Titel im
  Zielordner ist nur ein Hinweis.
- Zusammenführen ähnlicher Alben ergänzt das größte Album; die anderen bleiben bestehen.

## Sonderfälle
Smart-Alben (Favoriten, Screenshots …) werden nicht als Ziel verwendet. Geteilte und
synchronisierte Alben sind nur lesbar. Ausgeblendete Fotos zählen nur mit Zustimmung.

### Teil-Alben bei Ländern und Orten
Ein kleineres Album mit anderem Namen ist bei einer Orts-Sammlung ein Teil, nicht das
Album: „Rom · 2024“ enthält nur Italien-Fotos, ist aber Rom. Albumist schlägt nie vor, es
mit Fotos aus ganz Italien zu ergänzen. Ergänzt wird nur ein Album, das ein Wort mit dem
Ort teilt („Italien 2019“, „Urlaub in Italien“). Ein Album, das schon den ganzen Ort
enthält, zählt weiter als vollständig. Unter „Anpassen“ kann man ein Teil-Album trotzdem
wählen.

### Alben anderer Vorschläge
Ein Album, das Albumist für einen anderen Vorschlag angelegt oder ergänzt hat (laut den
Aufzeichnungen zu verwalteten Alben), wird nie mit fremden Fotos ergänzt und nicht
angeboten. Es zählt nur, wenn es schon genau diesen Vorschlag enthält (ein Land, das man
auf einer einzigen Reise besucht hat).

### Mehrere passende Alben
Albumist ergänzt dann nichts von sich aus. Die Erklärung nennt jedes passende Album; der
Hauptknopf heißt „Album auswählen“ und öffnet die Auswahl.
