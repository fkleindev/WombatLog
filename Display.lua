local ADDON, ns = ...
local Display = {}
ns.Display = Display

local WHITE = "Interface\\Buttons\\WHITE8X8"
local GRADIENT = "Interface\\AddOns\\WombatLog\\Media\\Gradient" -- white, alpha 1 -> 0 left to right
local DEFAULT_ICON = 134400
local POOL_SIZE = 30
local HEADER_FULL, HEADER_COMPACT, HEADER_GAP = 50, 36, 6
local PREVIEW_STRATA = "FULLSCREEN_DIALOG" -- above the Settings panel

local TAGS = { cast = "CAST", buff = "BUFF", debuffIn = "DEBUFF", debuffOut = "APPLY", fade = "FADES", kill = "KILL" }
local PREFIX = { heal = "+", healIn = "+", taken = "-" }

local FLAG_SUFFIX = {
    GLANCING = " (glancing)", CRUSHING = " (crushing)", ABSORB = " (absorbed)",
    BLOCK_REDUCED = " (blocked)", RESIST_REDUCED = " (resisted)",
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

    r.amount = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.critTag = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.critTag:SetText("CRIT")
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetWordWrap(false)
    r.name:SetTextColor(0.86, 0.86, 0.86)

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
        r.amount:SetText(tag)
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
    r.name:SetText((e.name or "") .. (FLAG_SUFFIX[e.flag] or ""))
    return crit
end

local function PlaceRow(r)
    local point = ns.db.appearance.newestOnTop and "TOPLEFT" or "BOTTOMLEFT"
    r:SetPoint(point, feed, point, 0, r.y)
    r:SetAlpha(r.alpha)
end

local function Relayout(snap)
    local A = ns.db.appearance
    local step = A.rowHeight + A.rowGap
    local n = #active
    for i, r in ipairs(active) do
        local index = n - i -- 0 = newest
        r.ty = A.newestOnTop and -index * step or index * step
        local a = 1
        if A.ageDim then
            a = math.max(r.isCrit and 0.55 or 0.3, 1 - index * (r.isCrit and 0.06 or 0.09))
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
    if not header or not header:IsShown() then return end
    local f, elapsed = ns.fight, ns.Elapsed()
    if self.preview and not f.active then
        f, elapsed = PREVIEW_STATS, PREVIEW_STATS.elapsed
    end
    local div = math.max(elapsed, 1)
    header.dps:SetText(ns.Short(f.damage / div))
    header.hps:SetText(ns.Short(f.healing / div))
    header.timer:SetText(string.format("%d:%02d", math.floor(elapsed / 60), math.floor(elapsed % 60)))
    header.totals:SetText(ns.Short(f.damage) .. " dmg    " .. ns.Short(f.taken) .. " taken")
    if f.top then
        header.top:SetText("Biggest hit  " .. f.top.name .. "  " .. ns.Full(f.top.amount)
            .. (f.top.crit and "  CRIT" or ""))
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
    root.overlayText:SetText("WombatLog - drag to move")
    root.overlay:Hide()
    root.overlayText:Hide()

    CreateHeader()

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
    root:SetSize(A.width, headerH + (headerH > 0 and HEADER_GAP or 0) + feedH)
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
        for _, r in ipairs(active) do
            Fill(r, r.entry)
            r:ClearAllPoints()
        end
        Relayout(true)
    end

    self:UpdateVisibility()
    self:UpdateHeader()
end

function Display:IsShown()
    return root and root:IsShown()
end

-- Shows or fades the window based on combat, preview, lock and visibility settings.
function Display:UpdateVisibility()
    if not root then return end
    local want = self.preview or not ns.locked or ns.db.behaviour.visibility == "always"
        or ns.fight.active or ns.lingering
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
    for _, e in ipairs(ns.PREVIEW_ENTRIES) do
        if ns.ShouldShow(e) then self:Push(e, true) end
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

-- instant: place the row without slide-in or crit animations (used by the preview)
function Display:Push(e, instant)
    if not root then return end
    while #active >= ns.db.behaviour.lines do Release(table.remove(active, 1)) end
    local r = table.remove(pool)
    if not r then return end

    local crit = Fill(r, e)

    local f = ns.fight
    if e.kind == "damage" and not e.dim and f.active and e.amount and (not f.top or e.amount > f.top.amount) then
        f.top = { name = e.name or "?", amount = e.amount, crit = e.crit }
    end

    active[#active + 1] = r
    local A = ns.db.appearance
    r.y = A.newestOnTop and A.rowHeight or -A.rowHeight
    r.alpha = 0
    r:ClearAllPoints()
    PlaceRow(r)
    r:Show()
    Relayout(instant)

    if crit and not instant then PlayCrit(r) end
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
