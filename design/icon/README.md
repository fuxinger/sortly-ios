# App-Icon „Glass Stack“

Gewählt am 14.11.2026. Drei Albumkarten übereinander, die vordere aus Milchglas mit Landschaft.

- `icon-light.svg`, `icon-dark.svg`, `icon-tinted.svg`: fertige Icons (1024 px). Daraus entstehen
  die PNGs in `App/Sortly/Resources/Assets.xcassets/AppIcon.appiconset/`.
- `0-background.svg` bis `5-hills.svg`: einzelne Ebenen für den **Icon Composer** auf dem Mac.
  Dort die Ebenen in dieser Reihenfolge hineinziehen; Glas, Schatten, Dunkel- und Getönt-Look
  macht der Icon Composer selbst. Ergebnis als `AppIcon.icon` ins Projekt legen.
- `make_icon.py <ausgabe> <ebenen>`: erzeugt alle SVGs neu. Gerendert wurde mit Chromium (Playwright).
