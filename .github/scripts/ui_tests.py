"""Runs one group of UI tests on its own simulator, and repeats only what the simulator lost.

Every UI job (ui.yml) uses this script, so all of them treat a failure the same way:

  pick  --device pro|se
      Prints the UDID of the simulator for the job, both pinned in .github/toolchain.json: the
      image's iPhone Pro ("pro", the screenshots of the UI flow) or a newly created iPhone SE
      ("se", the small iPhone of the accessibility tests), on the pinned runtime. No fallback.
  boot  --udid U [--reduce-motion] [--ready-file F]
      Boots the simulator (three attempts: CoreSimulator on the hosted Macs sometimes aborts
      the first bootstatus), grants photo access, fixes the status bar and writes the
      accessibility settings. With --ready-file it writes "ok" or "failed" there at the end,
      so the boot can run in the background while the build products are downloaded.
  run   --udid U --name N (--xctestrun F | --project P --scheme S) [--only T]... [--skip T]...
        [--reduce-motion] [--increase-contrast] [--video F] [--out DIR] [--deadline EPOCH]
      Runs the tests (T is "Class" or "Class/testMethod" of AlbumistUITests), prints the
      report lines for the log (steps, screenshots, accessibility findings, restart context,
      crash reports, SwiftUI runtime warnings), a last line "UI_RESULT NAME pass|fail|infra"
      (ui_evidence.py reads it) and exits with the result: 0, 1, or 75 when every pass failed
      on the simulator or XCTest alone (no test result; it writes DIR/no-test-result, and
      ui.yml fails the job in "No test result (simulator or XCTest failed in every pass)",
      which ui_evidence.py counts as no result rather than red). While a pass runs, the Mac
      answers the tests' request lines in the log (class HostGrants; xcodebuild gets
      TEST_RUNNER_ALBUMIST_HOST_HELPER=1, so the tests know someone answers): a test that reset
      the photo access (the CI simulator then answers "denied" without asking) prints
      UI_HOST_GRANT_PHOTOS [<answer file>], and the access is given back (`simctl privacy grant`;
      then "granted" or "failed" is written to the test's answer file, `write_host_answer`); a device
      test about to launch the app again prints "UI_HOST_TERMINATE_APP <epoch second> [<pid>]",
      and the running app is ended by the Mac instead of XCTest's terminate, which failed on an
      idle app in UI run 44446270757 (test07): with the app's process id exactly that process
      (SIGTERM, then SIGKILL; `end_app_process`), without it with `simctl terminate`. The test only reads the app's state
      meanwhile and ends it through XCTest itself after 60 s; a request older than 30 s (or
      without its second) is not answered any more, and a call that timed out is not repeated
      (`terminate_app`), so the Mac's end does not land on the next launch.
  settle --udid U [--limit S]
      Waits like every pass does before its first test (`settle`, below) and always exits 0;
      ci.yml's "Fresh simulator" step uses it after its boot.
  classify LOG [--status N] [--crash-report F]... [--bundle-json F] [--earlier FIRST_LOG]
      Prints what `run` would decide for a finished pass (for trying the rules on a log;
      without --bundle-json the result bundle counts as clean). For a repeat, --earlier names
      the log of the group's first pass, as `run` passes it (a test that passed there counts).

The retry rule (`decide`): a pass that failed is repeated ONCE, on a simulator that is shut
down, ERASED (app, photos, the runner's marker files) and booted and prepared again like a
new one, and only for the tests that did not pass (-only-testing as before, plus
-skip-testing for every test that passed), when all of these hold:
  - the log (or a simctl call right after the pass) shows an explicit failure of the
    simulator service or of the test runner before it ran a test: "Error returned in reply
    from CoreSimulatorService", "CoreSimulatorService: Connection interrupted", "Timed out
    waiting for AX loaded notification", "failed to initialize for UI testing", "Failed to
    install or launch the test runner", "Failed to establish communication with the test
    runner", "device is not booted", a runner stopped with SIGTERM before its first test.
    "Restarting after unexpected exit, crash, or test timeout" alone is NOT enough: it is
    also what an app hang or crash looks like;
  - no log line points at the app or the tests: no failed test case or suite, no ": error:"
    line (other than the infrastructure lines above; but a test's own ": error: -[...]", a
    "Test Case ... failed" or a crash other than SIGTERM counts even when it quotes one), no
    recorded issue, no A11Y_FAIL, no "Fatal error", "Crash:", "crashed", "Test crashed with signal ..." (other than the SIGTERM
    above) or "execution time allowance";
  - no crash report of the app or the test runner (~/Library/Logs/DiagnosticReports/Albumist*)
    was written during the pass;
  - the result bundle agrees: no test case failed with a message other than the
    infrastructure ones above, no issue outside a test, and it can be read at all (a JSON
    object with a list "testNodes").
A crash of XCTest's daemon testmanagerd during a test ("Critical process testmanagerd crashed",
the app lost with it; `daemon_crash`) also counts as such a failure: the failure lines it caused
are taken out, anything else still counts, and the tests that did not pass are repeated. That
goes beyond "a simulator failure before the first test": a test that had already started is
run again (decision of 18.11.2026, for the owner to confirm; docs/TESTFLIGHT.md). It is counted
(FLAKY_RETRY with the reason, also "app lost + daemon crash in <test>" when the app was lost in
that test without a crash report), and if the daemon crashes again in the same test in the
repeat, the group is red (likely app-caused, e.g. a huge accessibility tree).
A pass still running at --deadline (the job's time limit minus a margin, ui.yml) is stopped:
with a test still running a hang, red, never repeated (UI_HANG); with none running (between
tests, before the first) a deadline line that counts as infrastructure (UI_DEADLINE). A repeat
is not started with less than 30 min left (10 min after the erase): then no result. While a pass runs, failed test cases and ": error: -["
lines are echoed into the job log at once (UI_LIVE), so a cancel after a failure stays red.
Before every pass (first and repeat) `settle` waits up to 5 min until the simulator answers a
trivial process (launchctl) twice in a row in under 2 s (the Mac is starved after the boot; SIM_SETTLE with
the load, SIM_TOP), never into the 10 min a repeat keeps; then the pass starts anyway. No test
is repeated for it.
A watchdog (class Watchdog) stops a pass early when the simulator leaves "Booted" before
the first test started (two checks 20 s apart); the UI_WATCHDOG line it leaves in the log is
one of the infrastructure failures above, and the stop counts as FLAKY_BOOT. It never stops a
pass in which a test has started (the log is read again right before the stop, so a test that
started while simctl was being asked counts too).
Anything else is never repeated: a real failure stays red. That includes XCTest losing the
app at a launch ("Application ... does not have a process ID", device test 04 of UI run
44066730498): it is never repeated, but the verdict says which side it points at
(`lost_app_at_launch`), from the crash reports and the app's own launch record (the device
tests print "UI_FACT app process P started T UTC" from the file the app writes at launch):
a crash report means the app crashed; a process that started 30 s or more after the test's
"UI_FACT clock T launch" means the simulator began the launch late (simulator/XCTest side);
a process that started at once means the app itself did not come up in time (app side);
without a record of a new process the cause stays open. A pass that ran no test at all
fails (a renamed test would otherwise make an empty, green selection), and so does a group in
which no test passed because every test skipped itself (XCTSkip; G5-08), and a repeat whose
selection would be empty is not started (only possible when every --only entry is a single
test; a class or skip-only selection always starts the repeat, see `retry_arguments`). Both passes keep their own log and result bundle
(NAME.xcresult, NAME-retry.xcresult); the screenshots of the tests that passed in the first
pass are printed from its log.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

TARGET = "AlbumistUITests"
BUNDLE_ID = "app.albumist.ios"

# Lines of the xcodebuild log that go into the job log. PREVIEW_JPEG lines carry the
# screenshots (the gallery is built from them), A11Y_ lines the accessibility findings.
REPORT = re.compile(r"error:|UI_STEP|UI_SWEEP|UI_TIMING|UI_PERF|UI_FACT|UI_HOST|UI_STRESS|UI_FLAKY|A11Y_|PREVIEW_JPEG|Test Case|Executed|\*\* |"
                    r"Testing failed|Fatal error|crashed|Restarting after|unexpected exit|encountered an error")
REPORT_LIMIT = 15000

# Explicit failures of the simulator service or of the test runner before its first test
# (seen on the hosted Macs, Nov 2026). Matched per line.
INFRA = [
    (re.compile(r"Error returned in reply from CoreSimulatorService|CoreSimulatorService: Connection (?:interrupted|invalid)"),
     "CoreSimulatorService connection lost"),
    (re.compile(r"Timed out waiting for AX loaded notification"), "AX loaded notification timed out"),
    (re.compile(r"failed to initialize for UI testing", re.I), "test runner failed to initialize"),
    (re.compile(r"Failed to install or launch the test runner"), "test runner not installed or launched"),
    (re.compile(r"Failed to establish communication with the test runner"), "no connection to the test runner"),
    (re.compile(r"Test runner exited before starting test execution"), "test runner exited before the tests"),
    (re.compile(r"test runner hung before establishing connection", re.I), "test runner hung before connecting"),
    (re.compile(r"\bdevice is not booted\b"), "simulator not booted"),
    # SIGTERM to a runner that had not started a test yet (the simulator was going away).
    (re.compile(r"Test crashed with signal term (?:before establishing connection|while preparing to run tests)"),
     "test runner stopped before the tests"),
    # Written by this script's watchdog (run_pass): the simulator left "Booted" before the first
    # test started, so the pass was stopped instead of waiting for xcodebuild to notice.
    (re.compile(r"^UI_WATCHDOG simulator \S+ left Booted"), "simulator shut down before the tests (watchdog)"),
    # Written by run_pass: the deadline came while no test was running (between tests, before
    # the first one, xcodebuild winding up): the time ran out, not a test.
    (re.compile(r"^UI_DEADLINE\b"), "pass stopped at the job's deadline with no test running"),
]

# Anything here is about the app or the tests: never repeated. Matched per line, on lines
# that are not one of the infrastructure lines above.
REAL = [
    (re.compile(r"Test [Cc]ase '.*' failed"), "a test failed"),
    (re.compile(r"Test Suite '.*' failed"), "a test suite failed"),
    (re.compile(r": error:"), "an error was recorded"),
    (re.compile(r"recorded an issue"), "an issue was recorded"),
    (re.compile(r"with [1-9]\d* failures?\b"), "failures counted"),
    (re.compile(r"\bA11Y_FAIL\b"), "accessibility finding"),
    (re.compile(r"Fatal error"), "Swift runtime error (Fatal error)"),
    (re.compile(r"Test crashed with signal"), "a test crashed"),
    (re.compile(r"\bCrash:"), "a crash"),
    (re.compile(r"\bcrashed\b", re.I), "something crashed"),
    (re.compile(r"execution time allowance"), "a test ran out of time"),
    # Written by run_pass when a test was still running at the job's deadline (--deadline): a
    # hang is a finding (the app or a test never got done), never repeated.
    (re.compile(r"^UI_HANG\b"), "hang: the pass did not end before the job's deadline"),
    (re.compile(r"\*\* (?:TEST )?BUILD FAILED \*\*"), "build failed"),
]

# A test's own failure, even on a line that also quotes one of the infrastructure messages
# (an assertion whose text contains a CoreSimulatorService error is still an assertion).
STRONG_REAL = [
    (re.compile(r": error: -\["), "an error was recorded"),
    (re.compile(r"Test [Cc]ase .* failed"), "a test failed"),
    (re.compile(r"Test crashed with signal (?!term)"), "a test crashed"),
]

# XCTest's daemon testmanagerd crashed (UI run 44202318875 attempt 2, job 134494213854: SIGSEGV
# in com.apple.testmanagerd, responsible process SimulatorTrampoline). The test that was running
# then fails with "Lost connection to the application" and "Critical process testmanagerd
# crashed", and the runner restarts. That is the simulator's XCTest side, not the app: those
# lines, that test's "failed" line and the failure counts are taken out before the log is
# judged (daemon_crash); anything else that failed still counts, and so does a crash report of
# the app. The tests that did not pass run once more like after a simulator failure.
DAEMON_CRASH = re.compile(r"Critical process testmanagerd crashed")
# A testmanagerd crash in a test whose app was lost too, with no app crash report: still repeated,
# but named in the reasons (and so in the flaky record) as "app lost + daemon crash".
APP_LOST = re.compile(r"Lost connection to the application|does not have a process ID|is not running")
DAEMON_LOST = re.compile(r"Critical process testmanagerd crashed|Lost connection to the application"
                         r"|Couldn.t communicate with a helper application")
ERROR_OF = re.compile(r": error: -\[\w+\.(\w+) (\w+)\] : ")
FAILED_CASE = re.compile(r"Test [Cc]ase '-\[\w+\.(\w+) (\w+)\]' failed")
AGGREGATE = re.compile(r"Test Suite '.*' failed|with [1-9]\d* failures?\b")

# Echoed into the job log while a pass runs (HostGrants.check).
LIVE = re.compile(r"Test [Cc]ase '.*' failed|: error: -\[")

# Lines that carry data, not messages (base64 screenshots and video).
DATA_LINE = re.compile(r"PREVIEW_JPEG|UI_VIDEO_B64")

CASE = re.compile(r"Test Case '-\[(?:[\w]+)\.(\w+) (\w+)\]' (passed|failed|skipped)")
STARTED = re.compile(r"Test Case '-\[\w+\.\w+ \w+\]' started")
# Written by `run` when every pass failed on the simulator or XCTest alone, so the group has no
# test result (exit NO_TEST_EXIT): the workflow fails the job in a step of its own, and
# ui_evidence.py counts it neither green nor red.
NO_TEST_RESULT = "no-test-result"
# A repeat needs an erase and boot (up to ~25 min seen) and its tests: not started with less than
# this left before --deadline, nor after an erase that left less than RETRY_AFTER_RESET. The
# group then has no result (exit NO_TEST_EXIT) instead of a repeat cut off as a hang.
RETRY_BEFORE_RESET = 30 * 60
RETRY_AFTER_RESET = 10 * 60
NO_TEST_EXIT = 75
PASSED = ("Passed", "Skipped", "Expected Failure")


# ---------------------------------------------------------------------------------------------
# The decision (pure functions; unit tests in tests/test_ui_tests.py)


def finished_tests(log: str) -> dict[str, str]:
    """{"Class/test": "passed" | "failed" | "skipped"} from the XCTest lines of a log."""
    result: dict[str, str] = {}
    for cls, test, state in CASE.findall(log):
        name = f"{cls}/{test}"
        if result.get(name) != "failed":
            result[name] = state
    return result


def is_infra(line: str) -> list[str]:
    return [reason for pattern, reason in INFRA if pattern.search(line)]


def strong_real(line: str) -> list[str]:
    """Reasons from STRONG_REAL: these count even on a line that is also an infrastructure line."""
    return [reason for pattern, reason in STRONG_REAL if pattern.search(line)]


def scan(text: str) -> tuple[list[str], list[str]]:
    """(real reasons, infrastructure reasons) found in a log, line by line."""
    real: list[str] = []
    infra: list[str] = []
    for line in text.splitlines():
        if DATA_LINE.search(line):
            continue
        real += [reason for reason in strong_real(line) if reason not in real]
        found = is_infra(line)
        if found:
            infra += [r for r in found if r not in infra]
            continue
        real += [reason for pattern, reason in REAL if pattern.search(line) and reason not in real]
    return real, infra


def bundle_findings(tests: dict) -> list[str]:
    """Problems in `xcresulttool get test-results tests` output that are not the simulator's:
    any failure message that is not an infrastructure line (or that is one but also names a
    test's own failure, STRONG_REAL), and any test case that did not pass without saying why.
    Tests that never started are not in the bundle."""
    findings: list[str] = []

    def children(node: dict) -> list[dict]:
        found = node.get("children") or []
        return [child for child in found if isinstance(child, dict)] if isinstance(found, list) else []

    def messages(node: dict) -> list[str]:
        found = []
        for child in children(node):
            if child.get("nodeType") == "Failure Message":
                found.append(child.get("name", ""))
            found += messages(child)
        return found

    def walk(node: dict) -> None:
        kind = node.get("nodeType")
        if kind == "Failure Message":
            text = node.get("name", "")
            if strong_real(text) or not is_infra(text):
                findings.append(f"result bundle: {text[:200]}")
        if kind == "Test Case" and node.get("result") not in PASSED and not messages(node):
            findings.append(f"result bundle: {node.get('name', '?')} {node.get('result', 'no result')} without a message")
        for child in children(node):
            walk(child)

    for node in children({"children": tests.get("testNodes")}):
        walk(node)
    return findings


LOST_APP = re.compile(r"does not have a process ID")
LAUNCH_CLOCK = re.compile(r"UI_FACT clock (\d\d):(\d\d):(\d\d(?:\.\d)?) launch\b")
APP_PROCESS = re.compile(r"UI_FACT app process (\d+) started (\d\d):(\d\d):(\d\d(?:\.\d)?) UTC")
LATE_START = 30.0


def lost_app_at_launch(log: str, crash_reports: list[str] | None = None) -> list[str]:
    """Which side a lost app at a launch points at (see the module text); [] when none was lost.

    Always a reason for "fail" (it is added to the real reasons, never repeated)."""
    def seconds(match: re.Match, first: int) -> float:
        return int(match.group(first)) * 3600 + int(match.group(first + 1)) * 60 + float(match.group(first + 2))

    lines = [line for line in log.splitlines() if not DATA_LINE.search(line)]
    reasons: list[str] = []
    for index, line in enumerate(lines):
        if not (LOST_APP.search(line) and strong_real(line)):
            continue
        launch = None
        for earlier in reversed(lines[:index]):
            if STARTED.search(earlier):
                break
            launch = launch or LAUNCH_CLOCK.search(earlier)
        process = None
        for later in lines[index + 1:]:
            if STARTED.search(later):
                break
            process = process or APP_PROCESS.search(later)
        if crash_reports:
            reason = "XCTest lost the app at a launch, and a crash report was written (app side)"
        elif launch and process:
            late = (seconds(process, 2) - seconds(launch, 1)) % 86_400
            if late >= LATE_START:
                reason = (f"XCTest lost the app at a launch: no crash report, the simulator started the app "
                          f"process {late:.0f} s after the launch request (simulator/XCTest side)")
            else:
                reason = (f"XCTest lost the app at a launch: the app process started after {late:.0f} s "
                          f"but did not come up (app side)")
        else:
            reason = "XCTest lost the app at a launch: no crash report, no launch record of a new app process (cause open)"
        if reason not in reasons:
            reasons.append(reason)
    return reasons


def daemon_crash_tests(log: str) -> set[tuple[str, str]]:
    """(class, test) of each test in which testmanagerd crashed."""
    hit = set()
    for line in log.splitlines():
        match = ERROR_OF.search(line)
        if match and DAEMON_CRASH.search(line):
            hit.add(match.groups())
    return hit


def daemon_crash(log: str, bundle: list[str]) -> tuple[str, list[str], list[str]]:
    """(log, bundle findings, reasons) with the failure that a crash of testmanagerd caused taken
    out (see DAEMON_CRASH); unchanged and [] when it did not crash."""
    lines = log.splitlines()
    if not any(DAEMON_CRASH.search(line) for line in lines):
        return log, bundle, []
    hit = daemon_crash_tests(log)
    lost = sorted({e.groups() for line in lines if (e := ERROR_OF.search(line)) and e.groups() in hit
                   and APP_LOST.search(line)})
    reasons = ["XCTest daemon testmanagerd crashed"]
    if lost:
        reasons.append("app lost + daemon crash in " + ", ".join(f"{c}/{t}" for c, t in lost)
                       + " (no app crash report)")
    kept = []
    for line in lines:
        error, failed = ERROR_OF.search(line), FAILED_CASE.search(line)
        if DAEMON_CRASH.search(line) or AGGREGATE.search(line):
            continue  # the counts sum up the "failed" lines; another failure has its own line
        if error and error.groups() in hit and DAEMON_LOST.search(line):
            continue
        if failed and failed.groups() in hit:
            continue
        kept.append(line)
    return "\n".join(kept), [b for b in bundle if not DAEMON_LOST.search(b)], reasons


def decide(status: int, log: str, crash_reports: list[str] | None = None, probe: str = "",
           bundle: list[str] | None = None, earlier: str = "") -> tuple[str, list[str]]:
    """("pass" | "retry" | "fail", reasons) for one finished pass.

    status: exit code of xcodebuild; log: its whole output; crash_reports: paths of Albumist*
    reports written during the pass; probe: output of a simctl call made right after the pass
    (says whether the simulator is still there); bundle: `bundle_findings` of the pass's
    result bundle (or the reason it could not be read); earlier: the log of the group's first
    pass when this is its repeat. Both the log and the bundle must show nothing about the app
    before a pass is repeated.

    A green pass needs a test that passed, in it or in the group's first pass (the repeat runs
    only what did not pass there): a group whose every test skipped itself (XCTSkip) tested
    nothing and is red, never green (G5-08 of the review of 18.11.2026).
    """
    ran = finished_tests(log)
    if status == 0:
        if not ran:
            return "fail", ["no test ran (a renamed test, or a selection that matches nothing)"]
        if "passed" not in [*finished_tests(earlier).values(), *ran.values()]:
            skipped = sum(1 for state in ran.values() if state == "skipped")
            return "fail", [f"no test passed: {skipped} skipped themselves (XCTSkip), so the group tested nothing"]
        return "pass", []
    log, bundle, daemon = daemon_crash(log, list(bundle or []))
    real, infra = scan(log)
    infra[:0] = daemon
    real += [reason for reason in lost_app_at_launch(log, crash_reports) if reason not in real]
    if crash_reports:
        real.append("crash report " + ", ".join(os.path.basename(p) for p in crash_reports))
    real += list(bundle or [])
    if real:
        return "fail", real
    for line in probe.splitlines():
        infra += [r for r in is_infra(line) if r not in infra]
    if infra:
        return "retry", infra
    return "fail", ["no explicit simulator failure (unknown cause; a runner restart alone is not repeated)"]


def retry_arguments(only: list[str], skip: list[str], log: str) -> list[str] | None:
    """xcodebuild selection for the repeat: the same tests minus every test that passed or
    was skipped in the first pass.

    None (no repeat) only when every --only entry is a single test ("Class/test") that passed,
    was skipped or is in --skip: then there is nothing left to name. In every other case a
    selection is returned, also when nothing may be left to run: with a class in --only
    ("AccessibilityUITests") or with no --only at all (the flow-other group selects by
    --skip only) the script cannot tell from the log whether the class or target holds tests
    that never started, so the repeat starts with the passed tests skipped. If none is left,
    that repeat runs no test and `decide` fails it ("no test ran"): the group stays red."""
    done = [name for name, state in finished_tests(log).items() if state in ("passed", "skipped")]
    if only and all("/" in t and (t in done or t in skip) for t in only):
        return None
    return selection(only, skip + [name for name in done if name not in skip])


def selection(only: list[str], skip: list[str]) -> list[str]:
    return [f"-only-testing:{TARGET}/{t}" for t in only] + [f"-skip-testing:{TARGET}/{t}" for t in skip]


def restart_context(log: str, before: int = 60, limit: int = 400) -> list[str]:
    """What XCTest logged before each "Restarting after" (a runner that ended inside a test
    leaves no "passed"/"failed" line; this says where and why)."""
    lines = log.splitlines()
    picked: list[int] = []
    for index, line in enumerate(lines):
        if "Restarting after" in line:
            picked += [i for i in range(max(0, index - before), index + 1) if i not in picked]
    out = [f"{i + 1}:{lines[i][:300]}" for i in sorted(picked) if "PREVIEW_JPEG" not in lines[i]]
    return out[:limit]


# ---------------------------------------------------------------------------------------------
# Simulator


def watchdog_should_stop(log: str, states: list[str]) -> bool:
    """True when a pass is to be stopped: no test has started yet and the last two checks of the
    simulator (20 s apart) both found it known and not "Booted". A pass in which any test
    started is never stopped: whatever happens then is for the tests and `decide` to judge."""
    if STARTED.search(log):
        return False
    last = states[-2:]
    return len(last) == 2 and all(state and state != "Booted" for state in last)


def watchdog_bundle(findings: list[str]) -> list[str]:
    """Result bundle findings of a pass the watchdog stopped before any test, or that was stopped
    at the job's deadline (UI_HANG stays a finding from the log): a bundle that
    xcodebuild could not finish is expected then and is no finding; anything it does say still
    counts (and blocks the repeat)."""
    return [f for f in findings if not f.startswith("result bundle not readable")]


def flaky_record(name: str, first_log: str, retry_reasons: list[str], retry_log: str | None,
                 retry_result: str | None, boot_retries: list[str] | None = None) -> dict:
    """What a group's run says about flakiness, for build/flaky-NAME.json and the FLAKY lines.

    retries: every repeat after a simulator failure (also one that failed, and one that could
    not start); flaky: every test that passed only in that repeat, with the reason and what
    the first pass made of it ("failed" or "not started"), and every test that retried a step
    inside itself (its UI_FLAKY_RETRY line, first: INSIDE); boot: failed boot attempts."""
    record = {"group": name, "boot": list(boot_retries or []), "retries": [], "flaky": []}
    for test, why in dict.fromkeys(INSIDE_RETRY.findall(first_log + "\n" + (retry_log or ""))):
        record["flaky"].append({"test": test, "first": INSIDE, "reason": why})
    if retry_result is None and not retry_reasons:
        return record
    record["retries"].append({"reasons": retry_reasons, "result": retry_result or "not started"})
    first = finished_tests(first_log)
    for test, state in finished_tests(retry_log or "").items():
        if state == "passed":
            record["flaky"].append({"test": test, "first": first.get(test, "not started"),
                                    "reason": "; ".join(retry_reasons)})
    return record


# A UI test that retries a step inside itself prints "UI_FLAKY_RETRY <Class.test> <reason>"
# (DeviceConditionUITests test07). Counted and shown like a test that passed only on a repeat
# (flaky-*.json, FLAKY line, job and run summary, the flaky warning the TestFlight gate repeats
# for reused results); it does not block, like the other flaky tests: the rule is to count and
# fix them, and a test that still fails after its own retry is red anyway.
INSIDE_RETRY = re.compile(r"\bUI_FLAKY_RETRY (\S+) (.+?)\s*$", re.M)
INSIDE = "retried inside the test"


def flaky_lines(record: dict) -> list[str]:
    lines = [f"FLAKY_BOOT {record['group']} {reason}" for reason in record.get("boot", [])]
    lines += [f"FLAKY_RETRY {record['group']} {r['result']} ({'; '.join(r['reasons'])})" for r in record.get("retries", [])]
    lines += [f"FLAKY {f['test']} {f['reason']} " + (f"({INSIDE})" if f["first"] == INSIDE else
                                                     f"(first pass: {f['first']}; passed on the repeat)")
              for f in record.get("flaky", [])]
    return lines


SWEEP_SKIP = re.compile(r"\bUI_SWEEP_SKIP (.+?)\s*$")


def sweep_skips(log: str) -> list[dict]:
    """The rows the tap-through sweep (UI test 3) left out, from its UI_SWEEP_SKIP lines, in
    order and each once: {"where": "Vorschläge › Länder und Orte", "why": "section header or
    footer text"}. The sweep skips a cell without its own label that has fewer than two texts
    and no image as a section header or footer; listed in the run summary so that a real row
    skipped that way is seen."""
    found: list[dict] = []
    for line in log.splitlines():
        match = SWEEP_SKIP.search(line)
        if not match or ": error:" in line:
            continue
        text = match.group(1)
        why = re.match(r"^(.*?) \(([^()]*)\)$", text)
        entry = {"where": why.group(1), "why": why.group(2)} if why else {"where": text, "why": ""}
        if entry not in found:
            found.append(entry)
    return found


def sweep_summary(records: list[dict]) -> str:
    """Markdown: every row the sweep left out, per group ("" when no group has any)."""
    rows = [(r["group"], s) for r in records for s in r.get("sweep_skips", [])]
    if not rows:
        return ""
    cell = lambda text: text.replace("|", "\\|")  # noqa: E731
    md = ["### UI test 3: rows the tap-through sweep did not tap", "",
          f"{len(rows)} row(s) left out. \"section header or footer text\" is a cell without its own label "
          "with fewer than two texts and no image; if a real row is listed so, the sweep missed it.", "",
          "| Group | Where | Why |", "|---|---|---|"]
    md += [f"| {group} | {cell(s['where'])} | {cell(s['why'])} |" for group, s in rows]
    return "\n".join(md) + "\n"


def flaky_summary(records: list[dict]) -> tuple[str, list[str]]:
    """(Markdown for the run summary, FLAKY lines) over every group's record."""
    boots = sum(len(r.get("boot", [])) for r in records)
    retries = sum(len(r.get("retries", [])) for r in records)
    flaky = [f for r in records for f in r.get("flaky", []) if f.get("first") != INSIDE]
    inside = [f for r in records for f in r.get("flaky", []) if f.get("first") == INSIDE]
    lines = [line for r in records for line in flaky_lines(r)]
    md = ["### UI tests: simulator retries and flaky tests", "",
          f"{retries} repeat(s) after a simulator failure, {len(flaky)} test(s) passed only on the repeat, "
          f"{len(inside)} retry(ies) inside a test, "
          f"{boots} failed boot attempt(s), over {len(records)} pass record(s). A real test failure is never repeated.", ""]
    if lines:
        md += ["| Group | Kind | Test | First pass | Reason / result |", "|---|---|---|---|---|"]
        for r in records:
            md += [f"| {r['group']} | boot | | | {b} |" for b in r.get("boot", [])]
            md += [f"| {r['group']} | repeat | | | {x['result']}: {'; '.join(x['reasons'])} |" for x in r.get("retries", [])]
            md += [f"| {r['group']} | flaky | {f['test']} | {f['first']} | {f['reason']} |" for f in r.get("flaky", [])]
    sweep = sweep_summary(records)
    return "\n".join(md) + "\n" + ("\n" + sweep if sweep else ""), lines


def sh(command: list[str], timeout: float = 300, quiet: bool = False) -> tuple[int, str]:
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        output = (done.stdout or "") + (done.stderr or "")
        code = done.returncode
    except subprocess.TimeoutExpired:
        output, code = f"timed out after {int(timeout)} s: {' '.join(command)}", 124
    except OSError as error:
        output, code = str(error), 127
    if not quiet and output.strip():
        print(output.rstrip(), flush=True)
    return code, output


def pick(device: str) -> str:
    """UDID of the pinned simulator (.github/toolchain.json): "pro" is the image's iPhone Pro
    on the pinned runtime, "se" a new iPhone SE (375 pt) created from the pinned device type on
    that runtime. No fallback: a missing simulator fails the job (exit 2 in main)."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pick_simulator.py")
    if device == "se":
        sys.path.insert(0, os.path.dirname(script))
        from pick_simulator import pins
        toolchain = pins()
        small, runtime = toolchain["simulators"]["small"], toolchain["runtime"]["identifier"]
        code, udid = sh(["xcrun", "simctl", "create", small["name"], small["create"], runtime], quiet=True)
        if code == 0 and re.fullmatch(r"[0-9A-F-]{36}", udid.strip()):
            print(f"{small['name']} ({small['create']}) on {runtime}", file=sys.stderr)
            return udid.strip()
        print(f"::error title=Pinned toolchain::could not create {small['name']} ({small['create']}) on {runtime}: "
              f"{udid.strip()[:300]}. Update .github/toolchain.json on purpose.", flush=True)
        return ""
    _, listing = sh(["xcrun", "simctl", "list", "devices", "available", "-j"], quiet=True)
    done = subprocess.run([sys.executable, script, "--role", "pro"], input=listing, capture_output=True, text=True)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        print(f"::error title=Pinned toolchain::{done.stderr.strip()[:300]}", flush=True)
    return done.stdout.strip()


BOOT_RETRIES: list[str] = []


def timing(what: str, started: float) -> None:
    """UI_BOOT_TIMING lines: where the 2-5 min before the first test go (simulator boot, photo
    access, settings), measured per job; docs/TESTFLIGHT.md, "Messung"."""
    print(f"UI_BOOT_TIMING {what} {time.monotonic() - started:.1f} s", flush=True)


SETTLE_PROBE = 2.0
SETTLE_CALM = 2
SETTLE_LIMIT = 300
SETTLE_STEP = 10


def settle_limit(deadline: float, now: float) -> float:
    """How long `settle` may wait: SETTLE_LIMIT, but never into the RETRY_AFTER_RESET minutes
    that the retry guard in command_run promised to the tests (checked before the erase, while
    the wait comes after it)."""
    if not deadline:
        return SETTLE_LIMIT
    return max(0.0, min(SETTLE_LIMIT, deadline - now - RETRY_AFTER_RESET))


def simulator_probe(udid: str) -> float | None:
    """Seconds the simulator takes to start and end a trivial process (`simctl spawn U launchctl
    getenv HOME`: launchctl is part of every simulator runtime and `run` already asks it after a
    failed pass; it also asks the simulator's launchd); None when it failed, with why as a
    SIM_SETTLE line, so a probe that can never succeed does not pass for a slow simulator."""
    started = time.monotonic()
    code, out = sh(["xcrun", "simctl", "spawn", udid, "launchctl", "getenv", "HOME"], timeout=30, quiet=True)
    if code != 0:
        print(f"SIM_SETTLE probe failed (exit {code}): {' '.join(out.split())[:160]}", flush=True)
        return None
    return time.monotonic() - started


def settle(probe, load=lambda: os.getloadavg()[0], sleep=time.sleep, top=None,
           limit: float = SETTLE_LIMIT, step: float = SETTLE_STEP, clock=time.monotonic,
           going_on: str = "the pass starts anyway") -> bool:
    """Waits until the simulator answers quickly again (SETTLE_CALM probes in a row under
    SETTLE_PROBE s, `simulator_probe`), at most `limit` s, before a pass starts its first test.
    Every probe and the Mac's 1-minute load are a SIM_SETTLE line, what keeps the Mac busy a
    SIM_TOP line once a minute. True when it settled.

    Why: right after the simulator's boot the hosted Mac (3 cores) is starved for minutes. The
    first launch of a UI group then took 30 s (device test06, UI run 44397301774) or XCTest lost
    the app although it had started and drawn its first screen (flow-other test05, UI run
    44437759848: process after 4 s, its code after 9 s, a 2.3 s stall in dyld/os_log, "does not
    have a process ID" after 150 s). The load is logged only: on these Macs it stays at 200-850
    for minutes after the boot even when tests pass (ci.yml's SIM_SETTLE lines, CI 44437759869
    and 44397301952), so a load limit would always wait the whole time (second review of
    aadb7f1). How fast the simulator answers is what the launch needs. The pass still runs when
    it stays slow: the wait only gives the Mac its time."""
    # Measured on the clock: on a starved Mac a probe or `ps` (busiest) can take its 30 s timeout.
    start, next_top, calm = clock(), 0.0, 0
    while True:
        answer = probe()
        value = load()
        waited = clock() - start
        took = "failed" if answer is None else f"{answer:.1f} s"
        print(f"SIM_SETTLE simulator answered in {took}, load(1m)={value:.2f}, after {waited:.0f} s", flush=True)
        calm = calm + 1 if answer is not None and answer < SETTLE_PROBE else 0
        if calm >= SETTLE_CALM:
            return True
        if calm == 0 and waited >= next_top:
            next_top += 60
            for line in (top or busiest)():
                print(f"SIM_TOP {line}", flush=True)
        if waited >= limit:
            print(f"SIM_SETTLE still slow after {waited:.0f} s; {going_on}", flush=True)
            return False
        if calm == 0:
            sleep(min(step, limit - waited))


def busiest() -> list[str]:
    """The busiest processes on the Mac (for SIM_TOP)."""
    code, out = sh(["ps", "-Ao", "pcpu=,state=,comm=", "-r"], timeout=30, quiet=True)
    return [line[:160] for line in out.splitlines()[:8]] if code == 0 else []


def boot(udid: str) -> bool:
    for attempt in (1, 2, 3):
        started = time.monotonic()
        sh(["xcrun", "simctl", "boot", udid], timeout=600, quiet=True)
        timing(f"simctl boot (attempt {attempt})", started)
        code, _ = sh(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=900)
        timing(f"booted (attempt {attempt}, bootstatus {code})", started)
        if code == 0:
            return True
        BOOT_RETRIES.append(f"bootstatus failed (attempt {attempt} of 3)")
        print(f"FLAKY_BOOT {udid} bootstatus failed (attempt {attempt} of 3), retrying", flush=True)
        time.sleep(15)
    return False


def prepare(udid: str, reduce_motion: bool = False, increase_contrast: bool = False, basics: bool = True) -> None:
    """Photo access, status bar and the accessibility settings of the job."""
    spawn = ["xcrun", "simctl", "spawn", udid]
    started = time.monotonic()
    if basics:
        if sh(["xcrun", "simctl", "privacy", udid, "grant", "photos", BUNDLE_ID], timeout=600)[0] != 0:
            print("privacy grant failed")
        timing("photo access granted", started)
        sh(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
            "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"], timeout=120)
        timing("status bar set", started)
    if reduce_motion:
        # Settings › Accessibility › Motion. The app reads it at launch.
        sh(spawn + ["defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "true"])
        _, value = sh(spawn + ["defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled"], quiet=True)
        print(f"A11Y_SETTING ReduceMotionEnabled={value.strip()}", flush=True)
    if increase_contrast:
        if sh(["xcrun", "simctl", "ui", udid, "increase_contrast", "enabled"])[0] != 0:
            sh(spawn + ["defaults", "write", "com.apple.Accessibility", "DarkenSystemColors", "-bool", "true"])
        sh(spawn + ["defaults", "write", "com.apple.Accessibility", "EnhancedBackgroundContrastEnabled", "-bool", "true"])
        _, darken = sh(spawn + ["defaults", "read", "com.apple.Accessibility", "DarkenSystemColors"], quiet=True)
        _, enhanced = sh(spawn + ["defaults", "read", "com.apple.Accessibility", "EnhancedBackgroundContrastEnabled"], quiet=True)
        print(f"A11Y_SETTING DarkenSystemColors={darken.strip()} EnhancedBackgroundContrastEnabled={enhanced.strip()}", flush=True)
    timing("prepared", started)


def reset(udid: str, reduce_motion: bool, increase_contrast: bool) -> bool:
    """Shut down, erase, boot and prepare again: the repeat starts like a new group (the app,
    its data, the photo library and the runner's marker files are gone, so a repeated test 1
    meets the welcome screen and checks every step again)."""
    sh(["xcrun", "simctl", "shutdown", udid], timeout=180)
    if sh(["xcrun", "simctl", "erase", udid], timeout=300)[0] != 0:
        print("UI_SIM_ERASE_FAILED", flush=True)
        return False
    print("UI_SIM_ERASED", flush=True)
    if not boot(udid):
        return False
    prepare(udid, reduce_motion, increase_contrast)
    return True


def parse_bundle(text: str) -> list[str]:
    """`bundle_findings` of `xcresulttool get test-results tests` output, or why it is not
    readable (then no repeat): it must be a JSON object with a list "testNodes"."""
    try:
        tests = json.loads(text)
    except ValueError as error:
        return [f"result bundle not readable ({error})"]
    if not isinstance(tests, dict) or not isinstance(tests.get("testNodes"), list):
        return [f"result bundle not readable (no testNodes list in {text.strip()[:120]!r})"]
    return bundle_findings(tests)


def read_bundle(path: str) -> list[str]:
    """`bundle_findings` of a result bundle, or why it could not be read (then no repeat)."""
    code, output = sh(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path], timeout=300, quiet=True)
    if code != 0:
        return [f"result bundle not readable ({output.strip()[:200]})"]
    return parse_bundle(output)


def crash_reports(since: float) -> list[str]:
    """Crash reports of the app or the test runner written since `since`."""
    folder = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    found = []
    for path in glob.glob(os.path.join(folder, "**", "Albumist*"), recursive=True):
        try:
            if os.path.getmtime(path) >= since - 5:
                found.append(path)
        except OSError:
            pass
    return sorted(found)


def other_crash_reports(since: float) -> list[str]:
    folder = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    found = []
    for path in glob.glob(os.path.join(folder, "**", "*.ips"), recursive=True):
        name = os.path.basename(path)
        try:
            recent = os.path.getmtime(path) >= since - 5
        except OSError:
            recent = False
        if recent and not name.startswith("Albumist") and re.search(r"testmanagerd|XCTest|Runner|CoreSimulator|SpringBoard", name):
            found.append(path)
    return sorted(found)[:10]


# ---------------------------------------------------------------------------------------------
# One pass


class Recorder(threading.Thread):
    """Video of the sorting show in the full flow: starts when the test opens the plan
    ("UI_STEP_OK open plan") and stops a few seconds after the plan is done ("UI_TIMING apply")."""

    def __init__(self, udid: str, log_path: str, video: str):
        super().__init__(daemon=True)
        self.udid, self.log_path, self.video = udid, log_path, video
        self.stop_flag = threading.Event()
        self.offset = 0
        self.tail = ""
        self.lines: list[str] = []

    def seen(self, pattern: str) -> bool:
        """Reads only what was added to the log since the last call (it grows to tens of MB)."""
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as log:
                log.seek(self.offset)
                chunk = log.read()
                self.offset = log.tell()
        except OSError:
            chunk = ""
        text = self.tail + chunk
        complete, _, self.tail = text.rpartition("\n")
        self.lines += [l.rstrip() for l in complete.split("\n") if "UI_STEP_OK" in l or "UI_TIMING" in l]
        return any(re.search(pattern, line) for line in self.lines)

    def run(self) -> None:
        while not self.stop_flag.is_set() and not self.seen(r"UI_STEP_OK open plan"):
            time.sleep(1)
        if self.stop_flag.is_set():
            return
        recording = subprocess.Popen(["xcrun", "simctl", "io", self.udid, "recordVideo", "--codec=h264", "--force", self.video],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(240):
            if self.stop_flag.is_set() or self.seen(r"UI_TIMING apply"):
                break
            time.sleep(1)
        time.sleep(3)
        recording.send_signal(signal.SIGINT)
        try:
            recording.wait(timeout=30)
        except subprocess.TimeoutExpired:
            recording.kill()

    def stop(self) -> None:
        self.stop_flag.set()
        self.join(timeout=60)


# "UI_HOST_GRANT_PHOTOS [<answer file>]": with a file (DeviceConditionUITests.grantFromHost) the
# Mac writes its answer there once the grant has ended (`write_host_answer`).
HOST_GRANT = re.compile(r"(?:^|\s)UI_HOST_GRANT_PHOTOS(?: (/\S+))?\s*$")
# UITestAppEnd.end: "UI_HOST_TERMINATE_APP <epoch second of the request> [<app process id>]".
HOST_TERMINATE = re.compile(r"(?:^|\s)UI_HOST_TERMINATE_APP(?: (\d+))?(?: (\d+))?\s*$")


def host_grant_requests(text: str) -> int:
    """How many complete lines of `text` ask the Mac to give the photo access back."""
    return sum(1 for line in text.split("\n") if HOST_GRANT.search(line))


def host_requests(text: str) -> list[tuple[str, float | None, int | str | None]]:
    """The requests to the Mac in the complete lines of `text`, in log order: ("grant", None,
    answer file or None) for UI_HOST_GRANT_PHOTOS, ("terminate", epoch second or None, process id
    or None) for UI_HOST_TERMINATE_APP."""
    found: list[tuple[str, float | None, int | str | None]] = []
    for line in text.split("\n"):
        if match := HOST_GRANT.search(line):
            found.append(("grant", None, match.group(1)))
        elif match := HOST_TERMINATE.search(line):
            found.append(("terminate", float(match.group(1)) if match.group(1) else None,
                          int(match.group(2)) if match.group(2) else None))
    return found


GRANT_TRIES = 2
GRANT_TIMEOUT = 90


def grant_photos(udid: str, run=sh, tries: int = GRANT_TRIES, timeout: float = GRANT_TIMEOUT) -> bool:
    """`simctl privacy grant photos`, tried again once with a fresh call when it fails.

    UI run 44108052342 (device test 09): the call hung until its 120 s timeout, and the app's
    launches in that time waited for it (one began 55 s late, 4 s after the call was killed),
    so the access stayed taken away and test 09 and, through it, test 10 failed. A normal grant
    takes about a second. Every try is in the log ("UI_HOST ... attempt N of M"); the tests'
    own checks decide as before (a grant that never came stays a red test)."""
    for attempt in range(1, tries + 1):
        started = time.monotonic()
        code, output = run(["xcrun", "simctl", "privacy", udid, "grant", "photos", BUNDLE_ID], timeout=timeout, quiet=True)
        took = time.monotonic() - started
        if code == 0:
            print(f"UI_HOST photo access granted ({took:.0f} s, attempt {attempt} of {tries})", flush=True)
            return True
        detail = " ".join(output.split())[:200]
        print(f"UI_HOST photo access grant failed (exit {code}, {took:.0f} s, attempt {attempt} of {tries})"
              + (f": {detail}" if detail else ""), flush=True)
    print(f"UI_HOST photo access NOT granted after {tries} attempts; the test that asked will fail on it", flush=True)
    return False


# The answer to a grant request that named a file. Device test09 waited 190 s after each of its
# three requests for iOS to end the app (UI runs 44617747359, 44630953220 and job 136352444126:
# 9 of 9 requests, the app was never ended by a grant), about 9.5 minutes of the device group.
# With the answer the test goes on as soon as the grant is done (or has failed). Only a file
# of this simulator's test runner is written (inside its folder under SIMULATOR_DEVICES, links
# resolved, the name the test gives it), never anything else the log names: a path that only
# contains "/Devices/<UDID>/", a folder that is a link to elsewhere and a link planted at the
# half-written file's name are all refused or not followed.
HOST_ANSWER_NAME = re.compile(r"^uitest-host-answer-[A-Za-z0-9-]{1,64}$")
# Where CoreSimulator keeps the simulators (read at each call: `~` is the runner's home).
SIMULATOR_DEVICES = "~/Library/Developer/CoreSimulator/Devices"


def write_host_answer(udid: str, path: str, answer: str) -> bool:
    """Writes `answer` ("granted" or "failed") to the test's answer file `path`; True when written."""
    folder, name = os.path.split(path)
    device = os.path.realpath(os.path.join(os.path.expanduser(SIMULATOR_DEVICES), udid))
    real_folder = os.path.realpath(folder) if folder else ""
    if not os.path.isabs(path) or ".." in path.split("/") or not HOST_ANSWER_NAME.match(name) \
            or not udid or "/" in udid or not real_folder.startswith(device + "/") or not os.path.isdir(real_folder):
        print(f"UI_HOST answer not written: {path[:200]} is no answer file of this simulator's tests", flush=True)
        return False
    partial = None
    try:
        # A new file of its own (mkstemp: a random name, O_EXCL, so a planted link is never
        # followed), then renamed over the answer file.
        handle, partial = tempfile.mkstemp(dir=real_folder, prefix=f".{name}.", suffix=".partial")
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(answer + "\n")
        os.replace(partial, os.path.join(real_folder, name))
        partial = None
    except OSError as error:
        print(f"UI_HOST answer not written ({error}); the test waits as before", flush=True)
        return False
    finally:
        if partial is not None:
            try:
                os.unlink(partial)
            except OSError:
                pass
    print(f"UI_HOST answer '{answer}' written for the test", flush=True)
    return True


# Ending the app from the Mac (terminate_app). The test waits TERMINATE_WAIT s for the app to be
# gone and then ends it through XCTest and launches it again; an end from the Mac after that would
# hit the new launch (as the late photo grant did in UI run 44355110562, test 09). So a call is
# only started while the request is younger than TERMINATE_FRESH s, and the last one ends (its
# timeout) well before the test stops waiting.
TERMINATE_TRIES = 2
TERMINATE_TIMEOUT = 20
TERMINATE_FRESH = 30
TERMINATE_WAIT = 60
# simctl's answer when the app is not running (any more): nothing left to end.
NOTHING_TO_TERMINATE = re.compile(r"found nothing to terminate", re.I)


def terminate_app(udid: str, asked: float | None, run=sh, clock=time.time, tries: int = TERMINATE_TRIES,
                  timeout: float = TERMINATE_TIMEOUT) -> bool:
    """`simctl terminate U app.albumist.ios` for a test that asked (UI_HOST_TERMINATE_APP at the
    epoch second `asked`), tried again once when simctl refuses (not after a timeout: that call
    may still end the app, and a second one would then hit the test's next launch), never for a
    request older than TERMINATE_FRESH s or without its second. True when the app is gone (also when it was gone already).

    Why: in UI run 44446270757 (test07) XCTest's own terminate inside `launch()` failed with
    "Failed to terminate app.albumist.ios:20655" although the app stood idle; simctl ends the app
    through CoreSimulator instead of XCTest. The test only reads the app's state meanwhile (no
    tap, no query of the app), so XCTest has nothing in flight that the end could break. Every
    try is in the log ("UI_HOST ... attempt N of M"); when the app is not gone the test ends it
    through XCTest as before."""
    for attempt in range(1, tries + 1):
        # Without its second a request cannot be dated: not answered (it might be old).
        age = clock() - asked if asked is not None else float("inf")
        if age >= TERMINATE_FRESH:
            print(f"UI_HOST app end request from {age:.0f} s ago skipped (attempt {attempt} of {tries}): "
                  "the test ends the app itself after its wait", flush=True)
            return False
        started = time.monotonic()
        code, output = run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], timeout=timeout, quiet=True)
        took = time.monotonic() - started
        if code == 0:
            print(f"UI_HOST app ended ({took:.0f} s, attempt {attempt} of {tries})", flush=True)
            return True
        detail = " ".join(output.split())[:200]
        if code != 124 and NOTHING_TO_TERMINATE.search(output):
            print(f"UI_HOST app ended before the Mac asked ({took:.0f} s, attempt {attempt} of {tries}): {detail}", flush=True)
            return True
        print(f"UI_HOST app end failed (exit {code}, {took:.0f} s, attempt {attempt} of {tries})"
              + (f": {detail}" if detail else ""), flush=True)
        if code == 124:
            # A timed-out simctl may still end the app later (CoreSimulator goes on without its
            # client). The test then sees the app gone and launches it again at once; a second
            # call would end that new launch. So no second call after a timeout.
            print("UI_HOST app end not tried again after a timeout: the test ends the app through XCTest "
                  "if it is still there", flush=True)
            return False
    print(f"UI_HOST app NOT ended after {tries} attempts; the test ends it through XCTest", flush=True)
    return False


# Ending exactly the app process the test named (UI_HOST_TERMINATE_APP <second> <pid>). Two
# failures on PR #9's UI run 44464687545 (device group, job 135384078482) came from ending by
# bundle id: in test09 the app ended by itself (iOS ends it when the photo access is taken
# away) right after the test asked, the test saw it gone and launched it again, and the Mac's
# `simctl terminate`, read from the log up to 2 s later, ended that NEW launch ("no photo
# access: continue" missing, app not running after the relaunch); in test06 `simctl
# terminate` hung for 20 s on the app left by test04, and XCTest then failed with "Failed to
# terminate". A process id cannot name the next launch, and the simulator's apps are processes
# of the Mac, so the Mac ends it itself: SIGTERM, then SIGKILL after PID_TERM_WAIT s. The id is
# only used when its command line is the app inside this simulator (its Devices/UDID folder
# and APP_PATH followed by its arguments), so a
# reused id never ends anything else.
PID_TERM_WAIT = 10
PID_KILL_WAIT = 5
APP_PATH = "/Albumist.app/Albumist"


def app_process(udid: str, pid: int, run=sh) -> str:
    """The command line of process `pid` when it is this simulator's app, "" when there is no
    such process, None when it is another process."""
    code, output = run(["ps", "-o", "command=", "-p", str(pid)], timeout=10, quiet=True)
    command = output.strip()
    if code != 0 or not command:
        return ""
    return command if f"/Devices/{udid}/" in command and (APP_PATH + " " in command + " ") else None


def end_app_process(udid: str, pid: int, run=sh, sleep=time.sleep) -> bool:
    """Ends the app process `pid` of simulator `udid` (SIGTERM, then SIGKILL); True when it is gone."""
    started = time.monotonic()
    found = app_process(udid, pid, run)
    if found is None:
        print(f"UI_HOST app end skipped: process {pid} is not Albumist in this simulator", flush=True)
        return False
    if found == "":
        print(f"UI_HOST app process {pid} had ended already", flush=True)
        return True
    for signal_name, wait in (("TERM", PID_TERM_WAIT), ("KILL", PID_KILL_WAIT)):
        run(["kill", f"-{signal_name}", str(pid)], timeout=10, quiet=True)
        for _ in range(int(wait * 2)):
            if app_process(udid, pid, run) == "":
                print(f"UI_HOST app process {pid} ended by SIG{signal_name} "
                      f"({time.monotonic() - started:.0f} s)", flush=True)
                return True
            sleep(0.5)
        print(f"UI_HOST app process {pid} still there {time.monotonic() - started:.0f} s after SIG{signal_name}", flush=True)
    return False


class HostGrants(threading.Thread):
    """Answers the tests' requests to the Mac, in log order, each time a test asks: gives the
    photo access back (UI_HOST_GRANT_PHOTOS, DeviceConditionUITests.grantFromHost; the CI
    simulator shows no iOS question after an access reset, and Settings opens on its first page,
    not on Albumist's) and ends the app before the next launch (UI_HOST_TERMINATE_APP,
    UITestAppEnd.end; `terminate_app`)."""

    def __init__(self, udid: str, log_path: str, interval: float = 2, grant=None, terminate=None, answer=None):
        super().__init__(daemon=True)
        self.udid, self.log_path, self.interval = udid, log_path, interval
        self.grant = grant or self.grant_photos
        self.terminate = terminate or self.terminate_app
        self.answer = answer or (lambda path, text: write_host_answer(self.udid, path, text))
        self.stopped = threading.Event()
        self.offset = 0
        self.tail = ""

    def grant_photos(self) -> bool:
        return grant_photos(self.udid)

    def terminate_app(self, asked: float | None, pid: int | None = None) -> None:
        # With the app's process id: exactly that process (`end_app_process`); without (a
        # launch that wrote no id yet), by bundle id as before.
        if pid is not None:
            end_app_process(self.udid, pid)
        else:
            terminate_app(self.udid, asked)

    def check(self) -> None:
        """Reads what was added to the log since the last call; one answer per complete request line."""
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as log:
                log.seek(self.offset)
                chunk = log.read()
                self.offset = log.tell()
        except OSError:
            chunk = ""
        complete, _, self.tail = (self.tail + chunk).rpartition("\n")
        for kind, asked, detail in host_requests(complete):
            if kind == "grant":
                granted = self.grant()
                # The test waits for this answer instead of a fixed 190 s (`write_host_answer`).
                if isinstance(detail, str):
                    self.answer(detail, "granted" if granted else "failed")
            else:
                self.terminate(asked, detail)
        # A failure shows in the job log at once, not only when the pass ends: a run cancelled
        # (or a runner lost) after it is still red for ui_evidence.py.
        for line in complete.splitlines():
            if LIVE.search(line) and not DATA_LINE.search(line):
                print(f"UI_LIVE {line[:400]}", flush=True)

    def run(self) -> None:
        while not self.stopped.wait(self.interval):
            self.check()

    def stop(self) -> None:
        self.stopped.set()
        self.join(timeout=30)


def device_state(udid: str) -> str:
    """"Booted", "Shutdown", ... of a simulator, or "" when simctl does not say (then unknown)."""
    code, listing = sh(["xcrun", "simctl", "list", "devices", "-j"], timeout=30, quiet=True)
    if code != 0:
        return ""
    try:
        for entries in json.loads(listing).get("devices", {}).values():
            for d in entries:
                if d.get("udid") == udid:
                    return str(d.get("state", ""))
    except (ValueError, AttributeError):
        pass
    return ""


class Watchdog(threading.Thread):
    """Stops xcodebuild when the simulator leaves "Booted" before the first test started.

    Hosted Macs sometimes lose the simulator 1-5 min into a pass ("Test crashed with signal term
    while preparing to run tests", then "device is not booted"; UI run 43893790053 lost 4-5 min
    per group waiting for xcodebuild to give up). The stop is written to the log as a
    UI_WATCHDOG line (an infrastructure line for `decide`) and counted as FLAKY_BOOT; the pass is
    then repeated once on an erased simulator like any other simulator failure."""

    def __init__(self, udid: str, log_path: str, process: subprocess.Popen, interval: float = 20):
        super().__init__(daemon=True)
        self.udid, self.log_path, self.process, self.interval = udid, log_path, process, interval
        self.stopped = threading.Event()
        self.fired = ""

    def read_log(self) -> str:
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as log:
                return log.read()
        except OSError:
            return ""

    def run(self) -> None:
        states: list[str] = []
        while not self.stopped.wait(self.interval):
            text = self.read_log()
            if STARTED.search(text):
                return
            states.append(device_state(self.udid))
            if watchdog_should_stop(text, states):
                # device_state can take up to 30 s; a test that started meanwhile must not be
                # stopped, so the log is read again right before the stop.
                if STARTED.search(self.read_log()):
                    return
                self.fired = states[-1]
                print(f"UI_WATCHDOG simulator {self.udid} is {self.fired} before the first test; stopping the pass", flush=True)
                self.process.terminate()
                try:
                    self.process.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                return

    def stop(self) -> None:
        self.stopped.set()


# Handed to the tests (xcodebuild passes TEST_RUNNER_X on as X): the Mac answers UI_HOST_ lines
# (HostGrants). Without it (a run in Xcode) the tests do not ask the Mac to end the app.
HOST_HELPER = "TEST_RUNNER_ALBUMIST_HOST_HELPER"


def runner_env(base: dict | None = None) -> dict:
    """The environment of xcodebuild for a pass: the job's own plus HOST_HELPER=1."""
    env = dict(os.environ if base is None else base)
    env[HOST_HELPER] = "1"
    if MTC_DYLIB:
        env["TEST_RUNNER_ALBUMIST_MTC_DYLIB"] = MTC_DYLIB
        if MTC_PROBE_ON:
            env["TEST_RUNNER_ALBUMIST_MTC_PROBE"] = "1"
    return env


# Set by run_group (mtc_dylib, the gate's probe): the Main Thread Checker for every app launch.
MTC_DYLIB = ""
MTC_PROBE_ON = False
CONSOLES: list[str] = []


def run_pass(args, label: str, chosen: list[str], build: bool) -> tuple[int, str, str, float, bool]:
    """One xcodebuild run; returns (status, log text, result bundle path, start time, whether
    the watchdog stopped it)."""
    suffix = "" if label == "first" else "-retry"
    log_path = os.path.join(args.out, f"{args.name}{suffix}-log.txt")
    result = os.path.join(args.out, f"{args.name}{suffix}.xcresult")
    if args.xctestrun:
        command = ["xcodebuild", "test-without-building", "-xctestrun", args.xctestrun]
    else:
        command = ["xcodebuild", "test" if build else "test-without-building", "-project", args.project,
                   "-scheme", args.scheme, "CODE_SIGNING_ALLOWED=NO"]
    command += ["-destination", f"id={args.udid}", "-resultBundlePath", result] + chosen
    settled = time.monotonic()
    settle(lambda: simulator_probe(args.udid), limit=settle_limit(getattr(args, "deadline", 0) or 0, time.time()))
    timing(f"wait for the simulator before the {label} pass", settled)
    print(f"UI_PASS {args.name} {label}: {' '.join(chosen) or 'all tests'}", flush=True)
    # SwiftUI reports broken navigation (link without destination) and similar runtime problems
    # only in the system log, so it is recorded during the whole pass.
    with open(os.path.join(args.out, f"{args.name}-swiftui.txt"), "a") as swiftui:
        stream = subprocess.Popen(
            ["xcrun", "simctl", "spawn", args.udid, "log", "stream", "--style", "compact", "--level", "debug",
             "--predicate", 'process == "Albumist" AND (subsystem == "com.apple.SwiftUI" OR messageType == fault '
                            'OR eventMessage CONTAINS[c] "navigationDestination")'],
            stdout=swiftui, stderr=subprocess.STDOUT)
    recorder = None
    if args.video and not os.path.exists(args.video):
        recorder = Recorder(args.udid, log_path, args.video)
        recorder.start()
    started = time.time()
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=runner_env())
        watchdog = Watchdog(args.udid, log_path, process)
        watchdog.start()
        grants = HostGrants(args.udid, log_path)
        grants.start()
        status, hung = wait_until(process, getattr(args, "deadline", 0) or 0)
        grants.stop()
        watchdog.stop()
        watchdog.join(timeout=90)
    if hung:
        with open(log_path, encoding="utf-8", errors="replace") as log:
            test = running_test(log.read())
        with open(log_path, "a") as log:
            if test:
                log.write(f"\nUI_HANG pass {label}: {test} still running at the job's deadline; xcodebuild stopped\n")
            else:
                log.write(f"\nUI_DEADLINE pass {label} stopped at the job's deadline with no test running\n")
        print(f"::error title=UI {args.name}::The {label} pass did not end before the job's deadline"
              + (f" ({test} hangs); stopped." if test else "; no test was running, stopped."), flush=True)
        status = status or 1
    if watchdog.fired:
        with open(log_path, "a") as log:
            log.write(f"\nUI_WATCHDOG simulator {args.udid} left Booted (state {watchdog.fired}) before the first test; "
                      "pass stopped\n")
        BOOT_RETRIES.append(f"simulator left Booted (state {watchdog.fired}) before the first test of the {label} pass; "
                            "stopped by the watchdog")
        status = status or 1
    stream.terminate()
    if recorder:
        recorder.stop()
    # Before a repeat erases the simulator: the Main Thread Checker writes only to this file.
    CONSOLES.append(collect_console(args.udid, args.out, args.name, label))
    print(f"UI_PASS_TIME {args.name} {label} {int(time.time() - started)} s (exit {status})", flush=True)
    with open(log_path, encoding="utf-8", errors="replace") as log:
        text = log.read()
    # A pass stopped by the watchdog or at the deadline may leave a result bundle xcodebuild
    # could not finish; command_run then drops only the "not readable" finding (watchdog_bundle).
    return status, text, result, started, bool(watchdog.fired) or hung


