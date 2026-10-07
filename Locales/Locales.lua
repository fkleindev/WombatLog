local ADDON, ns = ...

-- Translations. Every key is the English text, so a missing translation falls back
-- to English. Each Locales/<code>.lua registers one language; the language picker in
-- the settings lists whatever is registered. Never look up L[...] while a file loads:
-- the language is only known at ADDON_LOADED.

ns.locales = {}

local active = {}
local missing, missingCount = {}, 0

function ns.RegisterLocale(code, name, strings)
    ns.locales[code] = { name = name, strings = strings }
end

ns.L = setmetatable({}, {
    __index = function(_, key)
        local v = active[key]
        if v then return v end
        if active ~= ns.locales.enUS.strings and not missing[key] then
            missing[key] = true
            missingCount = missingCount + 1
        end
        return key
    end,
})

-- client locales that share a translation
local ALIASES = { enGB = "enUS", esMX = "esES" }

local function clientLocale()
    local code = GetLocale and GetLocale() or "enUS"
    code = ALIASES[code] or code
    return ns.locales[code] and code or "enUS"
end

-- choice: "auto" (the game's language) or a registered code
function ns.SetLocale(choice)
    local code = choice
    if code == "auto" or not ns.locales[code] then code = clientLocale() end
    ns.localeCode = code
    active = ns.locales[code].strings
    wipe(missing)
    missingCount = 0
end

function ns.LocaleOptions()
    local list = {}
    for code, l in pairs(ns.locales) do list[#list + 1] = { text = l.name, value = code, raw = true } end
    table.sort(list, function(a, b) return a.text < b.text end)
    table.insert(list, 1, { text = "Automatic (game language)", value = "auto" })
    return list
end

-- Keys looked up since login that the active language doesn't translate.
function ns.MissingTranslations()
    local list = {}
    for k in pairs(missing) do list[#list + 1] = k end
    table.sort(list)
    return list, missingCount
end

-- Names WombatLog makes up itself (melee, pets, the sample fight) stay English inside
-- (records are keyed by them) and are only translated for display. Real spell and
-- mob names come from the game in its own language and pass through unchanged.
local OWN_NAMES = {
    ["Melee"] = true, ["Melee hit"] = true, ["Pet"] = true, ["Healed"] = true, ["Incoming"] = true,
    ["Fireball"] = true, ["Frostbolt"] = true, ["Shadow Bolt"] = true, ["Flash Heal"] = true,
    ["Corruption"] = true, ["Power Word: Shield"] = true, ["Inner Fire"] = true, ["Frost Armor"] = true,
    ["Curse of Weakness"] = true, ["Defias Thug"] = true, ["Clearcasting"] = true,
    ["Riposte"] = true, ["Battle Shout"] = true,
}

function ns.EventName(name)
    if not name then return name end
    if OWN_NAMES[name] then return ns.L[name] end
    local rest = name:match("^Pet: (.+)$")
    if rest then return ns.L["Pet: %s"]:format(OWN_NAMES[rest] and ns.L[rest] or rest) end
    return name
end
