"""Checks over all workflow files (plain text; PyYAML where it is installed, as on the runners).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import glob
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
WORKFLOWS = sorted(glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


try:
    import yaml
except ImportError:  # PyYAML is on the hosted runners; without it the plain reading below is used
    yaml = None

# An input name that skips something, and a line of workflow code that skips or forces: an
# input read ("inputs.force", "inputs.skip_ui"), the word force or forced on its own (not the
# "--force" flag of git, codesign or simctl), or "untested".
SKIP_INPUT = re.compile(r"(?i)force|skip|bypass|untested|emergency|no[-_]?tests?")
SKIP_MARK = re.compile(r"(?i)inputs\.\w*(?:force|skip)|inputs\[['\"]\w*(?:force|skip)|(?:vars|env|secrets)\.\w*(?:force|skip)"
                       r"|\b(?:force|skip)_\w+|(?<![-\w])forced?\b|untested")


def strip_comment(line):
    """The line without its YAML comment: "#" at the start or after a space, outside quotes."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def workflow_inputs(text, plain=False):
    """Names of the workflow_dispatch and workflow_call inputs, in order. With PyYAML (and not
    plain) from the parsed file; otherwise by indentation: the keys right under "inputs:" of the
    top-level "on:"."""
    if yaml is not None and not plain:
        data = yaml.safe_load(text) or {}
        on = data.get("on", data.get(True))  # YAML 1.1 reads the key on as true
        names = []
        if isinstance(on, dict):
            for event in ("workflow_dispatch", "workflow_call"):
                spec = on.get(event)
                if isinstance(spec, dict) and isinstance(spec.get("inputs"), dict):
                    names += list(spec["inputs"])
        return names
    names, inside_on, inputs_at, child_at = [], False, None, None
    for raw in text.splitlines():
        line = strip_comment(raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            inside_on, inputs_at = line.startswith("on:"), None
            continue
        if not inside_on:
            continue
        if inputs_at is not None and indent <= inputs_at:
            inputs_at = None
        if line.strip() == "inputs:":
            inputs_at, child_at = indent, None
        elif inputs_at is not None:
            child_at = indent if child_at is None else child_at
            if indent == child_at:
                names.append(line.strip().split(":", 1)[0])
    return names


def job_blocks(text):
    """{job id: its lines without comments}, read by indentation from the top-level "jobs:"."""
    blocks, current = {}, None
    for raw in text.split("\njobs:\n", 1)[1].splitlines():
        line = strip_comment(raw).rstrip()
        found = re.match(r"^  ([A-Za-z0-9_-]+):$", line)
        if found:
            current = found.group(1)
            blocks[current] = []
        elif re.match(r"^\S", line):
            current = None  # another top-level key after the jobs
        elif current is not None:
            blocks[current].append(line)
    return {job: "\n".join(lines) for job, lines in blocks.items()}


def job_field(text, job, field):
    """A job's "if:" or "needs:" as one line (a list joined by ", ")."""
    if yaml is not None:
        value = (yaml.safe_load(text)["jobs"][job] or {}).get(field, "")
        value = ", ".join(value) if isinstance(value, list) else str(value)
    else:
        block = re.split(r"\n  [A-Za-z0-9_-]+:\n", text.split(f"\n  {job}:\n", 1)[1], maxsplit=1)[0]
        found = re.search(rf"\n    {field}: (?:>-\n)?(.*?)\n    [a-z-]+:", "\n" + block, re.S)
        value = found.group(1) if found else ""
    return " ".join(value.split())


class AptTests(unittest.TestCase):
    """19.11.2026: archive.ubuntu.com was unreachable, a bare apt-get waited 6-13 minutes and the
    core tests on main never ran. Every Ubuntu package goes through apt_install.sh (short
    timeouts, retries, a second mirror; see test_apt_install.py)."""

    def test_no_workflow_calls_apt_get_directly(self):
        found = 0
        for path in WORKFLOWS:
            text = "\n".join(strip_comment(line) for line in read(path).splitlines())
            with self.subTest(workflow=os.path.basename(path)):
                self.assertNotRegex(text, r"\bapt(?:-get)?\s+(?:update|install)\b")
            found += text.count(".github/scripts/apt_install.sh")
        self.assertGreaterEqual(found, 3)  # ci.yml, ui.yml, nightly.yml


class CacheTests(unittest.TestCase):
    """No Actions cache anywhere: the owner's rule (a Mac build cache only if it provably cannot ship
    stale code; none is used)."""

    def test_no_workflow_restores_a_cache(self):
        self.assertTrue(WORKFLOWS)
        for path in WORKFLOWS:
            text = "\n".join(line.split("#", 1)[0] for line in read(path).splitlines())
            with self.subTest(workflow=os.path.basename(path)):
                self.assertNotRegex(text, r"actions/cache(?:/restore|/save)?@")
                self.assertNotRegex(text, r"\n\s+cache(?:-dependency-path)?:\s*\S")

    def test_no_checkout_of_another_ref(self):
        # CodeQL actions/cache-poisoning (PR #1, PR #7): nightly.yml checked out another ref
        # (needs.pick.outputs.sha) in the default branch's context. Every workflow tests the
        # commit it runs on; a checkout with "ref:" needs a reason (and persist-credentials:
        # false) before this test is changed.
        for path in WORKFLOWS:
            for step in re.split(r"\n\s+- ", read(path)):
                if "actions/checkout@" in step:
                    with self.subTest(workflow=os.path.basename(path)):
                        self.assertNotRegex(step, r"\n\s+ref:")


APPLE_SECRETS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "APPLE_TEAM_ID")
APPLE_SECRET = re.compile(r"secrets\.(%s)\b" % "|".join(APPLE_SECRETS))


