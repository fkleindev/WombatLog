local ADDON, ns = ...
local MF = {}
ns.MinimapFrame = MF
local L = ns.L
local Safe = ns.Safe

-- A minimap in WombatLog's look in place of the game's: square (rounded corners) or
-- round, with a border and shadow, the zone name above, the clock below, your
-- coordinates, status icons (mail, tracking, queues, difficulty, calendar invites),
-- zoom buttons and a drawer that collects the other addons' minimap buttons.
--
-- The game's own Minimap frame is the map: it moves into our frame and gets a new
-- shape. The game's frame around it (border, zone text, buttons) goes away into a
-- hidden frame. Everything moved is remembered, so switching off puts it back.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GLOW = MEDIA .. "Glow"
local LINES = MEDIA .. "Lines"
local DIAMOND = MEDIA .. "Diamond"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local MAIL_ICON = "Interface\\Minimap\\Tracking\\Mailbox"
local GAP = 3                -- px between stacked icons
local INSET = 4              -- px from the map's edge to the icons in its corners

local function cfg() return ns.db.map end
local function tint(t, c, a) t:SetVertexColor(c[1], c[2], c[3], a or 1) end

local function call(fn, ...)
    if not fn then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return select(2, unpack(r))
end

local function loadAddOn(name)
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then pcall(load, name) end
end

---------------------------------------------------------------------------
-- Borrowing the game's frames
---------------------------------------------------------------------------

local hider = CreateFrame("Frame")
hider:Hide()

local saved = {}             -- frame or texture -> where it was
local placing = false