RUNNING = re.compile(r"Test Case '-\[\w+\.(\w+) (\w+)\]' (started|passed|failed|skipped)")


def running_test(log: str) -> str | None:
    """"Class/test" of a test case that started and has no passed/failed/skipped line yet."""
    open_tests: list[str] = []
    for match in RUNNING.finditer(log):
        name = f"{match.group(1)}/{match.group(2)}"
        if match.group(3) == "started":
            open_tests.append(name)
        elif name in open_tests:
            open_tests.remove(name)
    return open_tests[-1] if open_tests else None


def wait_until(process, deadline: float, grace: float = 30) -> tuple[int, bool]:
    """(exit status, whether it hung): waits for `process` until the epoch second `deadline`
    (0: no deadline), then stops it: SIGINT first, which lets xcodebuild end the test and write
    its result bundle like Ctrl-C does; after `grace` seconds SIGTERM, after `grace` more SIGKILL."""
    if not deadline:
        return process.wait(), False
    try:
        return process.wait(timeout=max(1.0, deadline - time.time())), False
    except subprocess.TimeoutExpired:
        pass
    for stop in (lambda: process.send_signal(signal.SIGINT), process.terminate):
        stop()
        try:
            return process.wait(timeout=grace) or 1, True
        except subprocess.TimeoutExpired:
            continue
    process.kill()
    return process.wait() or 1, True