class UploadApprovalTests(unittest.TestCase):
    """The upload job runs in the environment testflight-upload, which only the branch main may
    use; the four App Store Connect secrets are environment secrets there; nothing else can read
    them. Since the owner's decision of 19.11.2026 (it replaced decision 5 of 18.11.) the upload
    runs without a click once every gate is green."""

    def test_the_upload_job_runs_in_the_protected_environment(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import upload_approval
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        release = job_blocks(text)["release"]
        self.assertEqual(upload_approval.ENVIRONMENT, "testflight-upload")
        self.assertIn(f"\n    environment: {upload_approval.ENVIRONMENT}\n", release + "\n")
        if yaml is not None:
            self.assertEqual(yaml.safe_load(text)["jobs"]["release"]["environment"], upload_approval.ENVIRONMENT)
        # No other job of any workflow names this environment: no second door to its secrets
        # (pages.yml has its own, github-pages).
        for path in WORKFLOWS:
            for job, block in job_blocks(read(path)).items():
                if (os.path.basename(path), job) != ("testflight.yml", "release"):
                    with self.subTest(workflow=os.path.basename(path), job=job):
                        self.assertNotIn(upload_approval.ENVIRONMENT, block)

    def test_the_apple_secrets_are_named_only_in_the_upload_job(self):
        users = []
        for path in WORKFLOWS:
            text = read(path)
            name = os.path.basename(path)
            code = "\n".join(strip_comment(line) for line in text.splitlines())
            with self.subTest(workflow=name):
                # Not around the jobs (a workflow-level env reaches every job), never all secrets
                # at once (passed on to a called workflow, or as JSON), never by a computed name.
                self.assertNotRegex(code.split("\njobs:\n", 1)[0], APPLE_SECRET)
                self.assertNotRegex(code, r"secrets:\s*inherit|toJSON\(\s*secrets\s*\)|secrets\[")
            blocks = job_blocks(text)
            if yaml is not None:
                self.assertEqual(sorted(blocks), sorted(yaml.safe_load(text)["jobs"]), name)
            users += [(name, job, sorted(set(APPLE_SECRET.findall(block)))) for job, block in blocks.items()
                      if APPLE_SECRET.search(block)]
        self.assertEqual(users, [("testflight.yml", "release", sorted(APPLE_SECRETS))])
        # The jobs before the upload need none: the first one checks the environment instead.
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertIn("run: python3 .github/scripts/upload_approval.py check", job_blocks(text)["check"])

    def test_the_first_job_is_the_setup_check_the_daily_build_reads(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import daily_build
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        check = job_blocks(text)["check"]
        self.assertIn(f"\n    name: {daily_build.CHECK_JOB}\n", "\n" + check + "\n")
        self.assertIn("\n    if: github.ref == 'refs/heads/main'\n", "\n" + check + "\n")
        self.assertIn("ready: ${{ steps.setup.outputs.ready }}", check)
        self.assertIn("\n      - name: Upload setup checked\n        id: setup\n", "\n" + check)
        # A private repository needs the owner's word that his plan has environments there
        # (upload_approval.PLAN_VARIABLE); the daily build reads the same variable.
        variable = "UPLOAD_PRIVATE_PLAN_OK: ${{ vars.UPLOAD_PRIVATE_PLAN_OK }}"
        self.assertIn(variable, check.split("- name: Upload setup checked", 1)[1].split("\n      - ", 1)[0])
        daily = read(os.path.join(ROOT, ".github", "workflows", "daily-build.yml"))
        self.assertIn(variable, daily.split("run: python3 .github/scripts/daily_build.py decide", 1)[0].rsplit("\n      - ", 1)[1])
        # Runs of before 19.11. named the job "Upload approval"; the daily build reads both.
        self.assertEqual(daily_build.CHECK_JOBS, (daily_build.CHECK_JOB, "Upload approval"))
        # The secrets' presence is checked first in the upload job, without their values in a step.
        release = job_blocks(text)["release"]
        first = release.split("\n      - ", 2)[1]
        self.assertTrue(first.startswith("name: App Store Connect secrets present"), first[:60])
        self.assertNotRegex(first, r"\$\{\{\s*secrets\.\w+\s*\}\}")
        # "Re-run all jobs" on a run that uploaded stops in its first job, and a re-run of the
        # upload job alone stops at its start, before the archive (upload_approval.py
        # not-uploaded; the tag build-<run number> exists).
        step = "\n      - name: Not uploaded by this run yet\n"
        for job, before in (("check", "- name: Choose the gate"), ("release", "- name: Earlier attempts of this run")):
            with self.subTest(job=job):
                block = job_blocks(text)[job]
                self.assertIn(step, "\n" + block)
                own = block.split(step.strip("\n"), 1)[1].split("\n      - ", 1)[0]
                self.assertIn("run: python3 .github/scripts/upload_approval.py not-uploaded", own)
                self.assertIn("GH_TOKEN: ${{ github.token }}", own)
                self.assertLess(block.index(step.strip("\n")), block.index(before))
        import earlier_attempts
        self.assertIn("Not uploaded by this run yet", earlier_attempts.MACHINERY_STEPS)
        # "Was testen" is set in the upload job now: no other job sets it with the key.
        self.assertEqual([job for job, block in job_blocks(text).items() if "testflight_notes.py upload" in block],
                         ["release"])


class FreshSimulatorTests(unittest.TestCase):
    """ci.yml's "Fresh simulator" waits like a UI pass: until the simulator answers quickly
    (ui_tests.py settle). Its old criterion, a 1-minute load under 3.5, never held on the hosted
    Macs (200-850 after the boot), so the step always waited its whole 5 min."""

    def step(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))
        return text.split("- name: Fresh simulator (erased and booted)\n", 1)[1].split("\n      - name: ", 1)[0]

    def test_it_waits_for_a_quick_simulator_not_for_the_load(self):
        step = self.step().split("        run: |\n", 1)[1]
        self.assertIn('python3 .github/scripts/ui_tests.py settle --udid "$UDID"', step)
        self.assertNotIn("3.5", step)
        self.assertNotIn("vm.loadavg", step)
        # The StoreKit log starts after the wait, as before.
        self.assertLess(step.index("ui_tests.py settle"), step.index("> storekit-live.log"))
        self.assertLess(step.index("bootstatus"), step.index("ui_tests.py settle"))


class TestFlightWiringTests(unittest.TestCase):
    """The upload waits for the UI gate (ui_evidence.py), which reads the group jobs' names."""

    def test_no_upload_starts_by_itself(self):
        # Fable P5-15: the old testflight.yml on main uploaded the old app state, untested, on
        # every push to main (16.11.: the website merge started one). TestFlight starts by
        # workflow_dispatch only, and no workflow that can read an App Store Connect key (named,
        # or all secrets passed on with "secrets: inherit") starts on a push or a pull request. A
        # schedule may read one (asc-feedback.yml fetches feedback with its own key; it uploads
        # nothing). The one workflow that starts TestFlight by itself is the daily build
        # (decision 10 of 18.11.2026): with the small gate, on main, and its upload still waits
        # for the owner's approval (UploadApprovalTests).
        starters = {}
        for path in WORKFLOWS:
            code = "\n".join(strip_comment(line) for line in read(path).splitlines())
            if re.search(r"testflight\.yml(?:/dispatches)?\b", code) and re.search(r"workflow run|/dispatches", code):
                starters[os.path.basename(path)] = code
        self.assertEqual(sorted(starters), ["daily-build.yml"])
        daily = starters["daily-build.yml"]
        self.assertIn("gh workflow run testflight.yml --repo \"$GITHUB_REPOSITORY\" --ref main -f gate=small\n", daily)
        self.assertEqual(len(re.findall(r"workflow run", daily)), 1)
        self.assertIn("if: github.ref == 'refs/heads/main'", daily)
        self.assertNotRegex(daily, r"secrets[.\[]|secrets:\s*inherit")
        trigger = read(os.path.join(ROOT, ".github", "workflows", "daily-build.yml")).split("\non:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", trigger, re.M), ["schedule", "workflow_dispatch"])
        for path in WORKFLOWS:
            text = read(path)
            if "secrets.ASC_" not in text and not re.search(r"secrets:\s*inherit", text):
                continue
            trigger = text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
            events = re.findall(r"^  ([a-z_]+):", trigger, re.M)
            with self.subTest(workflow=os.path.basename(path)):
                if os.path.basename(path) == "testflight.yml":
                    self.assertEqual(events, ["workflow_dispatch"])
                else:
                    self.assertNotIn("push", events)
                    self.assertNotIn("pull_request", events)
                    self.assertNotIn("pull_request_target", events)

    def test_upload_needs_the_ui_gate(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertIn("python3 .github/scripts/ui_evidence.py gate", text)
        release = text.split("\n  release:\n", 1)[1].split("\n  tag:\n", 1)[0]
        self.assertIn("needs: [check, tests, ui, stress, release-smoke, ui-gate, tsan]", release)
        self.assertIn("needs.ui-gate.result == 'success'", release)

    def test_upload_needs_the_thread_sanitizer(self):
        # Owner's decision 16.11.2026: Thread Sanitizer before every upload (the core on Linux).
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        tsan = text.split("\n  tsan:\n", 1)[1].split("\n\n  ", 1)[0]
        self.assertIn("uses: ./.github/workflows/sanitize.yml", tsan)
        release = text.split("\n  release:\n", 1)[1].split("\n  tag:\n", 1)[0]
        self.assertIn("needs.tsan.result == 'success'", release)
        sanitize = read(os.path.join(ROOT, ".github", "workflows", "sanitize.yml"))
        self.assertNotIn("pull_request", sanitize)
        self.assertNotIn("push:", sanitize)
        self.assertIn("swift test --sanitize=thread", sanitize)
        self.assertIn("-enableThreadSanitizer YES", sanitize)
        nightly = read(os.path.join(ROOT, ".github", "workflows", "nightly.yml"))
        self.assertIn("uses: ./.github/workflows/sanitize.yml", nightly)

    def test_nothing_skips_the_tests_before_an_upload(self):
        # G5-02/G6-02: the owner decided on 17.11. to remove the emergency input "force", which
        # uploaded a TestFlight build without running any test. No workflow has an input or a
        # flag to skip tests or the gate, and every job before the upload runs on the results of
        # the one before it alone.
        for path in WORKFLOWS:
            text = read(path)
            code = "\n".join(strip_comment(line) for line in text.splitlines())
            with self.subTest(workflow=os.path.basename(path)):
                self.assertEqual([name for name in workflow_inputs(text) if SKIP_INPUT.search(name)], [])
                self.assertEqual([line.strip() for line in code.splitlines() if SKIP_MARK.search(line)], [])
        # Scripts: no flag that lets a run through without tests ("--forced" in earlier_attempts.py
        # and testflight_notes.py). ui_tests.py --skip names single tests that another group runs
        # (ui-groups.json); the UI gate needs every group green, or with --groups the groups of the
        # small gate (the daily build, decision 10 of 18.11.2026; checked below).
        for path in glob.glob(os.path.join(ROOT, ".github", "scripts", "*.py")):
            with self.subTest(script=os.path.basename(path)):
                flags = re.findall(r"add_argument\(\s*[\"']--([\w-]+)[\"']", read(path))
                self.assertEqual([f for f in flags if re.search(r"(?i)force|untested|skip[-_]?(?:tests?|gate)|no[-_]?tests?", f)], [])
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertEqual(job_field(text, "tests", "if"), "needs.check.outputs.ready == 'true'")
        for job in ("ui", "stress"):
            self.assertIn("tests", [need.strip() for need in job_field(text, job, "needs").split(",")])
        # The two gates (the owner's decision 10 of 18.11.2026) differ only in the UI groups: the
        # stress pass runs before every upload, also before the daily build with the small gate
        # (the owner's rule of 17.11. and decision 4), so it has no condition of its own and the
        # UI gate and the upload need it green with either gate. The check job turns the input
        # into big or small and stops on anything else.
        self.assertEqual(job_field(text, "stress", "if"), "")
        stress = job_blocks(text)["stress"]
        self.assertNotIn("gate", stress)  # the same small pass with either gate
        self.assertIn("photos: '10000'", stress)
        self.assertIn("minutes: '15'", stress)
        for job, needed in (("ui-gate", ("tests", "ui", "stress")), ("release", ("tests", "ui", "stress", "release-smoke", "ui-gate"))):
            with self.subTest(job=job):
                rule = job_field(text, job, "if")
                self.assertNotIn("||", rule)
                self.assertNotIn("inputs.", rule)
                self.assertNotIn("gate", rule.replace("needs.ui-gate.result", ""))
                self.assertIn("needs.check.outputs.ready == 'true'", rule)
                for need in needed:
                    self.assertIn(f"needs.{need}.result == 'success'", rule)
        check = job_blocks(text)["check"]
        self.assertIn("GATE: ${{ inputs.gate || 'big' }}", check)
        self.assertIn("big) groups=\"$UI_GROUPS\"; checked=\"\" ;;", check)
        self.assertIn("small) groups=\"$SMALL_GATE_GROUPS\"; checked=\"$SMALL_GATE_GROUPS\" ;;", check)
        self.assertIn("*) echo \"::error title=Gate::unknown gate $GATE (big or small)\"; exit 1 ;;", check)

    def test_the_small_gate_is_the_two_short_ui_groups(self):
        # docs/TESTFLIGHT.md ("Messung", "Zwei Tore"): flow-full and contrast, about 18 min each.
        # The gate checks exactly the groups the UI flow ran.
        import json
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        small = re.search(r"\n          SMALL_GATE_GROUPS: (.+)\n", text).group(1).split()
        self.assertEqual(small, ["flow-full", "contrast"])
        with open(os.path.join(ROOT, ".github", "ui-groups.json"), encoding="utf-8") as f:
            names = [g["group"] for g in json.load(f)["groups"]]
        self.assertLess(set(small), set(names))
        jobs = job_blocks(text)
        self.assertIn("groups: ${{ needs.check.outputs.ui_groups }}", jobs["ui"])
        self.assertIn("GATE_GROUPS: ${{ needs.check.outputs.gate_groups }}", jobs["ui-gate"])
        self.assertIn('python3 .github/scripts/ui_evidence.py gate --groups "$GATE_GROUPS"', jobs["ui-gate"])

    def test_the_skip_check_finds_force_and_nothing_else(self):
        # Second review of 51e72f3: harmless "--force" flags of other tools are no skip, a
        # re-added input is found by both ways of reading the inputs, "#" in quotes is no comment.
        for harmless in ("git push --force-with-lease origin HEAD", "codesign --force --sign - App.app",
                         "xcrun simctl io booted recordVideo --force out.mp4"):
            self.assertIsNone(SKIP_MARK.search(harmless), harmless)
        for skip in ("if: inputs.force", "if: ${{ !inputs.skip_ui }}", "FORCED: yes", "echo untested", "      force:",
                     "if: vars.FORCE_UPLOAD == 'true'", "if: env.SKIP_TESTS != '1'", "${{ inputs['skip_ui'] }}",
                     "run: SKIP_TESTS=1 make"):
            self.assertIsNotNone(SKIP_MARK.search(skip), skip)
        sample = ("name: X\n\non:\n  workflow_dispatch:\n\n    inputs:\n      # an emergency switch\n\n      force:\n"
                  "        type: boolean\n      ui_groups:\n        type: string\n  workflow_call:\n    inputs:\n"
                  "      skip_gate: {type: boolean}\n\njobs:\n  a:\n    runs-on: x\n")
        self.assertEqual(workflow_inputs(sample), ["force", "ui_groups", "skip_gate"])
        self.assertEqual(workflow_inputs(sample, plain=True), ["force", "ui_groups", "skip_gate"])
        for path in WORKFLOWS:
            with self.subTest(workflow=os.path.basename(path)):
                self.assertEqual(workflow_inputs(read(path), plain=True), workflow_inputs(read(path)))
        self.assertEqual(strip_comment('run: echo "a # b" \'c # d\' # note'), 'run: echo "a # b" \'c # d\' ')
        self.assertEqual(strip_comment("url: https://x.example/#anchor"), "url: https://x.example/#anchor")

    def test_ui_flow_plans_its_groups(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        self.assertIn("python3 .github/scripts/ui_evidence.py plan", text)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}", text)
        self.assertIn("- name: Plan the UI groups", text)

    def test_ui_flow_ends_in_a_verdict_and_quick_never_uploads(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        verdict = text.split("\n  verdict:\n", 1)[1].split("\n  summary:\n", 1)[0]
        quick = "(!inputs.release && (github.event_name == 'pull_request' || inputs.quick))"
        # ci_gate.py looks for this name; the gate runs also when no group ran.
        self.assertIn(f"name: UI verdict (${{{{ {quick} && 'quick' || 'full' }}}})", verdict)
        self.assertIn("if: ${{ !cancelled() && needs.plan.result == 'success' && !inputs.release }}", verdict)
        self.assertIn("python3 .github/scripts/ui_evidence.py gate ${UI_QUICK:+--quick}", verdict)
        self.assertIn(f"UI_QUICK: ${{{{ {quick} && 'true' || '' }}}}", text)
        self.assertIn("plan --groups \"$UI_GROUPS\" ${UI_QUICK:+--quick}", text)
        self.assertIn("TEST_RUNNER_ALBUMIST_UI_QUICK: ${{ matrix.quick && '1' || '' }}", text)
        testflight = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        # Full, never --quick; the stress pass of 10,000 photos too (decision 20.11.2026, 17:20).
        self.assertIn("python3 .github/scripts/ui_evidence.py gate --stress 10000-15\n", testflight)
        self.assertIn('python3 .github/scripts/ui_evidence.py gate --groups "$GATE_GROUPS" --stress 10000-15\n', testflight)
        self.assertIn("      release: true\n      quick: false\n", testflight)

    def test_pull_request_runs_name_their_merge_commit(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import ui_evidence
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        self.assertIn("format('[merge {0}] {1}', github.sha, github.event.pull_request.title)", text)
        run = {"event": "pull_request", "display_title": "[merge " + "a" * 40 + "] Some PR", "head_sha": "b" * 40}
        self.assertEqual(ui_evidence.tested_sha(run), "a" * 40)

    def test_the_pass_deadline_and_the_evidence_follow_the_job_limit(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import ui_evidence
        text = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        group = text.split("\n  ui:\n", 1)[1].split("\n  verdict:\n", 1)[0]
        limit = int(re.search(r"\n    timeout-minutes: (\d+)\n", group).group(1))
        self.assertEqual(limit, ui_evidence.GROUP_TIMEOUT_MINUTES)
        self.assertIn(f'--deadline "$((UI_JOB_START + ({limit} - 12) * 60))"', group)
        self.assertLess(group.index("UI_JOB_START=$(date +%s)"), group.index("- name: Run UI tests"))

    def test_ui_flow_checkouts_keep_no_token(self):
        for step in re.split(r"\n\s+- ", read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))):
            if "actions/checkout@" in step:
                with self.subTest(step=step[:80]):
                    self.assertIn("persist-credentials: false", step)

    def test_machinery_steps_exist(self):
        import sys
        sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
        import earlier_attempts
        names = set()
        for path in WORKFLOWS:
            names |= set(re.findall(r"\n\s+(?:- )?name: (.+)", read(path)))
        for step in earlier_attempts.MACHINERY_STEPS - {"Set up job", "Initialize containers", "Stop containers",
                                                         "Complete job"}:
            with self.subTest(step=step):
                self.assertIn(step, names)


def job_steps(text, job):
    """[(name, if, run)] of a job's steps, read by indentation (comments left out). A folded
    "if: >-" is joined into one line."""
    steps = []
    for chunk in re.split(r"\n      - ", "\n" + job_blocks(text)[job])[1:]:
        lines = chunk.splitlines()
        fields, i = {}, 0
        keyed = [(lines[0], 0)] + [(line[8:], n) for n, line in enumerate(lines[1:], 1)
                                   if line.startswith("        ") and not line.startswith("         ")]
        for line, n in keyed:
            found = re.match(r"([a-z-]+):(?: (.*))?$", line)
            if not found or found.group(1) in fields:
                continue
            value = (found.group(2) or "").strip()
            if value in (">-", ">", "|"):
                more = []
                for later in lines[n + 1:]:
                    if not later.strip():
                        continue  # an empty line, or a comment line of the script (left out)
                    if not later.startswith("          "):
                        break
                    more.append(later.strip())
                value = (" " if value.startswith(">") else "\n").join(more)
            fields[found.group(1)] = value
        steps.append((fields.get("name", ""), " ".join(fields.get("if", "").split()), fields.get("run", "")))
    return steps


class CompileFirstTests(unittest.TestCase):
    """Tempo plan 20.11.: CI's Mac job compiles the app, its unit tests and the UI tests before
    the macOS core tests and the fresh simulator, so a compile error only the Mac finds is red
    within minutes (61e9b8c was red after 27 min). Every step stays."""

    def test_the_mac_job_builds_before_it_tests(self):
        ci = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))
        steps = job_steps(ci, "ios")
        names = [name for name, _, _ in steps]
        for name in ("Build app and its tests", "Build UI tests", "Core tests (macOS)",
                     "Fresh simulator (erased and booted)", "Build and test app", "Export strings for translation"):
            self.assertIn(name, names)
        order = [names.index(n) for n in ("Pick simulator", "Build app and its tests", "Build UI tests",
                                          "Core tests (macOS)", "Fresh simulator (erased and booted)", "Build and test app")]
        self.assertEqual(order, sorted(order))
        runs = {name: run for name, _, run in steps}
        first = runs["Build app and its tests"]
        self.assertRegex(first, r"xcodebuild build-for-testing\b")
        self.assertIn("-scheme Albumist\n", first.replace(" \\", ""))
        # The same build settings as the test step, so that one compiles nothing again.
        test = runs["Build and test app"]
        for setting in ("COMPILER_INDEX_STORE_ENABLE=NO", "CODE_SIGNING_ALLOWED=NO"):
            self.assertIn(setting, first)
            self.assertIn(setting, test)
            self.assertIn(setting, runs["Build UI tests"])
        # A failed build is red: no "|| true" after the build, and it is no machinery step.
        self.assertIn("exit 1", first)
        self.assertIn("tail -30 ../build-log.txt", first)
        # Second review of ci/tempo (S3): only the app build's failure stops the core tests and
        # the app tests, a failed "Build UI tests" does not.
        rules = {name: rule for name, rule, _ in steps}
        for name in ("Core tests (macOS)", "Fresh simulator (erased and booted)", "Build and test app"):
            with self.subTest(step=name):
                self.assertIn("!cancelled()", rules[name])
                self.assertIn("steps.appbuild.outcome == 'success'", rules[name])
        self.assertIn("id: appbuild", ci)
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "earlier_attempts", os.path.join(ROOT, ".github", "scripts", "earlier_attempts.py"))
        earlier_attempts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(earlier_attempts)
        self.assertFalse(earlier_attempts.is_machinery("Build app and its tests"))
        self.assertFalse(earlier_attempts.is_machinery("Build UI tests"))


