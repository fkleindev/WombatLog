local ADDON, ns = ...
local Range = {}
ns.RangeIndicator = Range
local Safe, SafeTable = ns.Safe, ns.SafeTable

-- A small mark on nameplates: are they in range of your spell? Enemies and allies
-- each get their own spell (a priest checks Smite on mobs and Flash Heal on the
-- group), picked automatically from the class's spells or set in the settings.
--
-- The mark is a frame of our own hung on the nameplate; the game's plate itself is
-- never changed, so nothing taints and other nameplate addons keep working. Range
-- comes from the game's spell range check. When the client won't tell (no answer,
-- or a secret value), the plate gets no mark rather than a wrong one.
--
-- Friendly nameplates are the game's: they only exist while switched on (Shift+V),
-- and in dungeons and raids the game doesn't hand them to addons at all.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local DOT = MEDIA .. "Round50"
local GLOW = MEDIA .. "Glow"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local POLL = 0.15          -- seconds between two range checks
local TEST_TIME = 5

-- Spells tried in order, the first one you know is used. IDs that a client doesn't
-- have are skipped, so one list serves every client.
Range.DEFAULTS = {
    PRIEST = {
        hostile = { 585, 589, 8092 },             -- Smite, Shadow Word: Pain, Mind Blast
        friendly = { 2061, 2050, 2054, 17, 1243 }, -- Flash Heal, Lesser Heal, Heal, PW: Shield, PW: Fortitude
    },
    MAGE = {
        hostile = { 116, 133, 30451, 5143 },      -- Frostbolt, Fireball, Arcane Blast, Arcane Missiles
        friendly = { 1459, 130 },                 -- Arcane Intellect, Slow Fall
    },
    WARLOCK = {
        hostile = { 686, 172, 348 },              -- Shadow Bolt, Corruption, Immolate
        friendly = { 5697 },                      -- Unending Breath
    },
    HUNTER = {
        hostile = { 3044, 75, 193455, 56641 },    -- Arcane Shot, Auto Shot, Cobra Shot, Steady Shot
        friendly = { 34477 },                     -- Misdirection
    },
    DRUID = {
        hostile = { 5176, 8921 },                 -- Wrath, Moonfire
        friendly = { 8936, 774, 5185, 1126 },     -- Regrowth, Rejuvenation, Healing Touch, Mark of the Wild
    },
    SHAMAN = {
        hostile = { 403, 188196, 8042 },          -- Lightning Bolt (two IDs), Earth Shock
        friendly = { 8004, 331, 77472 },          -- Healing Surge / Lesser Healing Wave, Healing Wave
    },
    PALADIN = {
        hostile = { 20271, 62124, 35395 },        -- Judgement, Hand of Reckoning, Crusader Strike
        friendly = { 19750, 635, 19740 },         -- Flash of Light, Holy Light, Blessing of Might
    },
    WARRIOR = {
        hostile = { 1715, 1464, 78, 772 },        -- Hamstring, Slam, Heroic Strike, Rend
        friendly = { 3411 },                      -- Intervene
    },
    ROGUE = {
        hostile = { 1752, 193315 },               -- Sinister Strike (two IDs)
        friendly = { 57934 },                     -- Tricks of the Trade
    },
    DEATHKNIGHT = {
        hostile = { 47541, 45477, 49998 },        -- Death Coil, Icy Touch, Death Strike
        friendly = { 61999 },                     -- Raise Ally
    },
    MONK = {
        hostile = { 117952, 100780 },             -- Crackling Jade Lightning, Tiger Palm
        friendly = { 116670, 115175 },            -- Vivify, Soothing Mist
    },
    DEMONHUNTER = {
        hostile = { 185123, 162794 },             -- Throw Glaive, Chaos Strike
        friendly = {},
    },
    EVOKER = {
        hostile = { 361469 },                     -- Living Flame
        friendly = { 361469, 355913 },            -- Living Flame, Emerald Blossom
    },
}

local function call(fn, ...)
    if not fn then return nil end
    local ok, a = pcall(fn, ...)
    if not ok then return nil end
    return Safe(a)
end

local function playerClass()
    return select(2, UnitClass("player"))
end

---------------------------------------------------------------------------
-- Spells
---------------------------------------------------------------------------