def report(text: str, status: int, label: str) -> None:
    printed = 0
    for line in text.splitlines():
        if REPORT.search(line) and "/SourcePackages/" not in line:
            print(line)
            printed += 1
            if printed >= REPORT_LIMIT:
                print(f"UI_REPORT_CUT {label}: more than {REPORT_LIMIT} lines")
                break
    # A pass that fails before any test runs leaves nothing for the filter above.
    if status != 0 and "Test Case" not in text:
        for line in [l for l in text.splitlines() if "PREVIEW_JPEG" not in l][-40:]:
            print(f"UI_LOG_TAIL {label} {line[:400]}")
    for line in restart_context(text):
        print(f"UI_RESTART_CONTEXT {label} {line}")


def print_crash_reports(paths: list[str], label: str) -> None:
    for path in paths:
        print(f"UI_CRASH_REPORT {label} {path}")
        try:
            with open(path, encoding="utf-8", errors="replace") as report_file:
                head = report_file.read(6000)
        except OSError as error:
            head = str(error)
        for line in head.splitlines()[:150]:
            print(f"UI_CRASH {line}")


def command_run(args) -> int:
    began = time.time()
    try:
        return run_group(args)
    finally:
        try:
            budget_check(args.name, time.time() - began, getattr(args, "budget_min", 0) or 0)
        except Exception as error:  # a report: never in place of the run's exit code or error
            print(f"UI_BUDGET {args.name}: not checked ({type(error).__name__}: {error})", flush=True)


