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
local IDLE_SLICES = 120  -- the slice-based idle styles use at most this many
local WAVE_RATE = 0.5    -- wavelengths per second at speed 1
local SHINE_RATE = 120   -- px per second at speed 1
local SHINE_PAUSE = 1.5  -- seconds between two shines
local PULSE_RATE = 0.4   -- pulses per second at speed 1
local STRIPE_RATE = 0.5  -- stripes per second at speed 1
local RAINBOW_RATE = 0.2 -- color cycles per second at speed 1
local SPARKS_MAX = 40    -- twinkling dots per layer at most
local TAU = math.pi * 2

XPBar.MAX_SEGMENTS = MAX_SEGMENTS

-- Your XP as a fraction of the level, or nil.
function XPBar.Fraction()
    local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    if not xp or not max or max <= 0 then return nil end
    return xp / max
end

-- True at the level cap or with XP gain turned off.
function XPBar.AtMaxLevel()
    if IsXPUserDisabled and Safe(IsXPUserDisabled()) then return true end
    local lvl = Safe(UnitLevel("player"))
    local max = GetMaxLevelForPlayerExpansion and Safe(GetMaxLevelForPlayerExpansion()) or MAX_PLAYER_LEVEL
    return lvl and max and lvl >= max or false
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
    bar.color = color
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
-- glowBase, gainColor, colorLevel: see RenderEffects.
function XPBar.Render(bar, B, value, from, age, glowBase, gainColor, colorLevel)
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

    XPBar.RenderEffects(bar, B, value, from, age, glowBase, gainColor, colorLevel)
end

