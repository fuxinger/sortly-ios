"""Print the UDID of an available iPhone simulator on the newest iOS runtime.

Usage: xcrun simctl list devices available -j | python3 pick_simulator.py [--pro]
--pro prefers a "Pro" model (not "Max"), like the screenshots in the App Store.
"""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
pro = "--pro" in sys.argv


def version(runtime: str) -> tuple[int, ...]:
    match = re.search(r"iOS-(\d+(?:-\d+)*)", runtime)
    return tuple(int(p) for p in match.group(1).split("-")) if match else ()


best = None
for runtime in sorted((r for r in devices if "iOS" in r), key=version):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if pro:
        phones = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]] or phones
    if phones:
        best = (runtime, phones[-1])
if best is None:
    sys.exit("No iPhone simulator found")
print(f"{best[1]['name']} on {best[0]}", file=sys.stderr)
print(best[1]["udid"])