def budget_check(name: str, seconds: float, budget_min: float) -> bool:
    """The group's time against its budget (review P5-05: one verdict took 84 min, nobody saw
    which group grew). Prints UI_BUDGET; over the budget a warning on the run page and a line in
    the job summary. Never red: a slow Mac is no test result. True when within the budget."""
    minutes = seconds / 60
    within = not budget_min or minutes <= budget_min
    budget = f"budget {budget_min:g} min" if budget_min else "no budget"
    print(f"UI_BUDGET {name} {minutes:.1f} min ({budget}){'' if within else ' OVER'}", flush=True)
    if not within:
        text = (f"{name} took {minutes:.0f} min, over its budget of {budget_min:g} min "
                "(.github/ui-groups.json, budget_min): a slow Mac or a test that grew; see UI_PASS_TIME and UI_TIMING")
        print(f"::warning title=UI {name} over its time budget::{text}", flush=True)
        path = os.environ.get("GITHUB_STEP_SUMMARY")
        if path:
            with open(path, "a", encoding="utf-8") as out:
                out.write(f"\n**Time budget:** {text}\n")
    return within


def run_group(args) -> int:
    global MTC_DYLIB, MTC_PROBE_ON
    os.makedirs(args.out, exist_ok=True)
    gate = load_gate()
    MTC_DYLIB = ""
    if gate["main_thread_checker"].get("inject", True):
        found = mtc_dylib(args.udid)
        if not found:
            print("::warning title=UI Main Thread Checker::library of the simulator runtime not found: "
                  "this group runs without the checker", flush=True)
        elif not mtc_preflight(args.udid, found):
            print(f"::warning title=UI Main Thread Checker::{found} stopped a test launch: this group runs without "
                  "the checker", flush=True)
        else:
            MTC_DYLIB = found
    MTC_PROBE_ON = bool(gate["main_thread_checker"].get("probe"))
    print(f"UI_MTC_DYLIB {MTC_DYLIB or 'none (the app runs without the Main Thread Checker)'}", flush=True)
    CONSOLES.clear()
    chosen = selection(args.only, args.skip)
    if args.increase_contrast:
        prepare(args.udid, increase_contrast=True, basics=False)
    status, text, bundle_path, started, stopped = run_pass(args, "first", chosen, build=True)
    report(text, status, "first")
    crashes = crash_reports(started) if status else []
    # Whether the simulator is still there after a failed pass ("device is not booted").
    probe = sh(["xcrun", "simctl", "spawn", args.udid, "launchctl", "getenv", "HOME"], timeout=60, quiet=True)[1] if status else ""
    bundle = read_bundle(bundle_path) if status else []
    if stopped:
        bundle = watchdog_bundle(bundle)
    verdict, reasons = decide(status, text, crashes, probe[:4000], bundle)
    print(f"UI_VERDICT {args.name} first: {verdict}" + (f" ({'; '.join(reasons)})" if reasons else ""), flush=True)
    print_crash_reports(crashes + other_crash_reports(started) if status else [], "first")
    passes = [("first", 0 if verdict == "pass" else (status or 1), verdict, reasons, text)]
    first_log, retry_reasons, retry_log, retry_result = text, [], None, None
    stays_red = False
    if verdict == "retry":
        retry_reasons = reasons
        retry = retry_arguments(args.only, args.skip, text)
        if retry is None:
            stays_red = True
            print(f"UI_VERDICT {args.name}: every selected test passed, nothing to repeat; the failed pass stays red")
        else:
            print(f"::warning title=UI {args.name}::The simulator failed ({'; '.join(reasons)}); no test found a problem. "
                  "The tests that did not pass run once more on an erased simulator.")
            deadline = getattr(args, "deadline", 0) or 0
            if deadline and deadline - time.time() < RETRY_BEFORE_RESET:
                print(f"UI_VERDICT retry skipped: {max(0, deadline - time.time()) / 60:.0f} min left before the job's "
                      "deadline, too little for an erase and a repeat")
                retry_result = "not started (too little time before the deadline)"
            elif not reset(args.udid, args.reduce_motion, args.increase_contrast):
                print("UI_VERDICT retry impossible: the simulator did not come back after the erase")
                retry_result = "not started (simulator did not come back)"
            elif deadline and deadline - time.time() < RETRY_AFTER_RESET:
                print(f"UI_VERDICT retry skipped: the erase took until {max(0, deadline - time.time()) / 60:.0f} min "
                      "before the job's deadline")
                retry_result = "not started (too little time before the deadline)"
            else:
                status, text, bundle_path, started, stopped = run_pass(args, "retry", retry, build=False)
                report(text, status, "retry")
                crashes = crash_reports(started) if status else []
                bundle = read_bundle(bundle_path) if status else []
                verdict, reasons = decide(status, text, crashes, bundle=watchdog_bundle(bundle) if stopped else bundle,
                                          earlier=first_log)
                # "infra": the repeat failed on the simulator or XCTest alone again.
                final = {"pass": "pass", "retry": "infra"}.get(verdict, "fail")
                again = daemon_crash_tests(first_log) & daemon_crash_tests(text)
                if final == "infra" and again:
                    # The daemon crashed again in the same test: likely caused by what the test
                    # does in the app (a huge accessibility tree, ...), so red, not "no result".
                    final = "fail"
                    reasons = ["testmanagerd crashed again in the same test: "
                               + ", ".join(f"{c}/{t}" for c, t in sorted(again)) + " (likely app-caused)"] + reasons
                print(f"UI_VERDICT {args.name} retry: {final}" + (f" ({'; '.join(reasons)})" if reasons else ""), flush=True)
                print_crash_reports(crashes + other_crash_reports(started) if status else [], "retry")
                passes.append(("retry", 0 if final == "pass" else (status or 1), final, reasons, text))
                retry_log, retry_result = text, final
        if retry is None:
            retry_reasons = []
    record = flaky_record(args.name, first_log, retry_reasons, retry_log, retry_result, boot_retries(args.out))
    record["sweep_skips"] = sweep_skips(first_log + "\n" + (retry_log or ""))
    write_flaky(args, record)
    # The result is the last pass: the first one when nothing was repeated, else the repeat
    # (which ran every test that had not passed in the first one).
    failed = passes[-1][1] != 0
    infra_only = failed and passes[-1][2] in ("retry", "infra") and not stays_red
    system_log_path = os.path.join(args.out, f"{args.name}-swiftui.txt")
    if swiftui_warnings(system_log_path) != 0:
        failed, infra_only = True, False
    # The video first: its base64 lines are most of the job log, and the reports below are read
    # from the log's end (a tail of 350 lines held only video in UI run 44870948643).
    if args.video:
        video_to_log(args.video)
    if quality_gates(args.name, system_log_path, "\n".join(CONSOLES), gate) and not infra_only:
        failed = True
    try:
        perf_report(args.name, "\n".join(p[4] for p in passes))
    except Exception as error:  # noqa: BLE001 - a report must not hide the test result
        print(f"::warning title=UI {args.name}::speed report failed: {error!r}", flush=True)
    if args.a11y_summary:
        joined = "\n".join(p[4] for p in passes)
        print(f"A11Y_SUMMARY {args.name} fails {joined.count('A11Y_FAIL ')} warnings {joined.count('A11Y_WARN ')}")
    write_summary(args.name, passes)
    # The line ui_evidence.py reads in the job log: only "fail" is a red for the group's key.
    result = "infra" if infra_only else ("fail" if failed else "pass")
    print(f"UI_RESULT {args.name} {result}", flush=True)
    if infra_only:
        # Every pass failed on the simulator or XCTest alone (the repeat too, or it could not
        # start): no test result for the group. The workflow fails the job in its own step "No
        # test result (simulator or XCTest failed in every pass)" instead of "Run UI tests".
        reasons = "; ".join(passes[-1][3]) or "no reason found"
        with open(os.path.join(args.out, NO_TEST_RESULT), "w", encoding="utf-8") as marker:
            marker.write(reasons + "\n")
        print(f"::warning title=UI {args.name}::No test result: the simulator or XCTest failed in every pass "
              f"({reasons}). Neither green nor red for this group; start it again.")
        return NO_TEST_EXIT
    return 1 if failed else 0


