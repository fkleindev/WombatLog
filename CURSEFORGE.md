# WombatLog - A better Combat Log

**A clean, borderless combat feed for World of Warcraft, with live DPS/HPS, crit alerts, kill alerts, a resource display and a fight journal.**

> ⚠️ **In active development** WombatLog is in an early development stage. Features may change, settings may be reset between versions, and you will probably run into bugs. Please report anything odd on the issue tracker. It helps a lot!

---

## What it does

Your combat events show up in a transparent, borderless window that fades in when combat starts and fades out a few seconds after it ends.

- **Combat feed:** spell icon, amount and name for every hit, colored by school or event type. Outgoing events on the left, incoming on the right.
- **DoT tracking:** each running DoT gets one pinned row that counts up its damage and ticks and shows the time left.
- **Crits that feel good:** bigger gold numbers with a pop-in, flash and light sweep.
- **Crit alerts:** a pop-up over your character and a sound, with crit streaks ("x3 CRIT STREAK") and personal records ("NEW RECORD!").
- **Proc alerts** for buffs you pick, such as Clearcasting.
- **Spell reminders:** icons that light up when a spell is usable (Riposte, Overpower, Execute), a buff or debuff is missing or running out, or your target casts something you can interrupt.
- **Kill and quest alerts:** XP counting up, "LEVEL UP!", multi-kill counter and a rising sound.
- **XP tracker:** a small XP bar hanging from the top edge of the screen that grows downward, with a glow, when you get XP.
- **Personal resource display:** health, power, druid mana, combo points and a cast bar under your character. Bars in any order, and combo points as a bar, squares, circles or diamonds.
- **Swing timer** for main hand, off hand and ranged.
- **Fight summary and journal:** fight history, personal records and session stats.
- **Session tracker** for leveling: XP per hour, time and kills to the next level.
- **Live header:** DPS, HPS, fight timer, damage dealt and taken, biggest hit.

Every feature can be turned off on its own, and the full settings panel shows a live preview as you change things. Profiles are included.

Available in **English, German, French, Spanish and Italian**. WombatLog follows your game language and can be switched in the settings.

## Supported clients

| Client | Combat data |
|--------|-------------|
| Classic Era (incl. Hardcore, Season of Discovery) | Exact, from the combat log |
| TBC Anniversary | Exact, from the combat log |
| Mists of Pandaria Classic | Exact, from the combat log |
| WoW Forever | Estimated from the events addons may still read |
| Retail (Midnight) | Estimated, best effort |

## Forever & Retail: limitations and workarounds

On the Classic clients WombatLog reads the full combat log, so every hit is exact. Forever and Retail use the Midnight addon rules: **addons can't read the combat log**, and some values (like your health, power, attack speed or auras) are **kept secret during combat**. WombatLog works around this as well as it can:

- **Rebuilding the feed:** it uses the events that are still allowed: hits on you and your target, your swings and your casts. Each hit on your target is matched to the swing or cast most likely behind it, by timing, cast order and damage school.
- **Built-in spell data:** every class spell of every rank ships with its school, DoT ticks and duration, generated from each client's own game data. Matching is right from the first cast. Anything missing (pets, items, racials) is learned as you play and saved for all your characters.
- **Secret values:** they go straight to the game's own bars, so health, power and combo points still fill correctly in combat. Only the numbers in the text may disappear.
- **Swing timer:** it remembers your weapon speed from outside combat and adjusts to the real gap between your swings, so haste buffs are picked up mid-fight.
- **Spell reminders:** they carry on from what they last saw and from your own casts while auras are hidden.

What this means in practice:

- Only you, your target and your pet are visible. AoE hits on other mobs don't show up, and DPS leaves them out.
- In groups, deciding which hits on your target are yours is a best guess. By default, hits that don't clearly match your swings or casts are left out.
- DoT ticks and pet hits are named by a best guess.

`/wl trace` shows what the game actually reports, if you want to look under the hood.

## Commands

| Command | What it does |
|---------|--------------|
| `/wl` | Open the settings |
| `/wl test` | Run a fake fight to see everything outside combat |
| `/wl journal` | Open the fight journal |
| `/wl unlock` / `/wl lock` | Move the window |
| `/wl reset` | Reset the current profile |

---

## 🤖 AI disclaimer

I'm a software developer, but I had no prior experience with Lua or the WoW addon API. WombatLog was built with the help of an AI coding assistant.

I want to be upfront about that. If you spot code that could be done better, feedback and contributions are very welcome.

## Feedback & source

The source code is on GitHub (MIT license): [https://github.com/fkleindev/WombatLog](https://github.com/fkleindev/WombatLog)

Bug reports and ideas: [https://github.com/fkleindev/WombatLog/issues](https://github.com/fkleindev/WombatLog/issues)