-- The gain flash and the glow, which follow the gain's age.
-- glowBase: the glow's alpha once the flash is over (nil = 0.25).
-- gainColor: the whole fill's and the lit part's color while it is lit (nil = the
-- bar's color and white).
-- colorLevel: how much of gainColor the whole fill takes, 0..1 (nil = the flash's curve).
function XPBar.RenderEffects(bar, B, value, from, age, glowBase, gainColor, colorLevel)
    local w = bar.width or bar:GetWidth()
    local flash = flashLevel(age or 0)
    -- with a source color the whole fill takes it, then blends back to the bar's color
    local c, g = bar.color, gainColor
    local k = colorLevel or flash
    if c then
        if g and k > 0 then
            bar:SetStatusBarColor(c[1] + (g[1] - c[1]) * k, c[2] + (g[2] - c[2]) * k,
                c[3] + (g[3] - c[3]) * k, 0.95)
        else
            bar:SetStatusBarColor(c[1], c[2], c[3], 0.95)
        end
    end
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

---------------------------------------------------------------------------
-- Idle animation, in two layers: one over the fill, one over the empty part (or the
-- fill's over the whole bar). It sits under the gloss, segments, spark and text, and
-- never leaves its layer's stretch of the bar.
---------------------------------------------------------------------------

local function idleTexture(bar, file, blend)
    local t = bar:CreateTexture(nil, "OVERLAY")
    t:SetTexture(file)
    if blend then t:SetBlendMode(blend) end
    t:Hide()
    return t
end

-- A layer's textures, made on first use, so bars without the animation cost nothing.
local function idleParts(bar, layer)
    bar.idle = bar.idle or {}
    local P = bar.idle[layer]
    if not P then
        P = {
            slices = {}, lines = {}, sparks = {}, used = 0, sparksUsed = 0,
            shine = idleTexture(bar, GLOW, "ADD"),
            pulse = idleTexture(bar, WHITE, "ADD"),
        }
        bar.idle[layer] = P
    end
    return P
end

local function idleSlice(bar, list, i)
    local t = list[i]
    if not t then
        t = idleTexture(bar, WHITE)
        list[i] = t
    end
    return t
end

local function hideParts(P)
    for _, t in ipairs(P.slices) do t:Hide() end
    for _, t in ipairs(P.lines) do t:Hide() end
    for _, s in ipairs(P.sparks) do s.tex:Hide(); s.born = nil end
    P.shine:Hide()
    P.pulse:Hide()
    P.style, P.used, P.sparksUsed = nil, 0, 0
end

-- layer: "fill" or "empty"; without it, both.
function XPBar.HideIdle(bar, layer)
    if not bar.idle then return end
    for key, P in pairs(bar.idle) do
        if not layer or key == layer then hideParts(P) end
    end
end

-- Calls fn(texture, x, width, i) for the slices covering x0..x1. The slices sit on a grid
-- fixed to the bar, so a pattern runs on seamlessly from one layer into the other.
local function forSlices(bar, P, x0, x1, fn)
    local w = bar.width or bar:GetWidth()
    local sw = math.max(2, w / IDLE_SLICES)
    local n, x = 0, math.floor(x0 / sw) * sw
    while x < x1 do
        local left, right = math.max(x, x0), math.min(x + sw, x1)
        if right - left >= 0.5 then
            n = n + 1
            fn(idleSlice(bar, P.slices, n), left, right - left, n)
        end
        x = x + sw
    end
    return n
end

-- A full-height lit slice.
local function lightSlice(bar, t, x, sx, r, g, b, a)
    t:SetBlendMode("ADD")
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
    t:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, 0)
    t:SetWidth(sx)
    t:SetVertexColor(r, g, b, a)
    t:Show()
end

-- Hue 0..1 to a full, bright color.
local function hueColor(h)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    if i == 0 then return 1, f, 0 end
    if i == 1 then return 1 - f, 1, 0 end
    if i == 2 then return 0, 1, f end
    if i == 3 then return 0, 1 - f, 1 end
    if i == 4 then return f, 0, 1 end
    return 1, 0, 1 - f
end

-- Bright bands running along.
local function renderWaves(bar, P, I, x0, x1, phase, c, a)
    return forSlices(bar, P, x0, x1, function(t, x, sx)
        local wave = math.max(0, math.sin(TAU * (x / I.wavelength - phase * WAVE_RATE)))
        lightSlice(bar, t, x, sx, c[1], c[2], c[3], 0.7 * a * wave * wave)
    end)
end

-- Even stripes marching along, like a loading bar.
local function renderStripes(bar, P, I, x0, x1, phase, c, a)
    return forSlices(bar, P, x0, x1, function(t, x, sx)
        local f = (x / I.wavelength - phase * STRIPE_RATE) % 1
        -- a square wave with soft edges: lit in the first half of each period
        local v = math.max(0, math.min(1, 0.5 + 2 * math.sin(TAU * f)))
        lightSlice(bar, t, x, sx, c[1], c[2], c[3], 0.5 * a * v)
    end)
end

-- The colors of the rainbow drifting along (ignores the color setting).
local function renderRainbow(bar, P, I, x0, x1, phase, a)
    return forSlices(bar, P, x0, x1, function(t, x, sx)
        local r, g, b = hueColor((x / I.wavelength - phase * RAINBOW_RATE) % 1)
        lightSlice(bar, t, x, sx, r, g, b, 0.6 * a)
    end)
end

-- The fill's top edge rolls like water: dark above the surface, a bright line on it.
-- The strength sets how deep the waves go; a is only the fade.
local function renderLiquid(bar, P, I, x0, x1, phase, c, a)
    local h = bar:GetHeight()
    return forSlices(bar, P, x0, x1, function(t, x, sx, i)
        local u = x / I.wavelength
        -- two waves at different lengths and speeds look less regular
        local level = 0.5 + 0.25 * math.sin(TAU * (u - phase * WAVE_RATE))
            + 0.25 * math.sin(TAU * (u * 1.7 + phase * WAVE_RATE * 0.6))
        local depth = h * 0.45 * I.strength * level
        t:SetBlendMode("BLEND")
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
        t:SetSize(sx, math.max(0.01, depth))
        t:SetVertexColor(0, 0, 0, 0.6 * a)
        t:SetShown(depth >= 0.5)
        local line = idleSlice(bar, P.lines, i)
        line:SetBlendMode("ADD")
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -depth)
        line:SetSize(sx, 1)
        line:SetVertexColor(c[1], c[2], c[3], 0.8 * a)
        line:Show()
    end)
end

-- A soft light sweeping across now and then.
local function renderShine(bar, P, I, x0, x1, phase, c, a)
    local t = P.shine
    local sw = I.wavelength
    local period = (x1 - x0 + sw) / SHINE_RATE + SHINE_PAUSE
    local pos = x0 + (phase % period) * SHINE_RATE - sw -- the shine's left edge
    local left, right = math.max(x0, pos), math.min(x1, pos + sw)
    if right - left < 1 then t:Hide(); return end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", bar, "TOPLEFT", left, 0)
    t:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", left, 0)
    t:SetWidth(right - left)
    -- the glow's bright middle band, cut where the shine leaves its stretch
    t:SetTexCoord((left - pos) / sw, (right - pos) / sw, 0.3, 0.7)
    t:SetVertexColor(c[1], c[2], c[3], a)
    t:Show()
end

-- Slowly brightens and dims.
local function renderPulse(bar, P, x0, x1, phase, c, a)
    local t = P.pulse
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", bar, "TOPLEFT", x0, 0)
    t:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x0, 0)
    t:SetWidth(x1 - x0)
    t:SetVertexColor(c[1], c[2], c[3], 0.5 * a * (0.5 - 0.5 * math.cos(TAU * phase * PULSE_RATE)))
    t:Show()
