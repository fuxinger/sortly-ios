#!/usr/bin/env bash
# Packs the committed code for an outside review (ChatGPT, Gemini …): source, tests, docs
# and the review prompt; leaves out the 4.6 MB world map data and images.
# Usage: tools/make_review_zip.sh <output.zip>
set -euo pipefail
out=${1:?output zip path}
cd "$(git rev-parse --show-toplevel)"
rm -f "$out"
git archive --format=zip --prefix=sortly/ -o "$out" HEAD -- . \
  ':(exclude)Sources/SortlyWorldMap/Resources' \
  ':(exclude)App/Sortly/Resources/Assets.xcassets' \
  ':(exclude)docs/launch/name-candidates.txt'
echo "$out ($(du -h "$out" | cut -f1), commit $(git rev-parse --short HEAD))"