# --- Hang watch and Main Thread Checker (owner's decision 16.11.2026) -----------------------------

GATE_FILE = ".github/hang-gate.json"
CONSOLE_FILE = "albumist-console.log"
MAIN_HANG = re.compile(r"\bUI_MAIN_HANG (\d+) ms (\w+) in \[(.*?)\]: (.*?)\s*$")
MTC_STATE = re.compile(r"\bUI_FACT main thread checker (active|not active)\b")
MTC_START = re.compile(r"Main Thread Checker: (.+?)\s*$")
MTC_FRAME = re.compile(r"^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.*?)\s*$")
MTC_PROBE = "MainThreadCheckerProbe"
OWN_IMAGES = ("Albumist", "Albumist.debug.dylib")
HANG_KINDS = ("app", "test", "start", "inactive", "starved", "system", "unknown")
# The app's ping goes out up to one watch tick (50 ms, MainThreadWatch.tick) after the main thread
# last answered, so a wait is measured up to 50 ms short: a line from limit - 50 ms counts.
MAIN_HANG_SLACK_MS = 50
# A system app the preflight launches with the checker inserted (always on the simulator).
PREFLIGHT_APP = "com.apple.Preferences"


def load_gate(path: str = "") -> dict:
    """The gate settings (GATE_FILE in the checkout this script belongs to, whatever the working
    directory); a missing or broken file means 'report' for both (never red by accident)."""
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", GATE_FILE)
    default = {"hangs": {"mode": "report", "limit_ms": 250, "known": []},
               "main_thread_checker": {"mode": "report", "inject": True, "probe": True, "known": []}}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not all(isinstance(data.get(k, {}), dict) for k in default):
            raise ValueError("not an object of objects")
    except (OSError, ValueError) as error:
        print(f"::warning::{path} not readable ({error}): hang watch and Main Thread Checker only report", flush=True)
        return default
    for key, value in default.items():
        data.setdefault(key, {})
        for field, fallback in value.items():
            data[key].setdefault(field, fallback)
    return data


