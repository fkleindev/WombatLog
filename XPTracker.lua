local ADDON, ns = ...
local XPTracker = {}
ns.XPTracker = XPTracker
local Safe = ns.Safe
local L = ns.L
local XPBar = ns.XPBar

-- A small XP bar that is always on screen, on a dark panel hanging from the top edge
-- of the screen. When XP comes in it springs down to a bigger size, fills with a
-- glow and the gained part lit, opens up to show "+342 XP" counting up, then settles
-- back. More XP while it is big keeps it big and adds up.

local GROW_STIFFNESS = 180   -- spring toward the target size
local GROW_DAMPING = 14      -- low: overshoots a little on the way up
local SHRINK_DAMPING = 26    -- settles back without wobbling
local TEXT_FADE = 0.4        -- the "+XP" text fades this long after the hold
local COUNT_UP = 0.5         -- seconds the gained XP counts up
local OPEN_SPEED = 10        -- how fast the panel opens for the "+XP" text
local MERGE = 1.2            -- a kill or quest this close to the XP is where it came from
local PAD = 6                -- panel padding
local RADIUS = 8             -- the panel's rounded bottom corners
local CORNER = "Interface\\AddOns\\WombatLog\\Media\\Corner"
local WHITE = "Interface\\Buttons\\WHITE8X8"

local SAMPLE_XP = 342

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function CreateFrames()
    local f = CreateFrame("Frame", "WombatLogXPTracker", UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    -- only sideways: it stays on the top edge
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local cfg = ns.db.xpTracker
        local s = UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        local cx = f:GetCenter()
        cfg.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", cfg.x, -cfg.offset)
    end)
    f:Hide()

    -- everything grows down from the top edge as one piece
    local c = CreateFrame("Frame", nil, f)
    c:SetPoint("TOP", f, "TOP")
    f.content = c

    -- the panel: a body, a strip between the two rounded corners, the corners
    local function piece()
        local t = c:CreateTexture(nil, "BACKGROUND", nil, -8)
        t:SetTexture(WHITE)
        t:SetVertexColor(0, 0, 0, 1)
        return t
    end
    f.bg = { piece(), piece(), piece(), piece() }
    local body, strip, left, right = f.bg[1], f.bg[2], f.bg[3], f.bg[4]
    body:SetPoint("TOPLEFT", c, "TOPLEFT")
    body:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, RADIUS)
    strip:SetPoint("TOPLEFT", c, "BOTTOMLEFT", RADIUS, RADIUS)
    strip:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -RADIUS, 0)
    left:SetTexture(CORNER)
    left:SetSize(RADIUS, RADIUS)
    left:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT")
    right:SetTexture(CORNER)
    right:SetTexCoord(1, 0, 0, 1) -- mirrored
    right:SetSize(RADIUS, RADIUS)
    right:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT")

    f.bar = XPBar.Create(c)
    f.level = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.level:SetPoint("RIGHT", f.bar, "LEFT", -6, 0)
    f.gain = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.gain:SetAlpha(0)

    f.overlay = f:CreateTexture(nil, "BACKGROUND", nil, -2)
    f.overlay:SetAllPoints()
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlayText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.overlayText:SetPoint("TOP", f, "BOTTOM", 0, -2)
    f.overlayText:SetText(L["WombatLog XP tracker - drag to move"])
    f.overlay:Hide()
    f.overlayText:Hide()
    return f
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local lastXP, lastMax

-- Shown fill, where the latest gain started, the fill it heads to, and the fill to
-- wrap to after a level up.
local shown, from, target, wrapTo
local gainAge            -- seconds since the latest gain, nil when there is none
local gained, shownGain = 0, 0
local gainKind           -- "kill", "quest" or nil (other XP): picks the gain's color
local source             -- { kind, t } of the latest kill or quest the kill alert saw
local scale, velocity = 1, 0
local open = 0           -- 0..1: how far the panel is opened for the "+XP" text
local restH, openH = 0, 0
local level, nextLevel   -- nextLevel shows once the bar wraps

local function atMaxLevel()
    if IsXPUserDisabled and Safe(IsXPUserDisabled()) then return true end
    local lvl = Safe(UnitLevel("player"))
    local max = GetMaxLevelForPlayerExpansion and Safe(GetMaxLevelForPlayerExpansion()) or MAX_PLAYER_LEVEL
    return lvl and max and lvl >= max or false
end

function XPTracker:Init()
    self.frame = CreateFrames()
    self.frame:SetScript("OnUpdate", function(_, dt) self:Step(dt) end)
    lastXP, lastMax = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    shown = XPBar.Fraction() or 0
    from, target = shown, shown
    level = Safe(UnitLevel("player"))
    self:Apply()