class KnownRedTests(unittest.TestCase):
    """Tempo plan 20.11.: a group already red for this app and test code shows as a red check at
    minute one (ui.yml "UI known red"), the groups still run and the verdict decides as before."""

    def test_the_known_red_job(self):
        ui = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        jobs = job_blocks(ui)
        self.assertIn("known-red", jobs)
        self.assertEqual(job_field(ui, "known-red", "needs").strip(), "plan")
        rule = job_field(ui, "known-red", "if")
        self.assertIn("needs.plan.outputs.known_red != ''", rule)
        self.assertIn("!inputs.release", rule)
        self.assertIn("known_red: ${{ steps.plan.outputs.known_red }}", jobs["plan"])
        steps = job_steps(ui, "known-red")
        self.assertEqual(len(steps), 1)
        self.assertTrue(steps[0][2].rstrip().endswith("exit 1"), "the job fails")
        # Nothing else waits for it: the groups and the verdict run as before.
        for job in ("build", "ui", "verdict", "summary"):
            with self.subTest(job=job):
                self.assertNotIn("known-red", job_field(ui, job, "needs"))
        # Its red is a verdict, not machinery: "Re-run failed jobs" does not hide it.
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "earlier_attempts", os.path.join(ROOT, ".github", "scripts", "earlier_attempts.py"))
        earlier_attempts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(earlier_attempts)
        self.assertFalse(earlier_attempts.is_machinery(steps[0][0]))