def known_entry(known: list[dict], *texts: str) -> dict | None:
    """The 'known' entry whose place is part of one of the texts."""
    for entry in known:
        places = [entry.get(k) for k in ("stack", "api") if entry.get(k)]
        if places and any(place in text for place in places for text in texts):
            return entry
    return None


def parse_hangs(text: str, limit_ms: int) -> list[dict]:
    hangs = []
    for line in text.splitlines():
        match = MAIN_HANG.search(line)
        if match and int(match.group(1)) >= limit_ms:
            hangs.append({"ms": int(match.group(1)), "kind": match.group(2),
                          "sections": match.group(3), "stack": match.group(4)})
    return hangs


def hang_report(name: str, log_path: str, gate: dict, summary: str | None = None) -> tuple[int, int]:
    """The group's hangs of 250 ms or more (UI_MAIN_HANG lines of the app, from the system log of
    every pass): UI_HANG_COUNT per kind, UI_HANG_APP per place of Albumist's code (count, longest,
    sections), a table in the job summary. Returns (new app hangs, all app hangs); new = not in
    the gate's 'known' list."""
    settings = gate["hangs"]
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            hangs = parse_hangs(f.read(), int(settings["limit_ms"]) - MAIN_HANG_SLACK_MS)
    except OSError:
        hangs = []
    kinds: dict[str, list[int]] = {}
    for hang in hangs:
        kinds.setdefault(hang["kind"], []).append(hang["ms"])
    for kind in HANG_KINDS:
        values = kinds.get(kind, [])
        print(f"UI_HANG_COUNT {name} {kind} {len(values)}" + (f" (longest {max(values)} ms, total {sum(values)} ms)" if values else ""),
              flush=True)
    places: dict[str, dict] = {}
    for hang in hangs:
        if hang["kind"] != "app":
            continue
        place = places.setdefault(hang["stack"], {"count": 0, "longest": 0, "sections": set()})
        place["count"] += 1
        place["longest"] = max(place["longest"], hang["ms"])
        place["sections"].add(hang["sections"])
    new = 0
    rows = []
    for stack, place in sorted(places.items(), key=lambda kv: (-kv[1]["longest"], -kv[1]["count"])):
        entry = known_entry(settings["known"], stack)
        if entry is None:
            new += place["count"]
        label = f"known: {entry.get('why', '')}" if entry else "new"
        print(f"UI_HANG_APP {name} {place['count']}x longest {place['longest']} ms ({label}) "
              f"in [{', '.join(sorted(place['sections']))}]: {stack}", flush=True)
        rows.append(f"| {place['count']} | {place['longest']} ms | {label} | "
                    f"{', '.join(sorted(place['sections']))} | `{stack.replace('|', '¦')}` |")
    total = len(kinds.get("app", []))
    if total and settings["mode"] == "fail" and new:
        print(f"::error title=UI {name} hangs::{new} hang(s) of {settings['limit_ms']} ms or more in Albumist's own "
              "code (UI_HANG_APP lines; .github/hang-gate.json)", flush=True)
    elif new:
        print(f"::warning title=UI {name} hangs::{new} hang(s) of {settings['limit_ms']} ms or more in Albumist's own "
              "code (report only; UI_HANG_APP lines)", flush=True)
    path = summary if summary is not None else os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        counts = ", ".join(f"{k} {len(kinds.get(k, []))}" for k in HANG_KINDS)
        with open(path, "a", encoding="utf-8") as out:
            out.write(f"\n**Hangs ≥ {settings['limit_ms']} ms ({name}, mode {settings['mode']}; measured up to "
                      f"{MAIN_HANG_SLACK_MS} ms short, so counted from {settings['limit_ms'] - MAIN_HANG_SLACK_MS} ms):** {counts}\n")
            if rows:
                out.write("\n| Count | Longest | Status | Sections | Albumist frames |\n|---|---|---|---|---|\n")
                out.write("\n".join(rows[:25]) + "\n")
    return new, total


