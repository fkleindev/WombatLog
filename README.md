# WombatLog

A combat feed for **World of Warcraft: Forever** (client 1.60.1, interface 16001).
Your combat events show up in a borderless, transparent window that fades in when
combat starts and fades out a few seconds after it ends.

- A scrolling feed of your own combat events: each row has the spell icon, the
  amount and the spell name, colored by school or event type.
- Your outgoing events line up on the left and incoming ones on the right.
- Crits stand out: a bigger gold number with a pop-in animation, a flash and a
  light sweep, a gold icon border and a CRIT tag.
- The header shows live DPS and HPS, a fight timer, damage dealt and taken, and the
  biggest hit of the fight.
- A full settings panel with live preview, color pickers, filters and profiles.

## Installation

1. Download or clone this repository.
2. Copy the folder to `<WoW Forever install>\Interface\AddOns\WombatLog`. The folder
   must contain `WombatLog.toc` and the `Media` folder.
3. Restart the game, or `/reload` if it was already running.

## Usage

| Command | What it does |
| --- | --- |
| `/wl` | Opens the settings (also in Esc > Options > AddOns > WombatLog) |
| `/wl test` | Runs a fake fight so you can see the window outside combat |
| `/wl unlock` / `/wl lock` | Lets you drag the window to a new place |
| `/wl reset` | Resets the current profile to defaults |

While the settings panel is open, the window shows a sample feed that updates as you
change settings.

## Settings

- **Appearance:** window width, row height and spacing, row background opacity
  (0 = fully transparent), spell icons, incoming events on the right or left, newest
  row on top or bottom, dimming of older rows, fonts (built-in plus LibSharedMedia),
  text sizes, outline, short or full numbers, and which header parts to show.
- **Crits:** each crit effect can be turned on or off, plus the pop size and the crit
  number size.
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

## How it works and its limits

Forever uses the same addon restrictions as retail Midnight: addons can't read the
combat log (`COMBAT_LOG_EVENT_UNFILTERED` is blocked). WombatLog builds its feed from
the events that are still allowed:

| Source | Used for |
| --- | --- |
| `UNIT_COMBAT` (player, target) | Damage and heals on you and on your target, misses and avoids |
| `PLAYER_SWING`, `UNIT_SPELLCAST_SUCCEEDED` | Working out which of the hits on your target are yours, and naming them |
| `UNIT_AURA` | Buffs and debuffs gained, applied and faded |
| `CHAT_MSG_COMBAT_XP_GAIN` | Kills |
| `PLAYER_REGEN_DISABLED` / `_ENABLED` | Showing and hiding the window |

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
- **Values the game keeps secret are skipped.** The game hides some values from
  addons during combat, and WombatLog never shows or calculates with them.

## Files

| File | Purpose |
| --- | --- |
| `Core.lua` | Settings defaults, profiles, the fight start/end cycle, filters, slash commands |
| `Sources.lua` | Turns game events into feed entries and decides which hits are yours |
| `Display.lua` | The window, header, rows, animations and live preview |
| `Config.lua` | The settings panel |
| `Media/Gradient.tga` | White-to-transparent texture used for the row backgrounds |

## Reporting problems

Run `/console scriptErrors 1` so errors show on screen, reproduce the problem, and
open an issue with the full error text. Forever is in beta, so its API can change
between builds.