-- Name, icon and spell ID of "Smite" or "585"; nil if the client doesn't know it
-- (by name, only spells in your spellbook resolve).
local function resolve(text)
    local key = tonumber(text) or text
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, key)
        info = ok and SafeTable(info)
        if info and Safe(info.name) then
            return info.name, Safe(info.iconID) or 134400, Safe(info.spellID)
        end
    elseif GetSpellInfo then
        local name, _, icon, _, _, _, id = GetSpellInfo(key)
        if name then return name, icon or 134400, id end
    end
end

local function knows(id)
    if not id then return false end
    if not IsPlayerSpell and not IsSpellKnown then return true end
    if IsPlayerSpell and call(IsPlayerSpell, id) then return true end
    if IsSpellKnown and call(IsSpellKnown, id) then return true end
    return false
end

local function known(id)
    local name, icon, sid = resolve(id)
    if name and (knows(id) or knows(sid)) then return name, icon, sid or id end
end

-- The player's choice for one side: nil (automatic), "none" or a spell name / ID.
function Range.Pick(side)
    local list = ns.db.rangeIndicator.spells[playerClass()]
    return list and list[side]
end

function Range.SetPick(side, value)
    local all = ns.db.rangeIndicator.spells
    local class = playerClass()
    all[class] = all[class] or {}
    if value == "auto" or value == "" then value = nil end
    all[class][side] = value
    Range:Apply()
end

-- The automatic spell for one side: the first default you know.
function Range.AutoSpell(side)
    local list = Range.DEFAULTS[playerClass()]
    for _, id in ipairs(list and list[side] or {}) do
        local name, icon, sid = known(id)
        if name then return name, icon, sid end
    end
end

-- { name, icon, id } the range is checked with for one side, or nil.
local function spellFor(side)
    local pick = Range.Pick(side)
    if pick == "none" then return nil end
    local name, icon, id
    if pick then
        name, icon, id = resolve(pick)
    else
        name, icon, id = Range.AutoSpell(side)
    end
    if name then return { name = name, icon = icon, id = id } end
end

