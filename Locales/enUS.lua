local ADDON, ns = ...

-- English is the source language: every key already is its English text.
--
-- Adding a language:
--   1. Copy Locales/deDE.lua to Locales/<code>.lua, using the game's locale code
--      (frFR, ptBR, ruRU, ...).
--   2. Change the RegisterLocale line to your code and the language's own name.
--   3. Translate the values on the right. Keep every %s, %d and %.1f in the same order.
--   4. Add the file to WombatLog.toc under the other Locales lines.
--   5. Check it with: python3 tools/check_locales.py
-- It then shows up in the language picker by itself.

ns.RegisterLocale("enUS", "English", {})
