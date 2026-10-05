local ADDON, ns = ...
local Resources = {}
ns.Resources = Resources
local Safe = ns.Safe

-- Personal resource display: health, power, druid mana, combo points and a cast bar,
-- stacked under your character. On Forever, player health and power are secret in
-- combat: bars get the values straight from the API (StatusBar accepts secrets) and
-- this file never does maths or comparisons on them.

local WHITE = "Interface\\Buttons\\WHITE8X8"
local GRADIENT = "Interface\\AddOns\\WombatLog\\Media\\Gradient"
-- shapes for combo points; squares use a plain white mask (no effect)
local PIP_MASKS = {
    circles = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    diamonds = "Interface\\AddOns\\WombatLog\\Media\\Diamond",
}
local MAX_PIPS = 7
local MANA, RAGE, ENERGY, COMBO = 0, 1, 3, 4

-- Classic clients may keep combo points on the target instead of the player.
local function comboPoints()
    local cp = Safe(UnitPower("player", COMBO))
    if (cp == nil or cp == 0) and GetComboPoints then
        local onTarget = Safe(GetComboPoints("player", "target"))
        if onTarget and onTarget > 0 then return onTarget end
    end
    return cp
end
local ORDER = { "health", "power", "druidMana", "combo", "castbar" }

-- The saved bar order, top to bottom, with unknown or doubled keys dropped and
-- missing ones added in the default order.
function Resources.Order()
    local list, seen, known = {}, {}, {}
    for _, key in ipairs(ORDER) do known[key] = true end
    for _, key in ipairs(ns.db.resources.order or {}) do
        if known[key] and not seen[key] then
            seen[key] = true
            list[#list + 1] = key
        end
    end
    for _, key in ipairs(ORDER) do
        if not seen[key] then list[#list + 1] = key end
    end
    return list
end

local TEXTURES = {
    flat = WHITE,
    blizzard = "Interface\\TargetingFrame\\UI-StatusBar",
    raid = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill",
}

local POWER_COLORS = {
    [0] = { 0.00, 0.55, 1.00 }, [1] = { 1.00, 0.10, 0.10 }, [2] = { 1.00, 0.50, 0.25 },
    [3] = { 1.00, 0.90, 0.10 }, [6] = { 0.00, 0.82, 1.00 },
}

local PREVIEW = { health = 0.7, power = 0.45, druidMana = 0.8, combo = 3 }

local function isSecret(v)
    return v ~= nil and issecretvalue ~= nil and issecretvalue(v)
end

local function sharedMedia()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

function Resources.TextureOptions()
    local list = {
        { text = "Flat", value = "flat" },
        { text = "Blizzard", value = "blizzard" },
        { text = "Raid", value = "raid" },
    }
    local LSM = sharedMedia()
    if LSM then
        for _, name in ipairs(LSM:List("statusbar")) do
            list[#list + 1] = { text = "SharedMedia: " .. name, value = "lsm:" .. name }
        end
    end
    return list
end

local function barTexture(key)
    local lsmName = key and key:match("^lsm:(.+)$")
    if lsmName then
        local LSM = sharedMedia()
        local path = LSM and LSM:Fetch("statusbar", lsmName, true)
        if path then return path end
    end
    return TEXTURES[key] or WHITE
end
ns.BarTexture = barTexture -- also used by the kill alert's XP bar

local function playerClass()
    local _, class = UnitClass("player")
    return class
end

local function powerType()
    return Safe((UnitPowerType("player"))) or MANA
end

---------------------------------------------------------------------------
-- Text: exact when readable, best effort when secret, empty otherwise
---------------------------------------------------------------------------

local percentCurve
local function healthPercentSecret()
    if not UnitHealthPercent then return nil end
    if not percentCurve and C_CurveUtil and C_CurveUtil.CreateCurve then
        percentCurve = C_CurveUtil.CreateCurve()
        percentCurve:AddPoint(0, 0)
        percentCurve:AddPoint(1, 100)
    end
    local ok, v = pcall(UnitHealthPercent, "player", false, percentCurve)
    return ok and v or nil
end

local function setText(fs, mode, cur, max, isHealth)
    if mode == "none" or cur == nil then
        fs:SetText("")
        return
    end
    if not isSecret(cur) and not isSecret(max) and max then
        if mode == "value" then
            fs:SetText(ns.Short(cur))
        elseif mode == "valuemax" then
            fs:SetText(ns.Short(cur) .. " / " .. ns.Short(max))
        elseif mode == "percent" then
            fs:SetText(max > 0 and (math.floor(cur / max * 100 + 0.5) .. "%") or "")
        elseif mode == "deficit" then
            fs:SetText(cur < max and ("-" .. ns.Short(max - cur)) or "")
        end
        return
    end
    -- secret: hand the value to the client's formatter; never show a stale number
    local ok = false
    if mode == "value" or mode == "valuemax" then
        if AbbreviateNumbers then
            local okAbbr, s = pcall(AbbreviateNumbers, cur)
            if okAbbr and s then
                if mode == "valuemax" and not isSecret(max) then
                    ok = pcall(fs.SetFormattedText, fs, "%s / %s", s, ns.Short(max))
                else
                    ok = pcall(fs.SetText, fs, s)
                end
            end
        end
        if not ok then ok = pcall(fs.SetFormattedText, fs, "%d", cur) end
    elseif mode == "percent" and isHealth then
        local p = healthPercentSecret()
        if p ~= nil then ok = pcall(fs.SetFormattedText, fs, "%.0f%%", p) end
    end
    if not ok then fs:SetText("") end
end

---------------------------------------------------------------------------
-- Bars
---------------------------------------------------------------------------

-- A 1 px black frame around b, just outside it.
local function makeEdges(b)
    local edges = {}
    for i, side in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0, -1 },
                            { "TOPLEFT", "BOTTOMLEFT", -1, 0 }, { "TOPRIGHT", "BOTTOMRIGHT", 1, 0 } }) do
        local t = b:CreateTexture(nil, "BACKGROUND", nil, -1)
        t:SetColorTexture(0, 0, 0, 1)
        t:SetPoint(side[1], b, side[1], side[3], side[4])
        t:SetPoint(side[2], b, side[2], side[3], side[4])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
        edges[i] = t
    end
    return edges
