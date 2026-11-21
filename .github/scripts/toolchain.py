"""Selects the pinned Xcode on a Mac job and checks it, or stops the job.

Usage: python3 .github/scripts/toolchain.py xcode [--runtime]
       python3 .github/scripts/toolchain.py xcodegen
       python3 .github/scripts/toolchain.py swiftlint
       python3 .github/scripts/toolchain.py periphery

Every Mac job calls this instead of picking "the newest Xcode" (which on image xcode-27-arm64
20261112 is a beta, and a beta build is refused by App Store Connect). It:
  - fails when the pinned Xcode.app (.github/toolchain.json) is not on the runner, listing the
    ones that are;
  - runs `sudo xcode-select -s` on it and checks `xcodebuild -version` for the pinned version
    and build number (a symlink or an updated app with the same path fails here);
  - with --runtime, also checks that the pinned iOS simulator runtime (identifier and build) is
    installed and available, for the jobs that test on a simulator.

`xcodegen` installs the pinned XcodeGen (version, release zip and its sha256 in
.github/toolchain.json) into $RUNNER_TEMP/xcodegen and puts it on $GITHUB_PATH, instead of
`brew install xcodegen` (whatever Homebrew has that day). A download that does not match the
checksum stops the job.

`swiftlint` installs the pinned SwiftLint the same way, from .github/lint-tools.json (a file of
its own: SwiftLint only reads the code, it does not build the app, so a new version must not
count in the app fingerprint of the UI runs the way toolchain.json does). It is the statically
linked Linux binary of the release, run in the swift container of the Linux jobs (ci.yml,
"SwiftLint"), which has the libsourcekitdInProc.so it loads. `periphery` installs the
pinned Periphery (unused code; macOS zip with the libIndexStore.dylib it loads) from the same file
(code-checks.yml).
"""
from __future__ import annotations

import glob
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pick_simulator import pins  # noqa: E402

LINT_TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lint-tools.json")


def xcode_problem(version_output: str, pin: dict) -> str | None:
    """Why `xcodebuild -version` does not show the pinned Xcode, or None."""
    version = re.search(r"^Xcode (\S+)", version_output, re.M)
    build = re.search(r"^Build version (\S+)", version_output, re.M)
    if not version or not build:
        return f"could not read `xcodebuild -version`: {version_output.strip()[:200]!r}"
    if (version.group(1), build.group(1)) != (pin["version"], pin["build"]):
        return (f"{pin['app']} is Xcode {version.group(1)} ({build.group(1)}), "
                f"pinned is {pin['version']} ({pin['build']})")
    return None


def runtime_problem(runtimes: dict, pin: dict) -> str | None:
    """Why `simctl list runtimes -j` does not offer the pinned runtime, or None."""
    listed = runtimes.get("runtimes", [])
    for r in listed:
        if r.get("identifier") == pin["identifier"]:
            if not r.get("isAvailable", False):
                return f"runtime {pin['identifier']} is installed but not available: {r.get('availabilityError', '?')}"
            if (r.get("version"), r.get("buildversion")) != (pin["version"], pin["build"]):
                return (f"runtime {pin['identifier']} is {r.get('version')} ({r.get('buildversion')}), "
                        f"pinned is {pin['version']} ({pin['build']})")
            return None
    offered = ", ".join(f"{r.get('identifier')} {r.get('buildversion')}" for r in listed) or "none"
    return f"runtime {pin['identifier']} is not installed (installed: {offered})"


def fail(message: str) -> int:
    print(f"::error title=Pinned toolchain::{message}. Update .github/toolchain.json on purpose.", flush=True)
    return 1


