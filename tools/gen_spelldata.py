"""Generates SpellData.lua: what every class spell does, from the game's own data.

Reads the DB2 tables of a WoW Forever build from wago.tools (CSV export) and writes,
for every class ability and every rank: damage school, whether it deals direct
damage or heals, damage over time (tick interval, school and duration), channeling,
on-next-swing, projectiles, and spells that never deal damage at all.

Run from the repository root:  python tools/gen_spelldata.py [--build 1.60.1.70205]
Needs only the Python standard library and internet access.
"""
import argparse
import csv
import io
import os
import urllib.request
from collections import defaultdict

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT_BUILD = "1.60.1.70205"
TABLES = ["SpellMisc", "SpellEffect", "SkillLineAbility", "SkillLine", "SpellName", "SpellDuration"]
CLASS_SKILL_CATEGORY = "7"

# SpellEffect.Effect
DAMAGE_EFFECTS = {2, 9, 17, 31, 58, 62, 121}   # school damage, leech, weapon damage variants, mana burn
HEAL_EFFECTS = {10, 67, 136}                    # heal, heal to full, heal percent
UNKNOWN_EFFECTS = {3, 64, 77, 142}              # dummy, trigger spell, script: may deal damage indirectly
WEAPON_EFFECTS = {17, 31, 58, 121}
AURA_EFFECTS = {6, 27, 35, 65, 119, 128, 129}   # apply aura, persistent area aura, area auras
# SpellEffect.EffectAura
PERIODIC_DAMAGE = {3, 53, 89}                   # periodic damage, leech, damage percent
PERIODIC_HEAL = {8}
PERIODIC_TRIGGER = 23
PERIODIC_DUMMY = 226
# SpellMisc attributes
ATTR0_PASSIVE = 0x40
ATTR0_NEXT_SWING = 0x4 | 0x400
ATTR1_CHANNELED = 0x4 | 0x40


def load(table, build, cache):
    path = os.path.join(cache, f"{table}-{build}.csv") if cache else None
    if path and os.path.exists(path):
        text = open(path, encoding="utf-8").read()
    else:
        url = f"https://wago.tools/db2/{table}/csv?build={build}"
        req = urllib.request.Request(url, headers={"User-Agent": "WombatLog-gen_spelldata"})
        with urllib.request.urlopen(req, timeout=300) as r:
            text = r.read().decode("utf-8")
        if path:
            os.makedirs(cache, exist_ok=True)
            open(path, "w", encoding="utf-8").write(text)
    return list(csv.DictReader(io.StringIO(text)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=DEFAULT_BUILD)
    ap.add_argument("--cache", help="folder to keep downloaded CSVs in")
    ap.add_argument("--out", default=os.path.join(ROOT, "SpellData.lua"))
    args = ap.parse_args()
    t = {name: load(name, args.build, args.cache) for name in TABLES}

    class_lines = {r["ID"] for r in t["SkillLine"] if r["CategoryID"] == CLASS_SKILL_CATEGORY}
    spells = sorted({int(r["Spell"]) for r in t["SkillLineAbility"] if r["SkillLine"] in class_lines})
    names = {int(r["ID"]): r["Name_lang"] for r in t["SpellName"]}
    misc = {int(r["SpellID"]): r for r in t["SpellMisc"] if r["DifficultyID"] == "0"}
    durations = {r["ID"]: int(r["Duration"]) / 1000 for r in t["SpellDuration"]}
    effects = defaultdict(list)
    for r in t["SpellEffect"]:
        if r["DifficultyID"] == "0":
            effects[int(r["SpellID"])].append(r)

    lines, counts = [], defaultdict(int)
    for sid in spells:
        m = misc.get(sid)
        if not m or int(m["Attributes_0"]) & ATTR0_PASSIVE:
            continue
        school = int(m["SchoolMask"]) or 1
        attr0, attr1 = int(m["Attributes_0"]), int(m["Attributes_1"])
        channel = bool(attr1 & ATTR1_CHANNELED)
        flags, tick, tick_school = set(), None, None
        for e in effects.get(sid, []):
            effect, aura = int(e["Effect"]), int(e["EffectAura"])
            period = int(e["EffectAuraPeriod"]) / 1000
            if effect in DAMAGE_EFFECTS:
                flags.add("d")
            if effect in WEAPON_EFFECTS:
                flags.add("w")
            if effect in HEAL_EFFECTS:
                flags.add("h")
            if effect in UNKNOWN_EFFECTS:
                flags.add("u")
            if effect in AURA_EFFECTS and period > 0:
                if aura in PERIODIC_DAMAGE or (aura == PERIODIC_DUMMY and channel):
                    flags.add("o")
                    tick = tick or period
                elif aura == PERIODIC_TRIGGER:
                    child = int(e["EffectTriggerSpell"])
                    child_effects = {int(c["Effect"]) for c in effects.get(child, [])}
                    if child_effects & DAMAGE_EFFECTS:
                        flags.add("o")
                        tick = tick or period
                        cm = misc.get(child)
                        if cm and int(cm["SchoolMask"]) and int(cm["SchoolMask"]) != school:
                            tick_school = int(cm["SchoolMask"])
                    elif child_effects & HEAL_EFFECTS:
                        flags.add("r")
                elif aura in PERIODIC_HEAL:
                    flags.add("r")
        if channel:
            flags.add("c")
        if attr0 & ATTR0_NEXT_SWING and "w" in flags:
            flags.add("n")
        if float(m["Speed"] or 0) > 0:
            flags.add("p")
        if not flags & set("dhoru"):
            flags.add("x")  # utility: never deals damage or heals
        order = "dhwnorcpux"
        f = "".join(c for c in order if c in flags)
        fields = [str(school), f'"{f}"']
        if tick:
            fields.append(f"{tick:g}")
            duration = durations.get(m["DurationIndex"], 0) if "o" in flags else 0
            if tick_school or duration > 0:
                fields.append(str(tick_school) if tick_school else "nil")
            if duration > 0:
                fields.append(f"{duration:g}")
        name = names.get(sid, "?").replace("\n", " ")
        lines.append(f"    [{sid}] = {{ {', '.join(fields)} }}, -- {name}")
        for c in f:
            counts[c] += 1

    header = [
        f"-- Generated by tools/gen_spelldata.py from WoW Forever build {args.build}. Do not edit by hand.",
        "-- [spellID] = { schoolMask, flags, tickSeconds, tickSchool, durationSeconds }",
        "--   d direct damage  h direct heal  w weapon-based  n on next swing",
        "--   o damage over time  r heal over time  c channeled  p projectile",
        "--   u effect that may deal damage indirectly (script/trigger)  x never damages or heals",
        "local ADDON, ns = ...",
        "",
        "ns.SPELL_DATA = {",
    ]
    out = "\n".join(header + lines + ["}", ""])
    open(args.out, "w", encoding="utf-8", newline="\n").write(out)
    print(f"{len(lines)} spells -> {args.out} ({len(out) // 1024} KB)")
    print("flags:", dict(sorted(counts.items())))


if __name__ == "__main__":
    main()