end

local function CreateBar(parent)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    -- gloss: the gradient texture turned to fade from the top edge down
    b.gloss = b:CreateTexture(nil, "OVERLAY")
    b.gloss:SetAllPoints()
    b.gloss:SetTexture(GRADIENT)
    b.gloss:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
    b.gloss:SetVertexColor(1, 1, 1, 0.22)
    b.edges = makeEdges(b)
    b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.left:SetPoint("LEFT", 4, 0)
    b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.right:SetPoint("RIGHT", -4, 0)
    b:Hide()
    return b
end

-- Newer clients can glide a bar to a value themselves, secret values included.
local EASE = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
local easeWorks = EASE ~= nil

local function setSecretValue(b, cur)
    if easeWorks and ns.db.resources.smooth then
        if pcall(b.SetValue, b, cur, EASE) then return end
        easeWorks = false -- the client doesn't take it after all
    end
    b:SetValue(cur)
end

-- Plain values glide here (smooth); secret ones go to the widget, which glides
-- them itself where the client can.
local function setBar(b, cur, max)
    b:SetMinMaxValues(0, max or 1)
    if isSecret(cur) or isSecret(max) then
        b.target, b.shownValue = nil, nil
        setSecretValue(b, cur)
    elseif ns.db.resources.smooth and b.shownValue then
        b.target = cur or 0
    else
        b.target = nil
        b.shownValue = cur or 0
        b:SetValue(cur or 0)
    end
end