-- Remembers where f is, once, so it can go back there.
local function remember(f)
    if saved[f] then return saved[f] end
    local s = { parent = f:GetParent(), points = {} }
    if f.GetScale then s.scale = f:GetScale() end
    if f.GetFrameStrata then s.strata, s.level = f:GetFrameStrata(), f:GetFrameLevel() end
    local ok, n = pcall(f.GetNumPoints, f)
    for i = 1, ok and n or 0 do
        local got = { pcall(f.GetPoint, f, i) }
        if got[1] then s.points[#s.points + 1] = { select(2, unpack(got)) } end
    end
    saved[f] = s
    return s
end

local function giveBack(f)
    local s = saved[f]
    if not s then return end
    saved[f] = nil
    f.wlPlace = nil
    pcall(f.SetParent, f, s.parent)
    if s.scale then pcall(f.SetScale, f, s.scale) end
    if s.strata then
        pcall(f.SetFrameStrata, f, s.strata)
        pcall(f.SetFrameLevel, f, s.level)
    end
    if s.drag ~= nil or s.dragStop ~= nil then
        f:SetScript("OnDragStart", s.drag or nil)
        f:SetScript("OnDragStop", s.dragStop or nil)
    end
    f:ClearAllPoints()
    for _, p in ipairs(s.points) do pcall(f.SetPoint, f, unpack(p)) end
end

-- Puts f where fn says and keeps it there when its owner moves it.
local function keepPlaced(f, fn)
    f.wlPlace = fn
    if not f.wlPlaceHook then
        f.wlPlaceHook = true
        hooksecurefunc(f, "SetPoint", function(self)
            if self.wlPlace and not placing then
                placing = true
                pcall(self.wlPlace, self)
                placing = false
            end
        end)
    end
    placing = true
    pcall(fn, f)
    placing = false
end

local function tuck(f)
    if not f or saved[f] then return end
    remember(f)
    pcall(f.SetParent, f, hider)
end

-- shared with the chat: the same borrowing for its buttons and boxes
ns.Borrow = { Remember = remember, GiveBack = giveBack, KeepPlaced = keepPlaced, Tuck = tuck }

-- The game's parts around the map that ours replaces.
local HIDE_NAMES = {
    "MinimapBorder", "MinimapBorderTop", "MinimapZoomIn", "MinimapZoomOut", "MinimapZoneTextButton",
    "MiniMapWorldMapButton", "MinimapToggleButton", "GameTimeFrame", "TimeManagerClockButton",
    "MinimapNorthTag", "MinimapCompassTexture", "MiniMapMailFrame", "MiniMapInstanceDifficulty",
    "GuildInstanceDifficulty", "MiniMapChallengeMode", "MiniMapVoiceChatFrame", "MiniMapRecordingButton",
    "MinimapBackdrop",
}

-- The game's own buttons that are never collected into the drawer.
local BLIZZARD = {}
for _, n in ipairs(HIDE_NAMES) do BLIZZARD[n] = true end
for _, n in ipairs({ "MiniMapTracking", "MiniMapTrackingFrame", "MiniMapBattlefieldFrame", "MiniMapLFGFrame",
                     "LFGMinimapFrame", "QueueStatusMinimapButton", "MinimapCluster", "Minimap" }) do
    BLIZZARD[n] = true
end

local function trackingFrame()
    return (MinimapCluster and MinimapCluster.Tracking) or MiniMapTracking or MiniMapTrackingFrame
end

local function queueFrames()
    local list = {}
    for _, f in ipairs({ MiniMapBattlefieldFrame, MiniMapLFGFrame, LFGMinimapFrame, QueueStatusMinimapButton }) do
        if f then list[#list + 1] = f end
    end
    return list
end

-- The game's buttons that belong in the drawer rather than away (Retail).
local function gameDrawerButtons()
    local list = {}
    for _, f in ipairs({ ExpansionLandingPageMinimapButton, GarrisonLandingPageMinimapButton, AddonCompartmentFrame }) do
        if f then list[#list + 1] = f end
    end
    return list
end

---------------------------------------------------------------------------
-- Art of the game's and other addons' buttons
---------------------------------------------------------------------------

local ART_IDS = { [136430] = true, [136467] = true, [136477] = true } -- tracking border, background, highlight
local ART_PATTERNS = { "trackingborder", "minimap%-background", "zoombutton%-highlight", "minimap%-border" }

local function isFrameArt(t)
    local ok, tex = pcall(t.GetTexture, t)
    tex = ok and tex or nil
    local id = t.GetTextureFileID and call(t.GetTextureFileID, t)
    if (type(id) == "number" and ART_IDS[id]) or (type(tex) == "number" and ART_IDS[tex]) then return true end
    local names = { type(tex) == "string" and tex or nil, t.GetAtlas and call(t.GetAtlas, t) or nil }
    for _, s in ipairs(names) do
        if type(s) == "string" then
            s = s:lower()
            for _, p in ipairs(ART_PATTERNS) do
                if s:find(p) then return true end
            end
            if s:find("minimap") and (s:find("background") or s:find("border")) then return true end
        end
    end
    return false
end

local stripped = {}          -- textures made invisible -> true

local function stripArt(f, deep)
    for _, r in ipairs({ f:GetRegions() }) do
        if r.IsObjectType and r:IsObjectType("Texture") and isFrameArt(r) then
            stripped[r] = true
            r:SetAlpha(0)
        end
    end
    if deep then
        for _, c in ipairs({ f:GetChildren() }) do stripArt(c, false) end
    end
end

local function unstrip()
    for t in pairs(stripped) do t:SetAlpha(1) end
    wipe(stripped)
end

-- Our look behind a button: a rounded (or round) border and background.
local function shapeTexture(size)
    local C = cfg()
    if C.shape == "round" then return ns.BlizzardUI.RoundTexture(50) end
    return ns.BlizzardUI.RoundTexture(size > 0 and C.radius / size * 100 or 0)
end

local function backing(f, size)
    local C = cfg()
    if not f.wlBack then
        f.wlBack = {
            edge = f:CreateTexture(nil, "BACKGROUND", nil, -8),
            bg = f:CreateTexture(nil, "BACKGROUND", nil, -7),
            hl = f:CreateTexture(nil, "HIGHLIGHT", nil, 7),
        }
    end
    local k = f.wlBack
    local b = C.border and C.borderSize or 0
    local tex = shapeTexture(size)
    for _, t in pairs(k) do
        t:SetTexture(tex)
        t:ClearAllPoints()
        t:SetPoint("CENTER", f, "CENTER", 0, 0)
        t:Show()
    end
    k.edge:SetSize(size, size)
    tint(k.edge, C.borderColor, b > 0 and C.borderOpacity or 0)
    k.bg:SetSize(size - 2 * b, size - 2 * b)
    tint(k.bg, C.pillColor, math.max(C.pillOpacity, 0.75))
    k.hl:SetSize(size - 2 * b, size - 2 * b)
    k.hl:SetVertexColor(1, 1, 1, 0.15)
    k.hl:SetBlendMode("ADD")
end

local function unback(f)
    if f.wlBack then
        for _, t in pairs(f.wlBack) do t:Hide() end
    end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function pill(parent)
    local f = CreateFrame("Button", nil, parent)
    f.edge = { strips = ns.BlizzardUI.NewStrips(f, "BACKGROUND", -6), corners = ns.BlizzardUI.NewRoundRect(f, "BACKGROUND", -6) }
    f.bg = ns.BlizzardUI.NewRoundRect(f, "BACKGROUND", -5)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("CENTER", 0, 0)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return f
end

local function layoutPill(f, height)
    local C = cfg()
    local r = math.floor(height / 2)
    ns.BlizzardUI.LayoutRoundRect(f.bg, f, 0, r)
    for _, t in ipairs(f.bg) do tint(t, C.pillColor, C.pillOpacity) end
    for _, t in ipairs(f.edge.strips) do t:Hide() end
    for _, t in ipairs(f.edge.corners) do t:Hide() end
end

-- A small square (or round) button of our own: zoom, the drawer's toggle.
local function smallButton(parent, label, icon)
    local b = CreateFrame("Button", nil, parent)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if icon then
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetTexture(icon)
        b.icon:SetPoint("CENTER")
    else
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER", 0, 1)
        b.text:SetText(label)
    end
    return b
end

local function create()
    local h = CreateFrame("Frame", "WombatLogMinimap", UIParent)
    h:SetFrameStrata("LOW")
    h:SetFrameLevel(2)
    h:SetClampedToScreen(true)
    h:SetMovable(true)
    h:Hide()

    -- the map with its border and shadow
    local m = CreateFrame("Frame", nil, h)
    m:SetFrameLevel(h:GetFrameLevel() + 1)
    h.map = m
    m.shadow = m:CreateTexture(nil, "BACKGROUND", nil, -8)
    m.shadow:SetTexture(GLOW)
    m.glow = m:CreateTexture(nil, "BACKGROUND", nil, -7) -- in combat
    m.glow:SetTexture(GLOW)
    m.glow:SetBlendMode("ADD")
    m.glow:Hide()
    m.edgeRect = ns.BlizzardUI.NewRoundRect(m, "BACKGROUND", -6)
    m.edgeRound = m:CreateTexture(nil, "BACKGROUND", nil, -6)
    m.edgeRound:SetTexture(ns.BlizzardUI.RoundTexture(50))
    m.edgeRound:SetAllPoints()

    -- everything on top of the map
    local top = CreateFrame("Frame", nil, h)
    top:SetAllPoints(m)
    h.top = top

    h.zone = pill(h)
    h.clock = pill(h)
    h.coords = pill(top)
    h.coords:EnableMouse(false)
    h.invite = h.clock:CreateTexture(nil, "OVERLAY")
    h.invite:SetTexture(DIAMOND)
    h.invite:SetVertexColor(1, 0.82, 0.2)
    h.invite:Hide()

    h.mail = CreateFrame("Frame", nil, top)
    h.mail.icon = h.mail:CreateTexture(nil, "ARTWORK")
    h.mail.icon:SetTexture(MAIL_ICON)
    h.mail:EnableMouse(true)
    h.mail:Hide()

    h.diff = pill(top)
    h.diff:Hide()

    h.zoomIn = smallButton(top, "+")
    h.zoomOut = smallButton(top, "-")
    h.toggle = smallButton(top, nil, LINES)

    -- the drawer for the other addons' buttons
    local d = CreateFrame("Frame", "WombatLogMinimapDrawer", h)
    d:SetFrameStrata("MEDIUM")
    d:SetClampedToScreen(true)
    d.edge = { strips = ns.BlizzardUI.NewStrips(d, "BACKGROUND", -6), corners = ns.BlizzardUI.NewRoundRect(d, "BACKGROUND", -6) }
    d.bg = ns.BlizzardUI.NewRoundRect(d, "BACKGROUND", -5)
    d.shadow = d:CreateTexture(nil, "BACKGROUND", nil, -8)
    d.shadow:SetTexture(GLOW)
    d:Hide()
    h.drawer = d

    -- moving: a tinted cover that takes the mouse while unlocked
    local o = CreateFrame("Frame", nil, h)
    o:SetAllPoints()
    o:SetFrameLevel(h:GetFrameLevel() + 30)
    o.tex = o:CreateTexture(nil, "OVERLAY")
    o.tex:SetAllPoints()
    o.tex:SetColorTexture(0.2, 0.6, 1, 0.2)
    o.text = o:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    o.text:SetPoint("BOTTOM", o, "TOP", 0, 2)
    o.text:SetText(L["WombatUI minimap - drag to move"])
    o:EnableMouse(true)
    o:RegisterForDrag("LeftButton")
    o:SetScript("OnDragStart", function() h:StartMoving() end)
    o:SetScript("OnDragStop", function()
        h:StopMovingOrSizing()
        local C = cfg()
        local s = UIParent:GetEffectiveScale() / h:GetEffectiveScale()
        local x, y = h:GetCenter()
        C.x = math.floor(x - UIParent:GetWidth() * s / 2 + 0.5)
        C.y = math.floor(y - UIParent:GetHeight() * s / 2 + 0.5)
        MF:Anchor()
    end)
    o:Hide()
    h.cover = o

    -- animations: fading in, mail pulsing, the combat glow
    h.fade = h:CreateAnimationGroup()
    local a = h.fade:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(0.6)
    a:SetSmoothing("OUT")
    h.pulse = h.mail:CreateAnimationGroup()
    for i = 1, 6 do
        local p = h.pulse:CreateAnimation("Alpha")
        p:SetFromAlpha(i % 2 == 1 and 1 or 0.25)
        p:SetToAlpha(i % 2 == 1 and 0.25 or 1)
        p:SetDuration(0.35)
        p:SetOrder(i)
    end
    return h
end

---------------------------------------------------------------------------
-- Places
---------------------------------------------------------------------------

-- Where the i-th icon (0 = first) of a corner goes, from the map's center: inside
-- the square's corners, or along the round map's edge.
local CORNERS = {
    TOPLEFT = { -1, 1, 135, 1 }, TOPRIGHT = { 1, 1, 45, -1 },
    BOTTOMLEFT = { -1, -1, 225, -1 }, BOTTOMRIGHT = { 1, -1, 315, 1 },
}

function MF:Slot(corner, i, size)
    local C = cfg()
    local sx, sy, angle, dir = unpack(CORNERS[corner])
    local half = C.size / 2
    if C.shape == "round" then
        local r = half - size * 0.1
        local step = math.deg((size + GAP) / r)
        local a = math.rad(angle + dir * i * step)
        return math.cos(a) * r, math.sin(a) * r
    end
    local off = half - INSET - size / 2
    return sx * off, sy * (off - i * (size + GAP))
end

local function putAt(f, corner, i, size)
    local h = MF.holder
    local x, y = MF:Slot(corner, i, size)
    -- a scaled frame's offsets count in its own scale
    local s = f.GetScale and f:GetScale() or 1
    if not s or s <= 0 then s = 1 end
    f:ClearAllPoints()
    f:SetPoint("CENTER", h.map, "CENTER", x / s, y / s)
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

local function textHeight() return cfg().textSize + 8 end

-- Where you put it, or the game's minimap's corner.
function MF:Anchor()
    local C, h = cfg(), self.holder
    h:ClearAllPoints()
    if C.x and C.y then
        h:SetPoint("CENTER", UIParent, "CENTER", C.x, C.y)
    else
        h:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -14, -8)
    end
end

-- The masks come in steps of 5 % of the side: the corner radius they draw, in px.
local function maskPercent()
    local C = cfg()
    return math.max(0, math.min(50, math.floor(C.radius / C.size * 100 / 5 + 0.5) * 5))
end

local function mapMask()
    local C = cfg()
    if C.shape == "round" then return CIRCLE end
    if maskPercent() == 0 then return WHITE end
    return ns.BlizzardUI.RoundTexture(maskPercent())
end

-- the game's own mask for its round map, to give it back
local function gameMask()
    if ns.FLAVOR == "vanilla" or ns.FLAVOR == "tbc" or ns.FLAVOR == "mists" then return "Textures\\MinimapMask" end
    return "Interface\\Masks\\CircleMaskScalable"
end

local function setMask(tex)
    pcall(Minimap.SetMaskTexture, Minimap, tex)
    local hy = HybridMinimap
    if hy and hy.CircleMask then pcall(hy.CircleMask.SetTexture, hy.CircleMask, tex) end
    if hy and hy.MapCanvas and hy.MapCanvas.SetMaskTexture then pcall(hy.MapCanvas.SetMaskTexture, hy.MapCanvas, tex) end
end

-- Map pins of other addons (HereBeDragons: Questie, SilverDragon and others) measure
-- the map again only when you move, zoom or its scale changes, not for a new size:
-- a scale changed by a hair, and back a moment later, tells them.
function MF:NudgePins()
    self.nudge = (self.nudge or 0) + 1
    local token = self.nudge
    Minimap:SetScale(0.999)
    C_Timer.After(1.5, function()
        if token == self.nudge and self.active then Minimap:SetScale(1) end
    end)
end

-- After a new size the map draws anew only when its zoom changes.
local function redraw()
    local z = Minimap:GetZoom()
    local levels = Minimap:GetZoomLevels()
    if z + 1 < levels then
        Minimap:SetZoom(z + 1)
    elseif z > 0 then
        Minimap:SetZoom(z - 1)
    end
    Minimap:SetZoom(z)
end

function MF:Layout()
    local C, h, A = cfg(), self.holder, ns.db.appearance
    local S = C.size
    local b = C.border and C.borderSize or 0
    local W = S + 2 * b
    local th = textHeight()
    local topH = C.zone and th + 3 or 0
    local botH = C.clock and th + 3 or 0
    h:SetScale(C.scale)
    h:SetSize(W, W + topH + botH)
    self:Anchor()

    local m = h.map
    m:ClearAllPoints()
    m:SetSize(W, W)
    m:SetPoint("TOP", h, "TOP", 0, -topH)

    -- the map itself
    keepPlaced(Minimap, function(f)
        f:ClearAllPoints()
        f:SetPoint("CENTER", m, "CENTER", 0, 0)
    end)
    Minimap:SetSize(S, S)
    setMask(mapMask())
    redraw()
    if self.lastSize ~= S then
        self.lastSize = S
        self:NudgePins()
    end

    -- border: a rounded square or a disc behind the map, showing past its edge
    local round = C.shape == "round"
    local r = (not round and maskPercent() > 0) and math.floor(S * maskPercent() / 100 + 0.5) + b or 0
    m.edgeRect[1]:Show()
    ns.BlizzardUI.LayoutRoundRect(m.edgeRect, m, 0, r)
    for _, t in ipairs(m.edgeRect) do
        tint(t, C.borderColor, C.borderOpacity)
        if round or b == 0 then t:Hide() end
    end
    m.edgeRound:SetShown(round and b > 0)
    tint(m.edgeRound, C.borderColor, C.borderOpacity)
    -- the glow texture is a soft disc: only its outer half shows past the map
    local sh = math.floor(W * 0.45)
    m.shadow:ClearAllPoints()
    m.shadow:SetPoint("TOPLEFT", m, "TOPLEFT", -sh, sh)
    m.shadow:SetPoint("BOTTOMRIGHT", m, "BOTTOMRIGHT", sh, -sh)
    m.shadow:SetShown(C.shadow)
    tint(m.shadow, { 0, 0, 0 }, C.shadowOpacity)
    -- the combat glow reaches farther, so more of its bright middle shows past the map
    local gs = math.floor(W * 0.6)
    m.glow:ClearAllPoints()
    m.glow:SetPoint("TOPLEFT", m, "TOPLEFT", -gs, gs)
    m.glow:SetPoint("BOTTOMRIGHT", m, "BOTTOMRIGHT", gs, -gs)
    tint(m.glow, C.combatGlowColor, 1)
    h.top:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    for _, f in ipairs({ h.coords, h.mail, h.diff, h.zoomIn, h.zoomOut, h.toggle }) do
        f:SetFrameLevel(h.top:GetFrameLevel() + 1)
    end

    -- zone above, clock below, coordinates at the map's bottom
    for _, p in ipairs({ h.zone, h.clock, h.coords, h.diff }) do
        ns.SetFont(p.text, p == h.zone and A.nameFont or A.amountFont, p == h.diff and math.max(8, C.textSize - 2) or C.textSize, "OUTLINE")
    end
    h.zone:SetHeight(th)
    h.zone:ClearAllPoints()
    h.zone:SetPoint("BOTTOM", m, "TOP", 0, 3)
    layoutPill(h.zone, th)
    h.clock:SetHeight(th)
    h.clock:ClearAllPoints()
    h.clock:SetPoint("TOP", m, "BOTTOM", 0, -3)
    layoutPill(h.clock, th)
    h.invite:SetSize(th - 6, th - 6)
    h.invite:ClearAllPoints()
    h.invite:SetPoint("RIGHT", h.clock, "LEFT", -3, 0)
    local ch = C.textSize + 4
    h.coords:SetHeight(ch)
    h.coords:ClearAllPoints()
    h.coords:SetPoint("BOTTOM", m, "BOTTOM", 0, round and math.floor(S * 0.06) + b or INSET + b)
    layoutPill(h.coords, ch)

    -- icons in the corners
    local is = C.iconSize
    h.mail:SetSize(is, is)
    h.mail.icon:SetAllPoints()
    backing(h.mail, is + 4)
    h.diff:SetHeight(math.max(12, is - 4))
    layoutPill(h.diff, math.max(12, is - 4))
    for _, z in ipairs({ h.zoomIn, h.zoomOut, h.toggle }) do
        z:SetSize(is, is)
        backing(z, is)
        if z.text then ns.SetFont(z.text, A.amountFont, math.floor(is * 0.75), "OUTLINE") end
        if z.icon then z.icon:SetSize(is * 0.6, is * 0.6) end
    end
    putAt(h.toggle, "BOTTOMLEFT", 0, is)
    putAt(h.zoomOut, "BOTTOMRIGHT", 0, is)
    putAt(h.zoomIn, "BOTTOMRIGHT", 1, is)
    self:PlaceStatus()
    self:LayoutDrawer()
    self:UpdateZone()
    self:UpdateClock()
    self:UpdateCoords()
    self:UpdateZoomButtons()
end

-- Mail and the queues top left, tracking and the difficulty top right; hidden ones
-- leave no gap.
function MF:PlaceStatus()
    local C, h = cfg(), self.holder
    local is = C.iconSize
    local i = 0
    if h.mail:IsShown() then
        putAt(h.mail, "TOPLEFT", i, is + 4)
        i = i + 1
    end
    for _, f in ipairs(self.queues or {}) do
        if f:IsShown() then
            local slot = i
            keepPlaced(f, function(q) putAt(q, "TOPLEFT", slot, is + 4) end)
            i = i + 1
        end
    end
    i = 0
    local t = self.tracking
    if t then t:SetFrameLevel(h.top:GetFrameLevel() + 2) end
    for _, f in ipairs(self.queues or {}) do f:SetFrameLevel(h.top:GetFrameLevel() + 2) end
    if t and t:IsShown() then
        keepPlaced(t, function(q) putAt(q, "TOPRIGHT", 0, is + 4) end)
        i = 1
    end
    if h.diff:IsShown() then putAt(h.diff, "TOPRIGHT", i, is) end
end

---------------------------------------------------------------------------
-- Zone, clock, coordinates
---------------------------------------------------------------------------

local PVP_COLORS = {
    sanctuary = { 0.41, 0.80, 0.94 }, arena = { 1.00, 0.10, 0.10 }, hostile = { 1.00, 0.10, 0.10 },
    friendly = { 0.10, 1.00, 0.10 }, contested = { 1.00, 0.70, 0.00 }, combat = { 1.00, 0.10, 0.10 },
}

local function fitPill(p, maxW)
    local w = p.text:GetStringWidth() or 0
    p:SetWidth(math.min(maxW, math.floor(w + 14)))
end

function MF:UpdateZone()
    local C, h = cfg(), self.holder
    h.zone:SetShown(C.zone)
    if not C.zone then return end
    h.zone.text:SetText(call(GetMinimapZoneText) or "")
    local c = { 1, 0.82, 0 }
    if C.zoneColor == "pvp" then
        c = PVP_COLORS[call(GetZonePVPInfo) or ""] or c
    else
        c = { 1, 1, 1 }
    end
    h.zone.text:SetTextColor(c[1], c[2], c[3])
    fitPill(h.zone, C.size + 2 * (C.border and C.borderSize or 0))
end

local function timeText(hour, minute)
    if cfg().clock24 then return ("%02d:%02d"):format(hour, minute) end
    local pm = hour >= 12
    hour = hour % 12
    if hour == 0 then hour = 12 end
    return ("%d:%02d %s"):format(hour, minute, pm and (TIMEMANAGER_PM or "PM") or (TIMEMANAGER_AM or "AM"))
end

local function localTime()
    local t = date("*t")
    return timeText(t.hour, t.min)
end

local function serverTime()
    local hour, minute = call(GetGameTime)
    if not hour then return nil end
    return timeText(hour, minute)
end

function MF:UpdateClock()
    local C, h = cfg(), self.holder
    h.clock:SetShown(C.clock)
    if not C.clock then h.invite:Hide() return end
    h.clock.text:SetText((C.clockServer and serverTime()) or localTime())
    h.clock.text:SetTextColor(1, 1, 1)
    fitPill(h.clock, C.size)
    local invites = C.calendar and C_Calendar and C_Calendar.GetNumPendingInvites and call(C_Calendar.GetNumPendingInvites) or 0
    h.invite:SetShown((invites or 0) > 0)
end

local function playerCoords()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local map = Safe(call(C_Map.GetBestMapForUnit, "player"))
    if not map then return nil end
    local pos = call(C_Map.GetPlayerMapPosition, map, "player")
    if not pos then return nil end
    local x, y = call(pos.GetXY, pos)
    x, y = Safe(x), Safe(y)
    if not x or not y or (x == 0 and y == 0) then return nil end
    return x * 100, y * 100
end

function MF:UpdateCoords()
    local C, h = cfg(), self.holder
    local x, y = nil, nil
    if C.coords then x, y = playerCoords() end
    h.coords:SetShown(x ~= nil)
    if not x then return end
    local fmt = C.coordsDecimals > 0 and "%.1f, %.1f" or "%d, %d"
    if C.coordsDecimals > 0 then
        h.coords.text:SetText(fmt:format(x, y))
    else
        h.coords.text:SetText(fmt:format(math.floor(x + 0.5), math.floor(y + 0.5)))
    end
    h.coords.text:SetTextColor(1, 1, 1)
    fitPill(h.coords, C.size)
end

---------------------------------------------------------------------------
-- Status: mail, difficulty, zoom
---------------------------------------------------------------------------

function MF:UpdateMail()
    local C, h = cfg(), self.holder
    local has = C.mail and call(HasNewMail) and true or false
    local was = h.mail:IsShown()
    h.mail:SetShown(has)
    if has and not was and C.anim.mailPulse and self.shownOnce then h.pulse:Play() end
    if was ~= has then self:PlaceStatus() end
end

function MF:UpdateDifficulty()
    local C, h = cfg(), self.holder
    local text
    if C.difficulty then
        local _, kind, id, _, maxPlayers = call(GetInstanceInfo)
        kind, id, maxPlayers = Safe(kind), Safe(id), Safe(maxPlayers)
        if kind and kind ~= "none" and id and id > 0 then
            local _, _, heroic, challenge, showHeroic, showMythic = call(GetDifficultyInfo, id)
            local mark = (showMythic or challenge) and "M" or (heroic or showHeroic) and "H" or "N"
            text = ((maxPlayers and maxPlayers > 0) and tostring(maxPlayers) or "") .. mark
        end
    end
    h.diff:SetShown(text ~= nil)
    if text then
        h.diff.text:SetText(text)
        h.diff.text:SetTextColor(1, 0.82, 0.2)
        fitPill(h.diff, 60)
    end
    self:PlaceStatus()
end

function MF:UpdateZoomButtons()
    local C, h = cfg(), self.holder
    local z, levels = Minimap:GetZoom(), Minimap:GetZoomLevels()
    h.zoomIn:SetShown(C.zoomButtons)
    h.zoomOut:SetShown(C.zoomButtons)
    h.zoomIn:SetAlpha(z + 1 < levels and 1 or 0.4)
    h.zoomOut:SetAlpha(z > 0 and 1 or 0.4)
end

function MF:Zoom(step)
    local z, levels = Minimap:GetZoom(), Minimap:GetZoomLevels()
    Minimap:SetZoom(math.max(0, math.min(levels - 1, z + step)))
    self:OnZoom()
end

-- Zoomed in: back out after a while.
function MF:OnZoom()
    self:UpdateZoomButtons()
    local C = cfg()
    self.zoomToken = (self.zoomToken or 0) + 1
    if not (self.active and C.autoZoom) or Minimap:GetZoom() == 0 then return end
    local token = self.zoomToken
    C_Timer.After(C.autoZoomDelay, function()
        if token ~= self.zoomToken or not self.active then return end
        Minimap:SetZoom(0)
        self:UpdateZoomButtons()
    end)
end

---------------------------------------------------------------------------
-- The drawer: the other addons' buttons
---------------------------------------------------------------------------

local collected = {}         -- button -> true
local order = {}             -- collected buttons, by name

local function nameOf(f)
    local ok, n = pcall(f.GetName, f)
    return ok and n or nil
end

local function wantsCollect(f)
    if f.wlOurs or collected[f] then return false end
    if not (f.IsObjectType and f:IsObjectType("Frame")) then return false end
    if f == WombatLogMinimapButton then return true end
    local name = nameOf(f)
    if not name or BLIZZARD[name] then return false end
    if name:find("^LibDBIcon10_") then return true end
    local n = name:lower()
    if not n:find("minimap") and not n:find("mmb") then return false end
    return (n:find("button") or n:find("icon") or n:find("btn")) and true or false
end

local function findIcon(f)
    local icon = f.icon or f.Icon
    if icon and icon.IsObjectType and icon:IsObjectType("Texture") then return icon end
    local name = nameOf(f)
    icon = name and (_G[name .. "Icon"] or _G[name .. "_Icon"])
    if icon and icon.IsObjectType and icon:IsObjectType("Texture") then return icon end
    for _, r in ipairs({ f:GetRegions() }) do
        if r.IsObjectType and r:IsObjectType("Texture") and not stripped[r] and r:GetDrawLayer() == "ARTWORK" then
            return r
        end
    end
end

local function relayout() if MF.holder then MF:LayoutDrawer() end end

local function collect(f, game)
    local s = remember(f)
    collected[f] = true
    f.wlCollected = true
    order[#order + 1] = f
    f.wlGame = game
    pcall(f.SetParent, f, MF.holder.drawer)
    -- dragging it along the map's edge has no place in the drawer
    s.drag, s.dragStop = f:GetScript("OnDragStart") or false, f:GetScript("OnDragStop") or false
    if f:GetScript("OnDragStart") then f:SetScript("OnDragStart", nil) end
    if f:GetScript("OnDragStop") then f:SetScript("OnDragStop", nil) end
    if not f.wlShowHook then
        f.wlShowHook = true
        f:HookScript("OnShow", relayout)
        f:HookScript("OnHide", relayout)
    end
end

-- Our look on a collected button: the round border goes, ours comes, the icon fills it.
local function restyle(f)
    if f.wlGame == "plain" or not cfg().buttonLook then return end
    local size = cfg().buttonSize
    stripArt(f, true)
    backing(f, size)
    local icon = f.wlIcon or findIcon(f)
    if icon then
        if not f.wlIcon then
            f.wlIcon = icon
            f.wlIconSaved = { w = icon:GetWidth(), h = icon:GetHeight(), points = {} }
            for i = 1, icon:GetNumPoints() do f.wlIconSaved.points[i] = { icon:GetPoint(i) } end
        end
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", f, "CENTER", 0, 0)
        icon:SetSize(math.floor(size * 0.62), math.floor(size * 0.62))
    end
end

local function unstyle(f)
    unback(f)
    local icon, s = f.wlIcon, f.wlIconSaved
    if icon and s then
        icon:ClearAllPoints()
        for _, p in ipairs(s.points) do pcall(icon.SetPoint, icon, unpack(p)) end
        icon:SetSize(s.w, s.h)
    end
    f.wlIcon, f.wlIconSaved = nil, nil
end

-- Looks for buttons that aren't collected yet.
function MF:Scan()
    if not (self.active and cfg().collect) then return end
    local found = false
    local function look(parent)
        if not parent then return end
        for _, c in ipairs({ parent:GetChildren() }) do
            if wantsCollect(c) then
                collect(c)
                found = true
            end
        end
    end
    look(Minimap)
    look(MinimapBackdrop)
    look(MinimapCluster)
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    if lib and lib.objects then
        for _, b in pairs(lib.objects) do
            if not collected[b] then
                collect(b)
                found = true
            end
        end
    end
    for _, b in ipairs(gameDrawerButtons()) do
        if not collected[b] then
            collect(b, b == AddonCompartmentFrame and "plain" or "game")
            found = true
        end
    end
    if found then self:LayoutDrawer() end
end

function MF:RequestScan()
    if self.scanPending then return end
    self.scanPending = true
    C_Timer.After(0.5, function()
        self.scanPending = false
        self:Scan()
    end)
end

local function drawerOpen()
    local C, h = cfg(), MF.holder
    return C.drawer == "bar" or h.drawerOpen
end

function MF:LayoutDrawer()
    -- showing or hiding the drawer shows or hides its buttons, which asks again
    if self.layingOut then return end
    self.layingOut = true
    local ok, err = pcall(self.DoLayoutDrawer, self)
    self.layingOut = false
    if not ok then error(err, 0) end
end

function MF:DoLayoutDrawer()
    local C, h = cfg(), self.holder
    local d = h.drawer
    table.sort(order, function(a, b) return (nameOf(a) or "") < (nameOf(b) or "") end)
    local list = {}
    for _, f in ipairs(order) do
        if f:IsShown() then list[#list + 1] = f end
    end
    local size, pad, gap = C.buttonSize, 6, 4
    local cols = math.max(1, math.min(C.columns, #list))
    local rows = math.max(1, math.ceil(#list / cols))
    d:SetSize(pad * 2 + cols * size + (cols - 1) * gap, pad * 2 + rows * size + (rows - 1) * gap)
    for i, f in ipairs(list) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        restyle(f)
        f:SetFrameStrata("MEDIUM")
        f:SetFrameLevel(d:GetFrameLevel() + 2)
        keepPlaced(f, function(b)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", d, "TOPLEFT", pad + col * (size + gap), -(pad + row * (size + gap)))
        end)
        if f.wlGame ~= "plain" then f:SetSize(size, size) end
    end
    -- the panel
    local r = C.shape == "round" and math.floor(size / 2) + pad or C.radius
    ns.BlizzardUI.LayoutRoundRect(d.bg, d, 0, math.max(0, r))
    for _, t in ipairs(d.bg) do tint(t, C.pillColor, math.max(C.pillOpacity, 0.75)) end
    for _, t in ipairs(d.edge.strips) do t:Hide() end
    for _, t in ipairs(d.edge.corners) do t:Hide() end
    d.shadow:ClearAllPoints()
    d.shadow:SetPoint("TOPLEFT", d, "TOPLEFT", -12, 12)
    d.shadow:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", 12, -12)
    d.shadow:SetShown(C.shadow)
    tint(d.shadow, { 0, 0, 0 }, C.shadowOpacity)
    d:ClearAllPoints()
    if C.drawerSide == "right" then
        d:SetPoint("TOPLEFT", h.map, "TOPRIGHT", 6, 0)
    elseif C.drawerSide == "bottom" then
        d:SetPoint("TOP", h, "BOTTOM", 0, -6)
    else
        d:SetPoint("TOPRIGHT", h.map, "TOPLEFT", -6, 0)
    end
    local any = #list > 0 and C.collect
    h.toggle:SetShown(any and C.drawer ~= "bar")
    d:SetShown(any and drawerOpen())
end

function MF:ToggleDrawer(open)
    local h = self.holder
    if open == nil then open = not h.drawerOpen end
    h.drawerOpen = open
    h.drawer.idle = 0
    self:LayoutDrawer()
end

-- Every collected button back to its place on the map's edge.
local function releaseAll()
    for _, f in ipairs(order) do
        unstyle(f)
        giveBack(f)
        collected[f] = nil
        f.wlCollected = nil
    end
    wipe(order)
    unstrip()
end

---------------------------------------------------------------------------
-- Switching on and off
---------------------------------------------------------------------------

local gameShape -- GetMinimapShape before ours

local function ourShape()
    return cfg().shape == "round" and "ROUND" or "SQUARE"
end

function MF:Activate()
    local h = self.holder
    self.active = true
    -- the map into our frame
    remember(Minimap)
    self.mapSize = { Minimap:GetSize() }
    Minimap:SetParent(h)
    Minimap:SetFrameStrata("LOW")
    Minimap:SetFrameLevel(h.map:GetFrameLevel() + 2)
    if not self.wheelSet and not Minimap:GetScript("OnMouseWheel") then
        self.wheelSet = true
        Minimap:EnableMouseWheel(true)
        Minimap:SetScript("OnMouseWheel", function(_, delta) if MF.active then MF:Zoom(delta > 0 and 1 or -1) end end)
    end
    -- the game's status buttons into our corners
    local C = cfg()
    self.tracking = C.tracking and trackingFrame() or nil
    if self.tracking then
        remember(self.tracking)
        self.tracking:SetParent(h.top)
        stripArt(self.tracking, true)
        local w = self.tracking:GetWidth() or 32
        self.tracking:SetScale(w > 0 and (C.iconSize + 6) / w or 1)
    end
    self.queues = {}
    if C.queue then
        for _, f in ipairs(queueFrames()) do
            remember(f)
            f:SetParent(h.top)
            stripArt(f, true)
            local w = f:GetWidth() or 32
            f:SetScale(w > 0 and (C.iconSize + 6) / w or 1)
            if not f.wlQueueHook then
                f.wlQueueHook = true
                f:HookScript("OnShow", function() if MF.active then MF:PlaceStatus() end end)
                f:HookScript("OnHide", function() if MF.active then MF:PlaceStatus() end end)
            end
            self.queues[#self.queues + 1] = f
        end
    end
    -- the other addons' buttons into the drawer, before their parents go
    self:Scan()
    -- the rest of the game's frame away
    for _, n in ipairs(HIDE_NAMES) do tuck(_G[n]) end
    for _, key in ipairs({ "ZoomIn", "ZoomOut", "ZoomHitArea" }) do
        if Minimap[key] then tuck(Minimap[key]) end
    end
    if MinimapCluster and MinimapCluster ~= h then
        MinimapCluster:Hide()
        if not self.clusterHook then
            self.clusterHook = true
            hooksecurefunc(MinimapCluster, "Show", function(f) if MF.active then f:Hide() end end)
        end
    end
    if gameShape == nil then gameShape = GetMinimapShape or false end
    GetMinimapShape = ourShape
    h:Show()
    if C.anim.fadeIn then h.fade:Play() end
    self.shownOnce = true
end

function MF:Deactivate()
    if not self.active then return end
    self.active = false
    local h = self.holder
    releaseAll()
    for f in pairs(saved) do giveBack(f) end
    if self.mapSize then Minimap:SetSize(self.mapSize[1], self.mapSize[2]) end
    if self.tracking then self.tracking:SetScale(1) end
    for _, f in ipairs(self.queues or {}) do f:SetScale(1) end
    self.tracking, self.queues = nil, {}
    if MinimapCluster then MinimapCluster:Show() end
    setMask(gameMask())
    if gameShape ~= nil then GetMinimapShape = gameShape or nil end
    h:Hide()
    if ns.Minimap and ns.Minimap.Apply then ns.Minimap:Apply() end
end

function MF:Apply()
    if not (ns.db and self.holder) then return end
    if InCombatLockdown() then
        self.pending = true
        return
    end
    self.pending = false
    local C = cfg()
    if C.enabled and not self.active then
        self:Activate()
    elseif not C.enabled and self.active then
        self:Deactivate()
        return
    elseif not C.enabled then
        return
    end
    -- collecting switched off: the buttons go back to the edge
    if not C.collect and #order > 0 then releaseAll() end
    if C.collect then
        if not C.buttonLook then
            for _, f in ipairs(order) do unstyle(f) end
            unstrip()
        end
        self:Scan()
    end
    self:Layout()
    self:UpdateMail()
    self:UpdateDifficulty()
    self:UpdateCombat()
    self:ApplyLocked()
end

function MF:UpdateCombat()
    local C, h = cfg(), self.holder
    local on = self.active and C.anim.combatGlow and self.inCombat
    self.glowing = on and true or false
    self.glowT = 0
    h.map.glow:SetShown(self.glowing)
    if not self.glowing then self:TintBorder(C.borderColor, C.borderOpacity) end
end

function MF:TintBorder(c, a)
    local m = self.holder.map
    for _, t in ipairs(m.edgeRect) do tint(t, c, a) end
    tint(m.edgeRound, c, a)
end

-- In combat the border pulses between its color and the glow's, the glow with it.
function MF:PulseGlow(elapsed)
    local C = cfg()
    self.glowT = (self.glowT or 0) + elapsed
    local f = 0.5 + 0.5 * math.sin(self.glowT * 3)
    local b, g = C.borderColor, C.combatGlowColor
    self:TintBorder({ b[1] + (g[1] - b[1]) * f, b[2] + (g[2] - b[2]) * f, b[3] + (g[3] - b[3]) * f }, math.max(C.borderOpacity, f))
    self.holder.map.glow:SetVertexColor(g[1], g[2], g[3], 0.45 + 0.55 * f)
end

function MF:SetLocked(locked)
    self.unlocked = not locked or nil
    self:ApplyLocked()
    if ns.Config then ns.Config:RefreshAll() end
end

function MF:ApplyLocked()
    if self.holder then self.holder.cover:SetShown(self.unlocked and self.active and true or false) end
end

-- /wl debug
function MF:Debug()
    if not self.active then
        ns.Print("minimap: off")
        return
    end
    local names = {}
    for _, f in ipairs(order) do names[#names + 1] = (nameOf(f) or "?") .. (f:IsShown() and "" or " (hidden)") end
    ns.Print(("minimap: shape %s, tracking %s, queues %d, drawer %d: %s"):format(
        ourShape(), self.tracking and (nameOf(self.tracking) or "yes") or "none", #(self.queues or {}),
        #order, #names > 0 and table.concat(names, ", ") or "-"))
end

---------------------------------------------------------------------------
-- Tooltips and clicks
---------------------------------------------------------------------------

local function tip(owner, fill)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    fill(GameTooltip)
    GameTooltip:Show()
end

local function hookScripts(h)
    h.zone:SetScript("OnClick", function()
        if ToggleWorldMap then ToggleWorldMap() end
    end)
    h.zone:SetScript("OnEnter", function(self)
        tip(self, function(t)
            t:AddLine(call(GetRealZoneText) or "", 1, 0.82, 0)
            local sub = call(GetSubZoneText)
            if sub and sub ~= "" then t:AddLine(sub, 1, 1, 1) end
            t:AddLine(L["Click: world map"], 0.6, 0.8, 1)
        end)
    end)
    h.clock:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if not Stopwatch_Toggle then loadAddOn("Blizzard_TimeManager") end
            if Stopwatch_Toggle then Stopwatch_Toggle() end
        elseif ToggleCalendar then
            ToggleCalendar()
        end
    end)
    h.clock:SetScript("OnEnter", function(self)
        tip(self, function(t)
            t:AddDoubleLine(L["Local time"], localTime(), 0.8, 0.8, 0.8, 1, 1, 1)
            local s = serverTime()
            if s then t:AddDoubleLine(L["Server time"], s, 0.8, 0.8, 0.8, 1, 1, 1) end
            local invites = C_Calendar and C_Calendar.GetNumPendingInvites and call(C_Calendar.GetNumPendingInvites) or 0
            if (invites or 0) > 0 then t:AddLine(L["Calendar invitations: %d"]:format(invites), 1, 0.82, 0.2) end
            t:AddLine(" ")
            t:AddLine(ToggleCalendar and L["Click: calendar   Right-click: stopwatch"] or L["Right-click: stopwatch"], 0.6, 0.8, 1)
        end)
    end)
    h.mail:SetScript("OnEnter", function(self)
        tip(self, function(t)
            t:AddLine(HAVE_MAIL_FROM or L["New mail"], 1, 0.82, 0)
            local senders = { call(GetLatestThreeSenders) }
            for _, s in ipairs(senders) do
                if type(s) == "string" then t:AddLine(s, 1, 1, 1) end
            end
        end)
    end)
    h.diff:SetScript("OnEnter", function(self)
        tip(self, function(t)
            local name, _, _, diffName = call(GetInstanceInfo)
            t:AddLine(name or "", 1, 0.82, 0)
            if diffName then t:AddLine(diffName, 1, 1, 1) end
        end)
    end)
    h.zoomIn:SetScript("OnClick", function() MF:Zoom(1) end)
    h.zoomOut:SetScript("OnClick", function() MF:Zoom(-1) end)
    h.toggle:SetScript("OnClick", function() MF:ToggleDrawer() end)
    h.toggle:SetScript("OnEnter", function(self)
        tip(self, function(t)
            t:AddLine(L["Addon buttons"], 1, 0.82, 0)
            t:AddLine(L["Click: show or hide"], 0.6, 0.8, 1)
        end)
    end)
    for _, f in ipairs({ h.zone, h.clock, h.mail, h.diff, h.toggle }) do
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    -- the drawer closes a moment after the mouse leaves it
    h.drawer:SetScript("OnUpdate", function(d, elapsed)
        if cfg().drawer == "bar" or not h.drawerOpen then return end
        if d:IsMouseOver() or h.toggle:IsMouseOver() then
            d.idle = 0
        else
            d.idle = (d.idle or 0) + elapsed
            if d.idle > 1.5 then MF:ToggleDrawer(false) end
        end
    end)
    -- the clock and coordinates tick
    local t = 0
    h:SetScript("OnUpdate", function(_, elapsed)
        if MF.glowing then MF:PulseGlow(elapsed) end
        t = t + elapsed
        if t < 0.2 then return end
        t = 0
        MF:UpdateCoords()
        local now = time()
        if now ~= MF.lastSecond then
            MF.lastSecond = now
            MF:UpdateClock()
        end
    end)
end

function MF:Init()
    -- the first test builds had a fixed spot as the default: back to the corner
    local C = cfg()
    if not C.placeVersion then
        C.x, C.y, C.placeVersion = nil, nil, 2
    end
    self.holder = create()
    self.inCombat = (InCombatLockdown() or Safe(UnitAffectingCombat("player"))) and true or false
    for _, f in ipairs({ self.holder.zone, self.holder.clock, self.holder.coords, self.holder.diff,
                         self.holder.mail, self.holder.toggle, self.holder.zoomIn, self.holder.zoomOut }) do
        f.wlOurs = true
    end
    hookScripts(self.holder)
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    if lib and lib.RegisterCallback then
        pcall(lib.RegisterCallback, MF, "LibDBIcon_IconCreated", function() MF:RequestScan() end)
    end
    self:Apply()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function ifActive(fn) return function(...) if MF.active then fn(...) end end end

for _, ev in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
    ns.Listen(ev, ifActive(function() MF:UpdateZone() end))
end
ns.Listen("PLAYER_ENTERING_WORLD", function()
    if not MF.holder then return end
    if MF.pending then MF:Apply() end
    if not MF.active then return end
    MF:UpdateZone()
    MF:UpdateMail()
    MF:UpdateDifficulty()
    MF:RequestScan()
    -- addons that make their buttons late
    C_Timer.After(3, function() MF:Scan() end)
end)
ns.Listen("UPDATE_INSTANCE_INFO", ifActive(function() MF:UpdateDifficulty() end))
ns.Listen("PLAYER_DIFFICULTY_CHANGED", ifActive(function() MF:UpdateDifficulty() end))
for _, ev in ipairs({ "UPDATE_PENDING_MAIL", "MAIL_INBOX_UPDATE", "MAIL_CLOSED" }) do
    ns.Listen(ev, ifActive(function() MF:UpdateMail() end))
end
ns.Listen("CALENDAR_UPDATE_PENDING_INVITES", ifActive(function() MF:UpdateClock() end))
ns.Listen("MINIMAP_UPDATE_ZOOM", ifActive(function() MF:OnZoom() end))
ns.Listen("ADDON_LOADED", function(name)
    if not MF.active then return end
    if name == "Blizzard_TimeManager" then tuck(TimeManagerClockButton) end
    if name == "Blizzard_HybridMinimap" then setMask(mapMask()) end
    MF:RequestScan()
end)
ns.Listen("PLAYER_REGEN_DISABLED", function()
    MF.inCombat = true
    if MF.active then MF:UpdateCombat() end
end)
ns.Listen("PLAYER_REGEN_ENABLED", function()
    MF.inCombat = false
    if MF.pending then MF:Apply() end
    if MF.active then MF:UpdateCombat() end
end)