class FullPassBeforeMergeTests(unittest.TestCase):
    """The owner's decision of 20.11.2026, 17:12: the full UI pass runs once before the merge, its
    verdict checks that the merge brings exactly the tested content, and TestFlight takes its
    greens by content (ui_evidence.py) instead of running the groups again."""

    def test_the_full_verdict_checks_the_merge_content(self):
        ui = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        steps = job_steps(ui, "verdict")
        rules = {name: rule for name, rule, _ in steps}
        runs = {name: run for name, _, run in steps}
        merge = "Merge content same as this commit"
        self.assertIn(merge, rules)
        self.assertIn("python3 .github/scripts/ui_evidence.py merge-content --base origin/main", runs[merge])
        for part in ("github.event_name == 'workflow_dispatch'", "!inputs.quick", "github.ref != 'refs/heads/main'"):
            self.assertIn(part, rules[merge])
        # The gate itself is unchanged: full unless quick.
        self.assertIn("python3 .github/scripts/ui_evidence.py gate ${UI_QUICK:+--quick}",
                      runs["UI groups green for this app and test code"])
        # The checkout has main's history (merge-tree needs origin/main).
        self.assertIn("fetch-depth: 0", job_blocks(ui)["verdict"])

    def test_testflight_still_runs_and_gates_every_group(self):
        tf = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        jobs = job_blocks(tf)
        # Groups "auto": only those without a full green for this content run; the gate checks
        # every group of the big gate, full (no --quick anywhere in the TestFlight run).
        self.assertIn("default: auto", tf)
        self.assertIn('python3 .github/scripts/ui_evidence.py gate --groups "$GATE_GROUPS"', jobs["ui-gate"])
        self.assertNotIn("--quick", tf)
        self.assertIn("stress", jobs)
        self.assertIn("release-smoke", jobs)


