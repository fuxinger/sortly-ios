"""Hang watch (250 ms) and Main Thread Checker of the UI runs: ui_tests.py hang_report,
main_thread_checker_report, quality_gates, mtc_dylib, collect_console (owner's decision 16.11.2026).
Log lines as the app writes them (MainThreadWatch, MainThreadCheckerProbe) and as Xcode's checker
prints them. Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ui_tests  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
PREFIX = "2026-11-21 05:01:02.123 F  Albumist[4321:9876] [app.albumist.ios:uitest] "
OURS = ("SwiftUICore AG::Graph::UpdateStack::update() | Albumist.debug.dylib closure #1 in "
        "OverviewView.body.getter | Albumist.debug.dylib AppModel.tick()")
SYSTEM_LOG = "\n".join([
    PREFIX + "UI_FACT main thread checker active",
    PREFIX + f"UI_MAIN_HANG 312 ms app in [overview body]: {OURS}",
    PREFIX + f"UI_MAIN_HANG 905 ms app in [unmarked]: {OURS}",
    PREFIX + "UI_MAIN_HANG 410 ms app in [plan review: order]: Albumist.debug.dylib PlanReviewView.order()",
    PREFIX + "UI_MAIN_HANG 2400 ms test in [unmarked]: XCTAutomationSupport x | Albumist.debug.dylib V.body",
    PREFIX + "UI_MAIN_HANG 3100 ms start in [unmarked]: libsystem_kernel.dylib mach_msg2_trap",
    PREFIX + "UI_MAIN_HANG 190 ms app in [unmarked]: Albumist.debug.dylib Tiny.work()",
    PREFIX + "UI_MAIN_HANG 210 ms app in [unmarked]: Albumist.debug.dylib Near.work()",
    PREFIX + "UI_MAIN_HANG 700 ms starved in [unmarked]: Albumist.debug.dylib V.body",
    PREFIX + "UI_FACT main thread checker not active",
])
# As libMainThreadChecker prints a report to the app's stderr.
CONSOLE = """=== Albumist launch 4321
Main Thread Checker: UI API called on a background thread: -[UIView setNeedsLayout]
PID: 4321, TID: 99, Thread name: (none), Queue name: com.apple.root.default-qos, QoS: 0
Backtrace:
4   Albumist.debug.dylib                0x0000000104a1b2c4 $s8Albumist22MainThreadCheckerProbeO18fireFromBackgroundyyFZ + 40
5   Foundation                          0x0000000180a2b3c4 __NSThread__start__ + 732
=== Albumist launch 4400
Main Thread Checker: UI API called on a background thread: -[UIApplication applicationState]
PID: 4400, TID: 120, Thread name: (none), Queue name: com.apple.root.utility-qos, QoS: 17
Backtrace:
4   Albumist.debug.dylib                0x0000000104a1c000 AppModel.backgroundCheck() + 88
5   Albumist.debug.dylib                0x0000000104a1c100 closure #1 in AppModel.start() + 12
6   libdispatch.dylib                   0x0000000180a00000 _dispatch_call_block_and_release + 32
some later line of the app
"""


def gate(hangs="report", mtc="report", known_hangs=(), known_mtc=()):
    return {"hangs": {"mode": hangs, "limit_ms": 250, "known": list(known_hangs)},
            "main_thread_checker": {"mode": mtc, "probe": True, "known": list(known_mtc)}}


class HangReportTests(unittest.TestCase):
    def run_report(self, settings):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "g-swiftui.txt")
            summary = os.path.join(tmp, "summary.md")
            with open(log, "w") as f:
                f.write(SYSTEM_LOG)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                result = ui_tests.hang_report("g", log, settings, summary=summary)
            with open(summary) as f:
                return result, out.getvalue(), f.read()

    def test_counts_by_kind_and_only_app_hangs_count(self):
        (new, total), out, summary = self.run_report(gate())
        # 210 ms counts (measured up to 50 ms short, MAIN_HANG_SLACK_MS), 190 ms does not.
        self.assertEqual((new, total), (4, 4))
        self.assertIn("UI_HANG_COUNT g app 4 (longest 905 ms, total 1837 ms)", out)
        self.assertIn("UI_HANG_COUNT g starved 1", out)
        self.assertIn("UI_HANG_COUNT g unknown 0", out)
        self.assertIn("UI_HANG_COUNT g test 1", out)
        self.assertIn("UI_HANG_COUNT g start 1", out)
        self.assertIn("UI_HANG_COUNT g system 0", out)
        self.assertIn("app 4, test 1, start 1, inactive 0, starved 1, system 0, unknown 0", summary)

    def test_one_line_per_place_longest_first(self):
        _, out, summary = self.run_report(gate())
        lines = [l for l in out.splitlines() if l.startswith("UI_HANG_APP")]
        self.assertEqual(len(lines), 3)
        self.assertTrue(lines[0].startswith("UI_HANG_APP g 2x longest 905 ms (new) in [overview body, unmarked]"))
        self.assertIn("PlanReviewView.order()", lines[1])
        self.assertIn("Near.work()", lines[2])
        self.assertIn("| 2 | 905 ms | new |", summary)

    def test_report_mode_warns_and_fail_mode_errors(self):
        _, out, _ = self.run_report(gate())
        self.assertIn("::warning title=UI g hangs::4 hang(s)", out)
        _, out, _ = self.run_report(gate(hangs="fail"))
        self.assertIn("::error title=UI g hangs::4 hang(s)", out)

    def test_known_places_do_not_count_as_new(self):
        (new, total), out, _ = self.run_report(gate(hangs="fail", known_hangs=[{"stack": "PlanReviewView.order()", "why": "N-09"}]))
        self.assertEqual((new, total), (3, 4))
        self.assertIn("(known: N-09)", out)

    def test_no_log_means_nothing_found(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(ui_tests.hang_report("g", "/nonexistent", gate(), summary=""), (0, 0))


class MainThreadCheckerTests(unittest.TestCase):
    def run_report(self, console, system_log=SYSTEM_LOG, settings=None):
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(out):
            new = ui_tests.main_thread_checker_report("g", console, system_log, settings or gate(),
                                                      summary=os.path.join(tmp, "s.md"))
        return new, out.getvalue()

    def test_reports_are_parsed_with_their_frames(self):
        reports = ui_tests.parse_mtc(CONSOLE)
        self.assertEqual([r["api"] for r in reports], ["UI API called on a background thread: -[UIView setNeedsLayout]",
                                                       "UI API called on a background thread: -[UIApplication applicationState]"])
        self.assertEqual(reports[1]["frames"][0], "Albumist.debug.dylib AppModel.backgroundCheck() + 88")
        self.assertEqual(len(reports[1]["frames"]), 3)  # the later app line ends the report

    def test_the_probe_never_counts_and_a_real_report_does(self):
        new, out = self.run_report(CONSOLE)
        self.assertEqual(new, 1)
        self.assertIn("probe reports 1, other reports 1", out)
        self.assertIn("UI_MTC g 1x (new) UI API called on a background thread: -[UIApplication applicationState] @ "
                      "Albumist.debug.dylib AppModel.backgroundCheck() + 88 | Albumist.debug.dylib closure #1 in AppModel.start() + 12", out)
        self.assertIn("::warning title=UI g Main Thread Checker::1 report(s)", out)
        new, out = self.run_report(CONSOLE, settings=gate(mtc="fail"))
        self.assertIn("::error title=UI g Main Thread Checker::1 report(s)", out)

    def test_a_launch_without_the_checker_or_a_missing_probe_is_said(self):
        _, out = self.run_report(CONSOLE)
        self.assertIn("1 launch(es) without the Main Thread Checker", out)
        new, out = self.run_report("")
        self.assertEqual(new, 0)
        self.assertIn("only 0 of 1 launches' deliberate probe reports", out)

    def test_fewer_probes_than_launches_with_the_checker_is_said(self):
        two = SYSTEM_LOG + "\n" + PREFIX + "UI_FACT main thread checker active"
        _, out = self.run_report(CONSOLE, system_log=two)
        self.assertIn("only 1 of 2 launches' deliberate probe reports", out)

    def test_known_reports_do_not_count(self):
        new, out = self.run_report(CONSOLE, settings=gate(mtc="fail", known_mtc=[{"api": "applicationState", "why": "N-10"}]))
        self.assertEqual(new, 0)
        self.assertIn("(known: N-10)", out)
        self.assertNotIn("::error", out)


class GateTests(unittest.TestCase):
    def test_the_shipped_gate_file_is_valid_and_starts_in_report_mode(self):
        with open(os.path.join(ROOT, ui_tests.GATE_FILE)) as f:
            data = json.load(f)
        self.assertEqual(data["hangs"]["limit_ms"], 250)
        for key in ("hangs", "main_thread_checker"):
            self.assertIn(data[key]["mode"], ("report", "fail"))
            for entry in data[key]["known"]:
                self.assertTrue(entry.get("why"), entry)
                self.assertTrue(entry.get("stack") or entry.get("api"), entry)

    def test_a_broken_gate_file_only_reports(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{ not json")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            loaded = ui_tests.load_gate(f.name)
        os.unlink(f.name)
        self.assertEqual(loaded["hangs"]["mode"], "report")
        self.assertEqual(loaded["main_thread_checker"]["mode"], "report")

    def test_red_only_in_fail_mode_with_something_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "g-swiftui.txt")
            with open(log, "w") as f:
                f.write(SYSTEM_LOG)
            env = dict(os.environ)
            old = ui_tests.MTC_DYLIB
            os.environ.pop("GITHUB_STEP_SUMMARY", None)
            try:
                ui_tests.MTC_DYLIB = "/R/usr/lib/libMainThreadChecker.dylib"
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertFalse(ui_tests.quality_gates("g", log, CONSOLE, gate()))
                    self.assertTrue(ui_tests.quality_gates("g", log, CONSOLE, gate(hangs="fail")))
                    self.assertTrue(ui_tests.quality_gates("g", log, CONSOLE, gate(mtc="fail")))
                    self.assertFalse(ui_tests.quality_gates("g", log, "", gate(mtc="fail")))
                    self.assertFalse(ui_tests.quality_gates("g", log, "", gate()))
                # In fail mode a group without the checker is loud (warning, UI_MTC_UNCHECKED) but
                # not red: a preflight hiccup must not block an upload through release-smoke or stress.
                ui_tests.MTC_DYLIB = ""
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertFalse(ui_tests.quality_gates("g", log, "", gate(mtc="fail")))
                self.assertIn("UI_MTC_UNCHECKED g", out.getvalue())
                self.assertIn("WITHOUT the checker", out.getvalue())
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertTrue(ui_tests.quality_gates("g", log, CONSOLE, gate(mtc="fail")))
            finally:
                ui_tests.MTC_DYLIB = old
                os.environ.clear()
                os.environ.update(env)

    def test_a_broken_report_never_hides_the_result(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertFalse(ui_tests.quality_gates("g", "/nonexistent", CONSOLE, {"hangs": {}}))
        self.assertIn("report failed", out.getvalue())

    def test_the_system_log_does_not_list_our_lines_as_runtime_warnings(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write(SYSTEM_LOG)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            ui_tests.swiftui_warnings(f.name)
        os.unlink(f.name)
        self.assertNotIn("UI_MAIN_HANG", out.getvalue())
        self.assertNotIn("main thread checker", out.getvalue())


class MacSideTests(unittest.TestCase):
    def test_the_library_of_the_devices_runtime(self):
        devices = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [{"udid": "OTHER"}],
                                          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": "U"}]}})
        runtimes = json.dumps({"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "runtimeRoot": "/R26"},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "runtimeRoot": "/R27"}]})
        run = lambda cmd, **kw: (0, devices if cmd[3] == "devices" else runtimes)
        self.assertEqual(ui_tests.mtc_dylib("U", run, exists=lambda p: True), "/R27/usr/lib/libMainThreadChecker.dylib")
        self.assertEqual(ui_tests.mtc_dylib("U", run, exists=lambda p: False), "")
        self.assertEqual(ui_tests.mtc_dylib("NONE", run, exists=lambda p: True), "")
        self.assertEqual(ui_tests.mtc_dylib("U", lambda cmd, **kw: (1, "no simctl"), exists=lambda p: True), "")
        self.assertEqual(ui_tests.mtc_dylib("U", lambda cmd, **kw: (0, "not json"), exists=lambda p: True), "")

    def test_the_preflight_keeps_the_checker_only_when_an_app_survives_it(self):
        calls = []

        def run(alive):
            def inner(cmd, **kw):
                calls.append((cmd, os.environ.get("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES")))
                if cmd[:3] == ["xcrun", "simctl", "launch"]:
                    return 0, "com.apple.Preferences: 4711\n"
                if cmd[0] == "ps":
                    return (0 if alive else 1), ""
                return 0, ""
            return inner
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(ui_tests.mtc_preflight("U", "/R/lib.dylib", run(True), sleep=lambda s: None))
            self.assertFalse(ui_tests.mtc_preflight("U", "/R/lib.dylib", run(False), sleep=lambda s: None))
            tries = []
            self.assertFalse(ui_tests.mtc_preflight("U", "/R/lib.dylib", lambda cmd, **kw: tries.append(cmd) or (1, "error"),
                                                    sleep=lambda s: None))
            self.assertEqual(len(tries), 2)  # once more after a pause, then without the checker
        launch = [c for c in calls if c[0][:3] == ["xcrun", "simctl", "launch"]][0]
        self.assertEqual(launch[1], "/R/lib.dylib")  # inserted into the launched app only
        self.assertNotIn("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES", os.environ)
        self.assertEqual([c[0][1] for c in calls if c[0][0] == "ps"], ["-p", "-p"])

    def test_a_gate_file_with_the_wrong_shape_only_reports(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"hangs": "fail"}')
        with contextlib.redirect_stdout(io.StringIO()):
            loaded = ui_tests.load_gate(f.name)
        os.unlink(f.name)
        self.assertEqual(loaded["hangs"]["mode"], "report")
        self.assertTrue(loaded["main_thread_checker"]["inject"])

    def test_the_runner_hands_the_checker_to_the_tests(self):
        old = ui_tests.MTC_DYLIB, ui_tests.MTC_PROBE_ON
        try:
            ui_tests.MTC_DYLIB, ui_tests.MTC_PROBE_ON = "/x/libMainThreadChecker.dylib", True
            env = ui_tests.runner_env({})
            self.assertEqual(env["TEST_RUNNER_ALBUMIST_MTC_DYLIB"], "/x/libMainThreadChecker.dylib")
            self.assertEqual(env["TEST_RUNNER_ALBUMIST_MTC_PROBE"], "1")
            ui_tests.MTC_DYLIB = ""
            self.assertNotIn("TEST_RUNNER_ALBUMIST_MTC_DYLIB", ui_tests.runner_env({}))
        finally:
            ui_tests.MTC_DYLIB, ui_tests.MTC_PROBE_ON = old

    def test_the_console_file_is_copied_and_emptied(self):
        with tempfile.TemporaryDirectory() as container, tempfile.TemporaryDirectory() as out:
            os.makedirs(os.path.join(container, "tmp"))
            with open(os.path.join(container, "tmp", ui_tests.CONSOLE_FILE), "w") as f:
                f.write(CONSOLE)
            run = lambda cmd, **kw: (0, container + "\n")
            self.assertEqual(ui_tests.collect_console("U", out, "g", "first", run), CONSOLE)
            self.assertFalse(os.path.exists(os.path.join(container, "tmp", ui_tests.CONSOLE_FILE)))
            with open(os.path.join(out, "g-console-first.txt")) as f:
                self.assertEqual(f.read(), CONSOLE)
            self.assertEqual(ui_tests.collect_console("U", out, "g", "retry", run), "")
            self.assertEqual(ui_tests.collect_console("U", out, "g", "x", lambda cmd, **kw: (1, "No such app")), "")

    def test_the_app_and_the_tests_agree_on_names(self):
        with open(os.path.join(ROOT, "App", "Albumist", "Platform", "UITestSupport.swift"), encoding="utf-8") as f:
            app = f.read()
        with open(os.path.join(ROOT, "App", "AlbumistUITests", "UITestAppEnd.swift"), encoding="utf-8") as f:
            tests = f.read()
        self.assertIn(f'"{ui_tests.CONSOLE_FILE}"', app)
        self.assertIn('"UI_MAIN_HANG \\(Int(waited * 1000)) ms \\(kind.rawValue) in [\\(hangNames)]: ', app)
        self.assertIn("UI_FACT main thread checker \\(active ? \"active\" : \"not active\")", app)
        self.assertIn("enum " + ui_tests.MTC_PROBE, app)
        self.assertIn('environment["ALBUMIST_MTC_DYLIB"]', tests)
        self.assertIn('environment["ALBUMIST_MTC_PROBE"]', tests)
        self.assertIn("mainThreadChecker(app)", tests)


if __name__ == "__main__":
    unittest.main()


class PerfReportTests(unittest.TestCase):
    """XCTMetric values of PerformanceUITests in the job summary (report only)."""
    LOG = "\n".join([
        "Test Case '-[AlbumistUITests.PerformanceUITests test1_LaunchTime]' measured [Duration (AppLaunch), s] "
        "average: 1.842, relative standard deviation: 6.120%, values: [1.9, 1.8], performanceMetricID:x",
        "Test case 'PerformanceUITests.test2_LibraryScroll()' measured [Duration (ScrollDeceleration), s] average: 0.610",
        "Test Case '-[AlbumistUITests.PerformanceUITests test1_LaunchTime]' measured [Duration (AppLaunch), s] "
        "average: 1.500, relative standard deviation: 2.000%, values: [1.5]",
        "UI_PERF analysis 287.4 s",
        "UI_PERFORMANCE something else",
    ])

    def test_values_from_xctest_and_own_lines_the_last_pass_wins(self):
        values = {(v["test"], v["metric"]): v for v in ui_tests.perf_values(self.LOG)}
        self.assertEqual(set(values), {("test1_LaunchTime", "Duration (AppLaunch), s"),
                                       ("test2_LibraryScroll", "Duration (ScrollDeceleration), s"),
                                       ("own", "analysis (s)")})
        self.assertEqual(values[("test1_LaunchTime", "Duration (AppLaunch), s")]["value"], 1.5)
        self.assertIsNone(values[("test2_LibraryScroll", "Duration (ScrollDeceleration), s")]["rsd"])
        self.assertEqual(values[("own", "analysis (s)")]["value"], 287.4)

    def test_summary_table_and_never_red(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "summary.md")
            with contextlib.redirect_stdout(io.StringIO()) as out:
                ui_tests.perf_report("flow-full", self.LOG, summary=path)
            table = open(path, encoding="utf-8").read()
        self.assertIn("| test1_LaunchTime | Duration (AppLaunch), s | 1.5 | 2.0 % |", table)
        self.assertIn("| own | analysis (s) | 287.4 | one run |", table)
        self.assertIn("UI_PERF_VALUE flow-full own analysis (s): 287.4", out.getvalue())
        self.assertNotIn("::error", out.getvalue())

    def test_unrecognised_xctest_lines_are_printed_raw(self):
        text = "Test Case '-[AlbumistUITests.PerformanceUITests test1_LaunchTime]' passed\nsome new measured format 1.2 s\nUI_PERF analysis 150.0 s"
        with contextlib.redirect_stdout(io.StringIO()) as out:
            # flow-other names the class only in its skip list (xcodebuild echoes the command).
            ui_tests.perf_report("flow-other", "-skip-testing:AlbumistUITests/PerformanceUITests\nx measured y", summary="")
        self.assertNotIn("UI_PERF_RAW", out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as out:
            ui_tests.perf_report("flow-full", text, summary="")
        self.assertIn("UI_PERF_RAW some new measured format 1.2 s", out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as out:
            ui_tests.perf_report("flow-full", self.LOG, summary="")
        self.assertNotIn("UI_PERF_RAW", out.getvalue())

    def test_no_values_no_table(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "summary.md")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ui_tests.perf_report("contrast", "Test Case 'x' passed", summary=path), [])
            self.assertFalse(os.path.exists(path))

    def test_the_performance_tests_never_set_a_baseline_and_launch_through_the_helper(self):
        swift = open(os.path.join(ROOT, "App", "AlbumistUITests", "PerformanceUITests.swift"), encoding="utf-8").read()
        self.assertNotIn("baseline", swift.split("final class", 1)[1].lower())
        self.assertIn("UITestAppEnd.launch(app)", swift)
        self.assertIn("ALBUMIST_UI_QUICK", swift)
        groups = json.load(open(os.path.join(ROOT, ".github", "ui-groups.json"), encoding="utf-8"))
        full = next(g for g in groups["groups"] if g["group"] == "flow-full")
        self.assertIn("PerformanceUITests", full["only"].split())


class HangNamingTests(unittest.TestCase):
    def test_the_watch_names_a_hang_off_the_main_thread(self):
        # UI run 44870948643 (accessibility): naming the stack in `answered` (main thread) was
        # itself reported as a 492 ms hang of the app. The naming runs on `hangNaming` now.
        swift = open(os.path.join(ROOT, "App", "Albumist", "Platform", "UITestSupport.swift"), encoding="utf-8").read()
        body = swift.split("private func answered() {", 1)[1].split("\n    }\n", 1)[0]
        naming = body.index("Self.hangNaming.async")
        self.assertLess(naming, body.index("Self.symbol("))
        self.assertLess(naming, body.index("HangKind(frames:"))
        self.assertEqual(body.count("Self.symbol("), 1)


class SmartAssistantAvailabilityTests(unittest.TestCase):
    def test_availability_is_asked_off_the_main_thread_and_cached(self):
        # Hang watch, UI run 44870948643: `SmartAssistant.isAvailable` asked FoundationModels in
        # the body of SearchView, AtlasView and ProposalDetailView, 0.7 to 1 s each on a cold
        # start. The system is asked in one place (`refreshNow`), in the background at launch
        # and on each return to the screen; `isAvailable` reads the cached answer.
        swift = open(os.path.join(ROOT, "App", "Albumist", "Platform", "SmartAssistant.swift"), encoding="utf-8").read()
        self.assertEqual(swift.count("SystemLanguageModel.default.availability"), 1)
        getter = swift.split("static var isAvailable: Bool {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("known.withLock", getter)
        self.assertNotIn("SystemLanguageModel", getter)
        self.assertIn("DispatchQueue.global", swift)
        app = open(os.path.join(ROOT, "App", "Albumist", "App", "AlbumistApp.swift"), encoding="utf-8").read()
        self.assertIn("SmartAssistant.watchAvailability()", app)
