#!/usr/bin/env python3
"""Checks the translations in Locales/ against the texts the addon looks up.

Collects every translation key from the Lua sources (L["..."] lookups, the settings
widgets' labels and the English text in the tables that are translated on display),
then reports for each Locales/<code>.lua the keys it is missing, keys nothing uses
any more, and translations whose %s/%d placeholders don't match the English text.

    python3 tools/check_locales.py               check all languages
    python3 tools/check_locales.py --template    print every key as a Lua table body,
                                                 a starting point for a new language
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCALES = ROOT / "Locales"

STR = r'"((?:[^"\\]|\\.)*)"'

# L["..."] anywhere
LOOKUP = re.compile(r'\bL\[' + STR + r'\]')
# settings widgets translate their label themselves
WIDGET = re.compile(r'\bp:(?:Header|Note|Checkbox|Slider|Dropdown|Color|Button|EditBox|OrderList)\(' + STR)
# dropdown options, unless marked raw
OPTION = re.compile(r'\{ text = ' + STR + r', value = [^}\n]*\}')

# Tables whose English text is translated where it is shown:
# (file, regex for the table's start, regex for the texts inside it)
TABLES = [
    ("Config.lua", r'local TABS = \{', r'\{ ' + STR + r','),
    ("Config.lua", r'local KINDS = \{', r'\{ "\w+", ' + STR + r' \}'),
    ("Config.lua", r'local MODE_TEXT = \{', r'= ' + STR),
    ("Config.lua", r'p:OrderList\("Bars", [^{]*\{', r'= ' + STR),
    ("Core.lua", r'ns\.SCHOOL_NAMES = \{', r'= ' + STR),
    ("Core.lua", r'ns\.AVOID_OUT = \{', r'= ' + STR),
    ("Core.lua", r'ns\.AVOID_IN = \{', r'= ' + STR),
    ("Display.lua", r'local TAGS = \{', r'= ' + STR),
    ("Display.lua", r'local FLAG_SUFFIX = \{', r'= ' + STR),
    ("Alerts.lua", r'local CUSTOM_SOUNDS = \{', r'text = ' + STR),
    ("Alerts.lua", r'local BUILTIN_SOUNDS = \{', r'\{ "\w+", ' + STR + r' \}'),
    ("Report.lua", r'local labels = \{', STR),
    ("Report.lua", r'local COLUMNS = \{', r'\{ ' + STR + r', \d'),
    ("Report.lua", r'local headers = \{', r'\{ ' + STR + r', \d'),
    ("Report.lua", r'local TABS = \{', r'\{ "\w+", ' + STR + r', Build'),
    ("Locales/Locales.lua", r'local OWN_NAMES = \{', r'\[' + STR + r'\] = true'),
]
# one-off spots: (file, regex)
SPOTS = [
    ("Alerts.lua", r'CreateAlertFrame\("\w+", ' + STR),
    ("Report.lua", r'lines\[[^\]]+\] = \{ ' + STR),
]

ENTRY = re.compile(r'^\s*\[' + STR + r'\]\s*=\s*' + STR + r',?\s*$', re.M)
PLACEHOLDER = re.compile(r'%[-+ #0]*\d*(?:\.\d+)?[sdfgx]')


def unescape(s):
    return s.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")


def block(text, start):
    """The text from start's opening brace to its matching closing brace."""
    m = re.search(start, text)
    if not m:
        return None
    i = text.index("{", m.end() - 1)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return None


def collect_keys():
    keys = {}

    def add(k, where):
        keys.setdefault(unescape(k), where)

    for path in sorted(ROOT.glob("*.lua")) + [LOCALES / "Locales.lua"]:
        if path.name.startswith("SpellData_"):
            continue
        text = path.read_text(encoding="utf-8")
        name = path.relative_to(ROOT).as_posix()
        for rx in (LOOKUP, WIDGET):
            for m in rx.finditer(text):
                add(m.group(1), name)
        for m in OPTION.finditer(text):
            if "raw = true" not in m.group(0):
                add(m.group(1), name)

    for file, start, item in TABLES:
        text = (ROOT / file).read_text(encoding="utf-8")
        b = block(text, start)
        if b is None:
            sys.exit(f"check_locales: table {start!r} not found in {file}, update TABLES")
        for m in re.finditer(item, b):
            add(m.group(1), file)
    for file, rx in SPOTS:
        text = (ROOT / file).read_text(encoding="utf-8")
        for m in re.finditer(rx, text):
            add(m.group(1), file)
    return keys


def read_locale(path):
    text = path.read_text(encoding="utf-8")
    return {unescape(k): unescape(v) for k, v in ENTRY.findall(text)}


def lua_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    keys = collect_keys()
    if "--template" in sys.argv:
        for k in sorted(keys, key=str.lower):
            print(f"    [{lua_quote(k)}] = {lua_quote(k)},")
        return 0

    ok = True
    for path in sorted(LOCALES.glob("*.lua")):
        if path.name in ("Locales.lua", "enUS.lua"):
            continue
        strings = read_locale(path)
        missing = [k for k in keys if k not in strings]
        unused = [k for k in strings if k not in keys]
        bad = [k for k, v in strings.items()
               if k in keys and PLACEHOLDER.findall(k) != PLACEHOLDER.findall(v)]
        print(f"{path.name}: {len(strings)} translations, {len(missing)} missing, "
              f"{len(unused)} unused, {len(bad)} placeholder mismatches")
        for k in missing:
            print(f"  missing  {k!r}  ({keys[k]})")
        for k in unused:
            print(f"  unused   {k!r}")
        for k in bad:
            print(f"  placeholders differ  {k!r} -> {strings[k]!r}")
        ok = ok and not missing and not bad
    print(f"{len(keys)} keys in the sources")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