def parse_mtc(text: str) -> list[dict]:
    """The Main Thread Checker's reports in the app's console file: the API it names and the
    frames of its backtrace."""
    reports: list[dict] = []
    current = None
    for line in text.splitlines():
        start = MTC_START.search(line)
        if start:
            current = {"api": start.group(1), "frames": []}
            reports.append(current)
            continue
        if current is None:
            continue
        frame = MTC_FRAME.match(line)
        if frame:
            current["frames"].append(f"{frame.group(1)} {frame.group(2)}")
        elif current["frames"] and not line.strip().startswith(("PID:", "Backtrace:")):
            current = None
    return reports


def mtc_place(report: dict) -> str:
    """Albumist's frames of a report (at most 5), else its first 3 frames."""
    own = [f for f in report["frames"] if f.split(" ", 1)[0] in OWN_IMAGES][:5]
    return " | ".join(own or report["frames"][:3])


def main_thread_checker_report(name: str, console_text: str, system_log: str, gate: dict,
                               summary: str | None = None) -> int:
    """The checker's reports of the group (UI_MTC lines, one per place) and whether it watched:
    every launch logs 'UI_FACT main thread checker active|not active', and with the probe every
    launch makes one deliberate report. Returns the number of new reports (not the probe, not
    'known')."""
    settings = gate["main_thread_checker"]
    states = MTC_STATE.findall(system_log)
    reports = parse_mtc(console_text)
    probes = [r for r in reports if any(MTC_PROBE in f for f in r["frames"])]
    real = [r for r in reports if r not in probes]
    print(f"UI_MTC_STATE {name} launches with the checker {states.count('active')}, without {states.count('not active')}, "
          f"probe reports {len(probes)}, other reports {len(real)}", flush=True)
    warnings = []
    if states.count("not active"):
        warnings.append(f"{states.count('not active')} launch(es) without the Main Thread Checker")
    if settings.get("probe") and len(probes) < states.count("active"):
        warnings.append(f"only {len(probes)} of {states.count('active')} launches' deliberate probe reports reached the console "
                        "file: reports of the other launches may be lost")
    places: dict[str, dict] = {}
    for r in real:
        place = places.setdefault(f"{r['api']} @ {mtc_place(r)}", {"count": 0, "api": r["api"], "stack": mtc_place(r)})
        place["count"] += 1
    new = 0
    rows = []
    for key, place in sorted(places.items(), key=lambda kv: -kv[1]["count"]):
        entry = known_entry(settings["known"], place["api"], place["stack"])
        if entry is None:
            new += place["count"]
        label = f"known: {entry.get('why', '')}" if entry else "new"
        print(f"UI_MTC {name} {place['count']}x ({label}) {key}", flush=True)
        rows.append(f"| {place['count']} | {label} | {place['api']} | `{place['stack'].replace('|', '¦')}` |")
    for warning in warnings:
        print(f"::warning title=UI {name} Main Thread Checker::{warning}", flush=True)
    if new:
        level = "error" if settings["mode"] == "fail" else "warning"
        print(f"::{level} title=UI {name} Main Thread Checker::{new} report(s) of UI work off the main thread (UI_MTC lines)",
              flush=True)
    path = summary if summary is not None else os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write(f"\n**Main Thread Checker ({name}, mode {settings['mode']}):** {len(real)} report(s), "
                      f"{states.count('active')} launch(es) watched, probe {'seen' if probes else 'not seen'}"
                      + (f"; {'; '.join(warnings)}" if warnings else "") + "\n")
            if rows:
                out.write("\n| Count | Status | API | Frames |\n|---|---|---|---|\n" + "\n".join(rows[:25]) + "\n")
    return new


def mtc_dylib(udid: str, run=sh, exists=os.path.exists) -> str:
    """The Main Thread Checker library of the simulator runtime `udid` runs on ('' when there is
    none): <runtimeRoot>/usr/lib/libMainThreadChecker.dylib, the copy Xcode itself inserts into a
    simulator app (the macOS one in Xcode's usr/lib would stop every launch)."""
    status, devices = run(["xcrun", "simctl", "list", "devices", "-j"], timeout=60, quiet=True)
    status2, runtimes = run(["xcrun", "simctl", "list", "runtimes", "-j"], timeout=60, quiet=True)
    if status or status2:
        return ""
    try:
        runtime = next(key for key, items in json.loads(devices).get("devices", {}).items()
                       if any(d.get("udid") == udid for d in items))
        root = next(r.get("runtimeRoot", "") for r in json.loads(runtimes).get("runtimes", [])
                    if r.get("identifier") == runtime)
    except (ValueError, StopIteration, AttributeError):
        return ""
    candidate = f"{root}/usr/lib/libMainThreadChecker.dylib" if root else ""
    return candidate if candidate and exists(candidate) else ""


def mtc_preflight(udid: str, dylib: str, run=sh, sleep=time.sleep, retried: bool = False) -> bool:
    """Launches a system app with the checker inserted and sees it still running after 5 s: a
    library that cannot load stops every process it is inserted into, and the UI tests would
    then fail at every launch, looking like a simulator failure. False: run without it."""
    env_name = "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"
    previous = os.environ.get(env_name)
    os.environ[env_name] = dylib
    try:
        status, out = run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, PREFLIGHT_APP],
                          timeout=90, quiet=True)
    finally:
        if previous is None:
            os.environ.pop(env_name, None)
        else:
            os.environ[env_name] = previous
    match = re.search(r":\s*(\d+)\s*$", out.strip())
    if (status or not match) and not retried:
        # A simulator still settling after its boot: once more after a pause.
        print(f"UI_MTC_PREFLIGHT launch failed, again in 30 s ({out.strip()[-200:]})", flush=True)
        sleep(30)
        return mtc_preflight(udid, dylib, run, sleep, retried=True)
    if status or not match:
        print(f"UI_MTC_PREFLIGHT launch failed ({out.strip()[-300:]})", flush=True)
        return False
    sleep(5)
    alive, _ = run(["ps", "-p", match.group(1)], timeout=30, quiet=True)
    run(["xcrun", "simctl", "terminate", udid, PREFLIGHT_APP], timeout=60, quiet=True)
    print(f"UI_MTC_PREFLIGHT {PREFLIGHT_APP} with the checker {'kept running' if alive == 0 else 'ended at once'}", flush=True)
    return alive == 0