-- Known spells of the class's default lists, for the settings dropdowns.
function Range.Choices()
    local out, seen = {}, {}
    local list = Range.DEFAULTS[playerClass()] or {}
    for _, side in ipairs({ "hostile", "friendly" }) do
        for _, id in ipairs(list[side] or {}) do
            local name, icon = known(id)
            if name and not seen[name] then
                seen[name] = true
                out[#out + 1] = { name = name, icon = icon, value = tostring(id) }
            end
        end
    end
    return out
end

-- Name for a stored pick, for the settings (works for unknown spells too).
function Range.Describe(pick)
    local name = resolve(pick)
    if not name and tonumber(pick) then
        local info = ns.SpellInfo(tonumber(pick))
        name = info and info.name
    end
    return name or pick
end

local spells = {}            -- side -> { name, icon, id }

local function refreshSpells()
    spells.hostile = spellFor("hostile")
    spells.friendly = spellFor("friendly")
end

-- true / false, or nil when the client can't or won't tell.
local function inRange(spell, unit)
    local r
    if C_Spell and C_Spell.IsSpellInRange then
        r = call(C_Spell.IsSpellInRange, spell.id or spell.name, unit)
        if r == nil and spell.id then r = call(C_Spell.IsSpellInRange, spell.name, unit) end
    elseif IsSpellInRange then
        r = call(IsSpellInRange, spell.name, unit)
    end
    if r == nil then return nil end
    return r == true or r == 1
end

-- "hostile", "friendly" or nil: which spell a unit is checked with.
local function sideOf(unit, cfg)
    if call(UnitIsUnit, unit, "player") then return nil end
    if call(UnitCanAttack, "player", unit) then
        return cfg.hostile and "hostile" or nil
    end
    if cfg.friendly and call(UnitCanAssist, "player", unit) then
        if cfg.friendlyPlayersOnly and not call(UnitIsPlayer, unit) then return nil end
        return "friendly"
    end
end

---------------------------------------------------------------------------
-- The marks
---------------------------------------------------------------------------

local plates = {}            -- nameplate unit tokens shown right now
local marks = {}             -- unit -> mark
local pool = {}
local version = 0            -- goes up with every settings change: marks repaint

local function plateOf(unit)
    return C_NamePlate and C_NamePlate.GetNamePlateForUnit and call(C_NamePlate.GetNamePlateForUnit, unit)
end

local function newMark()
    local m = CreateFrame("Frame")
    m:SetSize(10, 10)
    m.glow = m:CreateTexture(nil, "BACKGROUND")
    m.glow:SetTexture(GLOW)
    m.glow:SetBlendMode("ADD")
    m.glow:SetPoint("CENTER")
    m.edge = m:CreateTexture(nil, "BORDER")
    m.fill = m:CreateTexture(nil, "ARTWORK")
    m.fill:SetAllPoints()
    return m
end

local function paint(m, ok, icon, cfg)
    local c = ok and cfg.inColor or cfg.outColor
    local size = cfg.size
    m:SetSize(size, size)
    m.edge:ClearAllPoints()
    if cfg.style == "icon" then
        m.fill:SetTexture(icon or 134400)
        m.fill:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        m.fill:SetDesaturated(not ok)
        if ok then m.fill:SetVertexColor(1, 1, 1) else m.fill:SetVertexColor(1, 0.6, 0.6) end
        m.edge:SetTexture(WHITE)
        m.edge:SetPoint("TOPLEFT", -1, 1)
        m.edge:SetPoint("BOTTOMRIGHT", 1, -1)
        m.edge:SetVertexColor(c[1], c[2], c[3], 1)
    else
        m.fill:SetTexture(DOT)
        m.fill:SetTexCoord(0, 1, 0, 1)
        m.fill:SetDesaturated(false)
        m.fill:SetVertexColor(c[1], c[2], c[3], 1)
        m.edge:SetTexture(DOT)
        m.edge:SetPoint("TOPLEFT", -1.5, 1.5)
        m.edge:SetPoint("BOTTOMRIGHT", 1.5, -1.5)
        m.edge:SetVertexColor(0, 0, 0, 0.85)
    end
    m.glow:SetSize(size * 2.6, size * 2.6)
    m.glow:SetVertexColor(c[1], c[2], c[3], 0.5)
    m.glow:SetShown(cfg.glow)
    m:SetAlpha(cfg.alpha)
end

-- Where on the plate: its health bar when the game's own plate shows, else the
-- plate itself (other nameplate addons hide the game's and draw their own on it).
local function anchorOf(plate)
    local ok, bar = pcall(function()
        local uf = plate.UnitFrame
        if not uf or uf:IsForbidden() or not uf:IsVisible() then return nil end
        local b = uf.healthBar or uf.HealthBarsContainer
        if b and b:IsVisible() then return b end
    end)
    return ok and bar or plate
end

local SIDES = {
    left = { "RIGHT", "LEFT" }, right = { "LEFT", "RIGHT" },
    top = { "BOTTOM", "TOP" }, bottom = { "TOP", "BOTTOM" },
}

local function place(m, parent, anchor, cfg)
    m:SetParent(parent)
    m:ClearAllPoints()
    local s = SIDES[cfg.side] or SIDES.left
    m:SetPoint(s[1], anchor, s[2], cfg.dx, cfg.dy)
    m:SetFrameStrata(parent:GetFrameStrata())
    local ok, level = pcall(anchor.GetFrameLevel, anchor)
    level = ok and Safe(level)
    if level then m:SetFrameLevel(level + 5) end
end

local function release(unit)
    local m = marks[unit]
    if not m then return end
    marks[unit] = nil
    m:Hide()
    m:ClearAllPoints()
    m:SetParent(nil)
    m.plate, m.anchor, m.state, m.icon, m.version = nil, nil, nil, nil, nil
    pool[#pool + 1] = m
end

local function releaseAll()
    for unit in pairs(marks) do release(unit) end
end

local function show(unit, plate, ok, icon, cfg)
    local m = marks[unit]
    if not m then
        m = table.remove(pool) or newMark()
        marks[unit] = m
    end
    local anchor = anchorOf(plate)
    if m.plate ~= plate or m.anchor ~= anchor or m.version ~= version then
        place(m, plate, anchor, cfg)
        m.plate, m.anchor, m.state = plate, anchor, nil
    end
    if m.state ~= ok or m.icon ~= icon or m.version ~= version then
        paint(m, ok, icon, cfg)
        m.state, m.icon, m.version = ok, icon, version
    end
    m:Show()
end

---------------------------------------------------------------------------
-- Keeping up
---------------------------------------------------------------------------

local testUntil = 0
local fighting = false       -- PLAYER_REGEN_DISABLED comes before the lockdown starts

local function wanted(cfg, ok)
    if ok == nil then return false end
    if cfg.show == "out" then return not ok end
    if cfg.show == "in" then return ok end
    return true
end

function Range:Update()
    if GetTime() < testUntil then return end
    local cfg = ns.db.rangeIndicator
    local on = self.active and not (cfg.combatOnly and not fighting)
    for unit in pairs(plates) do
        local done = false
        if on then
            local side = sideOf(unit, cfg)
            local spell = side and spells[side]
            if spell then
                local ok = inRange(spell, unit)
                if wanted(cfg, ok) then
                    local plate = plateOf(unit)
                    if plate then
                        show(unit, plate, ok, spell.icon, cfg)
                        done = true
                    end
                end
            end
        end
        if not done then release(unit) end
    end
end

local poller = CreateFrame("Frame")
poller:Hide()
local since = 0
poller:SetScript("OnUpdate", function(_, dt)
    since = since + dt
    if since >= POLL then
        since = 0
        Range:Update()
    end
end)

-- The plates already up (after a /reload); the events keep the list after that.
local function scanPlates()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if call(UnitExists, unit) then plates[unit] = true end
    end
end

function Range:Init()
    self.ready = true
    fighting = Safe(UnitAffectingCombat("player")) and true or false
    self:Apply()
end

function Range:Apply()
    if not (ns.db and self.ready) then return end
    local cfg = ns.db.rangeIndicator
    version = version + 1
    self.active = cfg.enabled and (cfg.hostile or cfg.friendly) and true or false
    if self.active then
        refreshSpells()
        scanPlates()
    else
        releaseAll()
    end
    poller:SetShown(self.active)
    self:Update()
end

-- Settings button: one mark in range and one out of range, in the middle of the
-- screen, with the current look.
local testMarks

function Range:Test()
    local cfg = ns.db.rangeIndicator
    refreshSpells()
    releaseAll()
    testUntil = GetTime() + TEST_TIME
    testMarks = testMarks or { newMark(), newMark() }
    local icon = (spells.hostile or spells.friendly or {}).icon
    for i, m in ipairs(testMarks) do
        m:SetParent(UIParent)
        m:SetFrameStrata("HIGH")
        m:ClearAllPoints()
        m:SetPoint("CENTER", UIParent, "CENTER", (i == 1 and -1 or 1) * (cfg.size + 12), 120)
        paint(m, i == 1, icon, cfg)
        m:Show()
    end
    C_Timer.After(TEST_TIME, function()
        if GetTime() >= testUntil then
            for _, m in ipairs(testMarks) do m:Hide() end
            Range:Update()
        end
    end)
end

-- /wl debug: the spells in use and what the game says about your target.
function Range:Debug()
    if not ns.db then return end
    refreshSpells()
    local function raw(spell)
        if not spell then return "-" end
        local r
        if C_Spell and C_Spell.IsSpellInRange then
            local ok, v = pcall(C_Spell.IsSpellInRange, spell.id or spell.name, "target")
            r = ok and v or "error"
        elseif IsSpellInRange then
            local ok, v = pcall(IsSpellInRange, spell.name, "target")
            r = ok and v or "error"
        end
        if r ~= nil and issecretvalue and issecretvalue(r) then return "secret" end
        return tostring(r)
    end
    local n = 0
    for _ in pairs(plates) do n = n + 1 end
    ns.Print(("range: %s, enemies %s (target: %s), allies %s (target: %s), %d plates"):format(
        self.active and "on" or "off",
        spells.hostile and spells.hostile.name or "-", raw(spells.hostile),
        spells.friendly and spells.friendly.name or "-", raw(spells.friendly), n))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

ns.Listen("NAME_PLATE_UNIT_ADDED", function(unit)
    unit = Safe(unit)
    if not unit then return end
    plates[unit] = true
    if Range.active then Range:Update() end
end)

ns.Listen("NAME_PLATE_UNIT_REMOVED", function(unit)
    unit = Safe(unit)
    if not unit then return end
    plates[unit] = nil
    release(unit)
end)

local function spellsChanged()
    if Range.active then
        refreshSpells()
        Range:Update()
    end
end
ns.Listen("SPELLS_CHANGED", spellsChanged)
ns.Listen("PLAYER_TALENT_UPDATE", spellsChanged)
ns.Listen("ACTIVE_TALENT_GROUP_CHANGED", spellsChanged)

ns.Listen("PLAYER_REGEN_DISABLED", function()
    fighting = true
    if Range.active then Range:Update() end
end)
ns.Listen("PLAYER_REGEN_ENABLED", function()
    fighting = false
    if Range.active then Range:Update() end
end)
