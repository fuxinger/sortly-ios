"""Unit tests for .github/scripts/swiftlint_rule.py: SwiftLint is only loosened (a count in
.github/swiftlint-baseline.json raised, .github/swiftlint.yml changed) together with an entry in
docs/IMPROVEMENTS.md.

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
import swiftlint_report  # noqa: E402
import swiftlint_rule as rule  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class RaisedTests(unittest.TestCase):
    def test_higher_and_new_counts_are_raised(self):
        base = {"A.swift": {"line_length": 3, "nesting": 1}}
        head = {"A.swift": {"line_length": 4, "nesting": 0}, "B.swift": {"force_try": 1}}
        self.assertEqual(rule.raised(base, head), [("A.swift", "line_length", 3, 4), ("B.swift", "force_try", 0, 1)])

    def test_lower_equal_and_removed_counts_are_not(self):
        base = {"A.swift": {"line_length": 3}, "Gone.swift": {"nesting": 2}}
        self.assertEqual(rule.raised(base, {"A.swift": {"line_length": 3}}), [])
        self.assertEqual(rule.raised(base, {"A.swift": {"line_length": 1}}), [])


class CheckTests(unittest.TestCase):
    """The rule on a small git repository, as ci.yml runs it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.email", "t@example.com")
        git(self.root, "config", "user.name", "t")
        self.write(rule.CONFIG, "disabled_rules: []\n")
        self.write("docs/IMPROVEMENTS.md", "| Status | Punkt |\n|---|---|\n")
        self.base = self.commit()

    def write(self, path, text):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)

    def baseline(self, counts):
        self.write(rule.BASELINE, swiftlint_report.baseline_file(counts))

    def entry(self, text):
        with open(os.path.join(self.root, "docs/IMPROVEMENTS.md"), "a", encoding="utf-8") as f:
            f.write(text + "\n")

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "c")
        return git(self.root, "rev-parse", "HEAD")

    def check(self, base=None):
        lines = []
        code = rule.check(base or self.base, git(self.root, "rev-parse", "HEAD"), cwd=self.root, out=lines.append)
        return code, "\n".join(lines)

    def test_the_first_baseline_needs_nothing(self):
        self.baseline({"A.swift": {"line_length": 3}})
        self.commit()
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("first baseline", out)

    def test_a_raised_count_without_an_entry_is_red(self):
        self.baseline({"A.swift": {"line_length": 3}})
        base = self.commit()
        self.baseline({"A.swift": {"line_length": 4}})
        self.commit()
        code, out = self.check(base)
        self.assertEqual(code, 1)
        self.assertIn("SWIFTLINT_RULE raised A.swift line_length 3 -> 4 (NO ENTRY)", out)
        self.assertIn("::error file=.github/swiftlint-baseline.json", out)

    def test_a_raised_count_with_an_entry_naming_the_file_is_green(self):
        self.baseline({"Sources/X/A.swift": {"line_length": 3}})
        base = self.commit()
        self.baseline({"Sources/X/A.swift": {"line_length": 4}, "Sources/X/B.swift": {"nesting": 1}})
        self.entry("| 🔜 | SwiftLint gelockert: A.swift und B.swift, generierter Code |")
        self.commit()
        code, out = self.check(base)
        self.assertEqual(code, 0, out)
        # An entry that names another file does not count.
        self.baseline({"Sources/X/A.swift": {"line_length": 4}, "Sources/X/B.swift": {"nesting": 1}, "C.swift": {"x": 1}})
        self.commit()
        self.assertEqual(self.check(base)[0], 1)

    def test_lower_counts_need_nothing(self):
        self.baseline({"A.swift": {"line_length": 3}, "B.swift": {"nesting": 1}})
        base = self.commit()
        self.baseline({"A.swift": {"line_length": 1}})
        self.commit()
        self.assertEqual(self.check(base)[0], 0)

    def test_removing_the_baseline_is_red_without_an_entry(self):
        self.baseline({"A.swift": {"line_length": 3}})
        base = self.commit()
        os.remove(os.path.join(self.root, rule.BASELINE))
        self.commit()
        code, out = self.check(base)
        self.assertEqual(code, 1)
        self.assertIn("baseline removed", out)

    def test_a_settings_change_needs_a_line_naming_the_file(self):
        self.write(rule.CONFIG, "disabled_rules:\n  - nesting\n")
        self.commit()
        code, out = self.check()
        self.assertEqual(code, 1)
        self.assertIn(".github/swiftlint.yml changed (NO ENTRY)", out)
        self.entry("| ✅ | swiftlint.yml: nesting aus, weil ... |")
        self.commit()
        self.assertEqual(self.check()[0], 0)

    def test_a_disable_comment_in_code_needs_an_entry(self):
        self.write("Sources/X/A.swift", "let a = 1\n")
        base = self.commit()
        self.write("Sources/X/A.swift", "// swiftlint:disable:next force_try\nlet a = try! f()\n")
        self.commit()
        code, out = self.check(base)
        self.assertEqual(code, 1)
        self.assertIn("disable comment added in Sources/X/A.swift (NO ENTRY)", out)
        self.entry("| 🔜 | SwiftLint gelockert: A.swift, try! in einem Testhelfer |")
        self.commit()
        self.assertEqual(self.check(base)[0], 0)

    def test_a_disable_comment_outside_swift_code_needs_nothing(self):
        self.write("docs/NOTES.md", "swiftlint:disable is how a rule is switched off in code\n")
        self.commit()
        self.assertEqual(self.check()[0], 0)

    def test_the_counting_and_the_pinned_version_need_a_line(self):
        for path, name in ((".github/scripts/swiftlint_report.py", "swiftlint_report.py"),
                           (".github/lint-tools.json", "lint-tools.json")):
            with self.subTest(path):
                self.write(path, f"changed {name}\n")
                base = git(self.root, "rev-parse", "HEAD")
                self.commit()
                code, out = self.check(base)
                self.assertEqual(code, 1)
                self.assertIn(f"{path} changed (NO ENTRY)", out)
                self.write(path, f"changed {name} again\n")
                self.entry(f"| ✅ | {name}: neue Version, die Regeln ... |")
                self.commit()
                self.assertEqual(self.check(git(self.root, "rev-parse", "HEAD~1"))[0], 0)

    def test_an_unknown_base_is_red(self):
        self.assertEqual(self.check("0" * 40)[0], 1)


class WorkflowTests(unittest.TestCase):
    def test_ci_runs_the_rule_and_it_fails_the_job(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8") as f:
            text = f.read()
        lint = text.split("\n  lint:\n", 1)[1].split("\n  changes:\n", 1)[0]
        step = lint.split("- name: SwiftLint only loosened with an entry", 1)[1].split("\n      - ", 1)[0]
        self.assertIn("python3 .github/scripts/swiftlint_rule.py --base auto", step)
        self.assertNotIn("continue-on-error", step)
        self.assertNotIn("|| true", step)

    def test_the_main_entry_point(self):
        with mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_EVENT_PATH": ""}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(rule.main(["--base", "auto"]), 0)
        self.assertIn("SWIFTLINT_RULE no change to check for event workflow_dispatch", out.getvalue())


if __name__ == "__main__":
    unittest.main()
