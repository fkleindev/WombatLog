"""Generates SpellData_<Flavor>.lua: what every class spell does, from the game's own data.

Reads the DB2 tables of a WoW build from wago.tools (CSV export) and writes, for every
class ability and every rank: damage school, whether it deals direct damage or heals,
damage over time (tick interval and school), aura duration, cooldown, channeling, on-next-swing,
projectiles, and spells that never deal damage at all. Spell IDs and mechanics differ
between game versions, so every supported client gets its own file; each file only
builds its table on the client it belongs to.

Run from the repository root:
    python tools/gen_spelldata.py --all                  every supported client
    python tools/gen_spelldata.py --flavor tbc [--build 2.5.6.69795]
Needs only the Python standard library and internet access.
"""
import argparse
import csv
import io
import os
import urllib.request
from collections import defaultdict

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
# flavor -> (file suffix, default build); the flavor names match ns.FLAVOR in Core.lua
FLAVORS = {
    "forever": ("Forever", "1.60.1.70205"),
    "vanilla": ("Vanilla", "1.15.9.70003"),
    "tbc": ("TBC", "2.5.6.69795"),
    "mists": ("Mists", "5.5.4.70032"),
    "retail": ("Retail", "12.1.0.69933"),
}
TABLES = ["SpellMisc", "SpellEffect", "SkillLineAbility", "SkillLine", "SpellName", "SpellDuration", "SpellCooldowns"]
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
TRIGGER_SPELL = 64
ORDER = "dhwnorcpux"


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


def generate(flavor, build, cache, out):
    t = {name: load(name, build, cache) for name in TABLES}

    class_lines = {r["ID"] for r in t["SkillLine"] if r["CategoryID"] == CLASS_SKILL_CATEGORY}
    spells = sorted({int(r["Spell"]) for r in t["SkillLineAbility"] if r["SkillLine"] in class_lines})
    names = {int(r["ID"]): r["Name_lang"] for r in t["SpellName"]}
    misc = {int(r["SpellID"]): r for r in t["SpellMisc"] if r["DifficultyID"] == "0"}
    durations = {r["ID"]: int(r["Duration"]) / 1000 for r in t["SpellDuration"]}
    # the spell's own cooldown (or its category's, whichever is longer); the global
    # cooldown alone doesn't count
    cooldowns = {}
    for r in t["SpellCooldowns"]:
        if r["DifficultyID"] == "0":
            cd = max(int(r["RecoveryTime"] or 0), int(r["CategoryRecoveryTime"] or 0)) / 1000
            if cd > 1.5:
                cooldowns[int(r["SpellID"])] = cd
    effects = defaultdict(list)
    for r in t["SpellEffect"]:
        if r["DifficultyID"] == "0":
            effects[int(r["SpellID"])].append(r)

    def analyze(sid):
        """School, flags, tick interval, tick school and duration of one spell (None if unknown)."""
        m = misc.get(sid)
        if not m:
            return None
        school = int(m["SchoolMask"]) or 1
        attr0, attr1 = int(m["Attributes_0"]), int(m["Attributes_1"])
        channel = bool(attr1 & ATTR1_CHANNELED)
        flags, tick, tick_school, has_aura = set(), None, None, False
        for e in effects.get(sid, []):
            effect, aura = int(e["Effect"]), int(e["EffectAura"])
            period = int(e["EffectAuraPeriod"]) / 1000
            if effect in AURA_EFFECTS:
                has_aura = True
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
        # how long its buff, debuff or DoT lasts (for reminders and pinned DoTs)
        duration = durations.get(m["DurationIndex"], 0) if has_aura else 0
        return {"school": school, "flags": flags, "tick": tick, "tick_school": tick_school,
                "duration": duration, "cooldown": cooldowns.get(sid, 0), "passive": bool(attr0 & ATTR0_PASSIVE)}

    # Newer clients split many spells: the cast triggers a second spell that carries
    # the debuff (Corruption 172 -> 146739). Its ticks and auras use that second ID, so
    # it gets an entry of its own, and the cast inherits its damage over time.
    data, children = {}, {}
    for sid in spells:
        a = analyze(sid)
        if not a or a["passive"]:
            continue
        data[sid] = a
        for e in effects.get(sid, []):
            child = int(e["EffectTriggerSpell"] or 0)
            if int(e["Effect"]) != TRIGGER_SPELL or not child or child == sid:
                continue
            c = analyze(child)
            if not c or not c["flags"] & set("dhor"):
                continue
            children.setdefault(child, c)
            if "o" in c["flags"] and "o" not in a["flags"]:
                a["flags"].add("o")
                a["tick"] = c["tick"]
                a["duration"] = c["duration"]
                if c["school"] != a["school"]:
                    a["tick_school"] = c["tick_school"] or c["school"]
    for child, c in children.items():
        data.setdefault(child, c)

    lines, counts = [], defaultdict(int)
    for sid in sorted(data):
        a = data[sid]
        flags = a["flags"]
        if not flags & set("dhoru"):
            flags.add("x")  # utility: never deals damage or heals
        f = "".join(c for c in ORDER if c in flags)
        fields = [str(a["school"]), f'"{f}"']
        # optional fields; the ones before the last given one get nil placeholders
        extra = [
            f"{a['tick']:g}" if a["tick"] else None,
            str(a["tick_school"]) if a["tick_school"] else None,
            f"{a['duration']:g}" if a["duration"] > 0 else None,
            f"{a['cooldown']:g}" if a["cooldown"] > 0 else None,
        ]
        while extra and extra[-1] is None:
            extra.pop()
        fields += [v if v is not None else "nil" for v in extra]
        name = names.get(sid, "?").replace("\n", " ")
        lines.append(f"    [{sid}] = {{ {', '.join(fields)} }}, -- {name}")
        for c in f:
            counts[c] += 1

    header = [
        f"-- Generated by tools/gen_spelldata.py from the {flavor} build {build}. Do not edit by hand.",
        "-- [spellID] = { schoolMask, flags, tickSeconds, tickSchool, auraDurationSeconds, cooldownSeconds }",
        "--   d direct damage  h direct heal  w weapon-based  n on next swing",
        "--   o damage over time  r heal over time  c channeled  p projectile",
        "--   u effect that may deal damage indirectly (script/trigger)  x never damages or heals",
        "local ADDON, ns = ...",
        f'if ns.FLAVOR ~= "{flavor}" then return end',
        "",
        "ns.SPELL_DATA = {",
    ]
    text = "\n".join(header + lines + ["}", ""])
    open(out, "w", encoding="utf-8", newline="\n").write(text)
    print(f"{flavor}: {len(lines)} spells -> {out} ({len(text) // 1024} KB)")
    print("  flags:", dict(sorted(counts.items())))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavor", choices=sorted(FLAVORS), default="forever")
    ap.add_argument("--all", action="store_true", help="every flavor with its default build")
    ap.add_argument("--build", help="overrides the flavor's default build")
    ap.add_argument("--cache", help="folder to keep downloaded CSVs in")
    args = ap.parse_args()
    for flavor in (sorted(FLAVORS) if args.all else [args.flavor]):
        suffix, default_build = FLAVORS[flavor]
        build = (not args.all and args.build) or default_build
        generate(flavor, build, args.cache, os.path.join(ROOT, f"SpellData_{suffix}.lua"))


if __name__ == "__main__":
    main()
