local ADDON, ns = ...
local XPBar = {}
ns.XPBar = XPBar
local Safe = ns.Safe

-- Your XP bar as a widget: fill, rested stretch, segments, spark, gloss, glow
-- behind it and the part just gained lit up. Used by the kill alert and the XP tracker.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local GRADIENT = MEDIA .. "Gradient"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local MAX_SEGMENTS = 20
local FLASH_HOLD = 0.4   -- the gained part stays lit this long, then fades
local FLASH_FADE = 1.0

XPBar.MAX_SEGMENTS = MAX_SEGMENTS

-- Your XP as a fraction of the level, or nil.
function XPBar.Fraction()
    local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    if not xp or not max or max <= 0 then return nil end
    return xp / max
end

-- Rested XP as a fraction of the current level, or nil.
function XPBar.RestedFraction()
    local rested = GetXPExhaustion and Safe(GetXPExhaustion())
    local max = Safe(UnitXPMax("player"))
    if not rested or rested <= 0 or not max or max <= 0 then return nil end
    return rested / max
end

-- 1 while the gained part is freshly lit, then down to 0.
local function flashLevel(age)
    if age <= FLASH_HOLD then return 1 end
    return math.max(0, 1 - (age - FLASH_HOLD) / FLASH_FADE)
end

-- The bar on parent. Its glow sits on parent, behind the bar.
function XPBar.Create(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetMinMaxValues(0, 1)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0, 0, 0, 0.55)
    -- soft glow behind the bar
    bar.glow = parent:CreateTexture(nil, "BACKGROUND")
    bar.glow:SetTexture(GLOW)
    bar.glow:SetBlendMode("ADD")
    bar.glow:SetPoint("CENTER", bar, "CENTER")
    bar.glow:Hide()
    -- thin border
    bar.edges = {}
    for i, side in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0, -1 },
                            { "TOPLEFT", "BOTTOMLEFT", -1, 0 }, { "TOPRIGHT", "BOTTOMRIGHT", 1, 0 } }) do
        local t = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        t:SetColorTexture(0, 0, 0, 1)
        t:SetPoint(side[1], bar, side[1], side[3], side[4])
        t:SetPoint(side[2], bar, side[2], side[3], side[4])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
        bar.edges[i] = t
    end
    -- rested XP: a pale stretch after the fill (behind it)
    bar.rested = bar:CreateTexture(nil, "BORDER")
    bar.rested:SetTexture(WHITE)
    -- the part just gained, lit up
    bar.gain = bar:CreateTexture(nil, "OVERLAY")
    bar.gain:SetTexture(WHITE)
    bar.gain:SetBlendMode("ADD")
    -- gloss: the gradient turned to fade from the top edge down
    bar.gloss = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    bar.gloss:SetAllPoints()
    bar.gloss:SetTexture(GRADIENT)
    bar.gloss:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
    bar.gloss:SetVertexColor(1, 1, 1, 0.22)
    bar.ticks = {}
    for i = 1, MAX_SEGMENTS - 1 do
        local t = bar:CreateTexture(nil, "OVERLAY", nil, 2)
        t:SetColorTexture(0, 0, 0, 0.6)
        t:SetWidth(1)
        bar.ticks[i] = t
    end
    bar.spark = bar:CreateTexture(nil, "OVERLAY", nil, 3)
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetBlendMode("ADD")
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    return bar
end

-- Size and look from the settings B (a killAlert.bar-like table).
function XPBar.Apply(bar, B, w, h, color, font, outline)
    bar.width = w
    bar:SetSize(w, h)
    bar:SetStatusBarTexture(ns.BarTexture and ns.BarTexture(B.texture) or WHITE)
    bar:SetStatusBarColor(color[1], color[2], color[3], 0.95)
    bar.bg:SetColorTexture(0, 0, 0, B.bgOpacity)
    for _, e in ipairs(bar.edges) do e:SetShown(B.border) end
    bar.gloss:SetShown(B.gloss)
    bar.rested:SetVertexColor(color[1], color[2], color[3], 0.3)
    bar.glow:SetVertexColor(color[1], color[2], color[3], 1)
    bar.glow:SetSize(w * 1.3, math.max(24, h * 6))
    bar.spark:SetSize(math.max(6, h * 1.5), h * 3)
    local segments = math.min(B.segments, MAX_SEGMENTS)
    for i, t in ipairs(bar.ticks) do
        if segments >= 2 and i < segments then
            t:ClearAllPoints()
            t:SetPoint("TOP", bar, "TOPLEFT", w * i / segments, 0)
            t:SetPoint("BOTTOM", bar, "BOTTOMLEFT", w * i / segments, 0)
            t:Show()
        else
            t:Hide()
        end
    end
    ns.SetFont(bar.text, font, math.max(8, math.min(16, h + 2)), outline ~= "" and outline or "OUTLINE")
end

-- Fill, spark, rested stretch, percent text and the effects.
-- value: the shown fill, from: where the latest gain started, age: seconds since it,
-- glowBase, gainColor: see RenderEffects.
function XPBar.Render(bar, B, value, from, age, glowBase, gainColor)
    local w = bar.width or bar:GetWidth()
    bar:SetValue(value)

    bar.spark:SetShown(B.spark and value > 0 and value < 1)
    bar.spark:SetPoint("CENTER", bar, "LEFT", value * w, 0)

    local rested = B.rested and value < 1 and XPBar.RestedFraction()
    if rested then
        bar.rested:ClearAllPoints()
        bar.rested:SetPoint("TOPLEFT", bar, "TOPLEFT", value * w, 0)
        bar.rested:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", value * w, 0)
        bar.rested:SetWidth(math.max(1, (math.min(1, value + rested) - value) * w))
    end
    bar.rested:SetShown(rested and true or false)

    bar.text:SetShown(B.percent)
    if B.percent then bar.text:SetText(math.floor(value * 100) .. "%") end

    XPBar.RenderEffects(bar, B, value, from, age, glowBase, gainColor)
end

-- The gain flash and the glow, which follow the gain's age.
-- glowBase: the glow's alpha once the flash is over (nil = 0.25).
-- gainColor: the lit part's color (nil = white).
function XPBar.RenderEffects(bar, B, value, from, age, glowBase, gainColor)
    local w = bar.width or bar:GetWidth()
    local flash = flashLevel(age or 0)
    -- should the bar ever start past the fill, light it from the left edge
    from = (from and from <= value) and from or 0
    local gainW = (value - from) * w
    if B.gainFlash and flash > 0 and gainW >= 1 then
        bar.gain:ClearAllPoints()
        bar.gain:SetPoint("TOPLEFT", bar, "TOPLEFT", from * w, 0)
        bar.gain:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", from * w, 0)
        bar.gain:SetWidth(gainW)
        local c = gainColor
        if c then bar.gain:SetVertexColor(c[1], c[2], c[3], 1) else bar.gain:SetVertexColor(1, 1, 1, 1) end
        bar.gain:SetAlpha(0.55 * flash)
        bar.gain:Show()
    else
        bar.gain:Hide()
    end
    local base = glowBase or 0.25
    local alpha = base + (0.8 - base) * flash
    if B.glow and alpha > 0 then
        bar.glow:SetAlpha(alpha)
        bar.glow:Show()
    else
        bar.glow:Hide()
    end
end
