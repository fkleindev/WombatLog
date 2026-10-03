local ADDON, ns = ...
local Swing = {}
ns.Swing = Swing
local Safe = ns.Safe

-- The swing timer lives in a lane inside the log window, right under the header.
-- Active bars (main hand, off hand, ranged) share the lane's height, so the feed
-- below never shifts.

local WHITE = "Interface\\Buttons\\WHITE8X8"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local IDLE_HIDE = 3 -- seconds a finished bar stays before it clears
local RANGED_SPELLS = { [75] = true, [5019] = true } -- Auto Shot, Shoot (wands)
local ORDER = { "main", "off", "ranged" }
local SAMPLE = { main = 0.6, off = 0.35 }

local function CreateBar(lane)
    local b = CreateFrame("StatusBar", nil, lane)
    b:SetStatusBarTexture(WHITE)
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b.spark = b:CreateTexture(nil, "OVERLAY")
    b.spark:SetTexture(SPARK)
    b.spark:SetBlendMode("ADD")
    b.time = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.time:SetPoint("RIGHT", -2, 0)
    b:Hide()
    return b
end

-- Splits the lane between the bars that have something to show.
local function Layout()
    local lane = Swing.lane
    local shown = {}
    for _, key in ipairs(ORDER) do
        local b = Swing.bars[key]
        if b.active or b.sample then shown[#shown + 1] = b else b:Hide() end
    end
    lane.track:SetShown(#shown > 0)
    if #shown == 0 then return end

    local cfg = ns.db.swing
    local h = (cfg.height - (#shown - 1)) / #shown
    for i, b in ipairs(shown) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", lane, "TOPLEFT", 0, -(i - 1) * (h + 1))
        b:SetPoint("RIGHT", lane, "RIGHT")
        b:SetHeight(h)
        b.spark:SetSize(8, h * 2.4)
        b.time:SetShown(cfg.showTime and h >= 7)
        ns.SetFont(b.time, ns.db.appearance.nameFont, math.max(7, math.floor(h)), "OUTLINE")
        b:Show()
    end
end

local function OnUpdate()
    local now, changed = GetTime(), false
    for _, key in ipairs(ORDER) do
        local b = Swing.bars[key]
        if b.active then
            local elapsed = now - b.start
            if elapsed > b.dur + IDLE_HIDE then
                b.active = false
                changed = true
            else
                local p = math.min(1, elapsed / b.dur)
                b:SetValue(p)
                b.spark:SetPoint("CENTER", b, "LEFT", p * b:GetWidth(), 0)
                b.spark:SetShown(p < 1)
                b.time:SetText(p < 1 and string.format("%.1f", b.dur - elapsed) or "")
            end
        end
    end
    if changed then Layout() end
end

-- Called by Display:Init with the lane frame it reserved in the log window.
function Swing:Init(lane)
    self.lane = lane
    lane.track = lane:CreateTexture(nil, "BACKGROUND")
    lane.track:SetAllPoints()
    lane.track:SetColorTexture(0, 0, 0, 0.35)
    lane:SetScript("OnUpdate", OnUpdate)
    self.bars = {}
    for _, key in ipairs(ORDER) do self.bars[key] = CreateBar(lane) end
end

-- Display sizes and places the lane; this applies colors and refreshes the bars.
function Swing:Apply()
    if not self.lane then return end
    local cfg = ns.db.swing
    local colors = { main = cfg.color, off = cfg.offColor, ranged = cfg.rangedColor }
    for key, b in pairs(self.bars) do
        local c = colors[key]
        b:SetStatusBarColor(c[1], c[2], c[3], 0.9)
    end
    if not cfg.enabled then self:StopAll() end
    Layout()
end

function Swing:Start(key, dur)
    local cfg = ns.db.swing
    if not self.lane or not cfg.enabled then return end
    if key == "off" and not cfg.offhand then return end
    if key == "ranged" and not cfg.ranged then return end
    local b = self.bars[key]
    b.start, b.dur, b.active = GetTime(), math.max(dur or 2, 0.1), true
    Layout()
end

function Swing:StopAll()
    for _, b in pairs(self.bars) do b.active = false end
    Layout()
end

-- Static bars for the settings preview of the log window.
function Swing:SetSample(on)
    if not self.lane then return end
    for key, b in pairs(self.bars) do
        b.sample = on and SAMPLE[key] ~= nil and (key ~= "off" or ns.db.swing.offhand) or nil
        if b.sample and not b.active then
            b:SetValue(SAMPLE[key])
            b.spark:SetPoint("CENTER", b, "LEFT", SAMPLE[key] * b:GetWidth(), 0)
            b.spark:Show()
            b.time:SetText(string.format("%.1f", (1 - SAMPLE[key]) * 2.6))
        end
    end
    Layout()
end

-- Settings button: a few simulated main-hand swings in the preview.
function Swing:Test()
    local speed = Safe(UnitAttackSpeed("player")) or 2
    self:Start("main", speed)
    if self.testTicker then self.testTicker:Cancel() end
    self.testTicker = C_Timer.NewTicker(speed, function() self:Start("main", speed) end, 3)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

ns.Listen("PLAYER_SWING", function(...)
    if not (ns.db and ns.db.swing.enabled and Swing.lane) then return end
    local main, off = UnitAttackSpeed("player")
    main, off = Safe(main) or 2, Safe(off)

    -- the payload may say which hand swung; read it defensively
    local isOff
    for i = 1, select("#", ...) do
        local v = Safe((select(i, ...)))
        if type(v) == "boolean" then
            isOff = v
        elseif type(v) == "string" then
            local u = v:upper()
            if u:find("OFF") then isOff = true elseif u:find("MAIN") then isOff = false end
        end
    end
    if isOff == nil and off then
        -- no hint: a swing early in the main-hand cycle has to be the off-hand
        local m = Swing.bars.main
        isOff = m.active and (GetTime() - m.start) < m.dur * 0.5
    end
    if isOff then
        Swing:Start("off", off or main)
    else
        Swing:Start("main", main)
    end
end)

ns.Listen("UNIT_SPELLCAST_SUCCEEDED", function(_, _, spellID)
    spellID = Safe(spellID)
    if not (spellID and RANGED_SPELLS[spellID] and ns.db and ns.db.swing.enabled and Swing.lane) then return end
    local speed = Safe(UnitRangedDamage("player"))
    if speed and speed > 0 then Swing:Start("ranged", speed) end
end, "player")

ns.Listen("PLAYER_REGEN_ENABLED", function()
    if not Swing.lane then return end
    C_Timer.After(0.5, function()
        if not Safe(UnitAffectingCombat("player")) then Swing:StopAll() end
    end)
end)
