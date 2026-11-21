#!/usr/bin/env python3
"""A time limit in a test or a workflow is only loosened together with an entry in
docs/IMPROVEMENTS.md (review P5-13 of 18.11.2026).

Build 36 was built from 4bb7fdd, a commit that only let UI flow test1b wait 20 s instead of 5 s
for the note "2 Fotos ignoriert"; the slow answer of the app was a finding "for right after the
build", and the test that had found it was quieter. A longer wait may be right (rule of 17.11.:
name the measurement in the commit, docs/TESTFLIGHT.md), but it is never silent: the change that
raises a limit adds a row to docs/IMPROVEMENTS.md that says "Zeitgrenze gelockert" and names the
file. Those rows are counted (TIME_LIMIT_ENTRIES), so the loosened limits stay in sight until the
cause is fixed and the limit is tight again.

  python3 .github/scripts/time_limit_rule.py --base auto|<sha> [--head <sha>]
      Compares the limits of the files below between base and head. Exit 1 when a limit got
      longer and no added line of docs/IMPROVEMENTS.md says "Zeitgrenze gelockert" with the
      file's name. --base auto (ci.yml): a pull request's merge commit against its first
      parent (the branch it goes into), a push against the commit before it; other events
      (a manual run, a TestFlight run, which only runs on main, whose pushes were checked)
      have no change to check and say so.

What a time limit is (a number of seconds or minutes the code waits for or measures against):
  - Swift tests (App/AlbumistUITests, App/AlbumistTests, Tests): `timeout: 20` (waitForExistence,
    UITestWait, XCTWaiter; also a default `timeout: TimeInterval = 15`), `limit: 15` of the
    timed(...) steps, an upper bound `< .seconds(3)` / `<= .milliseconds(500)` / `< .minutes(2)`,
    `.timeLimit(.minutes(5))`, and a deadline the test builds itself (`Date().addingTimeInterval(900)`,
    `Date(timeIntervalSinceNow: 40)`; not one computed from a variable or moved back from a moment);
  - workflows (.github/workflows): `timeout-minutes: 75`.
A limit is loosened when a changed line keeps its code but gets a larger number (the line pairs
with the removed line of the same hunk that reads the same with the numbers left out, else with
the most similar one). A new limit (a new test) or a lower one needs nothing. Not seen: a limit
that is removed, one computed from variables, and one moved to another hunk.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys

ENTRY_FILE = "docs/IMPROVEMENTS.md"
MARKER = "Zeitgrenze gelockert"
NUMBER = r"([0-9][0-9_]*(?:\.[0-9]+)?)"
UNITS = {"seconds": 1.0, "milliseconds": 0.001, "minutes": 60.0}
SWIFT_LIMITS = (
    (re.compile(r"\btimeout\s*:\s*(?:TimeInterval\s*=\s*)?" + NUMBER + r"(?![\w.])"), lambda m: 1.0),
    (re.compile(r"\btimed\(.*?\blimit\s*:\s*" + NUMBER + r"(?![\w.])"), lambda m: 1.0),
    (re.compile(r"<=?\s*\.(seconds|milliseconds|minutes)\(\s*" + NUMBER + r"\s*\)"), lambda m: UNITS[m.group(1)]),
    (re.compile(r"\.timeLimit\(\s*\.minutes\(\s*" + NUMBER + r"\s*\)\s*\)"), lambda m: 60.0),
    # A deadline the test builds itself: `Date().addingTimeInterval(900)`, `Date(timeIntervalSinceNow: 40)`.
    (re.compile(r"\bDate\(\)\.addingTimeInterval\(\s*" + NUMBER + r"\s*\)"), lambda m: 1.0),
    (re.compile(r"\bDate\(\s*timeIntervalSinceNow\s*:\s*" + NUMBER + r"\s*\)"), lambda m: 1.0),
)
WORKFLOW_LIMITS = ((re.compile(r"^\s*timeout-minutes\s*:\s*" + NUMBER + r"\s*(?:#.*)?$"), lambda m: 60.0),)
SWIFT_DIRS = ("App/AlbumistUITests/", "App/AlbumistTests/", "Tests/")
WORKFLOW_DIR = ".github/workflows/"
# A file whose limits the rule reads, as an entry names it.
LIMIT_FILE = re.compile(r"\b[\w.+-]+\.(?:swift|ya?ml)\b")


def patterns_for(path: str):
    if path.endswith(".swift") and path.startswith(SWIFT_DIRS):
        return SWIFT_LIMITS
    if path.startswith(WORKFLOW_DIR) and path.endswith((".yml", ".yaml")):
        return WORKFLOW_LIMITS
    return None


def limits(line: str, patterns) -> list[tuple[int, int, float]]:
    """(start, end, seconds) of every time limit on a line of code (a whole-line comment has none)."""
    if line.lstrip().startswith("//" if patterns is SWIFT_LIMITS else "#"):
        return []
    found = []
    for pattern, unit in patterns:
        for m in pattern.finditer(line):
            group = m.lastindex
            found.append((m.start(group), m.end(group), float(m.group(group).replace("_", "")) * unit(m)))
    return sorted(found)


def masked(line: str, spots) -> str:
    """The line with its limits' numbers left out and no whitespace: what stays when only a number changes."""
    for start, end, _ in reversed(spots):
        line = line[:start] + "#" + line[end:]
    return "".join(line.split())


