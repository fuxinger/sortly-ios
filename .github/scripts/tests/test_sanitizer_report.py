"""Unit tests for sanitizer_report.py (the opt-in Thread Sanitizer run, sanitize.yml).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import sanitizer_report  # noqa: E402

RACE = """Test Case '-[AlbumistTests.ThumbnailTests testBatch]' started.
==================
WARNING: ThreadSanitizer: Swift access race (pid=4242)
  Modifying access of Swift variable at 0x7b0c00001234 by thread T3:
    #0 ThumbnailCache.store(_:for:) ThumbnailCache.swift:41 (Albumist:arm64+0x1000)
    #1 closure #1 in ThumbnailLoader.load() ThumbnailLoader.swift:88 (Albumist:arm64+0x2000)

  Previous read of size 8 at 0x7b0c00001234 by main thread:
    #0 ThumbnailCache.image(for:) ThumbnailCache.swift:30 (Albumist:arm64+0x3000)

SUMMARY: ThreadSanitizer: Swift access race ThumbnailCache.swift:41 in ThumbnailCache.store(_:for:)
==================
Test Case '-[AlbumistTests.ThumbnailTests testBatch]' passed (0.512 seconds).
"""


class ReportTests(unittest.TestCase):
    def test_clean_log_passes(self):
        markdown, marks = sanitizer_report.summary({"app.log": "Test Suite 'All tests' passed\n"})
        self.assertEqual(marks, 0)
        self.assertIn("No ThreadSanitizer report", markdown)

    def test_a_race_is_shown_with_both_stacks_and_fails(self):
        markdown, marks = sanitizer_report.summary({"app.log": RACE})
        self.assertEqual(marks, 2)
        self.assertIn("1x Swift access race ThumbnailCache.swift:41", markdown)
        self.assertIn("#1 closure #1 in ThumbnailLoader.load()", markdown)
        self.assertIn("Previous read of size 8", markdown)

    def test_same_race_twice_is_one_entry_with_its_count(self):
        markdown, _ = sanitizer_report.summary({"a.log": RACE, "b.log": RACE + RACE})
        self.assertIn("3x Swift access race", markdown)
        self.assertIn("**1 distinct report(s)**", markdown)

    def test_lines_outside_a_block_still_fail(self):
        text = "FATAL: ThreadSanitizer: unexpected memory mapping 0x7f0000000000-0x7f0000001000\n"
        markdown, marks = sanitizer_report.summary({"core.log": text})
        self.assertEqual(marks, 1)
        self.assertIn("unexpected memory mapping", markdown)

    def test_an_unrelated_fence_does_not_hide_the_log(self):
        text = "==================\nsome banner\n==================\nThreadSanitizer: reported 1 warnings\n"
        blocks, loose = sanitizer_report.reports(text)
        self.assertEqual(blocks, [])
        self.assertEqual(loose, ["ThreadSanitizer: reported 1 warnings"])

    def test_exit_status(self):
        with tempfile.TemporaryDirectory() as folder:
            clean, dirty = os.path.join(folder, "clean.log"), os.path.join(folder, "dirty.log")
            open(clean, "w").write("ok\n")
            open(dirty, "w").write(RACE)
            with open(os.devnull, "w") as null:
                stdout, stderr = sys.stdout, sys.stderr
                sys.stdout = sys.stderr = null
                try:
                    self.assertEqual(sanitizer_report.main([clean]), 0)
                    self.assertEqual(sanitizer_report.main([clean, dirty]), 1)
                finally:
                    sys.stdout, sys.stderr = stdout, stderr

    def run_main(self, args, files):
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for name, text in files.items():
                path = os.path.join(folder, name)
                with open(path, "w") as f:
                    f.write(text)
                paths.append(path)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = sanitizer_report.main(args + paths)
            return status, out.getvalue() + err.getvalue()

    def test_a_slow_test_under_tsan_is_a_warning(self):
        # Seen on Linux 21.11.: the wall-clock limit of this test fails only under TSan.
        log = ("✘ Test placeHeavyLibraryMatchesQuickly() recorded an issue at DecisionLifecycleTests.swift:662:9: "
               "Expectation failed: (seconds → 13.872977888000001) < (5 → 5.0)\n"
               "✘ Test placeHeavyLibraryMatchesQuickly() failed after 14.1 seconds with 1 issue.\n"
               "✘ Test run with 1568 tests in 204 suites failed after 1418.667 seconds with 7 issues.\n")
        status, out = self.run_main(["--tests", "failure"], {"core.log": log})
        self.assertEqual(status, 0)
        self.assertIn("1 test(s) failed under TSan", out)
        self.assertIn("placeHeavyLibraryMatchesQuickly()", out)

    def test_a_crash_or_a_failed_step_without_a_failed_test_is_red(self):
        status, out = self.run_main(["--tests", "failure"], {"core.log": "✔ Test a() passed\nerror: Exited with unexpected signal code 11\n"})
        self.assertEqual(status, 1)
        self.assertIn("did not run through", out)
        status, _ = self.run_main(["--tests", "failure"], {"core.log": "error: compile failed\n"})
        self.assertEqual(status, 1)
        status, _ = self.run_main(["--tests", "failure"], {"core.log": "TEST_HANG x() running for 2700 s\n✘ Test y() failed\n"})
        self.assertEqual(status, 1)
        # Stopped at the step's time limit: failed tests in the log but no end of the run.
        status, out = self.run_main(["--tests", "failure"], {"core.log": "✘ Test y() failed after 1 seconds with 1 issue.\n"})
        self.assertEqual(status, 1)
        self.assertIn("never reported its end", out)

    def test_a_race_is_red_even_when_every_test_passed(self):
        status, _ = self.run_main(["--tests", "success"], {"core.log": RACE})
        self.assertEqual(status, 1)
        status, _ = self.run_main(["--tests", "success"], {"core.log": "✔ Test a() passed\n"})
        self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
