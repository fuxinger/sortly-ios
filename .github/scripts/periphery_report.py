"""Job summary of the Periphery report (code-checks.yml, unused code).

Usage: python3 .github/scripts/periphery_report.py --status N findings.json >> "$GITHUB_STEP_SUMMARY"

Periphery (pinned, .github/lint-tools.json) runs report-only for now, like SwiftLint
(swiftlint_report.py): its findings do not fail the job. The job fails only when Periphery itself
did not scan: an exit status other than 0, or a JSON report that cannot be read. The summary
counts the findings by kind of finding ("unused", "assignOnlyProperty", ...), by declaration kind
and by folder, and lists the first ones with their place. Every finding also goes into the log
as a `PERIPHERY_FINDING place | declaration | finding` line: the artifact cannot be downloaded
through the API, the log can, and each finding is checked by hand.
"""
from __future__ import annotations

import argparse
import collections
import json
import sys

from swiftlint_report import folder


def place(finding: dict) -> str:
    """"path:line" of a finding (Periphery's location is "path:line:column")."""
    location = str(finding.get("location", "?"))
    parts = location.rsplit(":", 2)
    return f"{parts[0]}:{parts[1]}" if len(parts) == 3 else location


def summary(findings: list[dict], listed: int = 40) -> str:
    lines = ["## Periphery: unused code (report only)", ""]
    if not findings:
        lines.append("No findings.")
        return "\n".join(lines) + "\n"
    files = {place(f).rsplit(":", 1)[0] for f in findings}
    lines.append(f"{len(findings)} findings in {len(files)} files. Nothing fails on them yet; each one is checked by "
                 "hand before code is removed (Periphery cannot see every use, for example from SwiftUI previews or "
                 "a string).")
    hints = collections.Counter("/".join(f.get("hints") or ["?"]) for f in findings)
    kinds = collections.Counter(str(f.get("kind", "?")) for f in findings)
    folders = collections.Counter(folder(place(f).rsplit(":", 1)[0]) for f in findings)
    for title, counter in (("Finding", hints), ("Declaration", kinds), ("Folder", folders)):
        lines += ["", f"| {title} | Count |", "|---|---|"]
        for name, count in sorted(counter.items(), key=lambda item: (-item[1], item[0])):
            lines.append(f"| {name} | {count} |")
    lines += ["", "| Place | Declaration | Finding |", "|---|---|---|"]
    for f in sorted(findings, key=place)[:listed]:
        lines.append(f"| {place(f)} | {f.get('kind', '?')} {f.get('name', '?')} | {'/'.join(f.get('hints') or ['?'])} |")
    if len(findings) > listed:
        lines.append(f"| {len(findings) - listed} more (PERIPHERY_FINDING lines in the log, artifact \"periphery\") | | |")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--status", type=int, required=True, help="Periphery's exit status")
    parser.add_argument("report", help="Periphery's JSON report")
    args = parser.parse_args(argv)
    if args.status != 0:
        print(f"::error title=Periphery::Periphery stopped with exit status {args.status}, so it did not scan "
              "(see its output above)", file=sys.stderr)
        return 1
    try:
        with open(args.report, encoding="utf-8") as f:
            findings = json.load(f)
        if not isinstance(findings, list):
            raise ValueError("not a list")
    except (OSError, ValueError) as error:
        print(f"::error title=Periphery::its report {args.report} cannot be read: {error}", file=sys.stderr)
        return 1
    print(f"PERIPHERY findings={len(findings)}", file=sys.stderr)
    for f in sorted(findings, key=place):
        print(f"PERIPHERY_FINDING {place(f)} | {f.get('kind', '?')} {f.get('name', '?')} | "
              f"{'/'.join(f.get('hints') or ['?'])}", file=sys.stderr)
    sys.stdout.write(summary(findings))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
