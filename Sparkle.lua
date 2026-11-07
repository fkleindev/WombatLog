local ADDON, ns = ...
local Sparkle = {}
ns.Sparkle = Sparkle
local Safe, SafeTable = ns.Safe, ns.SafeTable
local L = ns.L

-- Things to click for a quest glittered in Classic; on Forever they don't any more.
-- Two ways to get it back, each with its own switch:
--
-- The game's own sparkle. Forever still has it, behind a hidden setting
-- (outlineModeShowLootEffectWhenDisabled). Graphics presets switch it off again, so it
-- is set at login and again a moment after any graphics change. It marks quest objects
-- and quest loot at any distance, but it only knows on and off. Switching it off only
-- takes effect after restarting the game. The outline mode stays as the player set it.
--
-- An effect of our own: sparks, a glow, an icon with an arrow or a beam of light, in
-- the strength and color you like. It hangs on the nameplate the game can give its
-- interaction target (soft targeting, the "softinteract" unit): the one object nearest
-- in front of you, up to about 15 yards. What the object is comes from the cursor the
-- game would show over it (herb, mining pick, quest), whether it belongs to a quest
-- also from the quest log; corpses count when they still hold loot for you. The
-- nameplate is only switched on for objects that get the effect, so NPCs and
-- mailboxes stay as they were. These settings are the game's (Options > Accessibility,
-- "Enable Interact Key"); their old values are kept and put back once the effect is off.
--
-- Settings can't change in combat: changes wait for the fight to end.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local STAR = "Interface\\Cooldown\\star4"
local ARROW = "Interface\\Buttons\\Arrow-Down-Up"
local SOFT = "softinteract"
local LOOT_CVAR = "outlineModeShowLootEffectWhenDisabled"
local POLL = 0.12          -- seconds between two looks at the interaction target
local APPEAR = 0.35        -- fade in
local BLEND = 0.3          -- between far / in reach / locked
local HOLD = 0.15          -- a new state shows once it held this long
local HOLD_LOCKED = 0.6
local TEST_TIME = 5
local MAX_SPARKS = 16
local GREY = { 0.62, 0.62, 0.62 }

local ICONS = {
    quest = "Interface\\GossipFrame\\AvailableQuestIcon",
    loot = "Interface\\Icons\\INV_Misc_Bag_10",
    herb = "Interface\\Icons\\Trade_Herbalism",
    ore = "Interface\\Icons\\Trade_Mining",
}

-- Intensity presets: { size, opacity, speed, sparks }
Sparkle.PRESETS = {
    subtle = { 0.75, 0.55, 0.7, 5 },
    normal = { 1, 0.9, 1, 8 },
    strong = { 1.4, 1, 1.3, 13 },
}

local sin, cos, sqrt, random, min, max, pi = math.sin, math.cos, math.sqrt, math.random, math.min, math.max, math.pi

