"""Checks app name candidates against the App Store (iTunes Search API, DE and US).

Prints one NAME_CHECK line per candidate: exact title matches, titles that start with the
name, and the closest existing apps. Runs in CI because the API is not reachable elsewhere.
"""
import json
import sys
import time
import urllib.parse
import urllib.request

def search(term, country):
    url = "https://itunes.apple.com/search?" + urllib.parse.urlencode(
        {"term": term, "entity": "software", "country": country, "limit": 25})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                return json.load(r).get("results", [])
        except Exception as e:  # rate limit or network: wait and retry
            time.sleep(5 * (attempt + 1))
    return None

names = [n.strip() for n in open(sys.argv[1], encoding="utf-8") if n.strip()]
for name in names:
    low = name.lower()
    exact, prefix, similar = set(), set(), set()
    failed = False
    for country in ("de", "us"):
        results = search(name, country)
        if results is None:
            failed = True
            continue
        for app in results:
            title = app.get("trackName", "")
            t = title.lower()
            first = t.replace(":", " ").replace("-", " ").split()[0] if t.split() else ""
            if first == low or t == low:
                exact.add(title)
            elif t.startswith(low) or low in t.replace(" ", ""):
                prefix.add(title)
            elif len(similar) < 3:
                similar.add(title)
        time.sleep(3)
    verdict = "TAKEN" if exact else ("CLOSE" if prefix else "FREE")
    if failed and not exact and not prefix:
        verdict = "UNKNOWN"
    print(f"NAME_CHECK {name} | {verdict} | exact: {sorted(exact)[:3]} | similar: {sorted(prefix)[:3]} | other hits: {sorted(similar)[:3]}", flush=True)
