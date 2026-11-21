"""Unit tests for asc_urls.py: the web addresses in App Store Connect move from the old Pages
site (sortly-ios) to the new one (albumist-ios), and nothing else changes."""
from __future__ import annotations

import io
import os
import sys
import unittest
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import asc_urls  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
OLD = "https://fuxinger.github.io/sortly-ios"
NEW = "https://fuxinger.github.io/albumist-ios"


class FakeASC:
    """App Store Connect as the calls of asc_urls.py see it; records every PATCH."""

    def __init__(self, info=None, versions=None, beta=None, refuse=(), fail=(), invalid=(), offline=(), apps=None):
        self.info = info if info is not None else [
            {"id": "il-de", "attributes": {"locale": "de-DE", "privacyPolicyUrl": f"{OLD}/de/datenschutz.html"}},
            {"id": "il-en", "attributes": {"locale": "en-US", "privacyPolicyUrl": f"{OLD}/en/privacy.html",
                                           "privacyChoicesUrl": None}}]
        self.versions = versions if versions is not None else {"v1": [
            {"id": "vl-de", "attributes": {"locale": "de-DE", "supportUrl": f"{OLD}/de/support.html",
                                           "marketingUrl": f"{OLD}/"}},
            {"id": "vl-en", "attributes": {"locale": "en-US", "supportUrl": "https://example.org/help", "marketingUrl": None}}]}
        self.beta = beta if beta is not None else [
            {"id": "bl-de", "attributes": {"locale": "de-DE", "privacyPolicyUrl": f"{OLD}/de/datenschutz.html",
                                           "feedbackEmail": "someone@example.org"}}]
        self.refuse, self.fail, self.patches = set(refuse), set(fail), []
        self.invalid, self.offline = set(invalid), set(offline)
        self.apps = apps if apps is not None else [{"id": "app1", "attributes": {"bundleId": "app.albumist.ios"}}]

    def __call__(self, method, path, body=None, **params):
        if method == "PATCH":
            kind, ident = path.split("/")
            if ident in self.refuse:
                raise urllib.error.HTTPError(path, 409, "Conflict", {}, io.BytesIO(b'{"errors":[{"code":"STATE_ERROR"}]}'))
            if ident in self.invalid:
                raise urllib.error.HTTPError(path, 409, "Conflict", {}, io.BytesIO(b'{"errors":[{"code":"ENTITY_ERROR.ATTRIBUTE.INVALID"}]}'))
            if ident in self.offline:
                raise urllib.error.URLError("timed out")
            if ident in self.fail:
                raise urllib.error.HTTPError(path, 500, "Error", {}, io.BytesIO(b"boom"))
            assert body["data"]["id"] == ident and body["data"]["type"] == kind
            self.patches.append((kind, ident, body["data"]["attributes"]))
            for loc in self.info + self.beta + [l for ls in self.versions.values() for l in ls]:
                if loc["id"] == ident:
                    loc["attributes"].update(body["data"]["attributes"])
            return {}
        if path == "apps":
            assert params["filter[bundleId]"] == "app.albumist.ios"
            return {"data": self.apps}
        if path == "apps/app1/appInfos":
            return {"data": [{"id": "info1", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]}
        if path == "appInfos/info1/appInfoLocalizations":
            return {"data": self.info}
        if path == "apps/app1/appStoreVersions":
            return {"data": [{"id": v, "attributes": {"versionString": "1.0", "appVersionState": "PREPARE_FOR_SUBMISSION"}}
                             for v in self.versions]}
        if path.startswith("appStoreVersions/"):
            return {"data": self.versions[path.split("/")[1]]}
        if path == "apps/app1/betaAppLocalizations":
            return {"data": self.beta}
        raise AssertionError(f"unexpected call {method} {path}")


def run(fake, dry_run=False):
    lines = []
    result = asc_urls.fix(fake, "app.albumist.ios", dry_run=dry_run, out=lines.append)
    return result, "\n".join(lines)


class MovedTests(unittest.TestCase):
    def test_only_the_old_site_moves(self):
        self.assertEqual(asc_urls.moved(f"{OLD}/de/datenschutz.html"), f"{NEW}/de/datenschutz.html")
        self.assertEqual(asc_urls.moved(f"{OLD}/"), f"{NEW}/")
        self.assertEqual(asc_urls.moved(OLD), NEW)
        self.assertEqual(asc_urls.moved("http://fuxinger.github.io/sortly-ios/en/privacy.html"), f"{NEW}/en/privacy.html")
        self.assertEqual(asc_urls.moved(" https://Fuxinger.GitHub.io/sortly-ios/de/support.html "), f"{NEW}/de/support.html")
        for other in (None, "", f"{NEW}/de/datenschutz.html", "https://example.org/sortly-ios/",
                      "https://fuxinger.github.io/sortly-ios-old/", "https://github.com/fuxinger/sortly-ios"):
            self.assertIsNone(asc_urls.moved(other), other)


class FixTests(unittest.TestCase):
    def test_every_old_address_moves_and_nothing_else(self):
        fake = FakeASC()
        result, out = run(fake)
        self.assertEqual(sorted(fake.patches, key=repr), sorted([
            ("appInfoLocalizations", "il-de", {"privacyPolicyUrl": f"{NEW}/de/datenschutz.html"}),
            ("appInfoLocalizations", "il-en", {"privacyPolicyUrl": f"{NEW}/en/privacy.html"}),
            ("appStoreVersionLocalizations", "vl-de", {"marketingUrl": f"{NEW}/"}),
            ("appStoreVersionLocalizations", "vl-de", {"supportUrl": f"{NEW}/de/support.html"}),
            ("betaAppLocalizations", "bl-de", {"privacyPolicyUrl": f"{NEW}/de/datenschutz.html"}),
        ], key=repr))
        self.assertEqual(len(result["changed"]), 5)
        self.assertNotIn("example.org/help", " ".join(str(p) for p in fake.patches))
        # The feedback address is never read out into the log.
        self.assertNotIn("someone@example.org", out)

    def test_a_second_run_changes_nothing(self):
        fake = FakeASC()
        run(fake)
        fake.patches.clear()
        result, out = run(fake)
        self.assertEqual(fake.patches, [])
        self.assertEqual(result["changed"], [])
        self.assertIn("nothing to change", out)

    def test_a_dry_run_only_lists(self):
        fake = FakeASC()
        result, out = run(fake, dry_run=True)
        self.assertEqual(fake.patches, [])
        self.assertEqual(len(result["changed"]), 5)
        self.assertIn(f"ASC_URL would change App-Informationen (app info PREPARE_FOR_SUBMISSION, de-DE) privacyPolicyUrl: "
                      f"{OLD}/de/datenschutz.html -> {NEW}/de/datenschutz.html", out)

    def test_a_live_version_is_left_alone_and_a_failure_is_reported(self):
        fake = FakeASC(refuse={"vl-de"}, fail={"bl-de"})
        result, out = run(fake)
        self.assertEqual([c["id"] for c in result["not_editable"]], ["vl-de", "vl-de"])
        self.assertEqual([c["id"] for c in result["failed"]], ["bl-de"])
        self.assertEqual(len(result["changed"]), 2)
        self.assertIn("not editable (left as it is)", out)
        self.assertIn("::warning title=App Store Connect address::", out)

    def test_a_409_for_an_invalid_value_is_a_failure_and_a_lost_connection_does_not_stop_the_rest(self):
        fake = FakeASC(invalid={"il-de"}, offline={"il-en"})
        result, out = run(fake)
        self.assertEqual(sorted(c["id"] for c in result["failed"]), ["il-de", "il-en"])
        self.assertEqual(result["not_editable"], [])
        self.assertEqual(len(result["changed"]), 3)
        self.assertIn("ENTITY_ERROR.ATTRIBUTE.INVALID", out)

    def test_only_the_app_with_exactly_this_bundle_id(self):
        fake = FakeASC(apps=[{"id": "other", "attributes": {"bundleId": "app.albumist.ios.widget"}},
                             {"id": "app1", "attributes": {"bundleId": "app.albumist.ios"}}])
        result, _ = run(fake)
        self.assertEqual(len(result["changed"]), 5)
        with self.assertRaises(LookupError):
            run(FakeASC(apps=[{"id": "other", "attributes": {"bundleId": "app.albumist.ios.widget"}}]))

    def test_an_empty_needed_address_is_named_not_filled(self):
        fake = FakeASC(info=[{"id": "il-de", "attributes": {"locale": "de-DE", "privacyPolicyUrl": None}}],
                       versions={"v1": [{"id": "vl-de", "attributes": {"locale": "de-DE", "supportUrl": ""}}]}, beta=[])
        result, out = run(fake)
        self.assertEqual(fake.patches, [])
        self.assertEqual(result["notes"], ["App-Informationen (app info PREPARE_FOR_SUBMISSION, de-DE) privacyPolicyUrl is empty",
                                           "Version (version 1.0 PREPARE_FOR_SUBMISSION, de-DE) supportUrl is empty"])

    def test_main_never_fails_the_job(self):
        def broken(method, path, body=None, **params):
            raise urllib.error.HTTPError(path, 401, "Unauthorized", {}, io.BytesIO(b"NOT_AUTHORIZED"))
        out = io.StringIO()
        from contextlib import redirect_stdout
        with redirect_stdout(out):
            self.assertEqual(asc_urls.main(["fix", "--bundle-id", "app.albumist.ios"], call=broken), 0)
        self.assertIn("::warning title=App Store Connect addresses::not checked (HTTPError): NOT_AUTHORIZED", out.getvalue())

        def odd(method, path, body=None, **params):
            raise FileNotFoundError("openssl")
        with redirect_stdout(io.StringIO()):
            self.assertEqual(asc_urls.main(["fix", "--bundle-id", "app.albumist.ios"], call=odd), 0)

    def test_the_summary(self):
        fake = FakeASC(refuse={"vl-de"})
        result, _ = run(fake)
        text = asc_urls.summary(result, dry_run=False)
        self.assertIn("- Changed: App-Informationen", text)
        self.assertIn("- Not editable in its state (STATE_ERROR): Version", text)


class WorkflowTests(unittest.TestCase):
    def test_it_runs_in_the_upload_job_after_the_notes_and_never_fails_it(self):
        with open(os.path.join(ROOT, ".github", "workflows", "testflight.yml"), encoding="utf-8") as f:
            text = f.read()
        notes = text.index('- name: Set "Was testen" for this build')
        step_start = text.index("- name: App Store Connect addresses of the website")
        remove = text.index("- name: Remove key")
        self.assertLess(notes, step_start)
        self.assertLess(step_start, remove)
        step = text[step_start:remove]
        self.assertIn("continue-on-error: true", step)
        self.assertIn("python3 .github/scripts/asc_urls.py fix --bundle-id app.albumist.ios", step)
        self.assertIn("timeout-minutes:", step)


if __name__ == "__main__":
    unittest.main()
