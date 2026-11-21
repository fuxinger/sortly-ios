"""SwiftLint check: only new findings fail (ci.yml, "SwiftLint").

Usage (ci.yml):
    python3 .github/scripts/swiftlint_report.py --status N --stderr stderr.txt \
        --baseline .github/swiftlint-baseline.json --write-counts swiftlint/counts.json findings.json
Usage (by hand, to commit the counts a CI run printed into its log):
    python3 .github/scripts/swiftlint_report.py --decode-log job.log > .github/swiftlint-baseline.json

SwiftLint (pinned, .github/lint-tools.json; settings with reasons in .github/swiftlint.yml) found
thousands of findings in code written before it ran. They stay as they are; what must not happen is
that more come. So the committed baseline counts the findings per file and rule, and the job fails
when a file has more findings of a rule than the baseline allows (a ratchet). Counting instead of
pinning lines: moving code inside a file does not read as a new finding. A file that is new or
renamed starts at zero.

The job also fails when SwiftLint itself did not work, so a broken tool or a setting it rejects is
seen at once instead of reading as "no new findings":
  - its exit status is neither 0 (no error-level finding) nor 2 (error-level findings);
  - it printed anything on stderr except the one known line (EXPECTED_STDERR);
  - its JSON report cannot be read.

Fewer findings than the baseline never fail; the summary says so, and every run prints the counts
of this commit into the log (SWIFTLINT_COUNTS lines) and writes them to --write-counts, so the
baseline can be lowered with --decode-log. Without a baseline file the run is report-only.
"""
from __future__ import annotations

import argparse
import base64
import collections
import gzip
import json
import os
import re
import sys

RAN = (0, 2)  # SwiftLint's exit status when it linted: 2 = error-level findings exist
# The statically linked Linux binary has no SourceKit and says once that it skips the one default
# rule that needs it (first run 21.11.2026). Anything else on stderr is a warning about the setup.
EXPECTED_STDERR = re.compile(r"^warning: Skipping enabled rule 'statement_position' because it requires SourceKit")
MARKER = "SWIFTLINT_COUNTS"
CHUNK = 900
MAX_ANNOTATIONS = 50
BASELINE_COMMENT = ("Findings per file and rule that were there before SwiftLint ran; more fail the job "
                    "(.github/scripts/swiftlint_report.py). Lower it, never raise it by hand.")

Counts = dict[str, dict[str, int]]


def relative(path: str) -> str:
    if os.path.isabs(path):
        path = os.path.relpath(path)
    return path.replace(os.sep, "/")


def folder(path: str) -> str:
    """The first two parts of a repository path ("Sources/AlbumistCore"), or the file itself."""
    parts = relative(path).split("/")
    return "/".join(parts[:2]) if len(parts) > 2 else "/".join(parts)


def count(findings: list[dict]) -> Counts:
    counts: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for f in findings:
        counts[relative(str(f.get("file", "?")))][str(f.get("rule_id", "?"))] += 1
    return {path: dict(sorted(rules.items())) for path, rules in sorted(counts.items())}


def compare(now: Counts, baseline: Counts) -> tuple[list[tuple[str, str, int, int]], int]:
    """(file, rule, now, allowed) for every count above the baseline, and how many findings fewer
    than the baseline allows there are elsewhere."""
    over, fewer = [], 0
    for path in sorted(set(now) | set(baseline)):
        for rule in sorted(set(now.get(path, {})) | set(baseline.get(path, {}))):
            n, allowed = now.get(path, {}).get(rule, 0), baseline.get(path, {}).get(rule, 0)
            if n > allowed:
                over.append((path, rule, n, allowed))
            else:
                fewer += allowed - n
    return over, fewer


def encode(counts: Counts) -> list[str]:
    data = base64.b64encode(gzip.compress(json.dumps(counts, sort_keys=True).encode(), mtime=0)).decode()
    chunks = [data[i:i + CHUNK] for i in range(0, len(data), CHUNK)] or [""]
    return [f"{MARKER} {n + 1}/{len(chunks)} {chunk}" for n, chunk in enumerate(chunks)]


def decode(log: str) -> Counts:
    """The counts from the SWIFTLINT_COUNTS lines of a job log (with or without time stamps)."""
    parts: dict[int, str] = {}
    total = None
    for match in re.finditer(rf"{MARKER} (\d+)/(\d+) (\S*)", log):
        index, of = int(match.group(1)), int(match.group(2))
        if total not in (None, of):
            raise ValueError("the log holds the counts of more than one run")
        total = of
        parts[index] = match.group(3)
    if total is None or sorted(parts) != list(range(1, total + 1)):
        raise ValueError(f"incomplete: {len(parts)} of {total} {MARKER} lines")
    return json.loads(gzip.decompress(base64.b64decode("".join(parts[i] for i in range(1, total + 1)))))


def baseline_file(counts: Counts) -> str:
    return json.dumps({"_comment": BASELINE_COMMENT, "files": counts}, indent=1, sort_keys=True) + "\n"


