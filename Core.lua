local ADDON, ns = ...
_G.WombatLog = ns

ns.defaults = {
    appearance = {
        width = 300, rowHeight = 22, rowGap = 2,
        amountFont = "Fonts\\FRIZQT__.TTF", nameFont = "Fonts\\ARIALN.TTF",
        amountSize = 14, nameSize = 13, critSize = 20,
        outline = "OUTLINE",     -- "OUTLINE" | "THICKOUTLINE" | ""
        rowBgOpacity = 0.42,     -- 0 = rows fully transparent
        showIcons = true,
        mirrorIncoming = true,   -- incoming rows right-aligned
        newestOnTop = false,
        ageDim = true,
        numberFormat = "full",   -- "full" | "short"
        header = { show = true, dps = true, hps = true, timer = true, totals = true, biggest = true },
    },
    crit = {
        pop = true, popScale = 1.5, shine = true, flash = true,
        glow = true, iconBorder = true, tag = true,
    },
    colors = {
        crit      = { 1.00, 0.82, 0.18 },
        heal      = { 0.35, 1.00, 0.45 },
        healIn    = { 0.55, 1.00, 0.60 },
        taken     = { 1.00, 0.30, 0.25 },
        avoid     = { 0.70, 0.70, 0.70 },
        cast      = { 0.60, 0.80, 1.00 },
        buff      = { 1.00, 0.82, 0.20 },
        debuffIn  = { 0.78, 0.40, 1.00 },
        debuffOut = { 0.78, 0.40, 1.00 },
        fade      = { 0.55, 0.55, 0.55 },
        kill      = { 1.00, 0.55, 0.15 },
        schools = {
            [1] = { 1.00, 0.93, 0.80 }, [2] = { 1.00, 0.90, 0.50 }, [4] = { 1.00, 0.50, 0.00 },
            [8] = { 0.30, 1.00, 0.30 }, [16] = { 0.50, 1.00, 1.00 }, [32] = { 0.62, 0.52, 1.00 },
            [64] = { 1.00, 0.50, 1.00 },
        },
    },
    position = { x = 320, y = -140, scale = 1, alpha = 1, strata = "MEDIUM" },
    behaviour = {
        visibility = "combat",   -- "combat" | "always"
        linger = 5, fadeIn = 0.25, fadeOut = 1.0,
        lines = 10,
        strict = true,           -- in groups, drop target hits that can't be matched to your swing/cast
        show = {
            damage = true, heal = true, avoid = true, taken = true, healIn = true, cast = true,
            buff = true, debuffIn = true, debuffOut = true, fade = true, kill = true,
        },
        minAmountOut = 0, minAmountIn = 0,
        hideNormalOut = false, hideNormalIn = false, -- only show crits for hits/heals
    },
}

ns.fight = { active = false, start = 0, stop = nil, damage = 0, healing = 0, taken = 0 }
ns.locked = true

