local ADDON, ns = ...
_G.WombatLog = ns

-- Which game client this is, from its interface number. Picks the matching
-- SpellData_<Flavor>.lua and the combat data source.
local INTERFACE = select(4, GetBuildInfo()) or 0
if INTERFACE >= 100000 then
    ns.FLAVOR = "retail"
elseif INTERFACE >= 50000 and INTERFACE < 60000 then
    ns.FLAVOR = "mists"
elseif INTERFACE >= 20000 and INTERFACE < 30000 then
    ns.FLAVOR = "tbc"
elseif INTERFACE >= 10000 and INTERFACE < 16000 then
    ns.FLAVOR = "vanilla"
else
    ns.FLAVOR = "forever" -- 16xxx, and the closest data for anything unknown
end
ns.isForever = ns.FLAVOR == "forever"
ns.isRetail = ns.FLAVOR == "retail"

-- Classic clients still hand addons the full combat log: exact sources, targets,
-- spell IDs and aura ends. Forever and Retail (Midnight rules) don't, so there the
-- feed is pieced together from UNIT_COMBAT and timing (Sources.lua).
ns.useCombatLog = false
if not ns.isForever and not ns.isRetail and CombatLogGetCurrentEventInfo then
    local probe = CreateFrame("Frame")
    ns.useCombatLog = pcall(probe.RegisterEvent, probe, "COMBAT_LOG_EVENT_UNFILTERED")
    pcall(probe.UnregisterAllEvents, probe)
end

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
        clearOnNewFight = true,  -- start every fight with an empty feed
        pinDots = true,          -- one pinned row per running DoT that counts its ticks up
        strict = true,           -- in groups, drop target hits that can't be matched to your swing/cast
        show = {
            damage = true, heal = true, avoid = true, taken = true, healIn = true, cast = true,
            buff = true, debuffIn = true, debuffOut = true, fade = true, kill = true,
        },
        minAmountOut = 0, minAmountIn = 0,
        hideNormalOut = false, hideNormalIn = false, -- only show crits for hits/heals
    },
}

ns.defaults.alerts = {
    visual = {
        enabled = true, heals = true, minAmount = 0, duration = 1.2, size = 44, scale = 1,
        showIcon = true, showName = true, glow = true,
        useCritColor = true, color = { 1.00, 0.82, 0.18 },
        x = 0, y = 180,
    },
    sound = {
        enabled = true, heals = false, minAmount = 0,
        sound = "wl:chime", channel = "Master", throttle = 0.15,
    },
}

ns.defaults.alerts.streak = { enabled = true, min = 2, escalatingSound = true }
ns.defaults.alerts.record = { banner = true, sound = true }

ns.defaults.stats = {
    summary = { enabled = true, duration = 8, scale = 1, x = 320, y = -330 },
    history = { enabled = true, keep = 30, minDuration = 3 },
    records = { enabled = true, minDpsDuration = 10 },
}

ns.defaults.procs = {
    enabled = true, list = {},
    sound = true, soundChoice = "wl:proc", channel = "Master",
    duration = 1.5, size = 30, scale = 1, showIcon = true, showName = true, glow = true,
    color = { 0.45, 0.85, 1.00 }, x = 0, y = 110,
}

-- shown as a lane inside the log window, under the header
ns.defaults.swing = {
    enabled = true, height = 8, offhand = true, ranged = true, showTime = false,
    color = { 0.95, 0.80, 0.30 }, offColor = { 0.60, 0.75, 1.00 }, rangedColor = { 0.50, 1.00, 0.50 },
}

-- personal resource display, under your character by default
ns.defaults.resources = {
    styleVersion = 2,
    enabled = true, visibility = "combatOrNotFull", fadeIn = 0.3, fadeOut = 0.6, alpha = 1,
    x = 0, y = -150, scale = 1, width = 200, spacing = 3,
    -- borderless with the log rows' dark fade behind each bar
    texture = "flat", gloss = false, bgStyle = "fade", bgOpacity = 0.42, border = false, smooth = true,
    health = { enabled = true, height = 10, classColor = true, color = { 0.20, 0.85, 0.30 },
               textLeft = "none", textRight = "percent", textSize = 10 },
    power = { enabled = true, height = 5, typeColor = true, color = { 0.20, 0.50, 1.00 },
              textLeft = "none", textRight = "none", textSize = 8, countForVisibility = true },
    druidMana = { enabled = true, height = 3, color = { 0.00, 0.55, 1.00 } },
    combo = { enabled = true, height = 6, onlyWhenActive = false, ticks = true, color = { 1.00, 0.82, 0.18 } },
    castbar = { enabled = true, height = 10, icon = true, name = true, time = true, textSize = 9,
                color = { 1.00, 0.75, 0.25 }, uninterruptibleColor = { 0.60, 0.60, 0.60 } },
}

