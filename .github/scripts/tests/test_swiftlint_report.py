"""Unit tests for swiftlint_report.py (ci.yml, "SwiftLint")."""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import swiftlint_report  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def finding(rule, path, severity="Warning"):
    return {"rule_id": rule, "file": path, "severity": severity, "line": 1, "character": 1, "reason": "r", "type": "t"}


class ReportTests(unittest.TestCase):
    def run_main(self, status, findings=None, text=None, baseline=None, stderr=None, extra=()):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "findings.json")
            if findings is not None or text is not None:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text if text is not None else json.dumps(findings))
            args = ["--status", str(status)]
            if baseline is not None:
                args += ["--baseline", os.path.join(folder, "baseline.json")]
                if baseline != "missing":
                    with open(args[-1], "w", encoding="utf-8") as f:
                        f.write(swiftlint_report.baseline_file(baseline))
            if stderr is not None:
                args += ["--stderr", os.path.join(folder, "stderr.txt")]
                with open(args[-1], "w", encoding="utf-8") as f:
                    f.write(stderr)
            counts_path = os.path.join(folder, "counts.json")
            args += ["--write-counts", counts_path, *extra, path]
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = swiftlint_report.main(args)
            self.counts = None
            if os.path.exists(counts_path):
                with open(counts_path, encoding="utf-8") as f:
                    self.counts = json.load(f)
            return code, out.getvalue(), err.getvalue()

    def test_findings_without_baseline_do_not_fail(self):
        findings = [finding("line_length", "Sources/AlbumistCore/A.swift"),
                    finding("line_length", "Sources/AlbumistCore/B.swift"),
                    finding("force_cast", "App/Albumist/C.swift", "Error")]
        for status in (0, 2):
            code, out, err = self.run_main(status, findings, baseline="missing")
            self.assertEqual(code, 0)
            self.assertIn("No baseline yet", out)
            self.assertIn("3 findings in 3 files: 1 errors, 2 warnings", out)
            self.assertIn("| line_length | warning | 2 |", out)
            self.assertIn("| Sources/AlbumistCore | 2 |", out)
            self.assertIn("SWIFTLINT findings=3 new=0", err)
            self.assertIn("::warning title=SwiftLint::no baseline", err)

    def test_counts_within_the_baseline_pass(self):
        findings = [finding("line_length", "A.swift"), finding("line_length", "A.swift"), finding("force_try", "B.swift")]
        baseline = {"A.swift": {"line_length": 2}, "B.swift": {"force_try": 3}, "Gone.swift": {"nesting": 1}}
        code, out, err = self.run_main(2, findings, baseline=baseline)
        self.assertEqual(code, 0, err)
        self.assertIn("No new findings.", out)
        self.assertIn("3 fewer than the baseline allows", out)
        self.assertIn("::warning title=SwiftLint baseline::3 findings fewer", err)
        self.assertEqual(self.counts["files"], {"A.swift": {"line_length": 2}, "B.swift": {"force_try": 1}})

    def test_one_more_finding_fails(self):
        findings = [finding("line_length", "A.swift"), finding("line_length", "A.swift"), finding("nesting", "New.swift")]
        baseline = {"A.swift": {"line_length": 1, "nesting": 5}}
        code, out, err = self.run_main(0, findings, baseline=baseline)
        self.assertEqual(code, 1)
        self.assertIn("**2 new findings** in 2 files", out)
        self.assertIn("| A.swift | line_length | 2 | 1 |", out)
        self.assertIn("| New.swift | nesting | 1 | 0 |", out)
        # Every finding of an over-count file and rule is marked: the count cannot say which is new.
        self.assertEqual(err.count("::error file=A.swift,line=1,title=SwiftLint line_length (2 in this file; baseline 1)"), 2)
        self.assertIn("::error file=New.swift", err)
        self.assertIn("SWIFTLINT findings=3 new=2", err)

    def test_a_rule_moving_between_files_is_new(self):
        code, _, _ = self.run_main(0, [finding("line_length", "B.swift")], baseline={"A.swift": {"line_length": 1}})
        self.assertEqual(code, 1)

    def test_annotations_are_capped(self):
        findings = [finding("line_length", "A.swift") for _ in range(swiftlint_report.MAX_ANNOTATIONS + 7)]
        code, _, err = self.run_main(0, findings, baseline={})
        self.assertEqual(code, 1)
        self.assertEqual(err.count("::error file="), swiftlint_report.MAX_ANNOTATIONS)
        self.assertIn("and 7 more findings", err)

    def test_absolute_and_relative_paths_count_alike(self):
        absolute = os.path.join(os.getcwd(), "Sources", "AlbumistCore", "A.swift")
        counts = swiftlint_report.count([finding("x", absolute), finding("x", "Sources/AlbumistCore/A.swift")])
        self.assertEqual(counts, {"Sources/AlbumistCore/A.swift": {"x": 2}})

    def test_no_findings(self):
        code, out, _ = self.run_main(0, [], baseline={})
        self.assertEqual(code, 0)
        self.assertIn("No findings.", out)

    def test_swiftlint_that_did_not_lint_fails(self):
        for status in (1, 3, 127):
            code, _, err = self.run_main(status, [])
            self.assertEqual(code, 1, status)
            self.assertIn("did not lint", err)

    def test_unreadable_report_fails(self):
        self.assertEqual(self.run_main(0)[0], 1)  # no file
        self.assertEqual(self.run_main(0, text="Linting Swift files")[0], 1)
        self.assertEqual(self.run_main(2, text="{}")[0], 1)

    def test_a_setting_swiftlint_rejects_fails(self):
        # SwiftLint falls back to a rule's default on a setting it does not take, and lints on.
        known = ("warning: Skipping enabled rule 'statement_position' because it requires SourceKit and SourceKit "
                 "access is prohibited.\n")
        self.assertEqual(self.run_main(0, [], baseline={}, stderr=known + "\n")[0], 0)
        for line in ("warning: Configuration for 'line_length' rule contains the invalid key(s) 'ignore_urls'.",
                     "Invalid configuration for 'identifier_name' rule. Falling back to default.",
                     "warning: Skipping enabled rule 'nesting' because it requires SourceKit"):
            code, _, err = self.run_main(0, [], baseline={}, stderr=known + line + "\n")
            self.assertEqual(code, 1, line)
            self.assertIn("warned about its setup", err)

    def test_counts_survive_the_log(self):
        findings = [finding(f"rule_{n % 7}", f"Sources/M{n % 50}/F{n}.swift") for n in range(3000)]
        _, _, err = self.run_main(0, findings, baseline={})
        # The way the API returns a job log: every line with a time stamp in front.
        log = "\n".join(f"2026-11-21T05:00:00.0000000Z {line}" for line in err.splitlines())
        self.assertEqual(swiftlint_report.decode(log), self.counts["files"])
        self.assertEqual(swiftlint_report.decode(log), swiftlint_report.count(findings))
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "job.log")
            with open(path, "w", encoding="utf-8") as f:
                f.write(log)
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(swiftlint_report.main(["--decode-log", path]), 0)
            self.assertEqual(json.loads(out.getvalue())["files"], self.counts["files"])

    def test_incomplete_or_mixed_log_is_refused(self):
        lines = swiftlint_report.encode({"A.swift": {"x": n} for n in range(1)} | {f"F{n}.swift": {"y": n} for n in range(400)})
        self.assertGreater(len(lines), 2)
        with self.assertRaises(ValueError):
            swiftlint_report.decode("\n".join(lines[:-1]))
        with self.assertRaises(ValueError):
            swiftlint_report.decode("\n".join(lines + swiftlint_report.encode({"B.swift": {"z": 1}})))
        with self.assertRaises(ValueError):
            swiftlint_report.decode("nothing here")

    def test_long_rule_list_is_cut(self):
        findings = [finding(f"rule_{n:02d}", "Tests/X/A.swift") for n in range(30)]
        out = swiftlint_report.summary(findings, None, 0, top=25)
        self.assertIn("| 5 more rules | | 5 |", out)

    def test_absolute_paths_are_made_relative(self):
        self.assertEqual(swiftlint_report.folder(os.path.join(os.getcwd(), "Sources", "AlbumistCore", "A.swift")),
                         "Sources/AlbumistCore")
        self.assertEqual(swiftlint_report.folder("Package.swift"), "Package.swift")