class HangLimitTests(unittest.TestCase):
    """20.11.2026: the core tests hung 30 min until the job's limit; every swift test step now runs
    under swift_test_watch.py, which names the tests still running before the step's limit."""

    def test_every_core_test_step_is_watched(self):
        ci = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))
        ui = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        watched = 0
        for text, job in ((ci, "core-linux"), (ci, "ios"), (ui, "core-linux")):
            for name, _, run in job_steps(text, job):
                if "swift test" not in run:
                    continue
                with self.subTest(job=job, step=name):
                    self.assertIn("python3 .github/scripts/swift_test_watch.py --minutes", run)
                    minutes = float(re.search(r"--minutes (\d+(?:\.\d+)?)", run).group(1))
                    block = "\n" + text.split(f"- name: {name}\n", 1)[1].split("\n      - ", 1)[0]
                    limit = re.search(r"\n        timeout-minutes: (\d+)", block)
                    self.assertIsNotNone(limit, "the step has its own timeout-minutes")
                    # The watchdog reports (and gives the backtrace a minute) before GitHub kills.
                    self.assertLessEqual(minutes + 2, int(limit.group(1)))
                    watched += 1
        self.assertEqual(watched, 4)
        # The Linux container installs python3 for it.
        for text in (ci, ui):
            self.assertIn("apt_install.sh libsqlite3-dev python3", text)


