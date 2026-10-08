local ADDON, ns = ...
local Display = {}
ns.Display = Display
local L = ns.L

local WHITE = "Interface\\Buttons\\WHITE8X8"
local GRADIENT = "Interface\\AddOns\\WombatLog\\Media\\Gradient" -- white, alpha 1 -> 0 left to right
local DEFAULT_ICON = 134400
local POOL_SIZE = 30
local HEADER_FULL, HEADER_COMPACT, HEADER_GAP = 50, 36, 6
local PREVIEW_STRATA = "FULLSCREEN_DIALOG" -- above the Settings panel
local PIN_END_GRACE = 0.5  -- the last tick lands right at the DoT's end
local PIN_STALL = 1.5      -- no tick for two periods plus this: the DoT is gone (target dead, dispelled)

local TAGS = { cast = "CAST", buff = "BUFF", debuffIn = "DEBUFF", debuffOut = "APPLY", fade = "FADES", kill = "KILL" }
local PREFIX = { heal = "+", healIn = "+", taken = "-" }

local FLAG_SUFFIX = {
    GLANCING = "glancing", CRUSHING = "crushing", ABSORB = "absorbed",
    BLOCK_REDUCED = "blocked", RESIST_REDUCED = "resisted",
}

local PREVIEW_STATS = {
    damage = 48210, healing = 9120, taken = 6430, elapsed = 42,
    top = { name = "Fireball", amount = 1248, crit = true },
}

local root, feed, header
local pool, active = {}, {}

local function schoolColor(mask)
    local schools = ns.db.colors.schools
    local c = schools[mask]
    if c then return c end
    for b = 2, 64 do
        if schools[b] and bit.band(mask or 0, b) ~= 0 then return schools[b] end
    end
    return schools[1]
end

local function brighten(c)
    return { c[1] + (1 - c[1]) * 0.35, c[2] + (1 - c[2]) * 0.35, c[3] + (1 - c[3]) * 0.35 }
end

local function formatAmount(n)
    if ns.db.appearance.numberFormat == "short" then return ns.Short(n) end
    return ns.Full(n)
end

-- Tinted fade, strongest at the given side. Uses a texture + vertex color because
-- SetGradient doesn't color reliably on the Forever client.
local function fade(tex, side, r, g, b, a)
    tex:SetTexture(GRADIENT)
    if side == "right" then
        tex:SetTexCoord(1, 0, 0, 1)
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
    tex:SetVertexColor(r, g, b, a)
end

local function font(fs, file, size, flags)
    if not fs:SetFont(file, size, flags or "") then
        fs:SetFont(STANDARD_TEXT_FONT, size, flags or "")
    end
    fs:SetShadowColor(0, 0, 0, 0.8)
    fs:SetShadowOffset(1, -1)
end
ns.SetFont = font