end

function XPTracker:Apply()
    local f = self.frame
    if not f then return end
    local T = ns.db.xpTracker
    f:SetScale(T.scale)
    f:ClearAllPoints()
    f:SetPoint("TOP", UIParent, "TOP", T.x, -T.offset)

    local font, _, outline, smallOutline = ns.AlertFonts(T)
    ns.SetFont(f.level, font, T.textSize, smallOutline)
    f.level:SetTextColor(1, 0.82, 0.18)
    ns.SetFont(f.gain, font, T.textSize, outline)
    local c = T.color
    XPBar.Apply(f.bar, T.bar, T.width, T.height, c, font, smallOutline)
    for _, t in ipairs(f.bg) do t:SetAlpha(T.bgOpacity) end

    -- one row with the level and the bar; the "+XP" text opens a second one below
    local rowH = math.max(T.height, T.textSize)
    restH = PAD * 2 + rowH
    openH = restH + T.textSize + 4
    f.bar:ClearAllPoints()
    f.bar:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", -PAD, -(PAD + (rowH - T.height) / 2))
    f.gain:ClearAllPoints()
    f.gain:SetPoint("TOP", f.content, "TOP", 0, -(PAD + rowH + 2))
    self.levelText = nil -- Render sizes the panel to the level text
    self:UpdateVisibility()
    self:Render()
end

-- The panel's width follows the level text, its height how far it is open.
function XPTracker:Layout()
    local f, T = self.frame, ns.db.xpTracker
    local levelW = T.showLevel and (math.ceil(f.level:GetStringWidth()) + 6) or 0
    local w = PAD * 2 + levelW + T.width
    f.content:SetSize(w, restH + (openH - restH) * open)
    f:SetSize(w, restH)
end

function XPTracker:UpdateVisibility()
    local f, T = self.frame, ns.db.xpTracker
    local show = self.unlocked or self.testing
        or (T.enabled and not (T.hideAtMax and atMaxLevel()) and XPBar.Fraction() ~= nil)
    f:SetShown(show and true or false)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- The gained XP's color: the kill or quest alert's, or the tracker's for other XP.
local function colorFor(kind)
    if kind == "kill" then return ns.db.killAlert.color end
    if kind == "quest" then return ns.db.questAlert.color end
    return nil
end

function XPTracker:Render()
    local f, T = self.frame, ns.db.xpTracker
    f.level:SetShown(T.showLevel)
    local text = T.showLevel and L["Lvl %d"]:format(level or 0) or ""
    f.level:SetText(text)
    if text ~= self.levelText then
        self.levelText = text
        self:Layout()
    end
    f.gain:SetText(L["+%s XP"]:format(ns.Full(shownGain)))
    local gc = colorFor(gainKind)
    local tc = gc or T.color
    f.gain:SetTextColor(tc[1], tc[2], tc[3])
    -- no glow at rest: it only lights up with a gain
    XPBar.Render(f.bar, T.bar, shown, from, gainAge or math.huge, 0, gc)
end

-- One frame: spring the size, fill the bar, count the XP up, fade the text.
function XPTracker:Step(dt)
    local f, T = self.frame, ns.db.xpTracker
    if not f:IsShown() then return end
    if not gainAge and scale == 1 and open == 0 and shown == target and not wrapTo then return end -- at rest
    if dt > 0.1 then dt = 0.1 end -- a hitch must not throw the spring off
    local hold = 0.25 + T.popHold
    local big = gainAge and gainAge < hold

    -- size: a spring toward popScale while big, back to 1 after
    local goal = big and T.popScale or 1
    local damping = big and GROW_DAMPING or SHRINK_DAMPING
    velocity = velocity + (GROW_STIFFNESS * (goal - scale) - damping * velocity) * dt
    scale = scale + velocity * dt
    if not big and math.abs(scale - 1) < 0.001 and math.abs(velocity) < 0.01 then
        scale, velocity = 1, 0
    end
    f.content:SetScale(math.max(0.2, scale))

    -- the panel opens downward for the "+XP" text while big
    local openGoal = (big and T.popText) and 1 or 0
    open = open + (openGoal - open) * math.min(1, dt * OPEN_SPEED)
    if math.abs(openGoal - open) < 0.005 then open = openGoal end
    self:Layout()

    -- fill: head for the target, wrap to 0 after a level up
    if shown ~= target then
        local d = target - shown
        shown = math.abs(d) < 0.002 and target or shown + d * math.min(1, dt * T.bar.speed)
    end
    if wrapTo and shown >= 0.999 then
        shown, from, target, wrapTo = 0, 0, wrapTo, nil
        level = nextLevel or Safe(UnitLevel("player")) or level
        nextLevel = nil
    end

    if gainAge then
        gainAge = gainAge + dt
        if shownGain < gained then
            local p = math.min(1, gainAge / COUNT_UP)
            shownGain = math.floor(gained * (1 - (1 - p) * (1 - p)) + 0.5)
        end
        local textAlpha = 1
        if gainAge > hold then textAlpha = math.max(0, 1 - (gainAge - hold) / TEXT_FADE) end
        f.gain:SetAlpha(T.popText and textAlpha or 0)
        if not big and scale == 1 and open == 0 and shown == target and textAlpha <= 0 then
            -- settled: the gain is over
            gainAge, gained, shownGain, gainKind = nil, 0, 0, nil
            if self.testing then
                self.testing = nil
                shown = XPBar.Fraction() or 0
                from, target = shown, shown
                self:UpdateVisibility()
            end
        end
    end
    self:Render()
