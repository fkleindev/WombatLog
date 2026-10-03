# WombatLog

A combat feed for **World of Warcraft: Forever** (client 1.60.1, interface 16001).
Your combat events show up in a borderless, transparent window that fades in when
combat starts and fades out a few seconds after it ends.

- A scrolling feed of your own combat events: each row has the spell icon, the
  amount and the spell name, colored by school or event type.
- Your outgoing events line up on the left and incoming ones on the right.
- Crits stand out: a bigger gold number with a pop-in animation, a flash and a
  light sweep, a gold icon border and a CRIT tag.
- **Crit alerts**, both optional and independent of each other: a pop-up over your
  character and a sound whenever you land a crit.
- **Crit streaks and records:** crits in a row grow a "x3 CRIT STREAK" banner with a
  rising sound, and beating a personal record shows "NEW RECORD!" with a fanfare.
- **Proc alerts** for buffs you choose, such as Clearcasting.
- **Personal resource display** under your character: health, power, druid mana,
  combo points and a cast bar.
- **Swing timer** built into the log window, for main hand, off hand and ranged
  auto-attacks.
- **Fight summary** after each fight, plus a **journal** with your fight history,
  personal records and session stats.
- **Session tracker** for leveling: XP per hour, time and kills to the next level,
  kills, deaths and money.
- **Minimap button** and an addon compartment entry.
- The header shows live DPS and HPS, a fight timer, damage dealt and taken, and the
  biggest hit of the fight.
- A full settings panel with live preview, color pickers, filters and profiles.

Every extra feature can be turned off on its own in the settings.

## Installation

1. Download or clone this repository.
2. Copy the folder to `<WoW Forever install>\Interface\AddOns\WombatLog`. The folder
   must contain `WombatLog.toc` and the `Media` folder.
3. Restart the game, or `/reload` if it was already running.

## Usage

| Command | What it does |
| --- | --- |
| `/wl` | Opens the settings (also in Esc > Options > AddOns > WombatLog) |
| `/wl test` | Runs a fake fight (with a crit streak, a sample record and a proc) so you can see everything outside combat |
| `/wl journal` | Opens the journal: fight history, records, session |
| `/wl session` / `/wl session reset` | Shows or resets the current session |
| `/wl unlock` / `/wl lock` | Lets you drag the window to a new place |
| `/wl reset` | Resets the current profile to defaults |
| `/wl trace` | Prints the raw hits, casts and swings to chat with timestamps (toggle) |
| `/wl debug` | Shows whether your health and power are readable right now |

While the settings panel is open, the window shows a sample feed that updates as you
change settings.

## Settings

- **Appearance:** window width, row height and spacing, row background opacity
  (0 = fully transparent), spell icons, incoming events on the right or left, newest
  row on top or bottom, dimming of older rows, fonts (built-in plus LibSharedMedia),
  text sizes, outline, short or full numbers, and which header parts to show.
- **Crits:** each crit effect can be turned on or off, plus the pop size and the crit
  number size.
- **Alerts:** the visual and the sound crit alert, crit streaks and the record
  alert (see below).
- **Procs:** proc alerts on/off, the buffs to watch (type a name or spell ID, or
  pick from the buffs you gained recently), sound, size, color and position.
- **Swing timer:** on/off, off-hand and ranged bars, time left, lane height and
  colors.
- **Resource display:** on/off, when it shows, fade times, opacity, position, size,
  bar texture, gloss, border and background, plus its own section for each bar
  (health, power, druid mana, combo points, cast bar) with on/off, height, colors
  and text.
- **Stats & history:** fight summary (display time, scale, position), fight
  history (how many fights to keep, minimum fight length) and personal records.
- **Session & minimap:** session tracker, an optional session line above the log
  window, and the minimap button.
- **Colors:** each event type, the crit highlight and the seven damage schools.
- **Position:** drag to move, X/Y position, scale, window opacity and frame layer.
- **Behaviour:**
  - when the window shows (only in combat or always), how long it stays after
    combat, fade times
  - max rows, and whether to clear the log when a new fight starts
  - which event types to show
  - minimum amounts, "only crits" filters, and the strict group filter
- **Profiles:** all your characters share the same list of profiles, and each
  character remembers which one it uses. You can create, copy, delete and reset
  profiles.

## Crit alerts

Both alerts trigger on your own damage and heal crits. They don't depend on the log
window, its filters or "only crits" settings, and each has its own on/off switch in
**Settings → Alerts**.