def collect_console(udid: str, out: str, name: str, label: str, run=sh) -> str:
    """Copies the app's console file (all launches of the pass) next to the logs and empties it
    for the next pass; returns its text ('' when the app never ran)."""
    status, container = run(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"], timeout=60, quiet=True)
    container = container.strip().splitlines()[-1] if status == 0 and container.strip() else ""
    if not container:
        return ""
    source = os.path.join(container, "tmp", CONSOLE_FILE)
    try:
        with open(source, encoding="utf-8", errors="replace") as f:
            text = f.read()
        os.remove(source)
    except OSError:
        return ""
    with open(os.path.join(out, f"{name}-console-{label}.txt"), "w", encoding="utf-8") as copy:
        copy.write(text)
    return text


def swiftui_warnings(path: str) -> int:
    """Prints the app's unique runtime warnings; 1 when a navigation link leads nowhere."""
    try:
        with open(path, encoding="utf-8", errors="replace") as log:
            lines = log.read().splitlines()
    except OSError:
        return 0
    counts: dict[str, int] = {}
    for line in lines:
        if re.search(r"^Filtering|^Timestamp|SwiftUI:Scenes|_UIHostingView|renderbox|UI_MAIN_HANG|UI_FACT main thread checker", line):
            continue
        key = line[24:]
        counts[key] = counts.get(key, 0) + 1
    for key, count in sorted(counts.items(), key=lambda kv: -kv[1])[:40]:
        print(f"UI_RUNTIME_WARNING {count:>7} {key}")
    text = "\n".join(lines)
    if re.search(r"Publishing changes from within view updates|Modifying state during view update", text, re.I):
        print("::warning::SwiftUI state was changed during a view update (see UI_RUNTIME_WARNING)")
    if re.search(r"no matching navigationDestination|NavigationLink is presenting|cannot be activated", text, re.I):
        print("::error::SwiftUI navigation warning in the UI run (a link leads nowhere)")
        return 1
    return 0


# "Test Case '-[AlbumistUITests.PerformanceUITests test1_LaunchTime]' measured [Duration (AppLaunch), s]
# average: 1.234, relative standard deviation: 3.210%, values: [...]" (newer xcodebuild: "Test case
# 'PerformanceUITests.test1_LaunchTime()' measured ...").
PERF_MEASURED = re.compile(r"Test [Cc]ase '([^']+)' measured \[([^\]]+)\] average: ([\d.]+)"
                           r"(?:, relative standard deviation: ([\d.]+)%)?")
PERF_OWN = re.compile(r"UI_PERF (\w+) ([\d.]+) (\w+)")


def perf_values(text: str) -> list[dict]:
    """The speed measurements of a group's log (PerformanceUITests): XCTest's "measured [...]
    average" lines and the tests' own UI_PERF lines. A value measured in two passes counts
    from the last one."""
    found: dict[tuple[str, str], dict] = {}
    for m in PERF_MEASURED.finditer(text):
        test = re.findall(r"test\w+", m.group(1))
        test = test[-1] if test else m.group(1)
        found[(test, m.group(2))] = {"test": test, "metric": m.group(2), "value": float(m.group(3)),
                                     "rsd": float(m.group(4)) if m.group(4) else None}
    for m in PERF_OWN.finditer(text):
        key = ("own", m.group(1))
        found[key] = {"test": "own", "metric": f"{m.group(1)} ({m.group(3)})", "value": float(m.group(2)), "rsd": None}
    return list(found.values())


def perf_report(name: str, text: str, summary: str | None = None) -> list[dict]:
    """UI_PERF_VALUE lines and a table in the job summary. Report only (owner 16.11.: generous
    limits or none): nothing here makes the run red."""
    values = perf_values(text)
    ran = re.search(r"Test [Cc]ase '[^']*PerformanceUITests[ .]test", text)
    if ran and not any(v["test"] != "own" for v in values):
        # XCTest's own values were not recognised (UI run 44875998902: only the analysis time
        # came through): the raw lines, so the next run shows their format.
        raw = [line.strip() for line in text.splitlines() if " measured " in line or "XCTMetric" in line][:12]
        print(f"UI_PERF_RAW {name} no XCTest values recognised; {len(raw)} line(s) with 'measured':", flush=True)
        for line in raw:
            print(f"UI_PERF_RAW {line[:400]}", flush=True)
    for v in values:
        rsd = f", spread {v['rsd']:.1f} %" if v["rsd"] is not None else ""
        print(f"UI_PERF_VALUE {name} {v['test']} {v['metric']}: {v['value']:g}{rsd}", flush=True)
    path = summary if summary is not None else os.environ.get("GITHUB_STEP_SUMMARY")
    if path and values:
        with open(path, "a", encoding="utf-8") as out:
            out.write(f"\n**Speed ({name}, report only; CI simulator, for trends between runs):**\n\n"
                      "| Test | Metric | Average | Spread |\n|---|---|---|---|\n")
            for v in values:
                spread = f"{v['rsd']:.1f} %" if v["rsd"] is not None else "one run"
                out.write(f"| {v['test']} | {v['metric'].replace('|', '¦')} | {v['value']:g} | {spread} |\n")
    return values


def quality_gates(name: str, system_log_path: str, console: str, gate: dict) -> bool:
    """Hang watch and Main Thread Checker for the group; True when a gate in mode 'fail' found
    something new. Never raises: a report that cannot be made is a warning, not a red run."""
    try:
        new_hangs, _ = hang_report(name, system_log_path, gate)
        try:
            with open(system_log_path, encoding="utf-8", errors="replace") as f:
                system_log = f.read()
        except OSError:
            system_log = ""
        new_mtc = main_thread_checker_report(name, console, system_log, gate)
    except Exception as error:  # noqa: BLE001 - a broken report must not hide the test result
        print(f"::warning title=UI {name}::hang and Main Thread Checker report failed: {error!r}", flush=True)
        return False
    checker = gate["main_thread_checker"]
    # A group that ran without the checker (its library not found, or the preflight launch failed
    # twice on a settling simulator) has no verdict on it. Loud, but not red: making it red let a
    # simulator hiccup block a TestFlight upload through release-smoke and stress, which run the
    # same groups code (second review 21.11.). UI_MTC_UNCHECKED counts such groups.
    if checker["mode"] == "fail" and checker.get("inject", True) and not MTC_DYLIB:
        print(f"UI_MTC_UNCHECKED {name}", flush=True)
        print(f"::warning title=UI {name} Main Thread Checker::the group ran WITHOUT the checker (UI_MTC_DYLIB): "
              "its launches were not checked", flush=True)
    red = (gate["hangs"]["mode"] == "fail" and new_hangs > 0) or (checker["mode"] == "fail" and new_mtc > 0)
    if red:
        print(f"UI_QUALITY_GATE {name} red (hangs {new_hangs}, Main Thread Checker {new_mtc})", flush=True)
    return red


def video_to_log(video: str) -> None:
    """Artifact downloads are not reachable from every reviewer's machine, so a smaller copy
    of the video is also printed into the log (base64 chunks, like the screenshots)."""
    if not os.path.exists(video):
        print("UI_VIDEO missing (the plan was not applied in this run)")
        return
    print(f"UI_VIDEO {os.path.basename(video)}")
    small = video[:-4] + "-small.mp4"
    if sh(["avconvert", "--source", video, "--output", small, "--preset", "Preset1920x1080", "--replace"],
          timeout=300, quiet=True)[0] != 0:
        with open(video, "rb") as source, open(small, "wb") as target:
            target.write(source.read())
    size = os.path.getsize(small)
    print(f"UI_VIDEO_SIZE {size}")
    if size < 25_000_000:
        import base64
        data = base64.b64encode(open(small, "rb").read()).decode()
        for index in range(0, len(data), 60000):
            print(f"UI_VIDEO_B64 {index // 60000 + 1} {data[index:index + 60000]}")


def boot_retries(out: str) -> list[str]:
    """Failed boot attempts of this job: the background boot (boot --out) and any reset here."""
    found = []
    path = os.path.join(out, "boot-retries.json")
    try:
        with open(path, encoding="utf-8") as f:
            found = json.load(f)
        os.remove(path)  # counted once, by the first run of the job
    except (OSError, ValueError):
        pass
    return [str(x) for x in found if isinstance(x, str)] + BOOT_RETRIES


def write_flaky(args, record: dict) -> None:
    """build/flaky-NAME.json (collected by the UI summary job), FLAKY lines in the log and,
    when anything was repeated or the sweep left rows out, rows in the job summary. Nothing is
    repeated silently."""
    with open(os.path.join(args.out, f"flaky-{args.name}.json"), "w", encoding="utf-8") as f:
        json.dump(record, f, indent=1)
    lines = flaky_lines(record)
    for line in lines:
        print(line, flush=True)
    repeated = [f["test"] for f in record["flaky"] if f["first"] != INSIDE]
    inside = [f["test"] for f in record["flaky"] if f["first"] == INSIDE]
    if record["flaky"]:
        parts = ([f"{len(repeated)} test(s) passed only on the repeat: {', '.join(repeated)}"] if repeated else []) \
            + ([f"{len(inside)} retry(ies) inside a test: {', '.join(inside)}"] if inside else [])
        print(f"::warning title=UI {args.name} flaky::{'; '.join(parts)}", flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path and (lines or record.get("sweep_skips")):
        with open(path, "a", encoding="utf-8") as out:
            out.write("\n" + flaky_summary([record])[0])


def write_summary(name: str, passes) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    rows = []
    for label, status, verdict, reasons, text in passes:
        tests = finished_tests(text)
        counts = {s: sum(1 for v in tests.values() if v == s) for s in ("passed", "failed", "skipped")}
        rows.append(f"| {name} | {label} | {'✅' if status == 0 else '❌'} {verdict} | {counts['passed']} | "
                    f"{counts['failed']} | {counts['skipped']} | {'; '.join(reasons)} |")
    with open(path, "a", encoding="utf-8") as out:
        out.write("\n| Group | Pass | Result | Passed | Failed | Skipped | Why |\n|---|---|---|---|---|---|---|\n")
        out.write("\n".join(rows) + "\n")


# ---------------------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pick")
    p.add_argument("--device", choices=["pro", "se"], default="pro")
    b = sub.add_parser("boot")
    b.add_argument("--udid", required=True)
    b.add_argument("--reduce-motion", action="store_true")
    b.add_argument("--ready-file")
    b.add_argument("--out", default="build")
    f = sub.add_parser("flaky-summary")
    f.add_argument("records", nargs="*")
    r = sub.add_parser("run")
    r.add_argument("--udid", required=True)
    r.add_argument("--name", required=True)
    r.add_argument("--xctestrun")
    r.add_argument("--project", default="App/Albumist.xcodeproj")
    r.add_argument("--scheme", default="AlbumistUI")
    r.add_argument("--only", action="append", default=[])
    r.add_argument("--skip", action="append", default=[])
    r.add_argument("--reduce-motion", action="store_true")
    r.add_argument("--increase-contrast", action="store_true")
    r.add_argument("--video")
    r.add_argument("--a11y-summary", action="store_true")
    r.add_argument("--budget-min", type=float, default=0,
                   help="the group's time budget in minutes (.github/ui-groups.json); over it: a warning, not red")
    r.add_argument("--out", default="build")
    r.add_argument("--deadline", type=float, default=0,
                   help="epoch second by which a pass must end (the job's limit minus a margin); 0: none")
    w = sub.add_parser("settle")
    w.add_argument("--udid", required=True)
    w.add_argument("--limit", type=float, default=SETTLE_LIMIT)
    c = sub.add_parser("classify")
    c.add_argument("log")
    c.add_argument("--status", type=int, default=65)
    c.add_argument("--crash-report", action="append", default=[])
    c.add_argument("--bundle-json", help="output of `xcrun xcresulttool get test-results tests` for the pass")
    c.add_argument("--earlier", help="for a repeat: the log of the group's first pass")
    args = parser.parse_args(argv)
    # Space-separated lists are allowed too (matrix values in ui.yml).
    for key in ("only", "skip"):
        if hasattr(args, key):
            setattr(args, key, [t for value in getattr(args, key) for t in value.split()])

    if args.command == "pick":
        udid = pick(args.device)
        if not udid:
            print("no simulator found", file=sys.stderr)
            return 1
        print(udid)
        return 0
    if args.command == "boot":
        ok = boot(args.udid)
        if BOOT_RETRIES:
            os.makedirs(args.out, exist_ok=True)
            with open(os.path.join(args.out, "boot-retries.json"), "w", encoding="utf-8") as f:
                json.dump(BOOT_RETRIES, f)
        if ok:
            prepare(args.udid, reduce_motion=args.reduce_motion)
        else:
            print("simulator did not boot")
        if args.ready_file:
            with open(args.ready_file, "w") as ready:
                ready.write("ok\n" if ok else "failed\n")
        return 0 if ok else 1
    if args.command == "run" and args.xctestrun is not None and not os.path.isfile(args.xctestrun):
        print(f"::error::--xctestrun '{args.xctestrun}' is not a file (no .xctestrun in the build products?)")
        return 2
    if args.command == "flaky-summary":
        records = []
        for path in args.records:
            try:
                with open(path, encoding="utf-8") as f:
                    records.append(json.load(f))
            except (OSError, ValueError) as error:
                print(f"::warning title=UI summary::{path} not readable ({error})")
        markdown, lines = flaky_summary(records)
        for line in lines:
            print(line, file=sys.stderr)
        flaky = sum(len(r.get("flaky", [])) for r in records)
        retries = sum(len(r.get("retries", [])) for r in records)
        if flaky or retries:
            print(f"::notice title=UI flaky tests::{retries} repeat(s) after a simulator failure, "
                  f"{flaky} test(s) passed only on the repeat", file=sys.stderr)
        skipped = sum(len(r.get("sweep_skips", [])) for r in records)
        if skipped:
            print(f"::notice title=UI sweep::{skipped} row(s) not tapped by the tap-through sweep "
                  "(listed in the run summary)", file=sys.stderr)
        print(markdown)
        return 0
    if args.command == "settle":
        started = time.monotonic()
        settle(lambda: simulator_probe(args.udid), limit=args.limit, going_on="the next step starts anyway")
        timing("wait for the simulator", started)
        return 0
    if args.command == "classify":
        with open(args.log, encoding="utf-8", errors="replace") as log:
            text = log.read()
        bundle = []
        if args.bundle_json:
            with open(args.bundle_json, encoding="utf-8") as tests:
                bundle = parse_bundle(tests.read())
        earlier = ""
        if args.earlier:
            with open(args.earlier, encoding="utf-8", errors="replace") as first:
                earlier = first.read()
        verdict, reasons = decide(args.status, text, args.crash_report, bundle=bundle, earlier=earlier)
        print(f"{verdict}: {'; '.join(reasons)}")
        return 0
    return command_run(args)


if __name__ == "__main__":
    sys.exit(main())