-- Fonts of a pop-up alert: its own, or the log window's when left empty. Small
-- name text gets a plain outline where the big numbers have a thick one.
function ns.AlertFonts(cfg)
    local A = ns.db.appearance
    local number = cfg.font ~= nil and cfg.font ~= "" and cfg.font or A.amountFont
    local name = cfg.nameFont ~= nil and cfg.nameFont ~= "" and cfg.nameFont or A.nameFont
    local outline = cfg.outline or "THICKOUTLINE"
    local nameOutline = outline == "THICKOUTLINE" and "OUTLINE" or outline
    return number, name, outline, nameOutline
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function CreateRow()
    local r = CreateFrame("Frame", nil, feed)
    if r.SetClipsChildren then r:SetClipsChildren(true) end

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()

    -- crit: tint that stays, plus a bright flash and a shine sweep on arrival
    r.critBg = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.critBg:SetAllPoints()

    r.flash = r:CreateTexture(nil, "BORDER")
    r.flash:SetAllPoints()
    r.flash:SetAlpha(0)

    r.shine = CreateFrame("Frame", nil, r)
    r.shine:SetAlpha(0)
    r.shineLeft = r.shine:CreateTexture(nil, "ARTWORK")
    r.shineLeft:SetPoint("TOPLEFT"); r.shineLeft:SetPoint("BOTTOMRIGHT", r.shine, "BOTTOM")
    r.shineRight = r.shine:CreateTexture(nil, "ARTWORK")
    r.shineRight:SetPoint("TOPRIGHT"); r.shineRight:SetPoint("BOTTOMLEFT", r.shine, "BOTTOM")

    r.accent = r:CreateTexture(nil, "ARTWORK")
    r.accent:SetTexture(WHITE)

    r.iconBorder = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.iconBorder:SetTexture(WHITE)

    r.icon = r:CreateTexture(nil, "ARTWORK", nil, 2)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.icon:SetPoint("CENTER", r.iconBorder)

    -- second icon when one reported hit held two abilities ("+N" beyond that)
    r.iconBorder2 = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.iconBorder2:SetTexture(WHITE)
    r.icon2 = r:CreateTexture(nil, "ARTWORK", nil, 2)
    r.icon2:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.icon2:SetPoint("CENTER", r.iconBorder2)
    r.badge = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.badge:SetPoint("BOTTOMRIGHT", r.iconBorder2, "BOTTOMRIGHT", 2, -1)

    r.amount = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.critTag = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.critTag:SetText(L["CRIT"])
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetWordWrap(false)
    r.name:SetTextColor(0.86, 0.86, 0.86)

    -- pinned DoT: remaining time and a bar running down along the bottom edge
    r.timer = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.timer:SetTextColor(0.8, 0.8, 0.8)
    r.timer:Hide()
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetTexture(WHITE)
    r.bar:SetHeight(2)
    r.bar:Hide()

    -- crit arrival animations
    r.flashAnim = r:CreateAnimationGroup()
    local fa = r.flashAnim:CreateAnimation("Alpha")
    fa:SetTarget(r.flash)
    fa:SetFromAlpha(0.7); fa:SetToAlpha(0)
    fa:SetDuration(0.6); fa:SetSmoothing("OUT")

    r.shineAnim = r:CreateAnimationGroup()
    local sIn = r.shineAnim:CreateAnimation("Alpha")
    sIn:SetTarget(r.shine); sIn:SetFromAlpha(0); sIn:SetToAlpha(1); sIn:SetDuration(0.08); sIn:SetOrder(1)
    local sMove = r.shineAnim:CreateAnimation("Translation")
    sMove:SetTarget(r.shine); sMove:SetDuration(0.45); sMove:SetSmoothing("IN_OUT"); sMove:SetOrder(1)
    local sOut = r.shineAnim:CreateAnimation("Alpha")
    sOut:SetTarget(r.shine); sOut:SetFromAlpha(1); sOut:SetToAlpha(0)
    sOut:SetDuration(0.12); sOut:SetStartDelay(0.33); sOut:SetOrder(1)
    r.shineMove = sMove

    -- recycled rows must never keep a leftover effect
    r.flashAnim:SetScript("OnFinished", function() r.flash:SetAlpha(0) end)
    r.shineAnim:SetScript("OnFinished", function() r.shine:SetAlpha(0) end)

    r.popAnim = r:CreateAnimationGroup()
    r.pop = r.popAnim:CreateAnimation("Scale")
    r.pop:SetTarget(r.amount)
    r.pop:SetDuration(0.25)
    r.pop:SetSmoothing("OUT")

    r:Hide()
    return r
end

local function SetPopScale(r, s)
    if r.pop.SetScaleFrom then
        r.pop:SetScaleFrom(s, s); r.pop:SetScaleTo(1, 1)
    else
        r.pop:SetFromScale(s, s); r.pop:SetToScale(1, 1)
    end
end

local function PlayCrit(r)
    local K = ns.db.crit
    if K.flash then r.flashAnim:Play() end
    if K.shine then r.shineAnim:Play() end
    if K.pop then
        SetPopScale(r, K.popScale)
        r.popAnim:Play()
    end
end

local function ResizeRow(r)
    local A = ns.db.appearance
    local h = A.rowHeight
    r:SetSize(A.width, h)
    r.shine:SetSize(math.floor(h * 2.2), h)
    r.iconBorder:SetSize(h - 2, h - 2)
    r.icon:SetSize(h - 4, h - 4)
    r.iconBorder2:SetSize(h - 2, h - 2)
    r.icon2:SetSize(h - 4, h - 4)
    r.side = nil -- force LayoutRow to re-anchor
end