def summary(findings: list[dict], over: list[tuple[str, str, int, int]] | None, fewer: int, top: int = 25) -> str:
    severities = collections.Counter(str(f.get("severity", "")).lower() for f in findings)
    files = {f.get("file") for f in findings}
    lines = ["## SwiftLint", ""]
    if over is None:
        lines += ["No baseline yet (.github/swiftlint-baseline.json): report only.", ""]
    elif over:
        lines += [f"**{sum(n - a for _, _, n, a in over)} new findings** in {len({p for p, *_ in over})} files "
                  "(more than the baseline allows):", "", "| File | Rule | Now | Allowed |", "|---|---|---|---|"]
        lines += [f"| {path} | {rule} | {n} | {allowed} |" for path, rule, n, allowed in over]
        lines.append("")
    else:
        lines += ["No new findings."]
        if fewer:
            lines.append(f"{fewer} fewer than the baseline allows: lower it with --decode-log (see the script).")
        lines.append("")
    if not findings:
        lines.append("No findings.")
        return "\n".join(lines) + "\n"
    lines.append(f"{len(findings)} findings in {len(files)} files: {severities.get('error', 0)} errors, "
                 f"{severities.get('warning', 0)} warnings.")
    by_rule = collections.Counter((f.get("rule_id", "?"), str(f.get("severity", "")).lower()) for f in findings)
    lines += ["", "| Rule | Severity | Findings |", "|---|---|---|"]
    for (rule, severity), n in by_rule.most_common(top):
        lines.append(f"| {rule} | {severity} | {n} |")
    if len(by_rule) > top:
        rest = sum(n for _, n in by_rule.most_common()[top:])
        lines.append(f"| {len(by_rule) - top} more rules | | {rest} |")
    by_folder = collections.Counter(folder(str(f.get("file", "?"))) for f in findings)
    lines += ["", "| Folder | Findings |", "|---|---|"]
    for name, n in sorted(by_folder.items(), key=lambda item: (-item[1], item[0])):
        lines.append(f"| {name} | {n} |")
    return "\n".join(lines) + "\n"


def annotations(findings: list[dict], over: list[tuple[str, str, int, int]]) -> list[str]:
    """One error per finding of an over-count file and rule: which of them is new, only the author
    knows (the count cannot say), so all are shown, each at its line."""
    keys = {(path, rule): (n, allowed) for path, rule, n, allowed in over}
    out = []
    for f in findings:
        key = (relative(str(f.get("file", "?"))), str(f.get("rule_id", "?")))
        if key in keys:
            n, allowed = keys[key]
            reason = str(f.get("reason", "")).replace("\n", " ")
            out.append(f"::error file={key[0]},line={f.get('line') or 1},title=SwiftLint {key[1]} "
                       f"({n} in this file; baseline {allowed})::{reason}")
    return out


def read_stderr(path: str | None) -> list[str]:
    if not path:
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        return [line.rstrip() for line in f if line.strip() and not EXPECTED_STDERR.match(line.strip())]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--status", type=int, help="SwiftLint's exit status")
    parser.add_argument("--stderr", help="what SwiftLint printed on stderr")
    parser.add_argument("--baseline", help="committed counts (.github/swiftlint-baseline.json)")
    parser.add_argument("--write-counts", help="write this commit's counts in the baseline format here")
    parser.add_argument("--decode-log", help="print the baseline from the SWIFTLINT_COUNTS lines of a job log")
    parser.add_argument("report", nargs="?", help="SwiftLint's JSON report")
    args = parser.parse_args(argv)
    if args.decode_log:
        with open(args.decode_log, encoding="utf-8", errors="replace") as f:
            sys.stdout.write(baseline_file(decode(f.read())))
        return 0
    if args.status is None or not args.report:
        parser.error("--status and the report are needed")
    if args.status not in RAN:
        print(f"::error title=SwiftLint::SwiftLint stopped with exit status {args.status}, so it did not lint "
              "(see its output above)", file=sys.stderr)
        return 1
    try:
        unexpected = read_stderr(args.stderr)
    except OSError as error:
        print(f"::error title=SwiftLint::its stderr {args.stderr} cannot be read: {error}", file=sys.stderr)
        return 1
    if unexpected:
        for line in unexpected[:20]:
            print(f"::error title=SwiftLint setup::{line}", file=sys.stderr)
        print("::error title=SwiftLint::SwiftLint warned about its setup (a setting in .github/swiftlint.yml it "
              "does not take falls back to the default without failing); fix the setting", file=sys.stderr)
        return 1
    try:
        with open(args.report, encoding="utf-8") as f:
            findings = json.load(f)
        if not isinstance(findings, list):
            raise ValueError("not a list")
    except (OSError, ValueError) as error:
        print(f"::error title=SwiftLint::its report {args.report} cannot be read: {error}", file=sys.stderr)
        return 1
    counts = count(findings)
    over, fewer = None, 0
    if args.baseline and os.path.exists(args.baseline):
        with open(args.baseline, encoding="utf-8") as f:
            over, fewer = compare(counts, json.load(f)["files"])
    elif args.baseline:
        print(f"::warning title=SwiftLint::no baseline at {args.baseline}: report only", file=sys.stderr)
    print(f"SWIFTLINT findings={len(findings)} new={sum(n - a for _, _, n, a in over or [])}", file=sys.stderr)
    if over == [] and fewer:
        # Slack: a fixed finding leaves room for a new one of the same rule in that file.
        print(f"::warning title=SwiftLint baseline::{fewer} findings fewer than the baseline allows; lower it "
              "(swiftlint_report.py --decode-log)", file=sys.stderr)
    if args.write_counts:
        with open(args.write_counts, "w", encoding="utf-8") as f:
            f.write(baseline_file(counts))
    print("::group::Counts of this commit (swiftlint_report.py --decode-log)", file=sys.stderr)
    for line in encode(counts):
        print(line, file=sys.stderr)
    print("::endgroup::", file=sys.stderr)
    sys.stdout.write(summary(findings, over, fewer))
    if over:
        marks = annotations(findings, over)
        for line in marks[:MAX_ANNOTATIONS]:
            print(line, file=sys.stderr)
        if len(marks) > MAX_ANNOTATIONS:
            print(f"... and {len(marks) - MAX_ANNOTATIONS} more findings in these files (table in the summary)",
                  file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