class StressBeforeMergeTests(unittest.TestCase):
    """The owner's decision of 20.11.2026, 17:20: the stress pass runs once before the merge, and
    TestFlight takes its green by content; without one it runs there as before."""

    def test_the_stress_workflow_plans_names_and_judges_its_pass(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "ui-stress.yml"))
        jobs = job_blocks(text)
        self.assertEqual(list(jobs)[:3], ["plan", "stress", "verdict"])
        plan = {n: r for n, _, r in job_steps(text, "plan")}["Key of this pass and whether it runs"]
        self.assertIn('ui_evidence.py stress-plan --photos "$STRESS_PHOTOS" --minutes "$STRESS_MINUTES" ${REUSE:+--reuse}', plan)
        # The weekly pass never reuses.
        self.assertIn("REUSE: ${{ github.event_name != 'schedule' && 'yes' || '' }}", jobs["plan"])
        self.assertIn("fetch-depth: 0", jobs["plan"])
        # The key in the job's name, where the gate and later plans find it.
        self.assertIn("[${{ needs.plan.outputs.group }} app ${{ needs.plan.outputs.app }} tests ${{ needs.plan.outputs.tests }}]",
                      jobs["stress"])
        self.assertEqual(job_field(text, "stress", "if").strip(), "${{ needs.plan.outputs.run == 'true' }}")
        verdict = {n: r for n, _, r in job_steps(text, "verdict")}["Stress pass green for this app and test code"]
        self.assertIn('ui_evidence.py gate --stress "${STRESS_PHOTOS}-${STRESS_MINUTES}" --stress-only', verdict)
        self.assertIn("!inputs.release", job_field(text, "verdict", "if"))
        self.assertIn("name: UI stress verdict", jobs["verdict"])

    def test_testflight_checks_the_stress_pass_by_content(self):
        tf = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        jobs = job_blocks(tf)
        gate = "\n".join(r for _, _, r in job_steps(tf, "ui-gate"))
        self.assertEqual(gate.count("--stress 10000-15"), 2)
        # Still called in every run with the small pass; the upload still needs it green
        # (a pass skipped for a green one by content leaves the called workflow green).
        self.assertIn("photos: '10000'", jobs["stress"])
        # The called workflow's plan reads earlier runs: the caller grants it.
        self.assertIn("actions: read", jobs["stress"])
        self.assertIn("checks: read", jobs["stress"])
        self.assertIn("minutes: '15'", jobs["stress"])
        self.assertIn("needs.stress.result == 'success'", job_field(tf, "release", "if"))
        self.assertIn("needs.release-smoke.result == 'success'", job_field(tf, "release", "if"))


class EnvironmentRetryTests(unittest.TestCase):
    """Rule 17.11.: an environment retry is counted and fixed at its cause, never hidden. The
    retries that exist are narrow (exact signatures, ui_tests.py INFRA; a boot that did not come
    up; an apt mirror) and each one shows in the check's annotations, not only in the log."""

    def test_the_ci_boot_retry_is_an_annotation(self):
        ci = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))
        step = ci.split("- name: Fresh simulator (erased and booted)\n", 1)[1].split("\n      - name: ", 1)[0]
        self.assertIn("for attempt in 1 2 3; do", step)
        self.assertIn("::warning title=Environment retry (simulator boot)::", step)
        self.assertIn('[ "$attempt" = 3 ] && { echo "simulator did not boot (3 attempts)"; exit 1; }', step)


