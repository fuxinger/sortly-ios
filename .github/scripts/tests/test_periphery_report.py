"""Unit tests for periphery_report.py and the Periphery pin (code-checks.yml)."""
from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import periphery_report  # noqa: E402
import toolchain  # noqa: E402
from test_toolchain import XcodeGenTests  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def finding(name, location, kind="function.method.instance", hints=("unused",)):
    return {"kind": kind, "name": name, "location": location, "hints": list(hints), "ids": ["s:x"],
            "accessibility": "internal", "modifiers": [], "attributes": []}


class ReportTests(unittest.TestCase):
    def run_main(self, status, findings=None, text=None):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "findings.json")
            if findings is not None or text is not None:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text if text is not None else json.dumps(findings))
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = periphery_report.main(["--status", str(status), path])
            return code, out.getvalue(), err.getvalue()

    def test_findings_do_not_fail(self):
        findings = [finding("old()", "App/Albumist/A.swift:12:10"),
                    finding("count", "Sources/AlbumistCore/B.swift:3:9", "var.instance", ("assignOnlyProperty",)),
                    finding("helper()", "Sources/AlbumistCore/B.swift:40:5")]
        code, out, err = self.run_main(0, findings)
        self.assertEqual(code, 0)
        self.assertIn("3 findings in 2 files", out)
        self.assertIn("| unused | 2 |", out)
        self.assertIn("| assignOnlyProperty | 1 |", out)
        self.assertIn("| Sources/AlbumistCore | 2 |", out)
        self.assertIn("| App/Albumist/A.swift:12 | function.method.instance old() | unused |", out)
        self.assertIn("PERIPHERY findings=3", err)
        # Every finding is in the log, not only the first 40 of the summary.
        self.assertEqual(err.count("PERIPHERY_FINDING "), 3)
        self.assertIn("PERIPHERY_FINDING Sources/AlbumistCore/B.swift:3 | var.instance count | assignOnlyProperty", err)

    def test_no_findings(self):
        code, out, _ = self.run_main(0, [])
        self.assertEqual((code, "No findings." in out), (0, True))

    def test_periphery_that_did_not_scan_fails(self):
        for status in (1, 2, 127):
            code, _, err = self.run_main(status, [])
            self.assertEqual(code, 1, status)
            self.assertIn("did not scan", err)

    def test_unreadable_report_fails(self):
        self.assertEqual(self.run_main(0)[0], 1)
        self.assertEqual(self.run_main(0, text="* Inspecting project...")[0], 1)
        self.assertEqual(self.run_main(0, text="{}")[0], 1)

    def test_long_list_is_cut(self):
        findings = [finding(f"f{n}()", f"Tests/X/A.swift:{n + 1}:1") for n in range(45)]
        self.assertIn("| 5 more (PERIPHERY_FINDING lines in the log, artifact \"periphery\") | | |", periphery_report.summary(findings, listed=40))


class PinTests(unittest.TestCase):
    def test_pinned_in_the_lint_file(self):
        pin = toolchain.lint_pins()["periphery"]
        self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(pin["url"].startswith(f"https://github.com/peripheryapp/periphery/releases/download/{pin['version']}/"))
        self.assertEqual(pin["binary"], "periphery")

    def test_install_checks_the_checksum(self):
        data = XcodeGenTests.archive({"periphery": "#!/bin/sh\necho 3.8.0\n", "libIndexStore.dylib": "x"})
        pin = {"version": "3.8.0", "url": "u", "sha256": hashlib.sha256(data).hexdigest(), "binary": "periphery"}
        with tempfile.TemporaryDirectory() as dest:
            folder = toolchain.install_periphery(pin, dest, fetch=lambda url: data)
            self.assertTrue(os.access(os.path.join(folder, "periphery"), os.X_OK))
            self.assertTrue(os.path.isfile(os.path.join(folder, "libIndexStore.dylib")))
        with tempfile.TemporaryDirectory() as dest, self.assertRaisesRegex(ValueError, "Periphery 3.8.0 download has sha256"):
            toolchain.install_periphery(dict(pin, sha256="0" * 64), dest, fetch=lambda url: data)


class WorkflowTests(unittest.TestCase):
    def test_wiring(self):
        with open(os.path.join(ROOT, ".github", "workflows", "code-checks.yml"), encoding="utf-8") as f:
            text = f.read()
        self.assertIn("toolchain.py periphery", text)
        self.assertIn("--skip-build", text)
        self.assertIn("COMPILER_INDEX_STORE_ENABLE=YES", text)
        self.assertNotIn("actions/cache", text)
        self.assertNotIn("continue-on-error", text)
        self.assertNotIn("mac-queue", text)
        self.assertIn("persist-credentials: false", text)
        # The report goes to the log too, and its exit status is not lost in the pipe (macOS
        # runs "bash -e" without pipefail).
        self.assertIn("| tee -a \"$GITHUB_STEP_SUMMARY\"", text)
        self.assertIn("set -o pipefail", text)


if __name__ == "__main__":
    unittest.main()
