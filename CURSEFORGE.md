# WombatUI (formerly WombatLog) - A modern UI, built around a better combat log

**A fresh, consistent look for the whole World of Warcraft interface: unit frames, nameplates, action bars, minimap, chat and quest tracker, with a clean live combat feed at its heart.**

> 💬 **Feedback welcome:** WombatUI keeps growing. If something looks odd or you have an idea, please report it on the issue tracker. It helps a lot!

---

## The combat log: what sets WombatUI apart

WombatUI started as a combat log, and that is still its centerpiece. Your combat events show up in a transparent, borderless window that fades in when combat starts and fades out a few seconds after it ends. On Forever and Retail, where addons can't read the combat log any more, WombatUI rebuilds the feed from what the game still allows.

- **Combat feed:** spell icon, amount and name for every hit, colored by school or event type. Outgoing and incoming events each on the left or right, with an optional border around the window.
- **Live header:** DPS, HPS, fight timer, damage dealt and taken, biggest hit.
- **DoT tracking:** each running DoT gets one pinned row that counts up its damage and ticks and shows the time left.
- **Crits that feel good:** bigger gold numbers with a pop-in, flash and light sweep.
- **Crit alerts:** a pop-up over your character and a sound, with crit streaks ("x3 CRIT STREAK") and personal records ("NEW RECORD!").
- **Proc alerts** for buffs you pick, such as Clearcasting.
- **Swing timer** for main hand, off hand and ranged, right in the log window.
- **Fight summary and journal:** fight history, personal records and session stats.

## A modern interface

Rounded panels, soft shadows and smooth animations, the same look everywhere. The game's frames keep working underneath (clicks, menus, Edit Mode, other addons). Each part is off by default, so you switch on just what you want.

- **Unit frames** for you, your pet, your target, its target, your focus and your party: a round, square or no portrait with a level badge and slim bars on a rounded panel. Elite, rare and boss units wear an ornament with a glint and an optional outline, in a style of your choice for each kind (blades, a classic dragon, laurel, crown, flames or a halo of rays), and you can give yourself one of your own. Lost health trails behind the bar, heals flash, low health pulses red, a new target slides in and the portrait shakes when hit; your power bar marks the cost of the spell you cast. Your party gets the look too, with spacing of your choice, their pets, range fading and a preview without a group.
- **Nameplates:** name, level and elite ornament, health, a cast bar, the auras you put on the unit (plus lists of ones to always or never show), raid icon, quest mobs marked, the target highlighted, threat colors (turned around for tanks), an execute mark and smooth, animated bars. Enemies and allies, size and stacking of your choice.
- **Action bars:** rounded corners, your own colors, borders and backgrounds, a panel behind each bar and smooth animations, without the gryphons. Optionally for the bag bar and the micro menu, too. Blizzard's XP bar and quest tracker can be hidden.
- **Minimap:** square with rounded corners or round, the zone name above it, the clock below (local or server time, calendar and stopwatch a click away), your coordinates, mail, tracking, queues and dungeon difficulty in its corners, zoom buttons and zooming back out by itself. The other addons' minimap buttons gather in a drawer beside it, in the same look. Fades in, pulses on new mail and glows in combat.
- **Chat:** a rounded panel behind the game's chat windows, flat tabs, the input box in the color of your channel, a menu instead of the game's buttons (copy the chat, social, channels). Short channel names, timestamps, names in class colors with their level, clickable web links, your name highlighted, a sound on whispers, and fading when idle.
- **Quest tracker:** a modern list of your watched quests, with a bar for every count, progress that lights up, quests that glide in and out and flash when done. Click a quest to follow it (the arrow and waypoint on Retail), fold single quests or the whole list, let it fold up in combat, switch to a compact view with one line per quest, or let it grow upward from a header at the bottom. Quest items get buttons that work in combat.

## In combat

- **Personal resource display:** health, power, druid mana, combo points and a cast bar under your character. Bars in any order, and combo points as a bar, squares, circles or diamonds. While you cast, the power the spell will take shimmers on the bar.
- **Spell reminders:** icons that light up when a spell is usable (Riposte, Overpower, Execute), a buff or debuff is missing or running out, or your target casts something you can interrupt.
- **Range indicator:** a dot or the spell's icon on nameplates, green in range of your spell and red out of range. Enemies and allies each get their own spell, so healers see who they can reach. Works next to other nameplate addons.
- **Global cooldown ring** at the mouse cursor: it runs down during the global cooldown and changes color when the game already takes your next spell.

## Leveling and quests

