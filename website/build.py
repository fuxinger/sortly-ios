#!/usr/bin/env python3
"""Builds the static website into ../_site (or the folder given as argument).

- Reads EINSTELLUNGEN.txt (KEY=value).
- Wraps every page in pages/<lang>/ with the shared layout.
- Replaces {{KEY}} with the value.
- Removes elements marked data-if="KEY" when KEY is empty,
  and elements marked data-ifnot="KEY" when KEY is set.
Only the Python standard library is used.
"""
import html
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT.parent / "_site"

# page file -> (title key, counterpart in the other language)
PAGES = {
    "de": {
        "index.html": ("Start", "index.html"),
        "support.html": ("Hilfe & Kontakt", "support.html"),
        "datenschutz.html": ("Datenschutz", "privacy.html"),
        "impressum.html": ("Impressum", "imprint.html"),
    },
    "en": {
        "index.html": ("Home", "index.html"),
        "support.html": ("Help & Contact", "support.html"),
        "privacy.html": ("Privacy", "datenschutz.html"),
        "imprint.html": ("Imprint", "impressum.html"),
    },
}
NAV = {
    "de": [("support.html", "Hilfe"), ("datenschutz.html", "Datenschutz"), ("impressum.html", "Impressum")],
    "en": [("support.html", "Help"), ("privacy.html", "Privacy"), ("imprint.html", "Imprint")],
}
OTHER = {"de": ("en", "English"), "en": ("de", "Deutsch")}


def read_settings():
    values = {}
    for line in (ROOT / "EINSTELLUNGEN.txt").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def apply_conditions(text, values):
    # Elements are written on one line: <tag data-if="KEY">...</tag>
    def keep(match):
        attr, key = match.group(1), match.group(2)
        filled = bool(values.get(key, ""))
        return match.group(0) if (filled if attr == "if" else not filled) else ""

    pattern = re.compile(r'^[ \t]*<[^>\n]*\bdata-(if|ifnot)="([A-Z_]+)"[^\n]*\n?', re.M)
    return pattern.sub(keep, text)


def fill(text, values):
    def repl(match):
        key = match.group(1)
        if key not in values:
            raise SystemExit(f"Unbekannter Platzhalter {{{{{key}}}}}")
        return html.escape(values[key], quote=True)

    return re.sub(r"\{\{([A-Z_]+)\}\}", repl, text)


def main():
    values = read_settings()
    layout = (ROOT / "layout.html").read_text(encoding="utf-8")
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(ROOT / "assets", OUT / "assets")
    shutil.copy(ROOT / "root-index.html", OUT / "index.html")

    for lang, pages in PAGES.items():
        (OUT / lang).mkdir(parents=True)
        other_lang, other_label = OTHER[lang]
        for name, (title, counterpart) in pages.items():
            body = (ROOT / "pages" / lang / name).read_text(encoding="utf-8")
            nav = "\n".join(
                f'<a href="{href}"{" aria-current=\"page\"" if href == name else ""}>{label}</a>'
                for href, label in NAV[lang]
            )
            page = (
                layout.replace("%LANG%", lang)
                .replace("%TITLE%", title)
                .replace("%NAV%", nav)
                .replace("%OTHER_HREF%", f"../{other_lang}/{counterpart}")
                .replace("%OTHER_LANG%", other_lang)
                .replace("%OTHER_LABEL%", other_label)
                .replace("%BODY%", body)
            )
            page = fill(apply_conditions(page, values), values)
            (OUT / lang / name).write_text(page, encoding="utf-8")

    missing = sorted(k for k, v in values.items() if v.startswith("["))
    if missing:
        print("Hinweis: Noch nicht ausgefüllt in EINSTELLUNGEN.txt:", ", ".join(missing))
    print(f"Fertig: {OUT}")


if __name__ == "__main__":
    main()
