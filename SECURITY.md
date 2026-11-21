# Sicherheit

## Eine Sicherheitslücke melden

Bitte melde Sicherheitsprobleme **nicht** als öffentliches Issue, sondern privat:

1. Auf GitHub im Repository unter **Security > Advisories > Report a vulnerability**
   (https://github.com/fuxinger/albumist-ios/security/advisories/new). Nur der Maintainer sieht
   die Meldung.
2. Beschreibe, was betroffen ist, wie es sich nachstellen lässt und welche Version (Build aus
   TestFlight oder Commit) du verwendet hast. Bitte keine privaten Fotos oder persönlichen Daten
   mitschicken.

Du bekommst innerhalb von 7 Tagen eine Antwort. Behebung und Veröffentlichung stimmen wir
gemeinsam ab; wenn du möchtest, wirst du in den Hinweisen zur Behebung genannt.

## Was zählt dazu

- Albumist liest die Fotomediathek nur auf dem Gerät. Alles, wodurch Fotos, Orte, Texte aus
  Bildern oder Albumnamen das Gerät verlassen könnten, ist ein Sicherheitsproblem.
- Änderungen an der Mediathek, die nicht vorher gezeigt und bestätigt wurden, oder die sich
  nicht rückgängig machen lassen.
- Probleme in den GitHub-Workflows, etwa wenn fremder Code an die App-Store-Schlüssel käme.

## Unterstützte Versionen

Nur der jeweils neueste TestFlight-Build und der aktuelle Stand von `main`.