local function LayoutRow(r, dir)
    local A = ns.db.appearance
    local side = (dir == "in" and A.mirrorIncoming) and "right" or "left"
    if r.side == side then return end
    r.side = side

    for _, region in ipairs({ r.accent, r.iconBorder, r.amount, r.critTag, r.name, r.shine }) do
        region:ClearAllPoints()
    end
    local near = side == "right" and "RIGHT" or "LEFT"
    local far = side == "right" and "LEFT" or "RIGHT"
    local sign = side == "right" and -1 or 1

    local shineW = r.shine:GetWidth()
    r.shine:SetPoint("LEFT", r, "LEFT", -shineW, 0)
    r.shineMove:SetOffset(A.width + shineW, 0)

    r.accent:SetPoint("TOP" .. near, r, "TOP" .. near, 0, -2)
    r.accent:SetPoint("BOTTOM" .. near, r, "BOTTOM" .. near, 0, 2)
    r.icon:SetShown(A.showIcons)
    r.iconBorder:SetShown(A.showIcons)
    r.iconBorder:SetPoint(near, r, near, 6 * sign, 0)
    r.amount:SetPoint(near, A.showIcons and r.iconBorder or r.accent, far, 6 * sign, 0)
    r.critTag:SetPoint(near, r.amount, far, 3 * sign, 1)
    r.name:SetPoint(far, r, far, -4 * sign, 0)
    r.name:SetJustifyH(near)
    r.pop:SetOrigin(near, 0, 0)

    local cc = ns.db.colors.crit
    local fc = brighten(cc)
    fade(r.bg, side, 0, 0, 0, A.rowBgOpacity)
    fade(r.critBg, side, cc[1], cc[2], cc[3], 0.22)
    fade(r.flash, side, fc[1], fc[2], fc[3], 1)
    -- shine: two halves fading out from a bright center line
    fade(r.shineLeft, "right", fc[1], fc[2], fc[3], 0.55)
    fade(r.shineRight, "left", fc[1], fc[2], fc[3], 0.55)
end

local function ResetEffects(r)
    r.flashAnim:Stop(); r.shineAnim:Stop(); r.popAnim:Stop()
    r.flash:SetAlpha(0)
    r.shine:SetAlpha(0)
end

-- Remaining seconds of a pinned DoT and the span the bar runs over (nil when unknown).
local function PinRemaining(pin, now)
    if pin.frozen then return pin.frozen, pin.span end
    if pin.expires then return math.max(0, pin.expires - now), pin.span end
end

local function UpdatePinTimer(r, now)
    local rem, span = PinRemaining(r.entry.pin, now)
    if not rem then
        r.timer:Hide(); r.bar:Hide()
        return
    end
    r.timer:SetText(rem < 3 and string.format("%.1fs", rem) or string.format("%ds", math.ceil(rem)))
    r.timer:Show()
    local frac = (span and span > 0) and math.min(1, rem / span) or 0
    r.bar:SetWidth(math.max(1, ns.db.appearance.width * frac))
    r.bar:Show()
end

-- "  6x  1 crit" behind a pinned DoT's name (kept after the DoT ran out)
local function TickText(e)
    if not e.ticks then return "" end
    local text = "  |cffa0a0a0" .. e.ticks .. "\195\151|r"
    if e.critTicks > 0 then
        local cc = ns.db.colors.crit
        text = text .. string.format("  |cff%02x%02x%02x%s|r",
            math.floor(cc[1] * 255), math.floor(cc[2] * 255), math.floor(cc[3] * 255), L["%d crit"]:format(e.critTicks))
    end
    return text
end

