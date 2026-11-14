"""Print the UDID of an available iPhone simulator on the newest iOS runtime.

Usage: xcrun simctl list devices available -j | python3 pick_simulator.py [--pro]
--pro prefers a "Pro" model (not "Max"), like the screenshots in the App Store.

Regular iPhones on the general runtime win: Xcode 27 also ships device-specific runtimes
(e.g. "iOS-27-2-iPhone19-4" for the foldable "iPhone Duo"), and the UI flow and its
screenshots are written for the classic portrait iPhone.
"""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
pro = "--pro" in sys.argv
SPECIAL = ("Duo", "Fold", "Flip")


def version(runtime: str) -> tuple[int, ...]:
    match = re.search(r"iOS-(\d+(?:-\d+)*)", runtime)
    return tuple(int(p) for p in match.group(1).split("-")) if match else ()


def generic(runtime: str) -> bool:
    """True for "…SimRuntime.iOS-27-2", false for a device-specific "…iOS-27-2-iPhone19-4"."""
    return re.search(r"iOS-\d+(?:-\d+)*$", runtime) is not None


def model_number(name: str) -> int:
    match = re.search(r"iPhone (\d+)", name)
    return int(match.group(1)) if match else 0


candidates = []
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    for d in entries:
        name = d["name"]
        if not name.startswith("iPhone"):
            continue
        regular = not any(word in name for word in SPECIAL)
        preferred = ("Pro" in name and "Max" not in name) if pro else ("Pro" not in name and "Plus" not in name)
        candidates.append(((regular, generic(runtime), version(runtime), preferred, model_number(name), name), runtime, d))

if not candidates:
    sys.exit("No iPhone simulator found")
_, runtime, best = max(candidates, key=lambda c: c[0])
print(f"{best['name']} on {runtime}", file=sys.stderr)
print(best["udid"])