def install_zip(pin: dict, dest: str, binary: str, name: str, fetch=None) -> str:
    """Downloads the pinned release zip, checks its sha256, unpacks it into dest and returns the
    directory of `binary` (its path inside the zip). Raises ValueError on a wrong checksum or a
    path that would leave dest."""
    def download(url):
        last = None
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=120) as response:
                    return response.read()
            except OSError as error:
                last = error
                time.sleep(5 * (attempt + 1))
        raise OSError(f"{url}: {last}")
    data = (fetch or download)(pin["url"])
    digest = hashlib.sha256(data).hexdigest()
    if digest != pin["sha256"]:
        raise ValueError(f"{name} {pin['version']} download has sha256 {digest}, pinned is {pin['sha256']}")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for member in archive.namelist():
            target = os.path.realpath(os.path.join(dest, member))
            if not target.startswith(os.path.realpath(dest) + os.sep):
                raise ValueError(f"unexpected path in the {name} zip: {member}")
        archive.extractall(dest)
    path = os.path.join(dest, binary)
    if not os.path.isfile(path):
        raise ValueError(f"the {name} zip has no {binary}")
    os.chmod(path, 0o755)
    return os.path.dirname(path)


def install_xcodegen(pin: dict, dest: str, fetch=None) -> str:
    """The pinned XcodeGen; returns the directory of the xcodegen binary."""
    return install_zip(pin, dest, "xcodegen/bin/xcodegen", "XcodeGen", fetch)


def install_swiftlint(pin: dict, dest: str, fetch=None) -> str:
    """The pinned SwiftLint; returns the directory of its binary (pin["binary"])."""
    return install_zip(pin, dest, pin["binary"], "SwiftLint", fetch)


def install_periphery(pin: dict, dest: str, fetch=None) -> str:
    """The pinned Periphery; returns the directory of its binary (pin["binary"])."""
    return install_zip(pin, dest, pin["binary"], "Periphery", fetch)


def lint_pins(path: str = LINT_TOOLS) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def install_and_check(pin: dict, install, folder: str, command: str, name: str, version_args=("--version",)) -> int:
    """Installs, checks `<command> --version` (or version_args) against the pin and puts the folder
    on GITHUB_PATH."""
    try:
        folder = install(pin, folder)
    except ValueError as error:
        return fail(str(error))
    version = subprocess.run([os.path.join(folder, command), *version_args], capture_output=True, text=True).stdout
    print(version.strip())
    if pin["version"] not in version:
        return fail(f"{command} {' '.join(version_args)} says {version.strip()!r}, pinned {name} is {pin['version']}")
    with open(os.environ.get("GITHUB_PATH", os.devnull), "a", encoding="utf-8") as out:
        out.write(folder + "\n")
    return 0


def main(argv: list[str]) -> int:
    temp = os.environ.get("RUNNER_TEMP", "/tmp")
    if argv and argv[0] == "xcodegen":
        return install_and_check(pins()["xcodegen"], install_xcodegen, os.path.join(temp, "xcodegen"), "xcodegen", "XcodeGen")
    if argv and argv[0] == "swiftlint":
        pin = lint_pins()["swiftlint"]
        return install_and_check(pin, install_swiftlint, os.path.join(temp, "swiftlint"), os.path.basename(pin["binary"]),
                                 "SwiftLint")
    if argv and argv[0] == "periphery":
        pin = lint_pins()["periphery"]
        return install_and_check(pin, install_periphery, os.path.join(temp, "periphery"), pin["binary"], "Periphery",
                                 version_args=("version",))
    if not argv or argv[0] != "xcode":
        print(__doc__)
        return 2
    toolchain = pins()
    pin = toolchain["xcode"]
    if not os.path.isdir(pin["app"]):
        installed = ", ".join(sorted(glob.glob("/Applications/Xcode*.app"))) or "none"
        return fail(f"Xcode {pin['version']} ({pin['build']}) is not at {pin['app']} (installed: {installed})")
    subprocess.run(["sudo", "xcode-select", "-s", pin["app"]], check=True)
    output = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    print(output.strip())
    problem = xcode_problem(output, pin)
    if problem:
        return fail(problem)
    if "--runtime" in argv:
        listing = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True, text=True).stdout
        try:
            problem = runtime_problem(json.loads(listing), toolchain["runtime"])
        except ValueError:
            problem = f"could not read `simctl list runtimes -j`: {listing.strip()[:200]!r}"
        if problem:
            return fail(problem)
        print(f"iOS simulator runtime {toolchain['runtime']['identifier']} {toolchain['runtime']['build']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
