"""Unit tests for .github/scripts/time_limit_rule.py: a time limit in a test or a workflow is only
loosened together with an entry in docs/IMPROVEMENTS.md (review P5-13 of 18.11.2026).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import time_limit_rule as rule  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))

# The change Build 36 was built from (4bb7fdd, review P5-13): only the wait for the note got longer.
BUILD_36 = """diff --git a/App/AlbumistUITests/AlbumistFlowUITests.swift b/App/AlbumistUITests/AlbumistFlowUITests.swift
--- a/App/AlbumistUITests/AlbumistFlowUITests.swift
+++ b/App/AlbumistUITests/AlbumistFlowUITests.swift
@@ -828 +828,7 @@ final class AlbumistFlowUITests: XCTestCase {
-            let shown = note.waitForExistence(timeout: 5)
+            // The note comes once the app has counted again.
+            let asked = Date()
+            let shown = note.waitForExistence(timeout: 20)
+            print("UI_TIMING ignore note")
"""


def diff(path, removed, added, start=10):
    lines = [f"--- a/{path}", f"+++ b/{path}", f"@@ -{start},{len(removed)} +{start},{len(added)} @@"]
    return "\n".join(lines + ["-" + r for r in removed] + ["+" + a for a in added]) + "\n"


def found(text):
    return [(f["path"].rsplit("/", 1)[-1], f["old"], f["new"]) for f in rule.loosened(text)]


class LoosenedTests(unittest.TestCase):
    def test_the_change_build_36_was_built_from_is_found(self):
        self.assertEqual(found(BUILD_36), [("AlbumistFlowUITests.swift", 5, 20)])
        self.assertEqual(rule.loosened(BUILD_36)[0]["line"], 830)

    def test_a_tighter_a_new_or_an_unchanged_limit_needs_nothing(self):
        ui = "App/AlbumistUITests/A.swift"
        self.assertEqual(found(diff(ui, ["x.waitForExistence(timeout: 20)"], ["x.waitForExistence(timeout: 5)"])), [])
        self.assertEqual(found(diff(ui, [], ["y.waitForExistence(timeout: 60)"])), [])
        self.assertEqual(found(diff(ui, ["x.waitForExistence(timeout: 5) // old"], ["x.waitForExistence(timeout: 5) // new"])), [])
        # A comment is no code: a number in it is no limit.
        self.assertEqual(found(diff(ui, ["// waits 5 s"], ["// waits 20 s (timeout: 20)"])), [])

    def test_the_kinds_of_limits(self):
        ui, unit, flow = "App/AlbumistUITests/A.swift", "Tests/AlbumistCoreTests/B.swift", ".github/workflows/ui.yml"
        self.assertEqual(found(diff(ui, ['UITestWait.appears(x, "plan", timeout: 10)'], ['UITestWait.appears(x, "plan", timeout: 30)'])),
                         [("A.swift", 10, 30)])
        self.assertEqual(found(diff(ui, ["static func until(_ what: String, timeout: TimeInterval = 15) {"],
                                    ["static func until(_ what: String, timeout: TimeInterval = 25) {"])), [("A.swift", 15, 25)])
        self.assertEqual(found(diff(ui, ['timed("atlas", limit: 15, { a() }, until: { b })'],
                                    ['timed("atlas", limit: 20, { a() }, until: { b })'])), [("A.swift", 15, 20)])
        # takeBackNewestPlans(limit: 4) counts plans, not seconds.
        self.assertEqual(found(diff(ui, ["takeBackNewestPlans(limit: 4)"], ["takeBackNewestPlans(limit: 9)"])), [])
        self.assertEqual(found(diff(unit, ["#expect(elapsed < .seconds(3))"], ["#expect(elapsed < .seconds(5))"])),
                         [("B.swift", 3, 5)])
        self.assertEqual(found(diff(unit, ["#expect(t <= .milliseconds(500))"], ["#expect(t <= .seconds(1))"])),
                         [("B.swift", 0.5, 1)])
        self.assertEqual(found(diff(unit, ["@Test(.timeLimit(.minutes(1))) func a() {}"], ["@Test(.timeLimit(.minutes(2))) func a() {}"])),
                         [("B.swift", 60, 120)])
        # A deadline the test builds itself (AlbumistLockedUITests: `Date().addingTimeInterval(900)`).
        self.assertEqual(found(diff(ui, ["let deadline = Date().addingTimeInterval(900)"],
                                    ["let deadline = Date().addingTimeInterval(1200)"])), [("A.swift", 900, 1200)])
        self.assertEqual(found(diff(ui, ["let end = Date(timeIntervalSinceNow: 40)"], ["let end = Date(timeIntervalSinceNow: 60)"])),
                         [("A.swift", 40, 60)])
        # A window moved back from a moment, or computed from a variable, is no deadline.
        self.assertEqual(found(diff(ui, ["reacted.addingTimeInterval(-1)"], ["reacted.addingTimeInterval(-2)"])), [])
        self.assertEqual(found(diff(ui, ["Date().addingTimeInterval(timeout)"], ["Date().addingTimeInterval(timeout * 2)"])), [])
        # Time the test moves forward is no limit.
        self.assertEqual(found(diff(unit, ["clock.advance(by: .seconds(5))"], ["clock.advance(by: .seconds(50))"])), [])
        self.assertEqual(found(diff(flow, ["    timeout-minutes: 60"], ["    timeout-minutes: 85"])), [("ui.yml", 3600, 5100)])
        self.assertEqual(found(diff(flow, ["    timeout-minutes: 60  # the archive"], ["    timeout-minutes: 85  # archive and upload"])),
                         [("ui.yml", 3600, 5100)])

    def test_only_tests_and_workflows(self):
        self.assertEqual(found(diff("Sources/AlbumistCore/A.swift", ["wait(timeout: 5)"], ["wait(timeout: 50)"])), [])
        self.assertEqual(found(diff("App/Albumist/A.swift", ["wait(timeout: 5)"], ["wait(timeout: 50)"])), [])
        self.assertEqual(found(diff("App/AlbumistTests/A.swift", ["wait(for: [e], timeout: 5)"], ["wait(for: [e], timeout: 50)"])),
                         [("A.swift", 5, 50)])

    def test_a_reworded_line_with_a_longer_limit_is_found(self):
        ui = "App/AlbumistUITests/A.swift"
        self.assertEqual(found(diff(ui, ['let shown = note.waitForExistence(timeout: 5)'],
                                    ['let shownNote = note.waitForExistence(timeout: 20)'])), [("A.swift", 5, 20)])
        # A new wait beside an unrelated changed line does not pair with it.
        self.assertEqual(found(diff(ui, ['XCTAssertTrue(app.buttons["Weiter"].waitForExistence(timeout: 5))'],
                                    ['XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5))',
                                     'let sheet = UITestWait.appears(app.sheets.firstMatch, "share sheet", timeout: 30)'])), [])


class EntryTests(unittest.TestCase):
    def test_an_entry_names_the_file(self):
        loose = rule.loosened(BUILD_36)
        self.assertEqual(rule.missing_entries(loose, []), loose)
        added = rule.entries_added("+| 🔜 | Zeitgrenze gelockert: AlbumistFlowUITests.swift test1b 5 -> 20 s | S | UI-Lauf 1 |\n")
        self.assertEqual(rule.missing_entries(loose, added), [])
        other = rule.entries_added("+| 🔜 | Zeitgrenze gelockert: DeviceConditionUITests.swift | S | x |\n")
        self.assertEqual(rule.missing_entries(loose, other), loose)
        # The file named without the marker is no entry.
        self.assertEqual(rule.entries_added("+| 🔜 | AlbumistFlowUITests.swift wartet länger | S | x |\n"), [])

    def test_entries_are_counted(self):
        text = ("| 🔜 | Zeitgrenze gelockert: A.swift | S | x |\n| ✅ | Zeitgrenze gelockert: B.swift, wieder 5 s | S | x |\n"
                "| offen | Zeitgrenze gelockert: C.swift | S | x |\nZeitgrenze gelockert im Fließtext: D.swift\n"
                "| 🔜 | Regel: eine Zeile, die „Zeitgrenze gelockert“ sagt, prüft `time_limit_rule.py` | S | x |\n")
        self.assertEqual(rule.count_entries(text), (3, 2))


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class CheckTests(unittest.TestCase):
    """The rule on a small git repository, as ci.yml runs it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.email", "t@example.com")
        git(self.root, "config", "user.name", "t")
        self.write("App/AlbumistUITests/FlowUITests.swift", "func test1() {\n    XCTAssertTrue(note.waitForExistence(timeout: 5))\n}\n")
        self.write("docs/IMPROVEMENTS.md", "| Status | Punkt |\n|---|---|\n")
        self.base = self.commit()

    def write(self, path, text):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "c")
        return git(self.root, "rev-parse", "HEAD")

    def check(self, base=None):
        lines = []
        code = rule.check(base or self.base, git(self.root, "rev-parse", "HEAD"), cwd=self.root, out=lines.append)
        return code, "\n".join(lines)

    def test_a_longer_wait_without_an_entry_is_red(self):
        self.write("App/AlbumistUITests/FlowUITests.swift", "func test1() {\n    XCTAssertTrue(note.waitForExistence(timeout: 20))\n}\n")
        self.commit()
        code, out = self.check()
        self.assertEqual(code, 1)
        self.assertIn("::error file=App/AlbumistUITests/FlowUITests.swift,line=2,title=Time limit loosened without an entry::5 s -> 20 s", out)
        self.assertIn("TIME_LIMIT_ENTRIES 0", out)

    def test_a_longer_wait_with_an_entry_is_green_and_counted(self):
        self.write("App/AlbumistUITests/FlowUITests.swift", "func test1() {\n    XCTAssertTrue(note.waitForExistence(timeout: 20))\n}\n")
        self.commit()
        # The entry may come in a later commit of the same pull request or push.
        self.write("docs/IMPROVEMENTS.md", "| Status | Punkt |\n|---|---|\n"
                   "| 🔜 | Zeitgrenze gelockert: FlowUITests.swift test1, Hinweis 5 -> 20 s (UI-Lauf 1: 1235 ms) |\n")
        self.commit()
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("TIME_LIMIT loosened App/AlbumistUITests/FlowUITests.swift:2 5 s -> 20 s (entry in docs/IMPROVEMENTS.md)", out)
        self.assertIn("TIME_LIMIT_ENTRIES 1 loosened limit(s) on record in docs/IMPROVEMENTS.md, 1 open", out)

    def test_an_entry_already_there_does_not_count_for_a_new_loosening(self):
        self.write("docs/IMPROVEMENTS.md", "| 🔜 | Zeitgrenze gelockert: FlowUITests.swift, früher |\n")
        base = self.commit()
        self.write("App/AlbumistUITests/FlowUITests.swift", "func test1() {\n    XCTAssertTrue(note.waitForExistence(timeout: 30))\n}\n")
        self.commit()
        self.assertEqual(self.check(base)[0], 1)

    def test_a_tighter_wait_is_green(self):
        self.write("App/AlbumistUITests/FlowUITests.swift", "func test1() {\n    XCTAssertTrue(note.waitForExistence(timeout: 3))\n}\n")
        self.commit()
        self.assertEqual(self.check(), (0, "TIME_LIMIT_ENTRIES 0 loosened limit(s) on record in docs/IMPROVEMENTS.md, 0 open"))

    def test_an_unknown_base_is_red(self):
        self.assertEqual(self.check("0123456789abcdef0123456789abcdef01234567")[0], 1)

    def test_the_base_of_a_ci_event(self):
        head = git(self.root, "rev-parse", "HEAD")
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"before": "0" * 40}, f)
        self.addCleanup(os.unlink, f.name)
        with mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push", "GITHUB_EVENT_PATH": f.name}):
            self.assertIsNone(rule.auto_base(head, cwd=self.root))  # a new branch
        with open(f.name, "w") as out:
            json.dump({"before": self.base}, out)
        with mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push", "GITHUB_EVENT_PATH": f.name}):
            self.assertEqual(rule.auto_base(head, cwd=self.root), self.base)
        # A pull request: GitHub's merge commit against its first parent, the branch it goes into.
        git(self.root, "checkout", "-q", "-b", "topic")
        self.write("App/AlbumistUITests/FlowUITests.swift", "func test1() {\n    XCTAssertTrue(note.waitForExistence(timeout: 20))\n}\n")
        self.commit()
        git(self.root, "checkout", "-q", "main")
        self.write("docs/other.md", "x\n")
        main = self.commit()
        git(self.root, "merge", "-q", "--no-ff", "-m", "merge", "topic")
        merge = git(self.root, "rev-parse", "HEAD")
        with mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": ""}):
            self.assertEqual(rule.auto_base(merge, cwd=self.root), main)
        self.assertEqual(self.check(main)[0], 1)
        for event in ("workflow_dispatch", "schedule", ""):
            with mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": event, "GITHUB_EVENT_PATH": ""}):
                self.assertIsNone(rule.auto_base(merge, cwd=self.root))


class WorkflowTests(unittest.TestCase):
    def test_ci_runs_the_rule_and_it_fails_the_job(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8") as f:
            text = f.read()
        lint = text.split("\n  lint:\n", 1)[1].split("\n  changes:\n", 1)[0]
        step = lint.split("- name: Time limits only loosened with an entry", 1)[1].split("\n      - ", 1)[0]
        self.assertIn("python3 .github/scripts/time_limit_rule.py --base auto", step)
        self.assertNotIn("continue-on-error", step)
        self.assertNotIn("|| true", step)

    def test_the_rule_is_written_down(self):
        with open(os.path.join(ROOT, "docs", "TESTFLIGHT.md"), encoding="utf-8") as f:
            self.assertIn(rule.MARKER, f.read())

    def test_the_main_entry_point(self):
        with mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_EVENT_PATH": ""}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(rule.main(["--base", "auto"]), 0)
        self.assertIn("TIME_LIMIT no change to check for event workflow_dispatch", out.getvalue())


if __name__ == "__main__":
    unittest.main()