class BaselineFileTests(unittest.TestCase):
    """The committed baseline (first counted 21.11.2026 in CI run 44871082263: 1,060 findings in
    206 files after the rules were tuned) exists, reads, and names only files that are there."""

    def test_the_baseline_is_committed_and_names_real_files(self):
        with open(os.path.join(ROOT, ".github", "swiftlint-baseline.json"), encoding="utf-8") as f:
            baseline = json.load(f)
        self.assertEqual(baseline["_comment"], swiftlint_report.BASELINE_COMMENT)
        files = baseline["files"]
        self.assertGreater(len(files), 0)
        for path, rules in files.items():
            self.assertFalse(os.path.isabs(path), path)
            self.assertTrue(rules and all(isinstance(n, int) and n > 0 for n in rules.values()), path)
        # A baseline for a file that is gone allows nothing; one that names many missing files
        # was written from another tree.
        missing = [p for p in files if not os.path.exists(os.path.join(ROOT, p))]
        self.assertLessEqual(len(missing), 5, missing[:10])


class WorkflowTests(unittest.TestCase):
    """The job fails on new findings and on a broken setup; it never runs in a release."""

    def test_job_wiring(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8") as f:
            text = f.read()
        job = text[text.index("\n  swiftlint:\n"):text.index("\n  changes:\n")]
        self.assertIn("if: ${{ !inputs.release }}", job)
        self.assertIn("--no-cache", job)
        self.assertIn("--config .github/swiftlint.yml", job)
        self.assertIn("toolchain.py swiftlint", job)
        self.assertNotIn("actions/cache", job)
        self.assertNotIn("continue-on-error", job)
        self.assertNotRegex(text, r"needs:[^\n]*swiftlint")
        self.assertIn("persist-credentials: false", job)
        self.assertIn("| tee -a \"$GITHUB_STEP_SUMMARY\"", job)
        self.assertIn("shell: bash", job)  # GitHub's "bash" runs with -o pipefail
        self.assertIn("2> swiftlint/stderr.txt", job)
        self.assertIn("--stderr swiftlint/stderr.txt", job)
        self.assertIn("--baseline .github/swiftlint-baseline.json", job)
        # Every folder with Swift code is linted; leaving one out would lower the counts unseen.
        self.assertIn("--reporter json \\\n            App Sources Tests Package.swift > swiftlint/findings.json", job)


if __name__ == "__main__":
    unittest.main()