local function styleBar(b, cfg, color)
    local R = ns.db.resources
    local A = ns.db.appearance
    b:SetStatusBarTexture(barTexture(R.texture))
    if color then b:SetStatusBarColor(color[1], color[2], color[3], 1) end
    if R.bgStyle == "fade" then
        -- the same dark side fade as the log rows
        b.bg:SetTexture(GRADIENT)
        b.bg:SetTexCoord(0, 1, 0, 1)
        b.bg:SetVertexColor(0, 0, 0, R.bgOpacity)
    else
        b.bg:SetColorTexture(0, 0, 0, R.bgOpacity)
        b.bg:SetVertexColor(1, 1, 1, 1)
    end
    b.gloss:SetShown(R.gloss)
    for _, e in ipairs(b.edges) do e:SetShown(R.border) end
    -- numbers in the log's number font, names (cast bar) in its name font
    local size = cfg.textSize or 9
    local outline = A.outline == "" and "OUTLINE" or A.outline
    ns.SetFont(b.left, b == Resources.bars.castbar and A.nameFont or A.amountFont, size, outline)
    ns.SetFont(b.right, A.amountFont, size, outline)
end

---------------------------------------------------------------------------
-- Which elements apply right now
---------------------------------------------------------------------------

local function hasCombo()
    local class = playerClass()
    return class == "ROGUE" or (class == "DRUID" and powerType() == ENERGY)
end

local function applies(key)
    local R = ns.db.resources
    local cfg = R[key]
    if not cfg.enabled then return false end
    if Resources.preview then return true end
    if key == "druidMana" then
        return playerClass() == "DRUID" and powerType() ~= MANA
    elseif key == "combo" then
        if not hasCombo() then return false end
        if cfg.onlyWhenActive then
            local cp = comboPoints()
            return cp == nil or cp > 0 -- unreadable counts as active
        end
        return true
    elseif key == "castbar" then
        return Resources.cast.active
    end
    return true
end

-- The cast bar comes and goes. With nothing shown below it, it hangs under the
-- display; with nothing above it, over the display; in between it keeps its slot
-- even while you don't cast, so the bars around it never jump.
local function Layout()
    local f, R = Resources.frame, ns.db.resources
    local order = Resources.Order()
    local castAt, before, after = 0, false, false
    for i, key in ipairs(order) do
        if key == "castbar" then castAt = i end
    end
    for i, key in ipairs(order) do
        if key ~= "castbar" and applies(key) then
            if i < castAt then before = true else after = true end
        end
    end

    local y = 0
    for _, key in ipairs(order) do
        local b = Resources.bars[key]
        local h = R[key].height
        if key == "castbar" then
            b:ClearAllPoints()
            if not after then
                b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
            elseif not before then
                b:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, R.spacing)
            else
                b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
                if R.castbar.enabled then y = y + h + R.spacing end
            end
            b:SetPoint("RIGHT", f, "RIGHT", 0, 0)
            b:SetHeight(h)
            b:SetShown(applies(key))
        elseif applies(key) then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
            b:SetPoint("RIGHT", f, "RIGHT", 0, 0)
            b:SetHeight(h)
            b:Show()
            y = y + h + R.spacing
        else
            b:Hide()
        end
    end
    f:SetHeight(math.max(1, y - R.spacing))
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

-- How many combo points there can be (5 when the game keeps it secret).
local function comboMax()
    local max = UnitPowerMax("player", COMBO)
    if isSecret(max) or not max or max <= 0 then return 5 end
    return math.min(max, MAX_PIPS)
end