local function Fill(r, e)
    local A, C, K = ns.db.appearance, ns.db.colors, ns.db.crit
    local tag = e.tag or TAGS[e.kind]
    local color = e.kind == "damage" and schoolColor(e.school or 1) or C[e.kind] or C.avoid
    local crit = (e.crit and e.amount and not tag) and true or false
    local cc = C.crit

    LayoutRow(r, e.dir)
    ResetEffects(r)
    r.entry = e
    r.isCrit = crit
    r.icon:SetTexture(e.icon or DEFAULT_ICON)

    if tag then
        font(r.amount, A.amountFont, math.max(8, A.amountSize - 4), A.outline)
        r.amount:SetText(L[tag])
        r.amount:SetTextColor(color[1], color[2], color[3])
    elseif crit then
        local c = e.kind == "damage" and cc or brighten(color)
        font(r.amount, A.amountFont, A.critSize, A.outline == "" and "OUTLINE" or "THICKOUTLINE")
        r.amount:SetText((PREFIX[e.kind] or "") .. formatAmount(e.amount))
        r.amount:SetTextColor(c[1], c[2], c[3])
    else
        font(r.amount, A.amountFont, A.amountSize, A.outline)
        r.amount:SetText((PREFIX[e.kind] or "") .. formatAmount(e.amount or 0))
        r.amount:SetTextColor(color[1], color[2], color[3])
    end

    if crit then
        r.accent:SetWidth(4)
        r.accent:SetColorTexture(cc[1], cc[2], cc[3], 1)
        if K.iconBorder then
            r.iconBorder:SetColorTexture(cc[1], cc[2], cc[3], 1)
        else
            r.iconBorder:SetColorTexture(0, 0, 0, 0.75)
        end
        r.critBg:SetShown(K.glow)
        r.critTag:SetShown(K.tag)
        font(r.critTag, A.amountFont, math.max(7, math.floor(A.critSize * 0.42)), "OUTLINE")
        r.critTag:SetTextColor(cc[1], cc[2], cc[3])
    else
        r.accent:SetWidth(2)
        r.accent:SetColorTexture(color[1], color[2], color[3], 0.9)
        r.iconBorder:SetColorTexture(0, 0, 0, 0.75)
        r.critBg:Hide()
        r.critTag:Hide()
    end

    -- the name's inner edge follows the amount, or the CRIT tag when shown
    font(r.name, A.nameFont, A.nameSize, A.outline)
    local inner = (crit and K.tag) and r.critTag or r.amount
    if r.side == "right" then
        r.name:SetPoint("RIGHT", inner, "LEFT", -7, 0)
    else
        r.name:SetPoint("LEFT", inner, "RIGHT", 7, 0)
    end
    local flag = FLAG_SUFFIX[e.flag]
    r.name:SetText((ns.EventName(e.name) or "") .. (flag and (" (" .. L[flag] .. ")") or "") .. TickText(e))

    local near = r.side == "right" and "RIGHT" or "LEFT"
    local far = r.side == "right" and "LEFT" or "RIGHT"
    local sign = r.side == "right" and -1 or 1

    -- pinned DoT: the timer takes the outer edge, the name ends before it
    local pin = e.pin
    if pin and PinRemaining(pin, GetTime()) then
        font(r.timer, A.nameFont, math.max(8, A.nameSize - 1), A.outline)
        r.timer:ClearAllPoints()
        r.timer:SetPoint(far, r, far, -4 * sign, 0)
        r.name:SetPoint(far, r.timer, near, -6 * sign, 0)
        r.bar:ClearAllPoints()
        r.bar:SetPoint("BOTTOM" .. near, r, "BOTTOM" .. near, 0, 0)
        r.bar:SetVertexColor(color[1], color[2], color[3], 0.85)
        UpdatePinTimer(r, GetTime())
    else
        r.timer:Hide()
        r.bar:Hide()
        r.name:SetPoint(far, r, far, -4 * sign, 0)
    end

    -- merged hit: the second spell's icon sits next to the first, the amount moves over
    local extra = A.showIcons and e.extraIcons and e.extraIcons[1]
    r.iconBorder2:SetShown(extra and true or false)
    r.icon2:SetShown(extra and true or false)
    if extra then
        r.iconBorder2:ClearAllPoints()
        r.iconBorder2:SetPoint(near, r.iconBorder, far, 2 * sign, 0)
        if crit and K.iconBorder then
            r.iconBorder2:SetColorTexture(cc[1], cc[2], cc[3], 1)
        else
            r.iconBorder2:SetColorTexture(0, 0, 0, 0.75)
        end
        r.icon2:SetTexture(extra)
        r.amount:SetPoint(near, r.iconBorder2, far, 6 * sign, 0)
    else
        r.amount:SetPoint(near, A.showIcons and r.iconBorder or r.accent, far, 6 * sign, 0)
    end
    if extra and e.combined and e.combined > 2 then
        font(r.badge, A.amountFont, math.max(7, math.floor(A.rowHeight * 0.4)), "OUTLINE")
        r.badge:SetText("+" .. (e.combined - 2))
        r.badge:Show()
    else
        r.badge:Hide()
    end
    return crit
end

local function PlaceRow(r)
    local point = ns.db.appearance.newestOnTop and "TOPLEFT" or "BOTTOMLEFT"
    r:SetPoint(point, feed, point, 0, r.y)
    r:SetAlpha(r.alpha)
end

-- Pinned DoT rows sit after all normal rows in `active`, i.e. at the newest end.
local function CountPinned()
    local n = 0
    for _, r in ipairs(active) do
        if r.entry.pin then n = n + 1 end
    end
    return n
end