def hunks(diff: str):
    """(path, [(new line number, removed text | None, added text | None)...]) per hunk of a
    unified diff with -U0: removed and added lines in order."""
    path, current = None, None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            if current is not None:
                yield current
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", line)
            current = (path, int(m.group(1)) if m else 0, [], [])
        elif current is not None and line.startswith("-") and not line.startswith("---"):
            current[2].append(line[1:])
        elif current is not None and line.startswith("+") and not line.startswith("+++"):
            current[3].append(line[1:])
    if current is not None:
        yield current


def loosened(diff: str) -> list[dict]:
    """Every limit that got longer in a unified diff (-U0): {"path", "line", "old", "new", "text"}."""
    found = []
    for path, first, removed, added in hunks(diff):
        patterns = patterns_for(path or "")
        if not patterns:
            continue
        old = [(text, limits(text, patterns)) for text in removed]
        old = [(t, s) for t, s in old if s]
        new = [(i, text, limits(text, patterns)) for i, text in enumerate(added)]
        new = [(i, t, s) for i, t, s in new if s]
        free = list(range(len(old)))
        for i, text, spots in new:
            if not free:
                break
            same = [k for k in free if masked(old[k][0], old[k][1]) == masked(text, spots)]
            if same:
                k = same[0]
            else:
                ratio = lambda k: difflib.SequenceMatcher(None, masked(old[k][0], old[k][1]), masked(text, spots)).ratio()  # noqa: E731
                k = max(free, key=ratio)
                if ratio(k) < 0.6:
                    continue
            free.remove(k)
            before = [s for _, _, s in old[k][1]]
            after = [s for _, _, s in spots]
            pairs = zip(before, after) if len(before) == len(after) else [(max(before), max(after))]
            for was, now in pairs:
                if now > was:
                    found.append({"path": path, "line": first + i, "old": was, "new": now, "text": text.strip()})
    return found


def entries_added(diff: str) -> list[str]:
    """The lines a diff of docs/IMPROVEMENTS.md adds that carry the marker."""
    return [line[1:] for line in diff.splitlines()
            if line.startswith("+") and not line.startswith("+++") and MARKER in line]


def missing_entries(found: list[dict], added: list[str]) -> list[dict]:
    """The loosened limits whose file no added entry names (by its file name)."""
    return [f for f in found if not any(os.path.basename(f["path"]) in line for line in added)]