class ReleaseSkipTests(unittest.TestCase):
    """In a TestFlight run (release) CI's Mac job leaves out a step only when ui.yml, called in
    the same run right after it, builds the same thing itself (coordinator's rule for C4: no
    step whose product nobody else makes is dropped)."""

    def test_a_step_left_out_in_release_is_built_by_the_ui_flow(self):
        ci = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))
        ui = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        build = "\n".join(run for _, _, run in job_steps(ui, "build"))
        left_out = [(name, run) for name, rule, run in job_steps(ci, "ios") if "!inputs.release" in rule.replace(" ", "")]
        self.assertEqual([name for name, _ in left_out], ["Build UI tests"])
        for name, run in left_out:
            with self.subTest(step=name):
                actions = re.findall(r"xcodebuild\s+(?:\\\s*)?([a-z-]+)", run)
                schemes = re.findall(r"-scheme\s+(\S+)", run)
                self.assertTrue(actions and schemes, "the step builds something with xcodebuild")
                for action in actions:
                    self.assertRegex(build, rf"xcodebuild\s+(?:\\\s*)?{action}\b")
                for scheme in schemes:
                    self.assertRegex(build, rf"-scheme\s+{re.escape(scheme)}\b")
        # ui.yml's build runs in release mode (Linux core tests skipped there) and the TestFlight
        # run calls the UI flow after CI.
        self.assertIn("(inputs.release && needs.core-linux.result == 'skipped')", job_field(ui, "build", "if"))
        tf = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        self.assertIn("tests", [need.strip() for need in job_field(tf, "ui", "needs").split(",")])
        self.assertIn("release: true", job_blocks(tf)["ui"])

    def test_the_step_reader(self):
        text = ("on: push\njobs:\n  a:\n    steps:\n      - name: One\n        if: x && !inputs.release\n        run: |\n"
                "          xcodebuild build-for-testing -scheme S\n      - uses: actions/checkout@v1\n      - name: Two\n"
                "        run: echo\n")
        self.assertEqual([(n, r) for n, r, _ in job_steps(text, "a")], [("One", "x && !inputs.release"), ("", ""), ("Two", "")])
        # A comment line inside a script does not end it.
        text = "on: push\njobs:\n  a:\n    steps:\n      - name: One\n        run: |\n          a\n          # note\n          b\n"
        self.assertEqual(job_steps(text, "a")[0][2], "a\nb")


class ReleaseSmokeTests(unittest.TestCase):
    """Review P5-03: every UI test ran a Debug build with -AlbumistUITest switches, and the Release
    build that is uploaded was never started before the upload (the archive and the manual
    Appetize job were the only Release builds). One UI test now runs on a Release build in every
    TestFlight run, beside the UI flow and the stress pass, and the upload needs it green."""

    def test_the_uploaded_configuration_is_ui_tested_first(self):
        text = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        jobs = job_blocks(text)
        self.assertIn("release-smoke", jobs)
        smoke = jobs["release-smoke"]
        steps = {name: run for name, _, run in job_steps(text, "release-smoke")}
        build = steps["Build for testing (Release)"]
        self.assertRegex(build, r"xcodebuild build-for-testing\b")
        self.assertIn("-scheme AlbumistUI", build)
        self.assertIn("-configuration Release", build)
        self.assertIn("Release-iphonesimulator/Albumist.app", build)
        run = steps["Run UI tests"]
        self.assertIn("--only ReleaseSmokeUITests", run)
        self.assertIn("TEST_RUNNER_ALBUMIST_RELEASE_SMOKE: '1'", smoke)
        # A skipped test is no pass (the test skips itself without the variable).
        self.assertIn("Test Case '-[AlbumistUITests.ReleaseSmokeUITests test1_ReleaseBuildOnboardsAnalysesAndApplies]' passed", run)
        # Beside the UI flow and the stress pass, not after them: it needs the tests only.
        self.assertEqual([n.strip() for n in job_field(text, "release-smoke", "needs").split(",")], ["tests"])
        self.assertEqual(job_field(text, "release-smoke", "if"), "")
        # The upload needs it green, with either gate.
        self.assertIn("release-smoke", [n.strip() for n in job_field(text, "release", "needs").split(",")])
        self.assertIn("needs.release-smoke.result == 'success'", job_field(text, "release", "if"))
        # Its repeats and flaky tests are counted with the others (flaky_history.RECORD).
        self.assertIn("name: ui-flaky-release-smoke-attempt-${{ github.run_attempt }}", smoke)
        self.assertIn("release-smoke", [n.strip() for n in job_field(text, "flaky", "needs").split(",")])

    def test_a_testflight_run_never_needs_more_than_five_macs(self):
        # Second review of C7: the account runs five Macs at once. After CI (its Mac job ends
        # before anything else starts), a TestFlight run has the UI groups (max-parallel in
        # release mode), the stress pass and the smoke test at the same time; the UI build job runs
        # before the groups.
        ui = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        found = re.search(r"\n      max-parallel: \$\{\{ inputs\.release && (\d) \|\| (\d) \}\}\n", ui)
        self.assertIsNotNone(found, "ui.yml: max-parallel ${{ inputs.release && N || 5 }}")
        in_release, otherwise = int(found.group(1)), int(found.group(2))
        # Outside TestFlight five groups (tempo plan 20.11.; beside CI's Mac job GitHub queues one).
        self.assertEqual(otherwise, 5)
        tf = read(os.path.join(ROOT, ".github", "workflows", "testflight.yml"))
        beside = [job for job in ("stress", "release-smoke")
                  if [n.strip() for n in job_field(tf, job, "needs").split(",")] == ["tests"]]
        self.assertEqual(beside, ["stress", "release-smoke"])
        self.assertLessEqual(in_release + len(beside), 5)

    def test_the_smoke_test_runs_only_there_and_as_a_user_would(self):
        path = os.path.join(ROOT, "App", "AlbumistUITests", "ReleaseSmokeUITests.swift")
        swift = read(path)
        self.assertIn('environment["ALBUMIST_RELEASE_SMOKE"] == "1"', swift)
        self.assertIn("throw XCTSkip(", swift)
        self.assertIn("func test1_ReleaseBuildOnboardsAnalysesAndApplies()", swift)
        # No test switch of the app: a Release build ignores them, and the test must not lean on one.
        self.assertNotIn('"-AlbumistUITest', swift)
        for name in ("ui.yml", "ui-stress.yml", "ci.yml"):
            with self.subTest(workflow=name):
                self.assertNotIn("ALBUMIST_RELEASE_SMOKE", read(os.path.join(ROOT, ".github", "workflows", name)))