ns.defaults.session = { enabled = true, headerLine = false }
ns.defaults.minimap = { enabled = true, angle = 200 }

-- icons for spells that want attention: usable now (Riposte) or a buff to refresh
ns.defaults.reminders = {
    enabled = true, combatOnly = false,
    refreshAt = 10,             -- buff reminders also show when less than this is left (0 = only when missing)
    list = {},                  -- { spell = "Riposte" or "14251", mode = "usable" | "buff" }
    sound = false, soundChoice = "wl:bell", channel = "Master", -- each reminder can pick its own, too
    size = 40, scale = 1, spacing = 6, showName = true, glow = true,
    color = { 1.00, 0.82, 0.18 }, x = 0, y = 60,
}

ns.fight = { active = false, start = 0, stop = nil, damage = 0, healing = 0, taken = 0 }
ns.locked = true

-- School bitmask -> display name
ns.SCHOOL_NAMES = {
    [1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature",
    [16] = "Frost", [32] = "Shadow", [64] = "Arcane",
}

-- Shared by both combat sources (Sources.lua, CombatLog.lua)
local ICONS = "Interface\\Icons\\"
ns.ICONS = {
    melee = ICONS .. "INV_Sword_04", taken = ICONS .. "Ability_Warrior_DefensiveStance",
    heal = ICONS .. "Spell_Holy_Heal", pet = ICONS .. "Ability_Hunter_BeastTaming",
    spell = ICONS .. "Spell_Nature_StarFall", kill = ICONS .. "Ability_Rogue_Eviscerate",
}
-- miss type -> row tag, for your attacks and for attacks on you
ns.AVOID_OUT = {
    MISS = "MISS", DODGE = "DODGE", PARRY = "PARRY", BLOCK = "BLOCK", RESIST = "RESIST",
    IMMUNE = "IMMUNE", EVADE = "EVADE", DEFLECT = "DEFLECT", REFLECT = "REFLECT", ABSORB = "ABSORB",
}
ns.AVOID_IN = {
    MISS = "MISSED", DODGE = "DODGED", PARRY = "PARRIED", BLOCK = "BLOCKED", RESIST = "RESISTED",
    IMMUNE = "IMMUNE", EVADE = "EVADED", DEFLECT = "DEFLECTED", REFLECT = "REFLECTED", ABSORB = "ABSORBED",
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
    if not (C_Spell and C_Spell.GetSpellInfo) and GetSpellInfo then
        -- older API (some Classic clients)
        local n, _, icon = GetSpellInfo(id)
        if n then
            cached = { name = n, icon = icon or 134400 }
            spellCache[id] = cached
            return cached
        end
    end
    if C_Spell and C_Spell.RequestLoadSpellData then
        C_Spell.RequestLoadSpellData(id)
    end
    return nil
end

---------------------------------------------------------------------------
-- Events: every registration gets its own frame, so several modules can listen
-- to the same event (also unit events with different units)
---------------------------------------------------------------------------

-- Registers fn for event; extra args make it a unit event. Returns false if the
-- client refuses the event (some are restricted or missing on Forever).
function ns.Listen(event, fn, ...)
    local f = CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, _, ...) fn(...) end)
    local ok
    if select("#", ...) > 0 then
        ok = pcall(f.RegisterUnitEvent, f, event, ...)
    else
        ok = pcall(f.RegisterEvent, f, event)
    end
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
    ns.Alerts:Apply()
    ns.Report:Apply()
    ns.Resources:Apply()
    ns.Minimap:Apply()
    ns.Reminders:Apply()
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
    -- profiles saved with the first resource display look get the new default look once
    local r = ns.db.resources
    local oldLook = r and r.styleVersion == nil
    fillDefaults(ns.db, ns.defaults)
    if oldLook then
        local D = ns.defaults.resources
        for _, k in ipairs({ "width", "spacing", "texture", "gloss", "bgStyle", "bgOpacity", "border" }) do
            r[k] = D[k]
        end
        for _, bar in ipairs({ "health", "power", "druidMana", "combo", "castbar" }) do
            r[bar].height = D[bar].height
            r[bar].textSize = D[bar].textSize
        end
        r.power.textRight = D.power.textRight
    end
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
    ns.Stats:StartFight()
    ns.Report:HideSummary()
    if ns.db.behaviour.clearOnNewFight then ns.Display:Clear() end
    ns.lingering = false
    ns.Display:UpdateVisibility()
end

function ns.EndFight()
    local f = ns.fight
    if not f.active then return end
    f.active, f.stop = false, GetTime()
    ns.Stats:FinishFight()
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

-- Starts the fight if the first event arrives before PLAYER_REGEN_DISABLED.
local function ensureFight()
    if ns.fight.active or ns.lingering then return true end
    if ns.Safe(UnitAffectingCombat("player")) then
        ns.StartFight()
        return true
    end
    return false
end