end

-- Soft dots twinkling up and fading at random spots. phase is their clock.
local function renderSparkle(bar, P, I, x0, x1, phase, c, a)
    local h = bar:GetHeight()
    local size = math.min(h, math.max(3, h * 0.6))
    local lo, hi = x0 + size / 2, x1 - size / 2
    local count = 0
    if hi > lo then
        count = math.min(SPARKS_MAX, math.max(1, math.floor((x1 - x0) / (I.wavelength / 3))))
    end
    for i = 1, count do
        local s = P.sparks[i]
        if not s then
            s = { tex = idleTexture(bar, GLOW, "ADD") }
            P.sparks[i] = s
        end
        local fresh = not s.born
        if fresh or phase - s.born > s.life or s.x < lo or s.x > hi then
            s.life = 0.6 + math.random() * 0.6
            -- new dots start part-way through, so they don't all light up together
            s.born = fresh and phase - math.random() * s.life or phase
            s.x = lo + math.random() * (hi - lo)
            s.y = size / 2 + math.random() * (h - size)
        end
        local p = math.max(0, math.min(1, (phase - s.born) / s.life))
        local t = s.tex
        t:ClearAllPoints()
        t:SetPoint("CENTER", bar, "TOPLEFT", s.x, -s.y)
        t:SetSize(size, size)
        t:SetVertexColor(c[1], c[2], c[3], a * math.sin(math.pi * p))
        t:Show()
    end
    for i = count + 1, P.sparksUsed do
        P.sparks[i].tex:Hide()
        P.sparks[i].born = nil
    end
    P.sparksUsed = count
end

-- layer: "fill" or "empty", I: its settings, x0..x1: the stretch of the bar in pixels,
-- t: running seconds, alpha: 0..1 fade (0 = hidden), color: the effect's color.
function XPBar.RenderIdle(bar, layer, I, x0, x1, t, alpha, color)
    local P = idleParts(bar, layer)
    local style = (alpha > 0 and x1 - x0 >= 1) and I.style or nil
    if style == "liquid" and layer ~= "fill" then style = nil end -- a surface needs the fill
    if style ~= P.style then hideParts(P) end
    P.style = style
    if not style then return end

    local phase, a, used = t * I.speed, alpha * I.strength, 0
    if style == "waves" then
        used = renderWaves(bar, P, I, x0, x1, phase, color, a)
    elseif style == "stripes" then
        used = renderStripes(bar, P, I, x0, x1, phase, color, a)
    elseif style == "rainbow" then
        used = renderRainbow(bar, P, I, x0, x1, phase, a)
    elseif style == "liquid" then
        used = renderLiquid(bar, P, I, x0, x1, phase, color, alpha)
    elseif style == "shine" then
        renderShine(bar, P, I, x0, x1, phase, color, a)
    elseif style == "sparkle" then
        renderSparkle(bar, P, I, x0, x1, phase, color, a)
    else
        renderPulse(bar, P, x0, x1, phase, color, a)
    end
    -- slices past the stretch (it shrank, or the bar got shorter)
    for i = used + 1, P.used do
        P.slices[i]:Hide()
        if P.lines[i] then P.lines[i]:Hide() end
    end
    P.used = used
end
