"""Moves the app's web addresses in App Store Connect from the old Pages site to the new one.

  python3 asc_urls.py fix --bundle-id app.albumist.ios [--dry-run]

The repository was renamed from sortly-ios to albumist-ios on 21.11.2026. GitHub forwards the old
repository address, but not the old Pages site: https://fuxinger.github.io/sortly-ios/... is gone,
the site is now https://fuxinger.github.io/albumist-ios/... (website/ANLEITUNG.md). App Store
Connect still names the old site where Fuchs entered it: the privacy policy (app information,
and TestFlight's beta app information), the support and marketing addresses of a version. The
owner asked on 21.11. that this is done through the API ("Mach selber").

Changes only an address that starts with the old site, to the same path on the new one; every
other value stays as it is, an empty one too (it is listed, not filled in). Idempotent: a second
run finds nothing to change. Where App Store Connect refuses a change because of the state of a
version (STATE_ERROR, for example one in review), it is listed and left alone; any other refusal
is a warning with Apple's answer.

Runs in the upload job of testflight.yml (release), the only job that gets the App Store Connect
key (test_workflows.py), after "Was testen", with continue-on-error: it never touches the upload.
Same JWT and calls as testflight_notes.py (KEY_ID, ISSUER_ID, KEY_PATH in the environment). A
failure is a warning and exit 0; the next TestFlight run tries again.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.error

from testflight_notes import call as asc_call

OLD_SITE = re.compile(r"^\s*https?://fuxinger\.github\.io/sortly-ios(?=/|$)", re.IGNORECASE)
NEW_SITE = "https://fuxinger.github.io/albumist-ios"

# The address fields of each kind of localization, and what the owner calls them.
FIELDS = {
    "appInfoLocalizations": ("privacyPolicyUrl", "privacyChoicesUrl"),
    "appStoreVersionLocalizations": ("supportUrl", "marketingUrl"),
    "betaAppLocalizations": ("privacyPolicyUrl", "marketingUrl"),
}
# Shown when empty: App Store Connect needs them before a submission.
NEEDED = {("appInfoLocalizations", "privacyPolicyUrl"), ("appStoreVersionLocalizations", "supportUrl")}
WHERE = {
    "appInfoLocalizations": "App-Informationen",
    "appStoreVersionLocalizations": "Version",
    "betaAppLocalizations": "TestFlight-Testinformationen",
}


def moved(value: str | None) -> str | None:
    """The address on the new site for one on the old site, None for any other value."""
    if not value or not OLD_SITE.match(value):
        return None
    return OLD_SITE.sub(NEW_SITE, value, count=1).strip()


def localizations(call, bundle_id: str) -> list[tuple[str, str, dict]]:
    """(kind, context, localization) of every place an address can be."""
    apps = call("GET", "apps", **{"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"})["data"]
    # Exactly this bundle id: the filter is said to match loosely (a second app "app.albumist.ios.x").
    apps = [a for a in apps if a.get("attributes", {}).get("bundleId") == bundle_id]
    if len(apps) != 1:
        raise LookupError(f"{len(apps)} apps with bundle id {bundle_id}")
    app = apps[0]["id"]
    found = []
    for info in call("GET", f"apps/{app}/appInfos", limit="200")["data"]:
        state = info.get("attributes", {}).get("state") or info.get("attributes", {}).get("appStoreState") or "?"
        for loc in call("GET", f"appInfos/{info['id']}/appInfoLocalizations", limit="50")["data"]:
            found.append(("appInfoLocalizations", f"app info {state}", loc))
    for version in call("GET", f"apps/{app}/appStoreVersions", limit="200")["data"]:
        attributes = version.get("attributes", {})
        context = f"version {attributes.get('versionString', '?')} {attributes.get('appVersionState') or attributes.get('appStoreState') or '?'}"
        for loc in call("GET", f"appStoreVersions/{version['id']}/appStoreVersionLocalizations", limit="50")["data"]:
            found.append(("appStoreVersionLocalizations", context, loc))
    for loc in call("GET", f"apps/{app}/betaAppLocalizations", limit="50")["data"]:
        found.append(("betaAppLocalizations", "TestFlight", loc))
    return found


def plan(found: list[tuple[str, str, dict]]) -> tuple[list[dict], list[str]]:
    """The changes (kind, id, field, old, new, label) and notes about empty needed fields."""
    changes, notes = [], []
    for kind, context, loc in found:
        attributes = loc.get("attributes", {})
        locale = attributes.get("locale", "?")
        for field in FIELDS[kind]:
            value = attributes.get(field)
            new = moved(value)
            label = f"{WHERE[kind]} ({context}, {locale}) {field}"
            if new:
                changes.append({"kind": kind, "id": loc["id"], "field": field, "old": value, "new": new, "label": label})
            elif not value and (kind, field) in NEEDED:
                notes.append(f"{label} is empty")
    return changes, notes


def not_editable(error: urllib.error.HTTPError, body: str) -> bool:
    """App Store Connect refuses a change because of a version's state (409 STATE_ERROR); a 409
    for an invalid value is a real failure."""
    return error.code == 409 and "STATE_ERROR" in body


def fix(call, bundle_id: str, dry_run: bool = False, out=print) -> dict:
    changes, notes = plan(localizations(call, bundle_id))
    result = {"changed": [], "not_editable": [], "failed": [], "notes": notes}
    for note in notes:
        out(f"ASC_URL note: {note}")
    if not changes:
        out("ASC_URL nothing to change: no address of the old site sortly-ios is left")
    for change in changes:
        line = f"{change['label']}: {change['old']} -> {change['new']}"
        if dry_run:
            out(f"ASC_URL would change {line}")
            result["changed"].append(change)
            continue
        try:
            call("PATCH", f"{change['kind']}/{change['id']}", {"data": {
                "type": change["kind"], "id": change["id"], "attributes": {change["field"]: change["new"]}}})
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")[:300]
            if not_editable(error, body):
                out(f"ASC_URL not editable (left as it is) {line}: {body}")
                result["not_editable"].append(change)
            else:
                out(f"::warning title=App Store Connect address::{change['label']} not changed: HTTP {error.code} {body}")
                result["failed"].append(change)
            continue
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            out(f"::warning title=App Store Connect address::{change['label']} not changed: {error}")
            result["failed"].append(change)
            continue
        out(f"ASC_URL changed {line}")
        result["changed"].append(change)
    return result


def summary(result: dict, dry_run: bool) -> str:
    verb = "Would change" if dry_run else "Changed"
    lines = ["### App Store Connect: Adressen der Website", ""]
    for key, title in (("changed", verb), ("not_editable", "Not editable in its state (STATE_ERROR)"),
                       ("failed", "Failed (next TestFlight run tries again)")):
        for change in result[key]:
            lines.append(f"- {title}: {change['label']}: `{change['old']}` → `{change['new']}`")
    lines += [f"- Note: {note}" for note in result["notes"]]
    if len(lines) == 2:
        lines.append("- Nothing to change.")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None, call=asc_call) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("fix")
    run.add_argument("--bundle-id", required=True)
    run.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    # Never a red step, whatever goes wrong (a missing openssl, an answer of an unexpected shape):
    # the build is uploaded already, and the next TestFlight run tries again.
    try:
        result = fix(call, args.bundle_id, args.dry_run)
    except Exception as error:  # noqa: BLE001
        detail = error.read().decode(errors="replace")[:300] if isinstance(error, urllib.error.HTTPError) else str(error)
        print(f"::warning title=App Store Connect addresses::not checked ({type(error).__name__}): {detail}; "
              "the next TestFlight run tries again")
        return 0
    try:
        with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as f:
            f.write(summary(result, args.dry_run))
    except OSError as error:
        print(f"::warning title=App Store Connect addresses::no job summary: {error}")
    if result["failed"]:
        print(f"::warning title=App Store Connect addresses::{len(result['failed'])} not changed (see above)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