-- School bitmask -> display name
ns.SCHOOL_NAMES = {
    [1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature",
    [16] = "Frost", [32] = "Shadow", [64] = "Arcane",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Forever (Midnight rules) hands out "secret" values that error on compare/math.
function ns.Safe(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

function ns.SafeTable(t)
    if type(t) ~= "table" then return nil end
    if issecrettable and issecrettable(t) then return nil end
    return t
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fd1ffWombatLog|r: " .. msg)
end

function ns.Short(n)
    if n >= 1e6 then return string.format("%.2fm", n / 1e6) end
    if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

function ns.Full(n)
    n = math.floor(n + 0.5)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

function ns.CopyTable(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = ns.CopyTable(v) end
    return c
end

-- Adds every key of src that dst lacks, recursing into nested tables.
local function fillDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = ns.CopyTable(v)
        elseif type(v) == "table" and type(dst[k]) == "table" then
            fillDefaults(dst[k], v)
        end
    end
end

local spellCache = {}

-- Cached { name, icon } for a spell ID, or nil while the client is still loading it.
function ns.SpellInfo(id)
    id = ns.Safe(id)
    if not id then return nil end
    local cached = spellCache[id]
    if cached then return cached end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    info = ns.SafeTable(info)
    local name = info and ns.Safe(info.name)
    if name then
        cached = { name = name, icon = ns.Safe(info.iconID) or ns.Safe(info.originalIconID) or 134400 }
        spellCache[id] = cached
        return cached
    end
    if C_Spell and C_Spell.RequestLoadSpellData then
        C_Spell.RequestLoadSpellData(id)
    end
    return nil
end

---------------------------------------------------------------------------
-- Events: one frame, one handler per event
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn then fn(...) end
end)

-- Registers fn for event; extra args make it a unit event. Returns false if the
-- client refuses the event (some are restricted or missing on Forever).
function ns.Listen(event, fn, ...)
    handlers[event] = fn
    local ok
    if select("#", ...) > 0 then
        ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, event, ...)
    else
        ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
    end
    if not ok then handlers[event] = nil end
    return ok
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------

local Profiles = {}
ns.Profiles = Profiles
local charKey

-- Pushes the active settings to the window, and to the panel when refreshPanel is set.
function ns.ApplyAll(refreshPanel)
    ns.Display:ApplySettings()
    if refreshPanel and ns.Config then ns.Config:RefreshAll() end
end

local function activate()
    local name = WombatLogDB.chars[charKey]
    if not WombatLogDB.profiles[name] then
        name = "Default"
        WombatLogDB.profiles.Default = WombatLogDB.profiles.Default or {}
        WombatLogDB.chars[charKey] = name
    end
    ns.db = WombatLogDB.profiles[name]
    fillDefaults(ns.db, ns.defaults)
end

-- Turns the pre-profile flat save into the Default profile.
local function migrate(old)
    local p = {}
    if old.point == "CENTER" or old.point == nil then
        p.position = { x = old.x, y = old.y, scale = old.scale }
    else
        p.position = { scale = old.scale }
    end
    p.behaviour = { lines = old.lines, strict = old.strict, linger = old.linger }
    if old.auras == false then
        p.behaviour.show = { buff = false, debuffIn = false, debuffOut = false, fade = false }
    end
    return { profiles = { Default = p }, chars = {} }
end

function Profiles.List()
    local list = {}
    for name in pairs(WombatLogDB.profiles) do list[#list + 1] = name end
    table.sort(list)
    return list
end

function Profiles.Current()
    return WombatLogDB.chars[charKey]
end

function Profiles.Set(name)
    if not WombatLogDB.profiles[name] then return false end
    WombatLogDB.chars[charKey] = name
    activate()
    ns.ApplyAll(true)
    return true
end

function Profiles.New(name, copyFrom)
    name = name and strtrim(name) or ""
    if name == "" or WombatLogDB.profiles[name] then return false end
    local source = copyFrom and WombatLogDB.profiles[copyFrom]
    WombatLogDB.profiles[name] = source and ns.CopyTable(source) or {}
    return Profiles.Set(name)
end

function Profiles.Delete(name)
    if name == Profiles.Current() or not WombatLogDB.profiles[name] then return false end
    WombatLogDB.profiles[name] = nil
    -- other characters on this profile fall back to Default on their next login
    return true
end

function Profiles.Reset()
    wipe(ns.db)
    activate()
    ns.ApplyAll(true)
end

---------------------------------------------------------------------------
-- Fight lifecycle
---------------------------------------------------------------------------

function ns.Elapsed()
    local f = ns.fight
    if f.start == 0 then return 0 end
    return (f.stop or GetTime()) - f.start
end

function ns.AddStat(key, amount)
    if ns.fight.active and amount and amount > 0 then
        ns.fight[key] = ns.fight[key] + amount
    end
end

function ns.StartFight()
    local f = ns.fight
    if f.active then return end
    if ns.lingerTimer then ns.lingerTimer:Cancel(); ns.lingerTimer = nil end
    f.active, f.start, f.stop = true, GetTime(), nil
    f.damage, f.healing, f.taken = 0, 0, 0
    f.top = nil
    ns.Display:Clear() -- every fight starts with an empty feed
    ns.lingering = false
    ns.Display:UpdateVisibility()
end

function ns.EndFight()
    local f = ns.fight
    if not f.active then return end
    f.active, f.stop = false, GetTime()
    ns.lingering = true
    ns.Display:UpdateHeader()
    if ns.lingerTimer then ns.lingerTimer:Cancel() end
    ns.lingerTimer = C_Timer.NewTimer(ns.db.behaviour.linger, function()
        ns.lingerTimer = nil
        ns.lingering = false
        ns.Display:UpdateVisibility()
    end)
end

local HIT_KINDS = { damage = true, heal = true, taken = true, healIn = true }

-- Applies the behaviour filters. Stats are counted before this, so hidden rows still add to DPS/HPS.
function ns.ShouldShow(e)
    local b = ns.db.behaviour
    if not b.show[e.kind] then return false end
    if e.amount and HIT_KINDS[e.kind] then
        local minAmount, hideNormal
        if e.dir == "in" then
            minAmount, hideNormal = b.minAmountIn, b.hideNormalIn
        else
            minAmount, hideNormal = b.minAmountOut, b.hideNormalOut
        end
        if e.amount < minAmount then return false end
        if hideNormal and not e.crit then return false end
    end
    return true
end

-- Entry point for everything that wants a row in the feed.
function ns.Emit(entry)
    if not (ns.fight.active or ns.lingering) then
        if ns.Safe(UnitAffectingCombat("player")) then
            ns.StartFight() -- the first hit can arrive before PLAYER_REGEN_DISABLED
        else
            return
        end
    end
    if ns.ShouldShow(entry) then ns.Display:Push(entry) end
end

---------------------------------------------------------------------------
-- Sample data: /wl test and the settings preview
---------------------------------------------------------------------------

local I = "Interface\\Icons\\"
local TEST_ENTRIES = {
    { kind = "damage", dir = "out", name = "Fireball", icon = I .. "Spell_Fire_Fireball02", school = 4, min = 300, max = 520 },
    { kind = "damage", dir = "out", name = "Frostbolt", icon = I .. "Spell_Frost_FrostBolt02", school = 16, min = 250, max = 420 },
    { kind = "damage", dir = "out", name = "Shadow Bolt", icon = I .. "Spell_Shadow_ShadowBolt", school = 32, min = 280, max = 460 },
    { kind = "damage", dir = "out", name = "Melee", icon = I .. "INV_Sword_04", school = 1, min = 80, max = 160 },
    { kind = "heal", dir = "out", name = "Flash Heal", icon = I .. "Spell_Holy_FlashHeal", school = 2, min = 400, max = 650 },
    { kind = "taken", dir = "in", name = "Melee hit", icon = I .. "Ability_Warrior_DefensiveStance", school = 1, min = 40, max = 130 },
    { kind = "avoid", dir = "out", name = "Melee", icon = I .. "INV_Sword_04", tag = "DODGE" },
    { kind = "debuffOut", dir = "out", name = "Corruption", icon = I .. "Spell_Shadow_AbominationExplosion" },
    { kind = "buff", dir = "in", name = "Power Word: Shield", icon = I .. "Spell_Holy_PowerWordShield" },
}

-- Fixed set for the settings preview, oldest first: every row kind, both sides, two crits.
ns.PREVIEW_ENTRIES = {
    { kind = "fade", dir = "in", name = "Inner Fire", icon = I .. "Spell_Holy_InnerFire" },
    { kind = "cast", dir = "out", name = "Frost Armor", icon = I .. "Spell_Frost_FrostArmor02" },
    { kind = "debuffIn", dir = "in", name = "Curse of Weakness", icon = I .. "Spell_Shadow_CurseOfMannoroth" },
    { kind = "debuffOut", dir = "out", name = "Corruption", icon = I .. "Spell_Shadow_AbominationExplosion" },
    { kind = "buff", dir = "in", name = "Power Word: Shield", icon = I .. "Spell_Holy_PowerWordShield" },
    { kind = "damage", dir = "out", name = "Melee", icon = I .. "INV_Sword_04", school = 1, amount = 142 },
    { kind = "healIn", dir = "in", name = "Healed", icon = I .. "Spell_Holy_Heal", amount = 420 },
    { kind = "avoid", dir = "out", name = "Melee", icon = I .. "INV_Sword_04", tag = "DODGE" },
    { kind = "damage", dir = "out", name = "Frostbolt", icon = I .. "Spell_Frost_FrostBolt02", school = 16, amount = 386 },
    { kind = "taken", dir = "in", name = "Melee hit", icon = I .. "Ability_Warrior_DefensiveStance", school = 1, amount = 96 },
    { kind = "heal", dir = "out", name = "Flash Heal", icon = I .. "Spell_Holy_FlashHeal", school = 2, amount = 1310, crit = true },
    { kind = "damage", dir = "out", name = "Shadow Bolt", icon = I .. "Spell_Shadow_ShadowBolt", school = 32, amount = 512 },
    { kind = "kill", dir = "out", name = "Defias Thug", icon = I .. "Ability_Rogue_Eviscerate" },
    { kind = "damage", dir = "out", name = "Fireball", icon = I .. "Spell_Fire_Fireball02", school = 4, amount = 1248, crit = true },
}

function ns.StopTest()
    if ns.testTicker then ns.testTicker:Cancel(); ns.testTicker = nil end
    ns.testing = false
end

function ns.RunTest()
    if ns.Safe(UnitAffectingCombat("player")) then
        ns.Print("can't run the test while in combat.")
        return
    end
    ns.StopTest()
    ns.fight.active = false
    ns.StartFight()
    ns.testing = true
    local runs = 0
    ns.testTicker = C_Timer.NewTicker(0.45, function()
        runs = runs + 1
        local t = TEST_ENTRIES[math.random(#TEST_ENTRIES)]
        local e = { kind = t.kind, dir = t.dir, name = t.name, icon = t.icon, school = t.school, tag = t.tag }
        if t.min then
            e.crit = math.random() < 0.25
            e.amount = math.random(t.min, t.max) * (e.crit and 2 or 1)
            if t.kind == "damage" then ns.AddStat("damage", e.amount)
            elseif t.kind == "heal" then ns.AddStat("healing", e.amount)
            elseif t.kind == "taken" then ns.AddStat("taken", e.amount) end
        end
        if ns.ShouldShow(e) then ns.Display:Push(e) end
        if runs >= 24 then
            ns.StopTest()
            ns.EndFight()
        end
    end, 24)
end

---------------------------------------------------------------------------
-- Init, combat state, slash commands
---------------------------------------------------------------------------

ns.Listen("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    if not WombatLogDB then
        WombatLogDB = { profiles = {}, chars = {} }
    elseif not WombatLogDB.profiles then
        WombatLogDB = migrate(WombatLogDB)
    end
    WombatLogDB.chars = WombatLogDB.chars or {}
    charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    activate()
    ns.Display:Init()
    if ns.Config then ns.Config:Init() end
end)

ns.Listen("PLAYER_ENTERING_WORLD", function()
    if ns.Safe(UnitAffectingCombat("player")) then ns.StartFight() end
end)

ns.Listen("PLAYER_REGEN_DISABLED", function()
    if ns.testing then
        ns.StopTest()
        ns.fight.active = false
    end
    ns.StartFight()
end)

ns.Listen("PLAYER_REGEN_ENABLED", function()
    ns.EndFight()
end)

SLASH_WOMBATLOG1 = "/wl"
SLASH_WOMBATLOG2 = "/wombatlog"
SlashCmdList.WOMBATLOG = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()

    if cmd == "" or cmd == "config" or cmd == "options" then
        ns.Config:Open()
    elseif cmd == "unlock" then
        ns.Display:SetLocked(false)
        ns.Print("unlocked - drag the window, then /wl lock.")
    elseif cmd == "lock" then
        ns.Display:SetLocked(true)
        ns.Print("locked.")
    elseif cmd == "test" then
        ns.RunTest()
    elseif cmd == "reset" then
        ns.Profiles.Reset()
        ns.Print("profile '" .. ns.Profiles.Current() .. "' reset to defaults.")
    else
        ns.Print("/wl - settings, /wl test - preview fight, /wl unlock | lock - move, /wl reset - reset profile")
    end
end