- **Kill and quest alerts:** XP counting up, "LEVEL UP!", multi-kill counter and a rising sound.
- **XP tracker:** a small XP bar hanging from the top edge of the screen that grows downward, with a glow, when you get XP and shows where it came from ("+342 XP · Defias Thug"). Mouse over it for your exact XP. The bar can move with waves, stripes, a rainbow, sparkles and more.
- **Quest progress:** a card with all objectives of a quest when it moves on. The changed one lights up with a "+1", "kill X" and "collect X" objectives get a filling bar, and the last one done brings "Quest complete!". Quests with a time limit stay on top with a countdown, and the quest you follow can stay up too. Can replace the game's yellow progress text.
- **Flight path timer:** two map pins joined by an arc, your faction's mount flying along it, the time left and when you arrive. Learns the real times as you fly; the flight map's tooltips show the flight time too.
- **Sparkles:** quest objects glitter again on Forever, and the object in front of you (quest object, corpse with loot, herb, ore vein) can get sparks, a glow, an icon with an arrow or a beam of light, in your colors.
- **Session tracker:** XP per hour, time and kills to the next level.

## Bags and tools

- **Quest items:** items your quests still need that aren't quest items themselves (cloth, ore, meat for a turn-in) get a glow and a quest icon in your bags and the quest in their tooltip. A merchant asks before selling one, and offers to buy it back if it went anyway. Works in the game's bags, Bagnon, AdiBags and Baganator.
- **Bag slots:** bags show on their icon how many slots they have, and special bags (herbs, soul shards, leather, quivers, ...) a small icon of what they take.
- **Macro builder:** build macros from blocks: pick a command, add conditions like Shift, @mouseover or in combat as chips and drag spells and items into the slots. Counts the 255 characters, checks spells and conditions and shows live which part would run right now.
- **Custom sounds:** drop your own .ogg or .mp3 files into the addon's `Media\Custom` folder and pick them for any alert.

## Settings

Every feature can be turned off on its own. The settings, a window of their own with a search, show a live preview as you change things. Profiles are included, and a **welcome screen** on each character's first login lets you pick your features and the language.

Available in **English, German, French, Spanish and Italian**. WombatUI follows your game language and can be switched in the settings.

## Supported clients

| Client | Combat data |
|--------|-------------|
| Classic Era (incl. Hardcore, Season of Discovery) | Exact, from the combat log |
| TBC Anniversary | Exact, from the combat log |
| Mists of Pandaria Classic | Exact, from the combat log |
| WoW Forever | Estimated from the events addons may still read |
| Retail (Midnight) | Estimated, best effort |

## Forever & Retail: limitations and workarounds

On the Classic clients WombatUI reads the full combat log, so every hit is exact. Forever and Retail use the Midnight addon rules: **addons can't read the combat log**, and some values (like your health, power, attack speed or auras) are **kept secret during combat**. WombatUI works around this as well as it can:

- **Rebuilding the feed:** it uses the events that are still allowed: hits on you and your target, your swings and your casts. Each hit on your target is matched to the swing or cast most likely behind it, by timing, cast order and damage school.
- **Built-in spell data:** every class spell of every rank ships with its school, DoT ticks and duration, generated from each client's own game data. Matching is right from the first cast. Anything missing (pets, items, racials) is learned as you play and saved for all your characters.
- **Secret values:** they go straight to the game's own bars, so health, power and combo points still fill correctly in combat. Only the numbers in the text may disappear.
- **Secret damage numbers (Forever):** the feed and crit alerts still show every hit's real number. DPS and totals come from Blizzard's damage meter. Records, the biggest hit and the minimum-amount filters pause while the numbers are secret.
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
| `/wl welcome` | Open the welcome screen again |
| `/wl test` | Run a fake fight to see everything outside combat |
| `/wl journal` | Open the fight journal |
| `/wl macro` | Open the macro builder |
| `/wl unlock` / `/wl lock` | Move the window |
| `/wl reset` | Reset the current profile |

---

## 🤖 AI disclaimer

I'm a software developer, but I had no prior experience with Lua or the WoW addon API. WombatUI was built with the help of an AI coding assistant.

I want to be upfront about that. If you spot code that could be done better, feedback and contributions are very welcome.

## Feedback & source

The source code is on GitHub (MIT license): [https://github.com/fkleindev/WombatLog](https://github.com/fkleindev/WombatLog)

Bug reports and ideas: [https://github.com/fkleindev/WombatLog/issues](https://github.com/fkleindev/WombatLog/issues)