end

-- XP came in: delta XP, the bar goes to toFrac (1 and on to wrap after a level up).
function XPTracker:Gain(delta, toFrac, wrap)
    if not gainAge or gainAge > 0.25 + ns.db.xpTracker.popHold then
        -- a new pop: the gain is lit from where the bar is now, the count starts over
        from, gained, shownGain = shown, 0, 0
    end
    gained = gained + delta
    gainAge = 0
    -- the kill or quest message often comes first; if not, MarkSource fixes it up
    gainKind = (source and GetTime() - source.t <= MERGE) and source.kind or nil
    if wrap then
        target, wrapTo = 1, wrap
    elseif wrapTo then
        wrapTo = toFrac -- still on the way to 100%: land on the newest XP after the wrap
    else
        target = toFrac
    end
end

-- A kill or quest gives XP now: its color for the gain, also one shown a moment ago.
function XPTracker:MarkSource(kind)
    source = { kind = kind, t = GetTime() }
    if gainAge and gainAge <= MERGE then
        gainKind = kind
        self:Render()
    end
end

---------------------------------------------------------------------------
-- Test and positioning
---------------------------------------------------------------------------

function XPTracker:Test()
    if self.unlocked then self:SetLocked(true) end
    self.testing = true
    self:UpdateVisibility()
    local frac = XPBar.Fraction() or 0.4
    self:Gain(SAMPLE_XP, math.min(1, frac + 0.06))
end

function XPTracker:SetLocked(locked)
    self.unlocked = not locked or nil
    local f = self.frame
    f:EnableMouse(not locked)
    f.overlay:SetShown(not locked)
    f.overlayText:SetShown(not locked)
    self:UpdateVisibility()
    if ns.Config then ns.Config:RefreshAll() end
end

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------

ns.Listen("PLAYER_XP_UPDATE", function()
    local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    if not xp or not max or max <= 0 then return end
    if lastXP and lastMax and lastMax > 0 and XPTracker.frame then
        local leveled = xp < lastXP
        local delta = leveled and (lastMax - lastXP + xp) or (xp - lastXP)
        if delta > 0 then
            if XPTracker.testing then
                XPTracker.testing = nil
                gainAge = nil
            end
            XPTracker:UpdateVisibility()
            XPTracker:Gain(delta, xp / max, leveled and xp / max or nil)
        end
    end
    lastXP, lastMax = xp, max
end)

ns.Listen("PLAYER_LEVEL_UP", function(newLevel)
    -- the new level shows once the bar wraps (this can come before the XP update),
    -- or a moment later if no wrap comes
    nextLevel = Safe(newLevel) or nextLevel
    C_Timer.After(2, function()
        if nextLevel and not wrapTo then
            level, nextLevel = nextLevel, nil
            if XPTracker.frame then XPTracker:Render() end
        end
    end)
    if XPTracker.frame then XPTracker:UpdateVisibility() end
end)

local function refresh()
    if not XPTracker.frame then return end
    XPTracker:UpdateVisibility()
    if not gainAge and not XPTracker.testing then
        shown = XPBar.Fraction() or shown
        from, target = shown, shown
        if not nextLevel then level = Safe(UnitLevel("player")) or level end
    end
    XPTracker:Render()
end
ns.Listen("UPDATE_EXHAUSTION", refresh)
ns.Listen("PLAYER_UPDATE_RESTING", refresh)
ns.Listen("PLAYER_ENTERING_WORLD", function()
    lastXP, lastMax = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    refresh()
end)
