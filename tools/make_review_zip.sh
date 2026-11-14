#!/usr/bin/env bash
# Packs the committed code for an outside review (ChatGPT, Gemini …) into one ZIP:
# PRUEFAUFTRAG.md (the review prompt) at the top, the code in sortly/ (source, tests, docs);
# leaves out the 4.6 MB world map data and images.
# Usage: tools/make_review_zip.sh <output.zip>
set -euo pipefail
out=${1:?output zip path}
cd "$(git rev-parse --show-toplevel)"
rm -f "$out"
git archive --format=zip --prefix=sortly/ -o "$out" HEAD -- . \
  ':(exclude)Sources/SortlyWorldMap/Resources' \
  ':(exclude)App/Sortly/Resources/Assets.xcassets' \
  ':(exclude)docs/launch/name-candidates.txt'
python3 - "$out" <<'PY'
import subprocess, sys, zipfile
prompt = subprocess.run(["git", "show", "HEAD:docs/review/CROSS_REVIEW_PROMPT.md"],
                        check=True, capture_output=True).stdout
with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED) as z:
    z.writestr("PRUEFAUFTRAG.md", prompt)
PY
echo "$out ($(du -h "$out" | cut -f1), commit $(git rev-parse --short HEAD))"