local function Relayout(snap)
    local A = ns.db.appearance
    local step = A.rowHeight + A.rowGap
    local n = #active
    local normal = n - CountPinned()
    for i, r in ipairs(active) do
        local index = n - i -- 0 = newest
        r.ty = A.newestOnTop and -index * step or index * step
        local a = 1
        if A.ageDim and not r.entry.pin then
            local age = normal - i -- among the normal rows
            a = math.max(r.isCrit and 0.55 or 0.3, 1 - age * (r.isCrit and 0.06 or 0.09))
        end
        if r.entry.dim then a = a * 0.5 end
        r.ta = a
        if snap then
            r.y, r.alpha = r.ty, r.ta
            PlaceRow(r)
        end
    end
    root.animating = true
end

local function Release(r)
    ResetEffects(r)
    r:Hide()
    r.entry = nil
    pool[#pool + 1] = r
end

-- The DoT ran out: the row keeps its totals and joins the normal rows as the newest,
-- which is where it already sits, so it simply scrolls away with the next rows.
local function Unpin(r)
    r.entry.pin = nil
    for i, row in ipairs(active) do
        if row == r then table.remove(active, i); break end
    end
    table.insert(active, #active - CountPinned() + 1, r)
    Fill(r, r.entry)
    Relayout()
end

local function UpdatePins()
    local now = GetTime()
    for i = #active, 1, -1 do
        local r = active[i]
        local pin = r and r.entry.pin
        if pin and not pin.frozen then
            -- one missed tick (a dodge, a tick put down to another spell) doesn't end it
            local stalled = now - pin.lastTick > 2 * (pin.period or 3) + PIN_STALL
            local expired = pin.expires and now > pin.expires + PIN_END_GRACE
            if stalled or expired then
                if ns.trace then
                    ns.Print(string.format("unpin %s (%s, %d ticks)", r.entry.name or "?",
                        expired and "ran out" or "no tick for " .. string.format("%.1fs", now - pin.lastTick), r.entry.ticks))
                end
                Unpin(r)
            else
                UpdatePinTimer(r, now)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Header
---------------------------------------------------------------------------

local function CreateHeader()
    header = CreateFrame("Frame", nil, root)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")

    local function text()
        return header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    end

    header.dps = text()
    header.dps:SetPoint("TOPLEFT", 4, -2)
    header.dpsLabel = text()
    header.dpsLabel:SetPoint("BOTTOMLEFT", header.dps, "BOTTOMRIGHT", 3, 3)
    header.dpsLabel:SetText("DPS")

    header.hps = text()
    header.hpsLabel = text()
    header.hpsLabel:SetPoint("BOTTOMLEFT", header.hps, "BOTTOMRIGHT", 3, 3)
    header.hpsLabel:SetText("HPS")

    header.timer = text()
    header.timer:SetPoint("TOPRIGHT", -4, -3)
    header.totals = text()

    header.top = text()
    header.top:SetPoint("BOTTOMLEFT", 4, 5)

    -- optional session line, just above the window so it works without the header too
    root.session = root:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    root.session:SetPoint("BOTTOMLEFT", root, "TOPLEFT", 4, 3)

    local line = header:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    fade(line, "left", 1, 1, 1, 0.5)
end

-- Applies header settings and returns its height (0 when hidden).
local function ApplyHeader()
    local A, C = ns.db.appearance, ns.db.colors
    local H = A.header
    font(root.session, A.nameFont, 11, "OUTLINE")
    root.session:SetTextColor(0.75, 0.85, 1)
    root.session:SetShown(ns.db.session.enabled and ns.db.session.headerLine)
    if not H.show then
        header:Hide()
        return 0
    end
    header:Show()

    local grey = 0.72
    font(header.dps, A.amountFont, 24, "OUTLINE")
    header.dps:SetTextColor(1, 1, 1)
    font(header.hps, A.amountFont, 24, "OUTLINE")
    header.hps:SetTextColor(C.heal[1], C.heal[2], C.heal[3])
    for _, label in ipairs({ header.dpsLabel, header.hpsLabel }) do
        font(label, A.amountFont, 10, "OUTLINE")
        label:SetTextColor(grey, grey, grey)
    end
    font(header.timer, A.amountFont, 15, "OUTLINE")
    font(header.totals, A.nameFont, 11, "OUTLINE")
    header.totals:SetTextColor(0.75, 0.75, 0.75)
    font(header.top, A.nameFont, 11, "OUTLINE")
    header.top:SetTextColor(C.crit[1], C.crit[2], C.crit[3])

    header.dps:SetShown(H.dps); header.dpsLabel:SetShown(H.dps)
    header.hps:SetShown(H.hps); header.hpsLabel:SetShown(H.hps)
    header.hps:ClearAllPoints()
    header.hps:SetPoint("TOPLEFT", H.dps and 120 or 4, -2)
    header.timer:SetShown(H.timer)
    header.totals:SetShown(H.totals)
    header.totals:ClearAllPoints()
    if H.timer then
        header.totals:SetPoint("TOPRIGHT", header.timer, "BOTTOMRIGHT", 0, -2)
    else
        header.totals:SetPoint("TOPRIGHT", -4, -6)
    end
    header.top:SetShown(H.biggest)

    local h = H.biggest and HEADER_FULL or HEADER_COMPACT
    header:SetHeight(h)
    return h
end

function Display:UpdateHeader()
    if root and root.session:IsShown() then root.session:SetText(ns.Stats:SessionLine()) end
    if not header or not header:IsShown() then return end
    local f, elapsed = ns.fight, ns.Elapsed()
    if self.preview and not f.active then
        f, elapsed = PREVIEW_STATS, PREVIEW_STATS.elapsed
    end
    local div = math.max(elapsed, 1)
    header.dps:SetText(ns.Short(f.damage / div))
    header.hps:SetText(ns.Short(f.healing / div))
    header.timer:SetText(string.format("%d:%02d", math.floor(elapsed / 60), math.floor(elapsed % 60)))
    header.totals:SetText(L["%s dmg    %s taken"]:format(ns.Short(f.damage), ns.Short(f.taken)))
    if f.top then
        header.top:SetText(L["Biggest hit"] .. "  " .. ns.EventName(f.top.name) .. "  " .. ns.Full(f.top.amount)
            .. (f.top.crit and ("  " .. L["CRIT"]) or ""))
    else
        header.top:SetText("")
    end
end

---------------------------------------------------------------------------
-- Root frame
---------------------------------------------------------------------------

local function OnUpdate(self, dt)
    -- window fade
    local a, target = self:GetAlpha(), self.fadeTarget
    if a ~= target then
        local B = ns.db.behaviour
        if target > a then
            a = math.min(target, a + dt / math.max(B.fadeIn, 0.01))
        else
            a = math.max(target, a - dt / math.max(B.fadeOut, 0.01))
        end
        self:SetAlpha(a)
        if a <= 0 then
            self:Hide()
            return
        end
    end

    -- row slide/fade
    if self.animating then
        local k = math.min(1, dt * 14)
        local moving = false
        for _, r in ipairs(active) do
            local dy, da = r.ty - r.y, r.ta - r.alpha
            if math.abs(dy) > 0.3 then r.y = r.y + dy * k; moving = true else r.y = r.ty end
            if math.abs(da) > 0.01 then r.alpha = r.alpha + da * k; moving = true else r.alpha = r.ta end
            PlaceRow(r)
        end
        self.animating = moving
    end

    -- pinned DoT timers
    self.pinClock = (self.pinClock or 0) + dt
    if self.pinClock >= 0.1 then
        self.pinClock = 0
        UpdatePins()
    end

    -- header refresh
    self.headerClock = (self.headerClock or 0) + dt
    if self.headerClock >= 0.25 then
        self.headerClock = 0
        Display:UpdateHeader()
    end
end

-- Stores the window's center as an offset from the screen center, in the window's own scale.
local function SavePosition()
    local P = ns.db.position
    local s = UIParent:GetEffectiveScale() / root:GetEffectiveScale()
    local cx, cy = root:GetCenter()
    P.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
    P.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
    root:ClearAllPoints()
    root:SetPoint("CENTER", UIParent, "CENTER", P.x, P.y)
end

function Display:Init()
    root = CreateFrame("Frame", "WombatLogFrame", UIParent)
    root:SetClampedToScreen(true)
    root:SetMovable(true)
    root:EnableMouse(false)
    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", root.StartMoving)
    root:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
        if ns.Config then ns.Config:RefreshAll() end
    end)
    root:SetScript("OnUpdate", OnUpdate)
    root.fadeTarget = 0
    root:SetAlpha(0)
    root:Hide()

    -- only visible while unlocked
    root.overlay = root:CreateTexture(nil, "BACKGROUND")
    root.overlay:SetAllPoints()
    root.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    root.overlayText = root:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    font(root.overlayText, "Fonts\\ARIALN.TTF", 12, "OUTLINE")
    root.overlayText:SetPoint("CENTER")
    root.overlayText:SetText(L["WombatLog - drag to move"])
    root.overlay:Hide()
    root.overlayText:Hide()

    CreateHeader()

    -- swing timer lane between header and feed
    root.swing = CreateFrame("Frame", nil, root)
    ns.Swing:Init(root.swing)

    feed = CreateFrame("Frame", nil, root)
    feed:SetPoint("BOTTOMLEFT")
    feed:SetPoint("BOTTOMRIGHT")
    if feed.SetClipsChildren then feed:SetClipsChildren(true) end

    for i = 1, POOL_SIZE do pool[i] = CreateRow() end

    self:ApplySettings()
end

function Display:ApplySettings()
    if not root then return end
    local A, P, B = ns.db.appearance, ns.db.position, ns.db.behaviour

    local headerH = ApplyHeader()
    local feedH = B.lines * (A.rowHeight + A.rowGap)
    feed:SetHeight(feedH)

    -- header, then the swing lane (when enabled), then the feed
    local S = ns.db.swing
    local top = headerH > 0 and (headerH + 3) or 0
    if S.enabled then
        root.swing:ClearAllPoints()
        root.swing:SetPoint("TOPLEFT", root, "TOPLEFT", 2, -top)
        root.swing:SetPoint("RIGHT", root, "RIGHT", -2, 0)
        root.swing:SetHeight(S.height)
        root.swing:Show()
        top = top + S.height + HEADER_GAP
    else
        root.swing:Hide()
        if headerH > 0 then top = headerH + HEADER_GAP end
    end
    root:SetSize(A.width, top + feedH)
    root:SetScale(P.scale)
    root:SetFrameStrata(self.preview and PREVIEW_STRATA or P.strata)
    root:ClearAllPoints()
    root:SetPoint("CENTER", UIParent, "CENTER", P.x, P.y)

    for _, r in ipairs(pool) do ResizeRow(r) end
    for _, r in ipairs(active) do ResizeRow(r) end

    if self.preview and not ns.fight.active then
        self:RenderPreview(false)
    else
        while #active > B.lines do Release(table.remove(active, 1)) end
        if not B.pinDots then
            for _, r in ipairs(active) do r.entry.pin = nil end
        end
        for _, r in ipairs(active) do
            Fill(r, r.entry)
            r:ClearAllPoints()
        end
        Relayout(true)
    end

    ns.Swing:Apply()
    ns.Swing:SetSample(self.preview)
    self:UpdateVisibility()
    self:UpdateHeader()
end

function Display:IsShown()
    return root and root:IsShown()
end

-- Shows or fades the window based on combat, preview, lock and visibility settings.
function Display:UpdateVisibility()
    if not root then return end
    local B = ns.db.behaviour
    local want = B.enabled and (self.preview or not ns.locked or B.visibility == "always"
        or ns.fight.active or ns.lingering)
    if want then
        root:Show()
        root.fadeTarget = ns.db.position.alpha
    else
        root.fadeTarget = 0
    end
end

function Display:SetLocked(locked)
    ns.locked = locked
    if not root then return end
    root:EnableMouse(not locked)
    root.overlay:SetShown(not locked)
    root.overlayText:SetShown(not locked)
    self:UpdateVisibility()
    if ns.Config then ns.Config:RefreshAll() end
end

-- While the settings panel is open, the window shows sample rows that follow every change.
function Display:SetPreview(on)
    if not root then return end
    self.preview = on
    root:SetFrameStrata(on and PREVIEW_STRATA or ns.db.position.strata)
    ns.Swing:SetSample(on)
    if not ns.fight.active then
        if on then
            self:RenderPreview(true)
        elseif not ns.lingering then
            self:Clear()
        end
    end
    self:UpdateVisibility()
    self:UpdateHeader()
end

function Display:RenderPreview(animate)
    self:Clear()
    local B = ns.db.behaviour
    for _, e in ipairs(ns.PREVIEW_ENTRIES) do
        if e.previewPin then
            if B.pinDots and B.show.damage then self:PushPreviewPin(e) end
        elseif ns.ShouldShow(e) then
            self:Push(e, true)
        end
    end
    if animate then
        for _, r in ipairs(active) do
            if r.isCrit then PlayCrit(r) end
        end
    end
end

function Display:Clear()
    while #active > 0 do Release(table.remove(active)) end
    if not ns.fight.active then ns.fight.top = nil end
end

local function FindPin(key)
    for _, r in ipairs(active) do
        local pin = r.entry.pin
        if pin and pin.key == key then return r end
    end
end

-- The row entry of a pinned DoT: the first tick's look, counting up with every tick.
local function PinEntry(e, now)
    return {
        kind = e.kind, dir = e.dir, name = e.name, icon = e.icon, school = e.school, spellID = e.spellID,
        amount = 0, ticks = 0, critTicks = 0,
        pin = { key = e.pinKey or e.spellID or e.name, period = e.tickPeriod, lastTick = now },
    }
end

local function AddTick(pe, e, now)
    local pin = pe.pin
    pe.amount = pe.amount + (e.amount or 0)
    pe.ticks = pe.ticks + 1
    if e.crit then pe.critTicks = pe.critTicks + 1 end
    pin.lastTick = now
    pin.period = e.tickPeriod or pin.period
    if e.dotEnd and e.dotEnd < now - PIN_END_GRACE then
        -- still ticking past the expected end (e.g. a talent made it longer): end on the stall instead
        pin.expires = nil
    elseif e.dotEnd then
        pin.expires = e.dotEnd
        -- a refreshed DoT fills the bar again
        pin.span = math.max(pin.span or 0, e.dotEnd - now)
    end
end

-- instant: place the row without slide-in or crit animations (used by the preview)
function Display:Push(e, instant)
    if not root then return end

    local f = ns.fight
    if e.kind == "damage" and not e.dim and f.active and e.amount and (not f.top or e.amount > f.top.amount) then
        f.top = { name = e.name or "?", amount = e.amount, crit = e.crit }
    end

    -- a DoT tick counts up its pinned row instead of adding one
    local now = GetTime()
    local pinned = e.tick and not e.dim and ns.db.behaviour.pinDots
    if pinned then
        local existing = FindPin(e.pinKey or e.spellID or e.name)
        if existing then
            AddTick(existing.entry, e, now)
            Fill(existing, existing.entry)
            if e.crit and not instant then PlayCrit(existing) end
            return
        end
    end

    while #active >= ns.db.behaviour.lines do Release(table.remove(active, 1)) end
    local r = table.remove(pool)
    if not r then return end

    local shown = e
    if pinned then
        shown = PinEntry(e, now)
        AddTick(shown, e, now)
    end
    local crit = Fill(r, shown)
    if pinned then crit = e.crit end

    -- normal rows go in before the pinned ones; a new pin is the newest row
    local slot = pinned and #active + 1 or #active - CountPinned() + 1
    table.insert(active, slot, r)
    local A = ns.db.appearance
    r.alpha = 0
    r:ClearAllPoints()
    Relayout(instant)
    if not instant then
        if slot == #active then
            r.y = A.newestOnTop and A.rowHeight or -A.rowHeight -- slides in from the edge
        else
            r.y = r.ty -- behind the pinned rows: fades in where it belongs
        end
        PlaceRow(r)
    end
    r:Show()

    if crit and not instant then PlayCrit(r) end
end

-- The DoT behind this pin key is gone (the combat log said so): unpin it now.
function Display:EndPin(key)
    local r = key and FindPin(key)
    if r and not r.entry.pin.frozen then Unpin(r) end
end

-- Settings preview: a pinned DoT frozen half-way.
function Display:PushPreviewPin(e)
    while #active >= ns.db.behaviour.lines do Release(table.remove(active, 1)) end
    local r = table.remove(pool)
    if not r then return end
    local P = e.previewPin
    local shown = PinEntry(e, GetTime())
    shown.amount, shown.ticks, shown.critTicks = e.amount, P.ticks, P.crits
    shown.pin.frozen, shown.pin.span = P.remaining, P.duration
    Fill(r, shown)
    active[#active + 1] = r
    r:ClearAllPoints()
    Relayout(true)
    r:Show()
end

-- Redraws the row showing this entry (e.g. after it was merged with another hit).
function Display:RefreshEntry(e)
    for _, r in ipairs(active) do
        if r.entry == e then Fill(r, e) end
    end
end

function Display:RefreshSpell(spellID, info)
    for _, r in ipairs(active) do
        local e = r.entry
        if e and e.pending and e.spellID == spellID then
            e.pending = nil
            local pet = e.name and e.name:find("^Pet: ")
            e.name = (pet and "Pet: " or "") .. info.name
            e.icon = info.icon
            Fill(r, e)
        end
    end
end

-- Replays the preview's crit animations (Crits tab button).
function Display:ReplayCrits()
    for _, r in ipairs(active) do
        if r.isCrit then PlayCrit(r) end
    end
end