def count_entries(text: str) -> tuple[int, int]:
    """(entries, of them still open: 🔜 or "offen") in docs/IMPROVEMENTS.md. An entry is a table
    row with the marker and the name of a test or workflow file (a row that only describes the
    rule names none)."""
    rows = [line for line in text.splitlines()
            if line.startswith("|") and MARKER in line and LIMIT_FILE.search(line)]
    open_rows = [r for r in rows if re.match(r"\|\s*(🔜|offen)", r)]
    return len(rows), len(open_rows)


def git(*args: str, cwd: str | None = None) -> str:
    done = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()[:300]}")
    return done.stdout


def have(sha: str, cwd: str | None = None) -> bool:
    """Whether git has the commit; fetches it once when not (a shallow checkout)."""
    check = ["git", "cat-file", "-e", f"{sha}^{{commit}}"]
    if subprocess.run(check, cwd=cwd, capture_output=True).returncode == 0:
        return True
    subprocess.run(["git", "fetch", "--quiet", "--no-tags", "--depth=1", "origin", sha], cwd=cwd, capture_output=True)
    return subprocess.run(check, cwd=cwd, capture_output=True).returncode == 0


def auto_base(head: str, cwd: str | None = None) -> str | None:
    """The commit a CI run's change is measured against, None when the event has no change."""
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    payload = {}
    if os.environ.get("GITHUB_EVENT_PATH"):
        try:
            with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as f:
                payload = json.load(f)
        except (OSError, ValueError):
            payload = {}
    if event == "pull_request":
        # GitHub's merge commit: its first parent is the branch the pull request goes into. The
        # commit object names its parents even in a shallow checkout.
        parents = [line.split()[1] for line in git("cat-file", "-p", head, cwd=cwd).splitlines()
                   if line.startswith("parent ")]
        if len(parents) == 2:
            return parents[0]
        return ((payload.get("pull_request") or {}).get("base") or {}).get("sha")
    if event == "push":
        before = payload.get("before") or ""
        return None if not before or set(before) == {"0"} else before
    return None


def check(base: str, head: str, cwd: str | None = None, out=print) -> int:
    for sha in (base, head):
        if not have(sha, cwd):
            out(f"::error title=Time limit rule::commit {sha} not found; the change cannot be checked")
            return 1
    diff = git("diff", "-U0", "--no-color", "-M", base, head, "--", *SWIFT_DIRS, WORKFLOW_DIR, cwd=cwd)
    found = loosened(diff)
    added = entries_added(git("diff", "-U0", "--no-color", base, head, "--", ENTRY_FILE, cwd=cwd))
    missing = missing_entries(found, added)
    for f in found:
        state = "NO ENTRY" if f in missing else "entry in " + ENTRY_FILE
        out(f"TIME_LIMIT loosened {f['path']}:{f['line']} {f['old']:g} s -> {f['new']:g} s ({state}): {f['text'][:160]}")
    for f in missing:
        out(f"::error file={f['path']},line={f['line']},title=Time limit loosened without an entry::"
            f"{f['old']:g} s -> {f['new']:g} s. Add a row to {ENTRY_FILE} that says \"{MARKER}\" and names "
            f"{os.path.basename(f['path'])}: why, the measurement (run, seconds) and what would make it tight again "
            "(docs/TESTFLIGHT.md, rule of 19.11.)")
    try:
        text = git("show", f"{head}:{ENTRY_FILE}", cwd=cwd)
    except RuntimeError:
        text = ""
    rows, still_open = count_entries(text)
    out(f"TIME_LIMIT_ENTRIES {rows} loosened limit(s) on record in {ENTRY_FILE}, {still_open} open")
    return 1 if missing else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", required=True, help="auto (from the CI event) or a commit")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    head = git("rev-parse", args.head).strip()
    base = auto_base(head) if args.base == "auto" else args.base
    if not base:
        print(f"TIME_LIMIT no change to check for event {os.environ.get('GITHUB_EVENT_NAME') or '(none)'}")
        return 0
    return check(base, head)


if __name__ == "__main__":
    sys.exit(main())