if __name__ == "__main__":
    unittest.main()


def gh_expr(expr, ctx):
    """Evaluates the small part of GitHub's expression language the concurrency groups and job
    conditions use: names with dots (missing = None), 'strings', format(), ==, !=, !, &&, ||,
    parentheses. && and || return an operand, as in GitHub."""
    tokens = re.findall(r"'(?:[^']|'')*'|&&|\|\||==|!=|!|\(|\)|,|[A-Za-z_][\w.\-\[\]']*|\d+", expr)
    pos = [0]

    def peek():
        return tokens[pos[0]] if pos[0] < len(tokens) else None

    def take():
        pos[0] += 1
        return tokens[pos[0] - 1]

    def primary():
        tok = take()
        if tok == "(":
            value = either()
            assert take() == ")"
            return value
        if tok == "!":
            return not primary()
        if tok.startswith("'"):
            return tok[1:-1].replace("''", "'")
        if tok in ("true", "false"):
            return tok == "true"
        if tok == "format":
            assert take() == "("
            args = [either()]
            while peek() == ",":
                take()
                args.append(either())
            assert take() == ")"
            return args[0].format(*args[1:])
        value = ctx
        for part in tok.split("."):
            value = value.get(part) if isinstance(value, dict) else None
        return value

    def compare():
        left = primary()
        while peek() in ("==", "!="):
            op, right = take(), primary()
            left = (left == right) if op == "==" else (left != right)
        return left

    def both():
        left = compare()
        while peek() == "&&":
            take()
            right = compare()
            left = right if left else left
        return left

    def either():
        left = both()
        while peek() == "||":
            take()
            right = both()
            left = left if left else right
        return left

    return either()


def concurrency_group(text):
    found = re.search(r"\nconcurrency:\n  group: >-\n((?:    .*\n)+)", text)
    return " ".join(strip_comment(line) for line in found.group(1).split("\n")).replace("${{", "").replace("}}", "")


def pr_context(user="someone", fork=False):
    return {"github": {"event_name": "pull_request", "workflow": "UI flow", "run_id": 7,
                       "ref": "refs/pull/8/merge",
                       "event": {"pull_request": {"user": {"login": user}, "head": {"repo": {"fork": fork}}}}},
            "inputs": {}}


def dispatch_context(ref, workflow="UI flow", release=False, event="workflow_dispatch"):
    return {"github": {"event_name": event, "workflow": workflow, "run_id": 7, "ref": ref, "event": {}},
            "inputs": {"release": release} if release else {}}


class MacQueueTests(unittest.TestCase):
    """19.11.2026: the stress pass dispatched on main after PR #9 waited in "mac-queue"; Dependabot
    rebased PR #8 and its UI run joined the queue and replaced the waiting pass (GitHub keeps one
    waiting run per group). Runs on main have a queue of their own now, and a Dependabot pull
    request uses no Mac until someone starts its UI run by hand before the merge."""

    def setUp(self):
        self.ui = read(os.path.join(ROOT, ".github", "workflows", "ui.yml"))
        self.stress = read(os.path.join(ROOT, ".github", "workflows", "ui-stress.yml"))
        self.ci = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))

    def test_main_has_its_own_queue(self):
        for name, text in (("ui", self.ui), ("ui-stress", self.stress)):
            group = concurrency_group(text)
            with self.subTest(workflow=name):
                self.assertEqual(gh_expr(group, dispatch_context("refs/heads/main")), "mac-queue-main")
                # The stress pass before the merge runs beside the branch's full UI pass (the
                # owner's decision of 20.11.2026, 17:20): a group per branch, not the Mac queue.
                self.assertEqual(gh_expr(group, dispatch_context("refs/heads/feature")),
                                 "stress-branch" if name == "ui-stress" else "mac-queue")

    def test_no_pull_request_joins_the_queue_of_main(self):
        group = concurrency_group(self.ui)
        self.assertEqual(gh_expr(group, pr_context()), "mac-queue")
        self.assertEqual(gh_expr(group, pr_context(fork=True)), "ui-fork")
        self.assertEqual(gh_expr(group, pr_context(user="dependabot[bot]")), "ui-dependabot")

    def test_testflight_and_the_weekly_pass_keep_their_own_groups(self):
        self.assertEqual(gh_expr(concurrency_group(self.ui), dispatch_context("refs/heads/main", "TestFlight", True, "workflow_call")),
                         "testflight-ui-7")
        group = concurrency_group(self.stress)
        self.assertEqual(gh_expr(group, dispatch_context("refs/heads/main", "TestFlight", True, "workflow_call")),
                         "testflight-stress-7")
        self.assertEqual(gh_expr(group, dispatch_context("refs/heads/main", "UI stress", event="schedule")), "stress-weekly")

    def test_a_dependabot_pull_request_starts_no_mac(self):
        bot, person = pr_context(user="dependabot[bot]"), pr_context()
        plan_if = job_field(self.ui, "plan", "if")
        self.assertTrue(plan_if, "the UI plan needs a condition for Dependabot")
        self.assertFalse(gh_expr(plan_if.replace("${{", "").replace("}}", ""), bot))
        self.assertTrue(gh_expr(plan_if.replace("${{", "").replace("}}", ""), person))
        self.assertTrue(gh_expr(plan_if.replace("${{", "").replace("}}", ""), dispatch_context("refs/heads/dependabot/x")))
        for job in ("core-linux", "build", "ui", "verdict"):
            with self.subTest(job=job):
                self.assertIn("plan", job_field(self.ui, job, "needs"))
        self.assertIn("github.event.pull_request.user.login != 'dependabot[bot]'", job_field(self.ci, "ios", "if"))

    def test_the_evaluator(self):
        self.assertEqual(gh_expr("a.b == 'x' && 'yes' || 'no'", {"a": {"b": "x"}}), "yes")
        self.assertEqual(gh_expr("a.b == 'x' && 'yes' || 'no'", {"a": {"b": "y"}}), "no")
        self.assertEqual(gh_expr("!a && format('q-{0}', n)", {"n": 3}), "q-3")