- **Visual alert:** a pop-up over your character with the spell icon, the crit amount
  and the spell name, plus a glow burst. You can set the display time, number size,
  scale and color, and turn the icon, name and glow on or off. Unlock it to drag it
  anywhere.
- **Sound alert:** comes with three sounds made for WombatLog (Chime, Coin, Impact),
  plus some built-in WoW sounds and any LibSharedMedia sounds. Picking a sound in the
  list plays it. You can choose the sound channel and a minimum time between sounds,
  so multi-crits don't stack up.
- Both alerts have a minimum amount and an option to include heal crits.
- **Crit streaks:** from your second crit in a row, the visual alert shows a
  "x2 CRIT STREAK" banner that grows and changes color (gold, orange, red with a pulse
  from x5). The sound can rise in pitch with the streak. Any normal hit or miss ends
  the streak.
- **Record alert:** when a hit beats one of your personal records, the alert shows
  "NEW RECORD!" and plays a short fanfare. Banner and sound can be turned off
  separately.

## Proc alerts

A second alert window, independent of the crit alert, that pops up whenever you gain a
buff from your list. In **Settings → Procs** you can type a buff name or spell ID, or
add a buff from the "Recently gained buffs" list. The alert has its own sound,
duration, size, color and position.

## Swing timer

A thin lane in the log window, right under the header, that restarts with every
auto-attack: main hand, off hand (when dual wielding) and ranged (Auto Shot, wands).
When several run at the same time they share the lane, so the feed below never
shifts. Durations come from your current weapon speed. The lane moves, scales and
fades with the log window; turning the swing timer off removes it from the window.

## Personal resource display

A compact stack of bars under your character, styled like the rest of WombatLog:

- **Health:** class color or your own color, with optional text on the left and
  right: value, value/max, percent or missing.
- **Power:** mana, rage, energy or focus, colored by type, with the same text
  options.
- **Druid mana:** a thin mana bar while you're in bear or cat form.
- **Combo points:** a segmented bar for rogues and druids in cat form.
- **Cast bar:** spell icon, name and time left. It turns grey for uninterruptible
  casts and shows "Interrupted" in red when a cast is cut off.