-- Every outgoing damage/heal/avoid entry that is yours, before any log filters:
-- stats, streaks and records first, then the crit/record alerts.
function ns.OnOutgoing(e)
    ensureFight()
    ns.Stats:Outgoing(e)
    if e.crit or e.record then ns.Alerts:OnHit(e) end
end

-- Entry point for everything that wants a row in the feed.
function ns.Emit(entry)
    if not ensureFight() then return end
    local b = ns.db.behaviour
    if entry.tick and not entry.dim and b.pinDots then
        -- every tick goes into its DoT's row, so the amount filters would falsify the counts
        if b.show[entry.kind] then ns.Display:Push(entry) end
    elseif ns.ShouldShow(entry) then
        ns.Display:Push(entry)
    end
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
    -- shown as a pinned DoT row while that option is on
    { kind = "damage", dir = "out", name = "Corruption", icon = I .. "Spell_Shadow_AbominationExplosion", school = 32,
      amount = 1374, previewPin = { ticks = 6, crits = 1, remaining = 9, duration = 18 } },
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
    ns.testing = true -- before StartFight: test fights never touch history, records or session
    ns.StartFight()
    local runs, dotEnd = 0, nil
    ns.testTicker = C_Timer.NewTicker(0.45, function()
        runs = runs + 1
        local t = TEST_ENTRIES[math.random(#TEST_ENTRIES)]
        -- runs 10-13: a guaranteed crit streak; run 20: a sample "new record"
        local forced = (runs >= 10 and runs <= 13) or runs == 20
        if forced then t = TEST_ENTRIES[math.random(3)] end
        local e = { kind = t.kind, dir = t.dir, name = t.name, icon = t.icon, school = t.school, tag = t.tag }
        if t.min then
            e.crit = forced or math.random() < 0.2
            e.amount = math.random(t.min, t.max) * (e.crit and 2 or 1)
            e.forceRecord = runs == 20
            if t.kind == "taken" then ns.AddStat("taken", e.amount) end
        end
        if t.kind == "damage" or t.kind == "heal" or (t.kind == "avoid" and t.dir == "out") then
            ns.OnOutgoing(e)
        end
        if runs == 6 then ns.Alerts:TestProc(true) end
        if ns.ShouldShow(e) then ns.Display:Push(e) end
        -- a sample DoT: ticks on runs 5, 10, 15 and 20, then runs out
        if runs % 5 == 0 and runs <= 20 then
            dotEnd = dotEnd or GetTime() + 0.45 * 15 + 0.2
            local d = { kind = "damage", dir = "out", name = "Corruption", school = 32,
                icon = I .. "Spell_Shadow_AbominationExplosion", tick = true, tickPeriod = 2.25, dotEnd = dotEnd }
            d.crit = math.random() < 0.25
            d.amount = math.random(90, 120) * (d.crit and 2 or 1)
            ns.OnOutgoing(d)
            ns.Emit(d)
        end
        if runs >= 24 then
            ns.EndFight()
            ns.StopTest()
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
    WombatLogDB.charData = WombatLogDB.charData or {}
    WombatLogDB.spellProfiles = WombatLogDB.spellProfiles or {} -- learned per-spell hit patterns
    if (WombatLogDB.spellProfilesVersion or 1) < 2 then
        -- tick schools learned by earlier versions could be wrong (a mark "ticking" nature)
        for _, p in pairs(WombatLogDB.spellProfiles) do
            p.tickSchool, p.tickVotes, p.lastVote = nil, nil, nil
        end
        WombatLogDB.spellProfilesVersion = 2
    end
    charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    ns.charKey = charKey
    activate()
    ns.Stats:Init()
    ns.Display:Init()
    ns.Alerts:Init()
    ns.Report:Init()
    ns.Resources:Init()
    ns.Minimap:Init()
    ns.Reminders:Init()
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
    elseif cmd == "debug" then
        ns.Print("client: " .. ns.FLAVOR .. " (" .. INTERFACE .. "), hits from "
            .. (ns.useCombatLog and "the combat log (exact)" or "UNIT_COMBAT (estimated)"))
        ns.Resources:Debug()
    elseif cmd == "trace" then
        ns.trace = not ns.trace
        ns.Print("event trace " .. (ns.trace and "on - hits, casts and swings print to chat" or "off"))
    elseif cmd == "journal" or cmd == "history" then
        ns.Report:ToggleJournal()
    elseif cmd == "session" then
        if (msg or ""):lower():find("reset") then
            ns.Stats:ResetSession()
            ns.Print("session reset.")
        else
            ns.Report:ToggleJournal("session")
        end
    elseif cmd == "reset" then
        ns.Profiles.Reset()
        ns.Print("profile '" .. ns.Profiles.Current() .. "' reset to defaults.")
    else
        ns.Print("/wl - settings, /wl test - preview fight, /wl journal - fights & records, "
            .. "/wl session [reset], /wl unlock | lock - move, /wl reset - reset profile")
    end
end
