local ADDON, ns = ...
local GCD = {}
ns.GCD = GCD
local Safe, SafeTable = ns.Safe, ns.SafeTable

-- A ring at the mouse cursor that runs down during the global cooldown. In the last
-- moments, when the game already takes the next spell (the spell queue window), it
-- changes color: press the next key now.
--
-- The time comes from the global cooldown's own spell (61304). Forever and Retail may
-- keep it secret in combat; then your casts start the ring with the last readable
-- length (out of combat, or earlier in the fight), 1.5 seconds until there is one.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local RINGS = { thin = MEDIA .. "Ring10", normal = MEDIA .. "Ring20", thick = MEDIA .. "Ring30" }
local GCD_SPELL = 61304
local MAX_GCD = 2           -- longer cooldowns on 61304 aren't a global cooldown
local FALLBACK = 1.5
local QUEUE_DEFAULT = 400   -- ms, the game's default spell queue window
local TEST_TIME = 5
-- casts that never start the global cooldown: Auto Attack, Auto Shot, Shoot (wands)
local NO_GCD = { [6603] = true, [75] = true, [5019] = true }

local frame, cd, track
local startAt, length = 0, 0   -- the running global cooldown
local learned                  -- last readable length
local queued = false           -- in the spell queue window
local fighting = false
local testUntil = 0

local function cfg() return ns.db.gcd end

---------------------------------------------------------------------------
-- Reading the global cooldown
---------------------------------------------------------------------------

-- start, duration of the global cooldown, or nil when the game won't tell.
local function readGCD()
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, c = pcall(C_Spell.GetSpellCooldown, GCD_SPELL)
        c = ok and SafeTable(c)
        if c then return Safe(c.startTime), Safe(c.duration) end
    elseif GetSpellCooldown then
        local ok, s, d = pcall(GetSpellCooldown, GCD_SPELL)
        if ok then return Safe(s), Safe(d) end
    end
end

local function queueWindow()
    local ms = tonumber(GetCVar and GetCVar("SpellQueueWindow") or nil) or QUEUE_DEFAULT
    return math.max(0, ms) / 1000
end

---------------------------------------------------------------------------
-- The ring
---------------------------------------------------------------------------

local function paint()
    local c = cfg()
    local col = (queued and c.queue) and c.queueColor or c.color
    cd:SetSwipeColor(col[1], col[2], col[3], c.alpha)
end

local function follow()
    local x, y = GetCursorPosition()
    local s = frame:GetEffectiveScale()
    local c = cfg()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s + c.dx, y / s + c.dy)
end

local function stop()
    length = 0
    if frame then frame:Hide() end
end

local function style()
    local c = cfg()
    local tex = RINGS[c.thickness] or RINGS.normal
    frame:SetSize(c.size, c.size)
    cd:SetSwipeTexture(tex)
    cd:SetReverse(c.fill and true or false)
    track:SetTexture(tex)
    local col = c.color
    track:SetVertexColor(col[1], col[2], col[3], c.alpha * 0.25)
    track:SetShown(c.background and true or false)
    paint()
end

local function build()
    if frame then return end
    frame = CreateFrame("Frame", nil, UIParent)
    frame:SetFrameStrata("TOOLTIP")
    frame:EnableMouse(false)
    frame:Hide()

    track = frame:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()

    cd = CreateFrame("Cooldown", nil, frame)
    cd:SetAllPoints()
    cd:EnableMouse(false)
    cd:SetDrawEdge(false)
    if cd.SetDrawBling then cd:SetDrawBling(false) end
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
    cd.noCooldownCount = true -- OmniCC and friends: no numbers on the ring

    frame:SetScript("OnUpdate", function()
        follow()
        local left = startAt + length - GetTime()
        if left <= 0 then
            stop()
            return
        end
        local q = left <= queueWindow()
        if q ~= queued then
            queued = q
            paint()
        end
    end)
