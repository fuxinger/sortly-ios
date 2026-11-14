"""Fails when a UI string in the app is missing from Localizable.xcstrings or has no
English translation. Usage: python3 check_strings.py <repo root>"""
import json, re, sys, glob
root = sys.argv[1]
cat = json.load(open(f'{root}/App/Sortly/Resources/Localizable.xcstrings'))
def norm(k):
    k = k.replace('%%', '%')
    k = re.sub(r'%(lld|ld|d|@|f|\.\d+f)', '#', k)
    return k
keys = {norm(k): k for k in cat['strings']}
pat = re.compile(r'(?:(?:Text|Button|Label|Section|navigationTitle|Toggle|TextField|NavigationLink|ContentUnavailableView|Picker|confirmationDialog|LabeledContent|LocalizedStringKey|accessibilityLabel|Link|Tab|alert)\(|String\(localized: )\s*"((?:[^"\\]|\\.)*)"')
missing = {}
for f in glob.glob(f'{root}/App/Sortly/**/*.swift', recursive=True):
    src = open(f).read()
    for m in pat.finditer(src):
        lit = m.group(1)
        if not re.search(r'[A-Za-zÄÖÜäöü]', lit): continue
        k = re.sub(r'\\\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\)', '#', lit).replace('\\"', '"')
        if norm(k) not in keys:
            missing.setdefault(k, f.split('/')[-1])
for k, f in sorted(missing.items(), key=lambda x: x[1]):
    print(f'MISSING_STRING {f} | {k}')
# Every catalog entry needs English; German plural forms are optional.
untranslated = [k for k, v in cat['strings'].items()
                if v.get('shouldTranslate', True) and 'en' not in v.get('localizations', {})]
for k in untranslated:
    print(f'NO_ENGLISH | {k}')
print(f'STRINGS_CHECKED {len(cat["strings"])} catalog entries, {len(missing)} missing, {len(untranslated)} without English')
sys.exit(1 if missing or untranslated else 0)