-- A layer over the combo points for the bar style's gloss and segment lines
-- (the points are frames of their own and would cover the lane's textures).
local function comboLayer(b)
    if b.layer then return b.layer end
    local l = CreateFrame("Frame", nil, b)
    l:SetAllPoints()
    l:SetFrameLevel(b:GetFrameLevel() + 5)
    l.gloss = l:CreateTexture(nil, "OVERLAY")
    l.gloss:SetAllPoints()
    l.gloss:SetTexture(GRADIENT)
    l.gloss:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
    l.gloss:SetVertexColor(1, 1, 1, 0.22)
    b.layer = l
    return l
end

local function comboTicks(b, n, show)
    b.ticks = b.ticks or {}
    local w = ns.db.resources.width
    for i = 1, math.max(n - 1, #b.ticks) do
        local t = b.ticks[i]
        if not t then
            t = comboLayer(b):CreateTexture(nil, "OVERLAY", nil, 1)
            t:SetColorTexture(0, 0, 0, 0.9)
            t:SetWidth(1)
            b.ticks[i] = t
        end
        if show and i < n then
            t:ClearAllPoints()
            t:SetPoint("TOP", b, "TOPLEFT", w * i / n, 0)
            t:SetPoint("BOTTOM", b, "BOTTOMLEFT", w * i / n, 0)
            t:Show()
        else
            t:Hide()
        end
    end
end

-- One combo point: a bar from i-1 to i, so handing it the count fills it fully or
-- not at all. That works with secret counts, which can't be compared.
local function getPip(b, i)
    b.pips = b.pips or {}
    local p = b.pips[i]
    if p then return p end
    p = CreateFrame("StatusBar", nil, b)
    p:SetMinMaxValues(i - 1, i)
    p:SetValue(0)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.edges = makeEdges(p)
    -- the backing of round and diamond points: their border
    p.backing = p:CreateTexture(nil, "BACKGROUND", nil, -2)
    p.backing:SetPoint("TOPLEFT", -1, 1)
    p.backing:SetPoint("BOTTOMRIGHT", 1, -1)
    p.backing:SetColorTexture(0, 0, 0, 1)
    p.mask = p:CreateMaskTexture()
    p.mask:SetAllPoints()
    p.bg:AddMaskTexture(p.mask)
    p.backingMask = p:CreateMaskTexture()
    p.backingMask:SetAllPoints(p.backing)
    p.backing:AddMaskTexture(p.backingMask)
    b.pips[i] = p
    return p
end

local function lerp(a, b, t) return a + (b - a) * t end

-- Places, shapes and colors the combo points. Cheap to call often: it only redoes
-- the work when the count or a setting changed.
local function styleCombo(b, n)
    local R = ns.db.resources
    local C = R.combo
    local key = n .. C.style .. C.height .. C.gap .. R.width .. tostring(C.gradient)
    if b.comboKey == key then return end
    b.comboKey = key

    local style = C.style
    local isBar = style == "bar" or not (style == "squares" or PIP_MASKS[style])
    local shaped = PIP_MASKS[style] ~= nil
    local gap = isBar and 0 or C.gap
    local w = shaped and C.height or (R.width - gap * (n - 1)) / n
    local x0 = (R.width - (w * n + gap * (n - 1))) / 2
    local tex = barTexture(R.texture)
    local mask = PIP_MASKS[style] or WHITE

    for i = 1, math.max(n, b.pips and #b.pips or 0) do
        local p = getPip(b, i)
        if i <= n then
            p:ClearAllPoints()
            p:SetPoint("TOPLEFT", b, "TOPLEFT", x0 + (i - 1) * (w + gap), 0)
            p:SetSize(w, C.height)
            p:SetStatusBarTexture(tex)
            local fill = p:GetStatusBarTexture()
            if p.maskedFill ~= fill then
                fill:AddMaskTexture(p.mask)
                p.maskedFill = fill
            end
            p.mask:SetTexture(mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            p.backingMask:SetTexture(mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            local c = C.color
            if C.gradient and n > 1 then
                local t, c2 = (i - 1) / (n - 1), C.color2
                c = { lerp(c[1], c2[1], t), lerp(c[2], c2[2], t), lerp(c[3], c2[3], t) }
            end
            p:SetStatusBarColor(c[1], c[2], c[3], 1)
            -- in the bar style the whole lane has one background and border
            p.bg:SetColorTexture(0, 0, 0, R.bgOpacity)
            p.bg:SetShown(not isBar)
            for _, e in ipairs(p.edges) do e:SetShown(R.border and not isBar and not shaped) end
            p.backing:SetShown(R.border and shaped)
            p:Show()
        else
            p:Hide()
        end
    end

    b:SetValue(0) -- the points do the filling
    b.bg:SetShown(isBar)
    b.gloss:Hide()
    comboLayer(b).gloss:SetShown(isBar and R.gloss)
    for _, e in ipairs(b.edges) do e:SetShown(isBar and R.border) end
    comboTicks(b, n, isBar and C.ticks)
end

-- cp may be secret: it only goes to the points' SetValue
local function setCombo(b, n, cp)
    styleCombo(b, n)
    if cp == nil then cp = 0 end
    for i = 1, n do b.pips[i]:SetValue(cp) end
end

-- Power and druid mana. Forever and Retail let them regenerate continuously, but
-- the power event only fires every so often, so this also runs every frame.
function Resources:UpdatePower()
    local R, bars = ns.db.resources, self.bars
    local pt = powerType()
    local p, pMax = UnitPower("player", pt), UnitPowerMax("player", pt)
    setBar(bars.power, p, pMax)
    setText(bars.power.left, R.power.textLeft, p, pMax)
    setText(bars.power.right, R.power.textRight, p, pMax)
    if bars.druidMana:IsShown() then
        setBar(bars.druidMana, UnitPower("player", MANA), UnitPowerMax("player", MANA))
    end
end

function Resources:Update()
    if not self.frame then return end
    local R = ns.db.resources
    local bars = self.bars

    if self.preview then
        setBar(bars.health, PREVIEW.health, 1)
        setText(bars.health.left, R.health.textLeft, 7000, 10000, true)
        setText(bars.health.right, R.health.textRight, 7000, 10000, true)
        setBar(bars.power, PREVIEW.power, 1)
        setText(bars.power.left, R.power.textLeft, 1350, 3000)
        setText(bars.power.right, R.power.textRight, 1350, 3000)
        setBar(bars.druidMana, PREVIEW.druidMana, 1)
        setCombo(bars.combo, 5, PREVIEW.combo)
        return
    end

    local hp, hpMax = UnitHealth("player"), UnitHealthMax("player")
    setBar(bars.health, hp, hpMax)
    setText(bars.health.left, R.health.textLeft, hp, hpMax, true)
    setText(bars.health.right, R.health.textRight, hp, hpMax, true)

    self:UpdatePower()
    if bars.combo:IsShown() then
        setCombo(bars.combo, comboMax(), comboPoints() or UnitPower("player", COMBO))
    end
end

-- Colors that follow class or power type.
function Resources:Colorize()
    local R = ns.db.resources
    local bars = self.bars
    local hc = R.health.color
    if R.health.classColor then
        local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[playerClass() or ""]
        if cc then hc = { cc.r, cc.g, cc.b } end
    end
    styleBar(bars.health, R.health, hc)

    local pc = R.power.color
    if R.power.typeColor then
        local pt = self.preview and MANA or powerType()
        local blizz = PowerBarColor and PowerBarColor[pt]
        pc = blizz and { blizz.r, blizz.g, blizz.b } or POWER_COLORS[pt] or pc
    end
    styleBar(bars.power, R.power, pc)
    styleBar(bars.druidMana, R.druidMana, R.druidMana.color)
    styleBar(bars.combo, R.combo, R.combo.color)
    bars.combo.comboKey = nil -- restyle the points too
    styleCombo(bars.combo, self.preview and 5 or comboMax())
    styleBar(bars.castbar, R.castbar, nil)
end

---------------------------------------------------------------------------
-- Visibility
---------------------------------------------------------------------------

-- Only readable values decide. Right after combat the game can still keep them
-- secret for a moment; the periodic re-check picks them up once they're readable.
-- true = not full, false = full, nil = unknown (the game keeps it secret)
local function fullness(cur, max)
    if cur == nil or max == nil or isSecret(cur) or isSecret(max) then return nil end
    return cur < max
end

-- Secret values can't be compared, but regeneration keeps sending updates until
-- you're full. Longer than mana's five-second pause after a cast.
local QUIET = 6

function Resources:WantShown()
    local R = ns.db.resources
    if self.preview or self.unlocked or (self.testUntil and GetTime() < self.testUntil) then return true end
    if not R.enabled then return false end
    if R.visibility == "always" then return true end
    if Safe(UnitAffectingCombat("player")) == true then return true end
    if R.visibility == "combat" then return false end
    if self.cast.active then return true end

    -- combatOrNotFull: readable values decide exactly
    local unknown = false
    local function check(state)
        if state == nil then unknown = true end
        return state == true
    end
    if check(fullness(UnitHealth("player"), UnitHealthMax("player"))) then return true end
    if R.power.countForVisibility then
        local pt = powerType()
        local p, pMax = UnitPower("player", pt), UnitPowerMax("player", pt)
        if pt == RAGE then
            -- rage rests at 0, everything else rests full
            if isSecret(p) then
                unknown = true
            elseif p and p > 0 then
                return true
            end
        elseif check(fullness(p, pMax)) then
            return true
        end
        if playerClass() == "DRUID" and pt ~= MANA
            and check(fullness(UnitPower("player", MANA), UnitPowerMax("player", MANA))) then
            return true
        end
    end
    -- secret values: still regenerating (updates keep coming) means not full yet
    if unknown and self.lastChange and GetTime() - self.lastChange < QUIET then return true end
    return false
end

-- /wl debug: what the game lets the resource display read right now.
function Resources:Debug()
    local function show(label, cur, max)
        local state = (isSecret(cur) or isSecret(max)) and "secret"
            or (tostring(cur) .. " / " .. tostring(max))
        ns.Print(label .. ": " .. state)
    end
    local pt = powerType()
    show("health", UnitHealth("player"), UnitHealthMax("player"))
    show("power (type " .. pt .. ")", UnitPower("player", pt), UnitPowerMax("player", pt))
    ns.Print("in combat: " .. tostring(Safe(UnitAffectingCombat("player")))
        .. ", last update " .. (self.lastChange and string.format("%.1fs ago", GetTime() - self.lastChange) or "never")
        .. ", shown: " .. tostring(self:WantShown()))
end

function Resources:UpdateVisibility()
    local f = self.frame
    if not f then return end
    if self:WantShown() then
        f:Show()
        f.fadeTarget = ns.db.resources.alpha
    else
        f.fadeTarget = 0
    end
end

---------------------------------------------------------------------------
-- Cast bar
---------------------------------------------------------------------------

Resources.cast = { active = false }

local function castInfo(channel)
    local name, icon, startMS, endMS, notInterruptible, _
    if channel then
        name, _, icon, startMS, endMS, _, notInterruptible = UnitChannelInfo("player")
    else
        name, _, icon, startMS, endMS, _, _, notInterruptible = UnitCastingInfo("player")
    end
    return Safe(name), Safe(icon), Safe(startMS), Safe(endMS), Safe(notInterruptible)
end

function Resources:StartCast(channel, test)
    local c = self.cast
    local name, icon, startMS, endMS, locked
    if test then
        name, icon = "Frostbolt", "Interface\\Icons\\Spell_Frost_FrostBolt02"
        startMS, endMS = GetTime() * 1000, (GetTime() + 2.5) * 1000
    else
        name, icon, startMS, endMS, locked = castInfo(channel)
    end
    if not ns.db.resources.castbar.enabled or not name or not startMS or not endMS or endMS <= startMS then
        -- times unreadable: no reliable progress, so no bar
        self:EndCast()
        return
    end
    c.active, c.channel, c.test, c.holdUntil = true, channel, test, nil
    c.start, c.stop = startMS / 1000, endMS / 1000
    local b, C = self.bars.castbar, ns.db.resources.castbar
    local color = locked and C.uninterruptibleColor or C.color
    b:SetStatusBarColor(color[1], color[2], color[3], 1)
    b.icon:SetTexture(icon or 134400)
    b.left:SetText(C.name and name or "")
    Layout()
    self:UpdateVisibility()
end

function Resources:EndCast()
    local c = self.cast
    if c.holdUntil and GetTime() < c.holdUntil then return end
    c.active = false
    Layout()
    self:UpdateVisibility()
end

function Resources:InterruptCast()
    local c = self.cast
    if not c.active then return end
    local b = self.bars.castbar
    b:SetMinMaxValues(0, 1)
    b:SetValue(1)
    b:SetStatusBarColor(0.85, 0.15, 0.15, 1)
    b.left:SetText("Interrupted")
    b.right:SetText("")
    c.holdUntil = GetTime() + 0.6
    c.interrupted = true
end

local function castOnUpdate()
    local c = Resources.cast
    if not c.active then return end
    local now = GetTime()
    if c.interrupted then
        if now >= c.holdUntil then
            c.interrupted, c.holdUntil = nil, nil
            Resources:EndCast()
        end
        return
    end
    local b = Resources.bars.castbar
    local total = c.stop - c.start
    local p = math.min(1, math.max(0, (now - c.start) / total))
    if c.channel then p = 1 - p end
    b:SetMinMaxValues(0, 1)
    b:SetValue(p)
    b.right:SetText(ns.db.resources.castbar.time and string.format("%.1f", math.max(0, c.stop - now)) or "")
    -- normally STOP ends the cast; this catches a missing event
    if now >= c.stop + (c.test and 0 or 0.3) then
        if c.test and Resources.preview then
            Resources:StartCast(false, true) -- keep the preview cast looping
        else
            c.test = nil
            Resources:EndCast()
        end
    end
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function OnUpdate(self, dt)
    -- fade like the log window
    local a, target = self:GetAlpha(), self.fadeTarget
    if a ~= target then
        local R = ns.db.resources
        if target > a then
            a = math.min(target, a + dt / math.max(R.fadeIn, 0.01))
        else
            a = math.max(target, a - dt / math.max(R.fadeOut, 0.01))
        end
        self:SetAlpha(a)
        if a <= 0 then
            self:Hide()
            return
        end
    end
    -- follow regeneration frame by frame (the preview keeps its fixed values)
    local bars = Resources.bars
    if not Resources.preview and (bars.power:IsShown() or bars.druidMana:IsShown()) then
        Resources:UpdatePower()
    end
    -- smooth plain values
    for _, b in pairs(Resources.bars) do
        if b.target and b.shownValue then
            local v = b.shownValue + (b.target - b.shownValue) * math.min(1, dt * 12)
            if math.abs(b.target - v) < 0.5 then v, b.target = b.target, nil end
            b.shownValue = v
            b:SetValue(v)
        end
    end
    castOnUpdate()
    -- out of combat, re-check twice a second: no event fires once you're full again
    self.recheck = (self.recheck or 0) + dt
    if self.recheck >= 0.5 then
        self.recheck = 0
        if Safe(UnitAffectingCombat("player")) ~= true then Resources:Update(); Resources:UpdateVisibility() end
    end
    -- a timed test ends on its own
    if Resources.testUntil and GetTime() >= Resources.testUntil then
        Resources.testUntil = nil
        Resources:UpdateVisibility()
    end
end

function Resources:Init()
    local f = CreateFrame("Frame", "WombatLogResources", UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local R = ns.db.resources
        local s = UIParent:GetEffectiveScale() / self:GetEffectiveScale()
        local cx, cy = self:GetCenter()
        R.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        R.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
        Resources:Apply()
        if ns.Config then ns.Config:RefreshAll() end
    end)
    f:SetScript("OnUpdate", OnUpdate)
    f.fadeTarget = 0
    f:SetAlpha(0)
    f:Hide()
    self.frame = f

    f.overlay = f:CreateTexture(nil, "BACKGROUND", nil, -2)
    f.overlay:SetPoint("TOPLEFT", -4, 4)
    f.overlay:SetPoint("BOTTOMRIGHT", 4, -4)
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlay:Hide()

    self.bars = {}
    for _, key in ipairs(ORDER) do self.bars[key] = CreateBar(f) end
    local cb = self.bars.castbar
    cb.icon = cb:CreateTexture(nil, "ARTWORK")
    cb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cb.icon:SetPoint("RIGHT", cb, "LEFT", -3, 0)
    self:Apply()
end

function Resources:Apply()
    local f = self.frame
    if not f then return end
    local R = ns.db.resources
    f:SetScale(R.scale)
    f:SetWidth(R.width)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", R.x, R.y)
    for _, b in pairs(self.bars) do b:SetWidth(R.width) end
    local cb, C = self.bars.castbar, R.castbar
    cb.icon:SetSize(C.height, C.height)
    cb.icon:SetShown(C.icon)
    if not C.enabled then self.cast.active = false end
    self:Colorize()
    Layout()
    self:Update()
    self:UpdateVisibility()
end

function Resources:SetPreview(on)
    self.preview = on or nil
    if not self.frame then return end
    if on then
        self:StartCast(false, true)
    elseif self.cast.test then
        self.cast.test = nil
        self:EndCast()
    end
    self:Apply()
end

function Resources:SetLocked(locked)
    self.unlocked = not locked or nil
    local f = self.frame
    if not f then return end
    f:EnableMouse(not locked)
    f.overlay:SetShown(not locked)
    self:UpdateVisibility()
    if ns.Config then ns.Config:RefreshAll() end
end

-- Settings button: show the display for a few seconds with a test cast.
function Resources:Test()
    self.testUntil = GetTime() + 4
    self:StartCast(false, true)
    self:UpdateVisibility()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function refresh()
    if not (ns.db and Resources.frame) then return end
    Resources:Update()
    Resources:UpdateVisibility()
end

-- health/power events also mark "still changing" for secret values
local function changed()
    Resources.lastChange = GetTime()
    refresh()
end

local function relayout()
    if not (ns.db and Resources.frame) then return end
    Resources:Colorize()
    Layout()
    refresh()
end

for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER" }) do
    ns.Listen(ev, changed, "player")
end
ns.Listen("UNIT_DISPLAYPOWER", relayout, "player")
ns.Listen("UPDATE_SHAPESHIFT_FORM", relayout)
ns.Listen("PLAYER_TARGET_CHANGED", changed) -- combo points on the target (Classic)
ns.Listen("PLAYER_ENTERING_WORLD", relayout)
ns.Listen("PLAYER_REGEN_DISABLED", refresh)
ns.Listen("PLAYER_REGEN_ENABLED", changed)

local function onCast(channel)
    return function()
        if ns.db and Resources.frame then Resources:StartCast(channel) end
    end
end
ns.Listen("UNIT_SPELLCAST_START", onCast(false), "player")
ns.Listen("UNIT_SPELLCAST_DELAYED", onCast(false), "player")
ns.Listen("UNIT_SPELLCAST_CHANNEL_START", onCast(true), "player")
ns.Listen("UNIT_SPELLCAST_CHANNEL_UPDATE", onCast(true), "player")
for _, ev in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
    ns.Listen(ev, function()
        if Resources.frame and not Resources.cast.test then Resources:EndCast() end
    end, "player")
end
for _, ev in ipairs({ "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
    ns.Listen(ev, function()
        if Resources.frame and not Resources.cast.test then Resources:InterruptCast() end
    end, "player")
end