end

local function begin(start, duration)
    if not (GCD.active or GetTime() < testUntil) then return end
    if GetTime() >= start + duration then return end
    if frame:IsShown() and math.abs(start - startAt) < 0.01 and math.abs(duration - length) < 0.01 then return end
    startAt, length = start, duration
    queued = false
    style()
    cd:SetCooldown(start, duration)
    follow()
    frame:Show()
end

-- After a cast or a cooldown update: the game's values when it tells them, else the
-- last readable length starting now (fromCast: only when your own cast caused it).
local function check(fromCast)
    if not GCD.active then return end
    if cfg().combatOnly and not fighting then return end
    local start, duration = readGCD()
    if start and duration then
        if duration > 0 and duration <= MAX_GCD then
            learned = duration
            begin(start, duration)
        end
    elseif fromCast then
        -- while it runs, only spells without a global cooldown can be cast
        if frame:IsShown() and startAt + length - GetTime() > 0.05 then return end
        begin(GetTime(), learned or FALLBACK)
    end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

function GCD:Init()
    self.ready = true
    fighting = Safe(UnitAffectingCombat("player")) and true or false
    self:Apply()
end

function GCD:Apply()
    if not (ns.db and self.ready) then return end
    build()
    self.active = cfg().enabled and true or false
    if self.active and frame:IsShown() then
        style()
    elseif GetTime() >= testUntil then
        stop()
    end
end

-- Settings button: a few global cooldowns in a row at the cursor.
function GCD:Test()
    if not ns.db then return end
    build()
    testUntil = GetTime() + TEST_TIME
    local len = learned or FALLBACK
    local function one()
        if GetTime() + len > testUntil then return end
        begin(GetTime(), len)
        C_Timer.After(len + 0.3, one)
    end
    one()
end

-- /wl debug: what the game says about the global cooldown right now.
function GCD:Debug()
    if not ns.db then return end
    local start, duration = readGCD()
    local state
    if start == nil or duration == nil then
        state = "secret or unknown"
    elseif duration > 0 then
        state = ("%.2fs, %.2fs left"):format(duration, math.max(0, start + duration - GetTime()))
    else
        state = "not running"
    end
    ns.Print(("global cooldown: %s, game: %s, learned %s, queue window %d ms"):format(
        self.active and "on" or "off", state,
        learned and ("%.2fs"):format(learned) or "-", queueWindow() * 1000))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

ns.Listen("SPELL_UPDATE_COOLDOWN", function() check(false) end)

-- Spells with a cast time start the global cooldown when the cast starts; their
-- "succeeded" at the end of the cast must not start it again.
local castStarted = {} -- cast GUID -> time its cast started

local function cast(guid, spellID, finished)
    if not GCD.active then return end
    spellID = Safe(spellID)
    if spellID and NO_GCD[spellID] then return end
    guid = Safe(guid)
    local now = GetTime()
    if finished then
        if guid and castStarted[guid] then
            castStarted[guid] = nil
            return
        end
    elseif guid then
        for g, t in pairs(castStarted) do
            if now - t > 60 then castStarted[g] = nil end -- interrupted casts
        end
        castStarted[guid] = now
    end
    check(true)
end

ns.Listen("UNIT_SPELLCAST_START", function(_, guid, spellID) cast(guid, spellID, false) end, "player")
ns.Listen("UNIT_SPELLCAST_CHANNEL_START", function(_, guid, spellID) cast(guid, spellID, false) end, "player")
ns.Listen("UNIT_SPELLCAST_SUCCEEDED", function(_, guid, spellID) cast(guid, spellID, true) end, "player")

ns.Listen("PLAYER_REGEN_DISABLED", function() fighting = true end)
ns.Listen("PLAYER_REGEN_ENABLED", function()
    fighting = false
    if ns.db and GCD.active and cfg().combatOnly and GetTime() >= testUntil then stop() end
end)