By default it shows while you're in combat or while your health or power isn't full
(rage counts while it's above 0), and it fades out otherwise. You can also show it
only in combat, or always. Every bar can be turned off on its own, and the whole
display has its own switch.

In combat the game keeps your own health and power secret from addons. The bars
still fill correctly because the game draws them directly, but the numbers in the
text may disappear while you fight. Out of combat they're exact.

## Fight summary and journal

After each fight a small card shows duration, DPS, HPS, crit rate, biggest hit,
longest crit streak, your top five spells and any new records. Click it to open the
fight in the journal, right-click to close it, and drag it to move it.

The **journal** (`/wl journal`, or click the minimap button) has three tabs:

- **Fights:** your recent fights with a full spell breakdown: total, share, hits,
  crit rate, average and maximum.
- **Records:** best normal hit and best crit per spell, best DPS (from fights of at
  least 10 s by default) and longest crit streak.
- **Session:** session time, time in combat, fights, kills, deaths, XP gained, XP
  per hour, time and kills to the next level, rested XP and money.

History, records and the session are saved per character. A `/reload` continues the
session, and logging in again starts a new one. Test fights are never saved.

## How it works and its limits

Forever uses the same addon restrictions as retail Midnight: addons can't read the
combat log (`COMBAT_LOG_EVENT_UNFILTERED` is blocked). WombatLog builds its feed from
the events that are still allowed:

| Source | Used for |
| --- | --- |
| `UNIT_COMBAT` (player, target) | Damage and heals on you and on your target, misses and avoids |
| `PLAYER_SWING`, `UNIT_SPELLCAST_SUCCEEDED` | Working out which of the hits on your target are yours, and naming them |
| `UNIT_AURA` | Buffs and debuffs gained, applied and faded; proc alerts |
| `PLAYER_SWING`, `UnitAttackSpeed` | Swing timer |
| `CHAT_MSG_COMBAT_XP_GAIN`, `PLAYER_XP_UPDATE` | Kills, XP per kill and per hour |
| `PLAYER_MONEY`, `PLAYER_DEAD` | Session money and deaths |
| `PLAYER_REGEN_DISABLED` / `_ENABLED` | Showing and hiding the window |

### How hits are matched to your abilities

Every hit on your target is matched to the swing or cast most likely behind it:

- **Built-in spell data:** WombatLog ships the facts for every class spell of all
  classes and all ranks, generated from the WoW Forever game data: damage school,
  direct damage or heal, damage over time with its tick interval, channeling,
  "on next swing" and projectiles, and spells that never deal damage (Hunter's
  Mark, Concussive Shot, seals). These are right from the first cast. Learning only
  fills in what isn't in the table, such as pets, items and racials.

- **Order:** hits arrive in the order you cast, so the oldest unused cast wins,
  and each hit uses up its cast.
- **School:** WombatLog learns each spell's damage school and its usual delay
  from cast to hit, but only from clear cases where just one cast was in flight.
  After that, a holy hit goes to Judgement and a physical one to Crusader Strike,
  even when both were cast within a split second.
- **Spells that never hit**, such as buffs, seals and auras, are recognised after a
  few casts and no longer claim hits.
- **On-hit procs:** spell damage arriving together with a swing is shown as a proc,
  for paladins named after the active seal.
- **Ranged auto attacks** (Auto Shot, wands) are matched like spells, so every
  arrow shows up under its own name instead of being added to another ability.
- **Damage over time:** most DoTs tick every 3 seconds from when they were
  applied, so a tick is matched to the debuff of yours whose timing fits. The
  timing comes from the debuff itself when the game lets addons read it, and
  otherwise from your cast (in combat on Forever, debuffs are often hidden). WombatLog
  also learns each DoT's damage school. Serpent Sting ticks therefore stay Serpent
  Sting even after you put Hunter's Mark on the target, and a debuff that never
  ticks doesn't take them.
- **Combined hits:** sometimes the game reports two abilities as one hit. When a
  damage spell gets no hit of its own but another hit landed in its window, the row
  shows both abilities' icons and names (for example "Crusader Strike + Judgement");
  with more than two, a "+N" counts the rest. Combined hits don't count toward
  personal records.

What WombatLog has learned is saved for all your characters and keeps improving as
you play. `/wl trace` shows what the game actually reports.

As a result:

- **Only your target, you and your pet are visible.** AoE hits on mobs you haven't
  targeted, and heals on party members you haven't targeted, can't be seen by
  addons.
- **In a group, deciding which hits are yours is a best guess.** A hit on your
  target counts as yours when it lands right after your own swing or cast. With the
  strict group filter on (the default), hits that don't match are dropped. With it
  off, they're shown dimmed and don't count toward your DPS.
- **Damage-over-time ticks and pet hits** are named by a best guess: your most recent
  debuff on the target, or "Pet". In a group, they usually don't match anything and
  are dropped.
- **Statistics only cover what WombatLog can see**, so DPS, records and the spell
  breakdown leave out AoE hits on mobs you haven't targeted.
- **Swing timer:** the game doesn't tell addons about parry haste or swing resets, so
  the bar can be off by a little in those cases.
- **Values the game keeps secret are skipped.** The game hides some values from
  addons during combat, and WombatLog never shows or calculates with them.

## Files

| File | Purpose |
| --- | --- |
| `Core.lua` | Settings defaults, profiles, the fight start/end cycle, filters, slash commands |
| `SpellData.lua` | Generated facts for every class spell (school, DoT ticks, channels, …) |
| `Sources.lua` | Turns game events into feed entries and decides which hits are yours |
| `Display.lua` | The window, header, rows, animations and live preview |
| `Stats.lua` | Fight statistics, history, records, crit streaks and the session tracker |
| `Alerts.lua` | Crit, streak, record and proc alerts (visual and sound) |
| `Report.lua` | Fight summary card and the journal window |
| `Swing.lua` | Swing timer lane inside the log window |
| `Resources.lua` | Personal resource display |
| `Minimap.lua` | Minimap button and addon compartment entry |
| `Config.lua` | The settings panel |
| `Media/Gradient.tga` | White-to-transparent texture used for the row backgrounds |
| `Media/Glow.tga` | Radial glow used by the crit alert |
| `Media/Sounds/*.ogg` | Alert sounds (crit, streak, record, proc) |
| `tools/gen_spelldata.py` | Regenerates `SpellData.lua` from a WoW Forever build's game data (via wago.tools) |
| `tools/gen_media.py` | Regenerates everything in `Media` (`pip install numpy soundfile`) |

## Reporting problems

Run `/console scriptErrors 1` so errors show on screen, reproduce the problem, and
open an issue with the full error text. Forever is in beta, so its API can change
between builds.