local function call(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return Safe(a), Safe(b)
end

---------------------------------------------------------------------------
-- Game settings
---------------------------------------------------------------------------

local function getCVar(name)
    if not (C_CVar and C_CVar.GetCVar) then return nil end
    local ok, v = pcall(C_CVar.GetCVar, name)
    return ok and v or nil
end

local writing = false
-- Only settings this client has, and only when the value really changes: every
-- write runs the game's own handlers right away.
local function setCVar(name, value)
    value = tostring(value)
    local cur = getCVar(name)
    if cur == nil or cur == value then return false end
    writing = true
    pcall(C_CVar.SetCVar, name, value)
    writing = false
    return true
end

local pending = {}           -- what waits for the end of the fight

function Sparkle.HasNative()
    return getCVar(LOOT_CVAR) ~= nil
end

function Sparkle:ApplyNative()
    if not Sparkle.HasNative() then return end
    if InCombatLockdown() then
        pending.native = true
        return
    end
    if ns.db.sparkle.native then
        if setCVar(LOOT_CVAR, 1) then WombatLogDB.sparkleNative = true end
    elseif WombatLogDB.sparkleNative then
        -- only undone when WombatLog switched it on
        WombatLogDB.sparkleNative = nil
        setCVar(LOOT_CVAR, 0)
        ns.Print(L["The game's sparkle goes away after restarting the game (/reload is not enough)."])
    end
end

local SOFT_CVARS = {
    "SoftTargetInteract", "SoftTargetIconGameObject", "SoftTargetInteractRange",
    "SoftTargetInteractArc", "SoftTargetInteractOnlyInRange", "SoftTargetNameplateInteract",
}

local function wantEffect()
    local cfg = ns.db and ns.db.sparkle
    return cfg and cfg.enabled and (cfg.quest or cfg.loot or cfg.herb or cfg.ore) and true or false
end

local gate                   -- is the interaction target's nameplate on? nil = unknown

local function setGate(open)
    if open == gate or InCombatLockdown() then return end
    gate = open
    setCVar("SoftTargetNameplateInteract", open and 1 or 0)
end

-- Soft targeting on. "Enable Interact Key" and the icons on objects are the player's
-- settings too: they are switched on when the effect starts or is switched on (force),
-- not at every login, so whoever turns them off afterwards keeps them off.
local function applySoftTarget(force)
    if InCombatLockdown() then
        pending.soft = "apply"
        pending.force = pending.force or force
        return
    end
    local saved = WombatLogDB.sparkleCVars
    if not saved then
        saved = {}
        for _, name in ipairs(SOFT_CVARS) do saved[name] = getCVar(name) or false end
        WombatLogDB.sparkleCVars = saved
        force = true
    end
    if force then
        setCVar("SoftTargetInteract", 3)        -- an interaction target all the time
        setCVar("SoftTargetIconGameObject", 1)  -- objects get a nameplate at all
    end
    setCVar("SoftTargetInteractRange", 30)      -- the game still stops at about 15
    setCVar("SoftTargetInteractArc", 2)         -- all around, not only straight ahead
    setCVar("SoftTargetInteractOnlyInRange", 0) -- also objects not yet in reach
    gate = nil
end

local function restoreSoftTarget()
    if InCombatLockdown() then
        pending.soft = "restore"
        return
    end
    local saved = WombatLogDB.sparkleCVars
    if not saved then return end
    for name, value in pairs(saved) do
        if value ~= false then setCVar(name, value) end
    end
    WombatLogDB.sparkleCVars = nil
    gate = nil
end

---------------------------------------------------------------------------
-- What the target is
---------------------------------------------------------------------------

local probe = UIParent:CreateTexture(nil, "BACKGROUND") -- reads the cursor, never shown
probe:Hide()

local cursorFiles = {}       -- file ID -> { category, greyed out }
if GetFileIDFromPath then
    for name, cat in pairs({ Mine = "ore", GatherHerbs = "herb", Quest = "quest",
        QuestRepeatable = "quest", QuestTurnIn = "quest" }) do
        for _, prefix in ipairs({ "", "Unable" }) do
            local id = call(GetFileIDFromPath, "Interface\\Cursor\\" .. prefix .. name)
            if id then cursorFiles[id] = { cat, prefix ~= "" } end
        end
    end
end

-- A cursor's path or atlas name: "Interface\Cursor\UnableMine", "Cursor_..._Mine_64"
local function fromCursorName(s)
    if type(s) ~= "string" then return nil end
    s = s:lower()
    local greyed = s:find("unable", 1, true) ~= nil
    if s:find("herb", 1, true) or s:find("gather", 1, true) then return "herb", greyed end
    if s:find("mine", 1, true) then return "ore", greyed end
    if s:find("quest", 1, true) then return "quest", greyed end
    return nil, greyed
end

local function cursorCategory(unit)
    if not SetUnitCursorTexture or not call(SetUnitCursorTexture, probe, unit, nil, true) then return nil end
    local tex = Safe(probe:GetTexture())
    local known = type(tex) == "number" and cursorFiles[tex]
    if known then return known[1], known[2] end
    local cat, greyed = fromCursorName(tex)
    if cat then return cat, greyed end
    return fromCursorName(probe.GetAtlas and Safe(probe:GetAtlas()))
end

local function normalize(s)
    s = s:lower():gsub("\194\160", " "):gsub("\226\128\153", "'")
    return strtrim(s)
end

-- Its name in an objective not done yet ("Soaked Saw"), or the objective in its
-- name ("Supplies" in "Crate of Supplies").
local function inObjectives(name)
    if type(name) ~= "string" or #name < 4 then return false end
    name = normalize(name)
    for _, q in pairs(ns.QuestProgress.Known()) do
        for _, o in ipairs(q.objectives or {}) do
            if not o.done and type(o.text) == "string" then
                local t = normalize(o.text)
                if t:find(name, 1, true) or (#t >= 5 and name:find(t, 1, true)) then return true end
            end
        end
    end
    return false
end

local OBJECTIVE_LINE = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.QuestObjective

local function forQuest(unit)
    if C_QuestLog and call(C_QuestLog.UnitIsRelatedToActiveQuest, unit) == true then return true end
    if OBJECTIVE_LINE and C_TooltipInfo then
        local data = SafeTable(call(C_TooltipInfo.GetUnit, unit))
        for _, line in ipairs(data and data.lines or {}) do
            if Safe(line.type) == OBJECTIVE_LINE then return true end
        end
    end
    return inObjectives(call(UnitName, unit))
end

-- category ("quest", "loot", "herb", "ore" or nil) and whether the game refuses it now
local function classify(unit)
    if call(UnitIsGameObject, unit) == true then
        local cat, greyed = cursorCategory(unit)
        if cat ~= "herb" and cat ~= "ore" and forQuest(unit) then cat = "quest" end
        return cat, greyed or false
    end
    -- of the creatures only corpses that still hold loot for you
    if call(UnitIsDead, unit) == true and CanLootUnit then
        local guid = call(UnitGUID, unit)
        if guid then
            local ok, hasLoot, canLoot = pcall(CanLootUnit, guid)
            if ok and Safe(hasLoot) == true and Safe(canLoot) ~= false then return "loot", false end
        end
    end
    return nil
end

-- "near": in reach, "far": not yet, "locked": in reach but refused (skill too low)
local function reach(unit, greyed)
    local inRange = UnitIsInInteractRange and call(UnitIsInInteractRange, unit)
    if inRange == false then return "far" end
    if greyed then return inRange == true and "locked" or "far" end
    return "near"
end

---------------------------------------------------------------------------
-- Finding the target's nameplate
---------------------------------------------------------------------------

local plates = {}            -- nameplate unit tokens shown right now
local direct = false         -- the interaction target's own token gave an object's plate

local function plateOf(unit)
    return C_NamePlate and C_NamePlate.GetNamePlateForUnit and call(C_NamePlate.GetNamePlateForUnit, unit)
end

-- The unit to ask about, its nameplate (nil while there is none yet), and with no
-- target at all whether that is because the game wouldn't say.
local function target()
    local isUnit, isObject = call(UnitExists, SOFT), call(UnitIsGameObject, SOFT)
    if isUnit == false and isObject == false then return nil end
    local plate = plateOf(SOFT)
    if plate then
        if isObject then direct = true end
        return SOFT, plate
    end
    if not direct then
        -- clients whose plate only answers to its own token
        for unit in pairs(plates) do
            if call(UnitIsGameObject, unit) == true or call(UnitIsUnit, unit, SOFT) == true then
                plate = plateOf(unit)
                if plate then return unit, plate end
            end
        end
    end
    if isUnit or isObject then return SOFT, nil end
    return nil, nil, true
end

---------------------------------------------------------------------------
-- The effect
---------------------------------------------------------------------------

local fx                     -- the one effect frame
local state = {}             -- its animation

local function tex(f, file, layer, add)
    local t = f:CreateTexture(nil, layer or "OVERLAY")
    t:SetTexture(file)
    if add ~= false then t:SetBlendMode("ADD") end
    if t.SetSnapToPixelGrid then
        t:SetSnapToPixelGrid(false)
        t:SetTexelSnappingBias(0)
    end
    t:Hide()
    return t
end

-- A spark somewhere new in a flat disc around the object, after a short dark pause.
local function respawn(s, now)
    local a, r = random() * 2 * pi, sqrt(random())
    s.x, s.y = cos(a) * r * 46, sin(a) * r * 34
    s.life = 0.6 + 0.8 * random()
    s.scale = 0.5 + 0.7 * random()
    s.angle = random() * 2 * pi
    s.turn = (random() - 0.5) * 2
    s.age = now and 0 or -0.6 * random()
end

local function createFX()
    fx = CreateFrame("Frame")
    fx:SetSize(1, 1)
    fx:Hide()
    fx.sparks = {}
    for i = 1, MAX_SPARKS do fx.sparks[i] = { t = tex(fx, STAR) } end
    fx.halo = tex(fx, GLOW, "ARTWORK")
    fx.core = tex(fx, GLOW)
    fx.beam = tex(fx, GLOW, "ARTWORK")
    fx.beamCore = tex(fx, GLOW)
    fx.iconGlow = tex(fx, GLOW, "ARTWORK")
    fx.icon = tex(fx, ICONS.quest, "OVERLAY", false)
    fx.arrow = tex(fx, ARROW, "OVERLAY", false)
    fx:SetScript("OnUpdate", function(_, dt) Sparkle:Animate(dt) end)
end

local function approach(v, goal, step)
    if v < goal then return min(v + step, goal) end
    return max(v - step, goal)
end

local function lerp(a, b, t) return a + (b - a) * t end

local function hideAll()
    for _, s in ipairs(fx.sparks) do s.t:Hide() end
    fx.halo:Hide(); fx.core:Hide(); fx.beam:Hide(); fx.beamCore:Hide()
    fx.iconGlow:Hide(); fx.icon:Hide(); fx.arrow:Hide()
end

function Sparkle:Animate(dt)
    dt = min(dt, 0.1) -- no jump after a frame freeze
    local cfg = ns.db.sparkle
    state.appear = approach(state.appear, 1, dt / APPEAR)
    state.near = approach(state.near, state.reach == "near" and 1 or 0, dt / BLEND)
    state.locked = approach(state.locked, state.reach == "locked" and 1 or 0, dt / BLEND)
    local near, locked = state.near, state.locked
    -- dimmer and calmer while out of reach, grey and slow when the game refuses it
    local alpha = cfg.alpha * state.appear * lerp(0.55, 1, near) * (1 - 0.55 * locked)
    local speed = cfg.speed * lerp(0.8, 1.2, near) * (1 - 0.5 * locked)
    local c = cfg.colors[state.cat] or cfg.colors.quest
    local r, g, b = lerp(c[1], GREY[1], locked), lerp(c[2], GREY[2], locked), lerp(c[3], GREY[3], locked)
    local size = cfg.size
    state.t = state.t + dt * speed
    local t = state.t
    local style = cfg.style

    if style ~= state.style then
        state.style = style
        hideAll()
    end

    if style == "glow" then
        local pulse = sin(t * 3)
        local h = 90 * size * (1 + 0.12 * pulse)
        fx.halo:SetSize(h, h * 0.75)
        fx.halo:SetPoint("CENTER")
        fx.halo:SetVertexColor(r, g, b, alpha * (0.55 + 0.25 * pulse))
        fx.core:SetSize(40 * size, 30 * size)
        fx.core:SetPoint("CENTER")
        fx.core:SetVertexColor(r, g, b, alpha * (0.6 + 0.3 * sin(t * 3 + 1)))
        fx.halo:Show(); fx.core:Show()
    elseif style == "icon" then
        local bob = 6 * size * sin(t * 3)
        local s = 26 * size
        local y = 46 * size + bob
        fx.icon:SetTexture(ICONS[state.cat] or ICONS.quest)
        if state.cat == "quest" then fx.icon:SetTexCoord(0, 1, 0, 1) else fx.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        fx.icon:SetSize(s, s)
        fx.icon:SetPoint("CENTER", fx, "CENTER", 0, y)
        fx.icon:SetVertexColor(1, 1, 1, alpha)
        fx.iconGlow:SetSize(s * 2.2, s * 2.2)
        fx.iconGlow:SetPoint("CENTER", fx.icon, "CENTER")
        fx.iconGlow:SetVertexColor(r, g, b, alpha * (0.45 + 0.2 * sin(t * 3)))
        fx.arrow:SetSize(s * 0.8, s * 0.8)
        fx.arrow:SetPoint("TOP", fx.icon, "BOTTOM", 0, 2)
        fx.arrow:SetVertexColor(r, g, b, alpha)
        fx.icon:Show(); fx.iconGlow:Show(); fx.arrow:Show()
    elseif style == "beam" then
        local pulse = sin(t * 2)
        fx.beam:SetSize(30 * size, 280 * size)
        fx.beam:SetPoint("BOTTOM", fx, "CENTER", 0, -20 * size)
        fx.beam:SetVertexColor(r, g, b, alpha * (0.55 + 0.2 * pulse))
        fx.beamCore:SetSize(10 * size, 240 * size)
        fx.beamCore:SetPoint("BOTTOM", fx, "CENTER", 0, -10 * size)
        fx.beamCore:SetVertexColor(r, g, b, alpha * (0.7 + 0.2 * pulse))
        fx.core:SetSize(60 * size, 36 * size)
        fx.core:SetPoint("CENTER")
        fx.core:SetVertexColor(r, g, b, alpha * 0.8)
        fx.beam:Show(); fx.beamCore:Show(); fx.core:Show()
    else -- sparks
        local count = min(MAX_SPARKS, cfg.count)
        for i, s in ipairs(fx.sparks) do
            if i > count then
                s.t:Hide()
            else
                s.age = s.age + dt * speed
                if s.age >= s.life then respawn(s) end
                local shine = s.age > 0 and sin(pi * s.age / s.life) or 0
                local px = max(34 * size * s.scale * (0.35 + 0.65 * shine), 0.01)
                s.t:SetSize(px, px)
                s.t:SetPoint("CENTER", fx, "CENTER", s.x * size, s.y * size + 10 * max(s.age, 0))
                s.t:SetRotation(s.angle + s.turn * max(s.age, 0))
                s.t:SetVertexColor(r, g, b, min(alpha * shine, 1))
                s.t:Show()
            end
        end
    end
end

local function release()
    if not fx or not state.anchor then return end
    fx:Hide()
    fx:ClearAllPoints()
    fx:SetParent(nil)
    state.anchor, state.retarget = nil, nil
end

local function attach(anchor, cat, where, test)
    if not fx then createFX() end
    fx:SetParent(anchor)
    if not test then
        -- under the nameplate's own content, so its text stays readable
        local ok, level = pcall(anchor.GetFrameLevel, anchor)
        level = ok and Safe(level)
        if level then fx:SetFrameLevel(max(level - 1, 0)) end
        fx:SetIgnoreParentAlpha(true)
    end
    fx:ClearAllPoints()
    fx:SetPoint("CENTER", anchor, "CENTER", 0, test and 0 or ns.db.sparkle.offset)
    state.anchor, state.cat, state.reach, state.pending = anchor, cat, where, nil
    state.near = where == "near" and 1 or 0
    state.locked = where == "locked" and 1 or 0
    state.appear, state.t, state.style = 0, 0, nil
    for _, s in ipairs(fx.sparks) do respawn(s) end
    fx:Show()
end

-- A new state only shows once it held for a moment (no flicker at the edge of reach).
local function propose(where)
    if where == state.reach then
        state.pending = nil
        return
    end
    local now = GetTime()
    if state.pending ~= where then
        state.pending, state.since = where, now
    elseif now - state.since >= (where == "locked" and HOLD_LOCKED or HOLD) then
        state.pending, state.reach = nil, where
        if where == "near" then
            for _, s in ipairs(fx.sparks) do respawn(s, true) end -- a burst when it comes in reach
        end
    end
end

---------------------------------------------------------------------------
-- Keeping up with the target
---------------------------------------------------------------------------

local testUntil = 0

function Sparkle:Evaluate()
    if GetTime() < testUntil then return end
    local cfg = ns.db.sparkle
    if not wantEffect() or (cfg.hideInCombat and InCombatLockdown()) then
        release()
        return
    end
    local unit, plate, unknown = target()
    if not unit then
        setGate(unknown == true) -- when in doubt, let the game show its target
        release()
        return
    end
    local cat, greyed = classify(unit)
    local wanted = cat ~= nil and cfg[cat] == true
    setGate(wanted)
    if not wanted or not plate then
        release() -- without a plate it was just asked for: the effect follows when it comes
        return
    end
    local where = reach(unit, greyed)
    if state.anchor ~= plate or state.retarget or state.cat ~= cat then
        release()
        attach(plate, cat, where)
    else
        propose(where)
    end
end

local poller = CreateFrame("Frame")
poller:Hide()
local since = 0
poller:SetScript("OnUpdate", function(_, dt)
    since = since + dt
    if since >= POLL then
        since = 0
        Sparkle:Evaluate()
    end
end)

-- Settings wait for login: before it, the game's own may not be loaded yet.
function Sparkle:Apply()
    if not (ns.db and self.ready) then return end
    self:ApplyNative()
    if wantEffect() then
        -- switched on just now (not at login): the interact key goes on too
        local switchedOn = self.active == false
        self.active = true
        applySoftTarget(switchedOn)
    else
        self.active = false
        release()
        restoreSoftTarget()
    end
    poller:SetShown(self.active)
    if self.active then self:Evaluate() end
end

-- Settings button: the effect in the middle of the screen for a few seconds, with
-- the current look; each press shows the next kind of object.
local TEST_CATS = { "quest", "herb", "ore", "loot" }
local testIndex = 0

function Sparkle:Test()
    testIndex = testIndex % #TEST_CATS + 1
    release()
    testUntil = GetTime() + TEST_TIME
    attach(UIParent, TEST_CATS[testIndex], "near", true)
    C_Timer.After(TEST_TIME, function()
        if GetTime() >= testUntil and state.anchor == UIParent then
            release()
            Sparkle:Evaluate()
        end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local nativeAt
local nativeTimer = CreateFrame("Frame")
nativeTimer:Hide()
nativeTimer:SetScript("OnUpdate", function(self)
    if GetTime() >= nativeAt then
        self:Hide()
        Sparkle:ApplyNative()
        if Sparkle.active then applySoftTarget(false) end
    end
end)
local function applyLater(delay)
    nativeAt = GetTime() + delay
    nativeTimer:Show()
end

-- settings synced from the account can come in after login and overwrite ours
ns.Listen("PLAYER_LOGIN", function()
    Sparkle.ready = true
    Sparkle:Apply()
    applyLater(5)
end)
ns.Listen("VARIABLES_LOADED", function() if ns.db then applyLater(2) end end)

local WATCHED = { graphicsquality = true, raidgraphicsquality = true, [LOOT_CVAR:lower()] = true }
ns.Listen("CVAR_UPDATE", function(name)
    name = Safe(name)
    if writing or type(name) ~= "string" or not ns.db then return end
    if WATCHED[name:lower()] then applyLater(1) end
end)

ns.Listen("PLAYER_REGEN_DISABLED", function()
    if Sparkle.active and ns.db.sparkle.hideInCombat then
        -- close the plate just before settings lock: else corpses keep a plate all fight
        setGate(false)
        release()
    end
end)

ns.Listen("PLAYER_REGEN_ENABLED", function()
    if pending.native then
        pending.native = nil
        Sparkle:ApplyNative()
    end
    if pending.soft == "apply" then
        applySoftTarget(pending.force)
    elseif pending.soft == "restore" then
        restoreSoftTarget()
    end
    pending.soft, pending.force = nil, nil
    if Sparkle.active then Sparkle:Evaluate() end
end)

ns.Listen("NAME_PLATE_UNIT_ADDED", function(unit)
    plates[unit] = true
    if Sparkle.active then Sparkle:Evaluate() end
end)

ns.Listen("NAME_PLATE_UNIT_REMOVED", function(unit)
    plates[unit] = nil
    local plate = plateOf(unit)
    if plate and plate == state.anchor then release() end
end)

ns.Listen("PLAYER_SOFT_INTERACT_CHANGED", function(old, new)
    old, new = Safe(old), Safe(new)
    -- a plate handed on from one target to the next doesn't show the change by itself
    if old and new and old ~= new then state.retarget = state.anchor ~= nil end
    if Sparkle.active then Sparkle:Evaluate() end
end)
