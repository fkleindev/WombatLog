local ADDON, ns = ...
local UnitFrames = {}
ns.UnitFrames = UnitFrames
local L = ns.L
local Safe, isSecret = ns.Safe, ns.IsSecret

-- Modern unit frames for you, your pet and your target. Blizzard's frames stay what
-- they are (clicks, the right-click menu, auras, the target's cast bar, target of
-- target, Edit Mode, the fade out of range): only their art, bars, portrait and
-- texts go invisible, and a frame of WombatLog's own inside each draws the new look
-- from the same unit. Nothing is touched until it's turned on.
--
-- Health and power may be secret on Forever and Retail in combat: the bars take them
-- straight from the API, and whatever needs maths (the damage trail, the heal flash,
-- low health) only runs on plain values, or asks the client to do it.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GLOW = MEDIA .. "Glow"
local SHINE = MEDIA .. "Shine"
local WINGS = { left = MEDIA .. "WingsLeft", right = MEDIA .. "Wings" }
local PAD = 2              -- px between the panel's border and the bars
local GAP = 1              -- px between health and power
local SHADOW = 12          -- px the shadow and the glows reach past the frame
local LAG_HOLD = 0.35      -- lost health stays this long...
local LAG_SPEED = 3        -- ...then runs after the bar (share of the rest per second)
local HEAL_FLASH = 0.5
local HIT_TIME = 0.3
local ENTER_TIME = 0.25
local ENTER_SLIDE = 14     -- px a new target slides in from
local PORTRAIT_FLASH = 0.35

local GREY = { 0.5, 0.5, 0.5 }
local TAPPED = { 0.55, 0.55, 0.55 }
local GREEN = { 0.10, 0.80, 0.20 }
local LOW = { 1.00, 0.12, 0.10 }
local COMBAT = { 1.00, 0.35, 0.15 }

-- poll: the game sends no events for the unit (target of target), so it's read
-- a few times a second, like Blizzard's own frame does
local UNITS = {
    { key = "player", frame = "PlayerFrame", unit = "player", side = "left" },
    { key = "pet", frame = "PetFrame", unit = "pet", side = "left" },
    { key = "target", frame = "TargetFrame", unit = "target", side = "right" },
    -- hideAll: everything in Blizzard's frame goes but its auras (the parts are named
    -- differently from client to client, and there are no icons to keep)
    { key = "targettarget", frame = "TargetFrameToT", unit = "targettarget", side = "left", poll = true, hideAll = true },
    { key = "focus", frame = "FocusFrame", unit = "focus", side = "right" }, -- not on Classic Era
}
local POLL = 0.1
-- the events that bring a new unit into a frame, and which frame
local NEW_UNIT = { PLAYER_TARGET_CHANGED = "target", PLAYER_FOCUS_CHANGED = "focus" }

-- Blizzard's parts the new look replaces, by global name (older UIs) or by a key
-- path from the frame (".a.b", newer UIs). Whatever isn't there is skipped. Icons
-- (raid target, PvP, leader, rest, combat), auras, the cast bar and the target of
-- target stay.
local HIDE = {
    PlayerFrame = { "PlayerFrameTexture", "PlayerFrameBackground", "PlayerFrameVehicleTexture",
        "PlayerStatusTexture", "PlayerStatusGlow", "PlayerAttackBackground", "PlayerAttackGlow",
        "PlayerRestGlow", "PlayerFrameFlash", "PlayerHitIndicator", "PlayerLevelText", "PlayerPVPIcon",
        ".PlayerFrameContainer", ".PlayerFrameContent.PlayerFrameContentMain",
        ".PlayerFrameContent.PlayerFrameContentContextual.PVPIcon",
        ".PlayerFrameContent.PlayerFrameContentContextual.PrestigePortrait",
        ".PlayerFrameContent.PlayerFrameContentContextual.PrestigeBadge" },
    PetFrame = { "PetFrameTexture", "PetFrameFlash", "PetAttackModeTexture", "PetHitIndicator" },
    TargetFrame = { "TargetFrameBackground", "TargetFrameNameBackground", "TargetFrameFlash",
        "TargetFrameTextureFrameTexture", "TargetFrameTextureFrameHighLevelTexture",
        "TargetFrameTextureFrameDeadText", "TargetFrameTextureFrameUnconsciousText",
        "TargetFrameTextureFramePVPIcon",
        ".TargetFrameContainer", ".TargetFrameContent.TargetFrameContentMain" },
    -- named outright: not every client sets the usual keys on it
    TargetFrameToT = { "TargetFrameToTTextureFrameTexture", "TargetFrameToTBackground",
        "TargetFrameToTTextureFrameDeadText", "TargetFrameToTTextureFrameUnconsciousText",
        "TargetFrameToTPortrait", "TargetFrameToTHealthBar", "TargetFrameToTManaBar",
        "TargetFrameToTTextureFrameName",
        ".FrameTexture", ".Background", ".Portrait", ".HealthBar", ".ManaBar", ".Name" },
    -- the focus frame is built like the target frame
    FocusFrame = { "FocusFrameBackground", "FocusFrameNameBackground", "FocusFrameFlash",
        "FocusFrameTextureFrameTexture", "FocusFrameTextureFrameHighLevelTexture",
        "FocusFrameTextureFrameDeadText", "FocusFrameTextureFrameUnconsciousText",
        "FocusFrameTextureFramePVPIcon",
        ".TargetFrameContainer", ".TargetFrameContent.TargetFrameContentMain" },
}
-- the same parts by the keys every client's unit frame code sets
local HIDE_KEYS = { "healthbar", "manabar", "portrait", "name", "levelText", "borderTexture",
    "nameBackground", "threatIndicator", "deadText", "unconsciousText", "Background", "flash",
    "pvpIcon", "prestigePortrait", "prestigeBadge" }
-- the PvP badge we draw instead, on top: the picture's badge fills its top left part
local PVP_TEXTURE = "Interface\\TargetingFrame\\UI-PVP-"
local PVP_CROP = 0.65625
local BAR_TEXTS = { "TextString", "LeftText", "RightText" }

local function cfg()
    return ns.db.blizzard.unitFrames
end

local function tint(t, c, a)
    t:SetVertexColor(c[1], c[2], c[3], a or 1)
end

local function tintAll(list, c, a)
    for _, t in ipairs(list) do tint(t, c, a) end
end

local function lerp(a, b, t) return a + (b - a) * t end

-- The textures of a border made by makeBorder (strips and corner discs).
local function borderParts(e)
    local list = {}
    for _, t in ipairs(e.strips) do list[#list + 1] = t end
    for i = 4, 7 do list[#list + 1] = e.corners[i] end
    return list
end

-- A border of size px around frame with corner radius r: like the action bars'
-- panels, the corner discs sit under the background's own rounded corners.
local function layoutBorder(e, frame, size, r)
    local B = ns.BlizzardUI
    B.LayoutStrips(e.strips, frame, size, r)
    B.LayoutRoundRect(e.corners, frame, 0, r)
    for i = 1, 3 do e.corners[i]:Hide() end
    for _, t in ipairs(e.strips) do t:SetShown(size > 0) end
    for i = 4, 7 do e.corners[i]:SetShown(size > 0 and r > 0) end
end

---------------------------------------------------------------------------
-- Hiding Blizzard's parts
---------------------------------------------------------------------------

-- region -> how it was before WombatLog hid it: { alpha = } for frames, { parent = }
-- for textures and texts.
local hidden = {}

-- Textures and texts move onto this hidden frame: some clients set a picture's
-- alpha from inside the game (the live rendered portrait), past any hook.
local hider = CreateFrame("Frame")
hider:Hide()

local function isRegion(r)
    local t = r.GetObjectType and r:GetObjectType()
    return t == "Texture" or t == "FontString"
end

local function hide(r)
    if not r or not r.SetAlpha or hidden[r] then return end
    if isRegion(r) and r.SetParent then
        hidden[r] = { parent = r:GetParent() }
        r:SetParent(hider)
        return
    end
    -- frames go invisible; Blizzard sets the alpha of some itself (flashes, fades):
    -- they go back to 0 right after
    hidden[r] = { alpha = r:GetAlpha() }
    r:SetAlpha(0)
    if not r.wlUFHook then
        r.wlUFHook = true
        hooksecurefunc(r, "SetAlpha", function(self, a)
            if hidden[self] and hidden[self].alpha and a ~= 0 then self:SetAlpha(0) end
        end)
    end
end

local function unhide(r)
    local h = hidden[r]
    if h == nil then return end
    hidden[r] = nil
    if h.parent then r:SetParent(h.parent) else r:SetAlpha(h.alpha) end
end

-- Hides r for our frame w, which gives it back when it's turned off (parts found
-- by looking, not from the lists).
local function hideFor(w, r)
    hide(r)
    w.extra = w.extra or {}
    w.extra[r] = true
end

local function resolve(blizz, path)
    if path:sub(1, 1) ~= "." then return _G[path] end
    local o = blizz
    for k in path:gmatch("[^.]+") do
        o = type(o) == "table" and o[k] or nil
    end
    return o
end

-- Every part of blizz the new look replaces.
-- x's name or key, or nil when there is none or the client keeps it secret.
local function nameOf(x)
    for _, m in ipairs({ "GetName", "GetParentKey" }) do
        local ok, v = pcall(function() return x[m] and x[m](x) end)
        if ok and type(v) == "string" and not isSecret(v) then return v end
    end
end

-- A buff or debuff button (or a holder of them), by its name or key.
local function isAura(f)
    for _, get in ipairs({ "GetName", "GetParentKey" }) do
        local ok, v = pcall(function() return f[get] and f[get](f) end)
        if ok and type(v) == "string" and not isSecret(v) then
            v = v:lower()
            if v:find("buff", 1, true) or v:find("aura", 1, true) then return true end
        end
    end
    return false
end

local frames = {} -- key -> our frame

local function blizzardParts(u, blizz)
    local list = {}
    local function add(r)
        if type(r) == "table" and r.SetAlpha then list[#list + 1] = r end
    end
    for _, path in ipairs(HIDE[u.frame] or {}) do add(resolve(blizz, path)) end
    for _, k in ipairs(HIDE_KEYS) do add(blizz[k]) end
    for _, bar in ipairs({ blizz.healthbar, blizz.manabar }) do
        for _, k in ipairs(BAR_TEXTS) do add(bar and bar[k]) end
    end
    if u.hideAll then
        -- every texture and text on the frame, and every frame in it but ours and the auras
        for _, r in ipairs({ blizz:GetRegions() }) do add(r) end
        for _, c in ipairs({ blizz:GetChildren() }) do
            if c ~= frames[u.key] and not isAura(c) then add(c) end
        end
        -- parts named after the frame but kept by its parent (the target frame), e.g.
        -- a bar text some clients put there
        local prefix = nameOf(blizz)
        local parent = blizz:GetParent()
        if prefix and parent and parent ~= UIParent then
            local function named(r)
                local ok, n = pcall(r.GetName, r)
                return ok and type(n) == "string" and not isSecret(n) and n:sub(1, #prefix) == prefix
            end
            local function scan(f, depth)
                if depth > 4 then return end
                for _, r in ipairs({ f:GetRegions() }) do
                    if named(r) then add(r) end
                end
                for _, c in ipairs({ f:GetChildren() }) do
                    if c ~= blizz then
                        if named(c) and not isAura(c) then add(c) else scan(c, depth + 1) end
                    end
                end
            end
            scan(parent, 0)
        end
    end
    return list
end

-- For frames that hide everything: parts the client makes later (a text shown for
-- the first time) are caught on the next look.
-- Whether f is one of our frames.
local function isOurs(f)
    for _, w in pairs(frames) do
        if w == f then return true end
    end
    return false
end

-- r's box on screen, in UIParent's units.
local function screenRect(r, owner)
    local ok, l, b, width, height = pcall(r.GetRect, r)
    if not ok or not l or isSecret(l) then return nil end
    local s = (owner:GetEffectiveScale() or 1) / UIParent:GetEffectiveScale()
    return l * s, b * s, width * s, height * s
end

-- Texts of Blizzard's that show over our frame w, wherever the client keeps them:
-- in the frame, or in its parent (the target frame). Auras keep theirs.
local function hideTextsOver(w)
    local wl, wb, ww, wh = screenRect(w, w)
    if not wl then return end
    local function over(r, owner)
        local l, b, width, height = screenRect(r, owner)
        return l and l < wl + ww and wl < l + width and b < wb + wh and wb < b + height
    end
    local function scan(f, depth)
        if depth > 6 or isOurs(f) or isAura(f) then return end
        for _, r in ipairs({ f:GetRegions() }) do
            if r:GetObjectType() == "FontString" and not hidden[r] and r:IsVisible() and over(r, f) then
                hideFor(w, r)
            end
        end
        for _, c in ipairs({ f:GetChildren() }) do scan(c, depth + 1) end
    end
    scan(w.blizz, 0)
    local parent = w.blizz:GetParent()
    if parent and parent ~= UIParent then scan(parent, 0) end
end

local function rehide(w)
    if not w.u.hideAll then return end
    for _, r in ipairs(blizzardParts(w.u, w.blizz)) do hideFor(w, r) end
    hideTextsOver(w)
end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------

local function dead(unit)
    return Safe(UnitIsDeadOrGhost(unit)) or (UnitIsConnected and Safe(UnitIsConnected(unit)) == false)
end

local function healthColor(unit)
    local C = cfg()
    if dead(unit) then return GREY end
    if UnitIsTapDenied and Safe(UnitIsTapDenied(unit)) then return TAPPED end
    local mode = C.healthColor
    if mode == "custom" then return C.customColor end
    if mode == "green" then return GREEN end
    if mode == "class" and Safe(UnitIsPlayer(unit)) then
        local _, class = UnitClass(unit)
        class = Safe(class)
        local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then return { c.r, c.g, c.b } end
    end
    local reaction = Safe(UnitReaction(unit, "player"))
    local c = reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
    if c then return { c.r, c.g, c.b } end
    return GREEN
end

local function powerColor(unit)
    local pt, token = UnitPowerType(unit)
    pt, token = Safe(pt), Safe(token)
    local c = PowerBarColor and ((token and PowerBarColor[token]) or (pt and PowerBarColor[pt]))
    if c and c.r then return { c.r, c.g, c.b } end
    return { 0.00, 0.55, 1.00 }
end

local function levelColor(level)
    local get = GetCreatureDifficultyColor or GetQuestDifficultyColor
    local c = level and level > 0 and get and get(level)
    if c and c.r then return c.r, c.g, c.b end
    return 1, 0.82, 0
end

-- elite, rare, rareelite, boss or nil
local function classification(unit)
    if UnitIsBossMob and Safe(UnitIsBossMob(unit)) then return "boss" end
    local c = Safe(UnitClassification(unit))
    if c == "worldboss" then return "boss" end
    if c == "elite" or c == "rare" or c == "rareelite" then return c end
end

local function classColors(cls)
    local E = cfg().elite
    if cls == "boss" then return E.bossColor, E.bossColor end
    if cls == "rareelite" then return E.rareEliteColor, E.eliteColor end
    if cls == "rare" then return E.rareColor, E.rareColor end
    return E.eliteColor, E.eliteColor -- wings, portrait border
end

-- A color for low health worked out by the client, for secret health: the low
-- color at full alpha below the threshold, see-through above it.
local lowCurve, lowCurveAt
local function lowColorSecret(unit)
    if not (UnitHealthPercent and C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
    local at = cfg().anim.lowAt
    if not lowCurve or lowCurveAt ~= at then
        local ok, curve = pcall(C_CurveUtil.CreateColorCurve)
        if not ok or not curve then return nil end
        local on, off = CreateColor(LOW[1], LOW[2], LOW[3], 1), CreateColor(LOW[1], LOW[2], LOW[3], 0)
        if not pcall(function()
            curve:AddPoint(0, on)
            curve:AddPoint(math.max(0, at - 0.001), on)
            curve:AddPoint(at, off)
            curve:AddPoint(1, off)
        end) then return nil end
        lowCurve, lowCurveAt = curve, at
    end
    local ok, color = pcall(UnitHealthPercent, unit, false, lowCurve)
    return ok and type(color) == "table" and color.GetRGBA and color or nil
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------


local function glow(w, sub)
    local t = w:CreateTexture(nil, "BACKGROUND", nil, sub)
    t:SetTexture(GLOW)
    t:SetBlendMode("ADD")
    t:SetAlpha(0)
    return t
end

local function statusBar(parent, level)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetFrameLevel(level)
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    return b
end

local function text(parent, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    return fs
end

local function create(u, blizz)
    local w = CreateFrame("Frame", nil, blizz)
    w.u, w.blizz, w.side = u, blizz, u.side
    local base = blizz:GetFrameLevel() + 1
    w:SetFrameLevel(base)

    -- behind everything: the shadow, the glows and the elite ornament
    w.shadow = w:CreateTexture(nil, "BACKGROUND", nil, -8)
    w.shadow:SetTexture(GLOW)
    w.combat = glow(w, -8)
    w.wingGlow = glow(w, -8)
    -- low health lives on frames of its own: a texture's vertex alpha is its alpha, so
    -- the textures carry the color (from the client, for secret health, see-through
    -- above the threshold) and the frames' alpha does the pulse
    w.lowGlowF = CreateFrame("Frame", nil, w)
    w.lowGlowF:SetFrameLevel(base)
    w.lowGlowF:SetAllPoints()
    w.lowGlowF:SetAlpha(0)
    w.low = w.lowGlowF:CreateTexture(nil, "BACKGROUND")
    w.low:SetTexture(GLOW)
    w.low:SetBlendMode("ADD")
    w.wings = w:CreateTexture(nil, "BACKGROUND", nil, -7)
    w.wingMask = w:CreateMaskTexture()
    w.shine = w:CreateTexture(nil, "BACKGROUND", nil, -6)
    w.shine:SetTexture(SHINE, "REPEAT", "CLAMP")
    w.shine:SetBlendMode("ADD")
    w.shine:AddMaskTexture(w.wingMask)

    -- the panel behind the bars: border, a red border for low health, background
    local B = ns.BlizzardUI
    w.panel = CreateFrame("Frame", nil, w)
    w.panel:SetFrameLevel(base + 1)
    -- borders: strips along the sides and quarter discs in the corners
    w.edge = { strips = B.NewStrips(w.panel, "BACKGROUND", -6), corners = B.NewRoundRect(w.panel, "BACKGROUND", -6) }
    w.bg = B.NewRoundRect(w.panel, "BACKGROUND", -4)
    -- above the panel's own border (the bars stay clear of it)
    w.lowEdgeF = CreateFrame("Frame", nil, w)
    w.lowEdgeF:SetFrameLevel(base + 2)
    w.lowEdgeF:SetAllPoints(w.panel)
    w.lowEdgeF:SetAlpha(0)
    w.lowEdge = { strips = B.NewStrips(w.lowEdgeF, "ARTWORK", 0), corners = B.NewRoundRect(w.lowEdgeF, "ARTWORK", 0) }

    -- health over the damage trail (which carries the bar's background), power
    w.lag = statusBar(w, base + 2)
    w.lag:SetStatusBarTexture(WHITE)
    w.lagBg = w.lag:CreateTexture(nil, "BACKGROUND")
    w.lagBg:SetAllPoints()
    w.hp = statusBar(w, base + 3)
    w.heal = w.hp:CreateTexture(nil, "OVERLAY")
    w.heal:SetTexture(WHITE)
    w.heal:SetBlendMode("ADD")
    w.heal:SetAlpha(0)
    w.pp = statusBar(w, base + 2)
    w.ppBg = w.pp:CreateTexture(nil, "BACKGROUND")
    w.ppBg:SetAllPoints()

    -- the portrait: border, background, picture, the hit and the new-target flash
    w.pf = CreateFrame("Frame", nil, w)
    w.pf:SetFrameLevel(base + 4)
    w.pBorder = w.pf:CreateTexture(nil, "BACKGROUND")
    w.pBg = w.pf:CreateTexture(nil, "BORDER")
    w.portrait = w.pf:CreateTexture(nil, "ARTWORK")
    w.pMask = w.pf:CreateMaskTexture()
    w.portrait:AddMaskTexture(w.pMask)
    w.hit = w.pf:CreateTexture(nil, "OVERLAY")
    w.pFlash = w.pf:CreateTexture(nil, "OVERLAY", nil, 1)
    for _, t in ipairs({ w.hit, w.pFlash }) do
        t:SetBlendMode("ADD")
        t:AddMaskTexture(w.pMask)
        t:SetAlpha(0)
    end

    -- texts, and the level badge on the portrait
    w.top = CreateFrame("Frame", nil, w)
    w.top:SetFrameLevel(base + 6)
    w.top:SetAllPoints()
    w.name = text(w.top, "LEFT")
    w.hpText = text(w.top, "RIGHT")
    w.ppText = text(w.top, "CENTER")
    w.badge = CreateFrame("Frame", nil, w)
    w.badge:SetFrameLevel(base + 5)
    w.badgeRing = w.badge:CreateTexture(nil, "BACKGROUND")
    w.badgeRing:SetAllPoints()
    w.badgeBg = w.badge:CreateTexture(nil, "BORDER")
    w.level = text(w.badge, "CENTER")
    w.level:SetPoint("CENTER", w.badge, "CENTER", 0, 0)
    w.pvp = w.top:CreateTexture(nil, "OVERLAY")
    w.pvp:SetTexCoord(0, PVP_CROP, 0, PVP_CROP)
    w.pvp:Hide()

    w:SetScript("OnUpdate", UnitFrames.OnUpdate)
    w:Hide()
    return w
end

-- region at x, y (from the top left, mirrored for frames whose portrait is on the right)
local function put(w, region, x, y, width, height)
    region:ClearAllPoints()
    if w.side == "right" then x = w.T - x - width end
    region:SetPoint("TOPLEFT", w, "TOPLEFT", x, -y)
    region:SetSize(width, height)
end

local function setFonts(w)
    local C, A = cfg(), ns.db.appearance
    local size = w.u.key == "pet" and math.max(7, C.textSize - 2) or C.textSize
    ns.SetFont(w.name, A.nameFont, size, "OUTLINE")
    ns.SetFont(w.hpText, A.amountFont, size, "OUTLINE")
    ns.SetFont(w.ppText, A.amountFont, math.max(7, size - 2), "OUTLINE")
    ns.SetFont(w.level, A.amountFont, math.max(7, size - 1), "OUTLINE")
end

-- Sizes and places everything from the settings.
local function layout(w)
    local C, U = cfg(), cfg()[w.u.key]
    local style = C.portrait
    local b = C.border and C.borderSize or 0
    local h1, h2 = U.healthHeight, U.powerHeight
    local Hp = b * 2 + PAD * 2 + h1 + (h2 > 0 and (GAP + h2) or 0)
    local P = style ~= "none" and math.max(U.portraitSize, Hp) or 0
    local H = math.max(P, Hp)
    local px0 = P > 0 and math.floor(P / 2) or 0
    local bx0 = P > 0 and (P + 3) or (b + PAD)
    local bx1 = bx0 + U.width
    w.T = bx1 + PAD + b
    w.P, w.H, w.Hp = P, H, Hp
    w:SetSize(w.T, H)
    w.anchorX, w.anchorY = U.x, U.y
    w:ClearAllPoints()
    w:SetPoint("CENTER", w.blizz, "CENTER", U.x, U.y)

    local panelY = math.floor((H - Hp) / 2)
    put(w, w.panel, px0, panelY, w.T - px0, Hp)
    local r = C.radius > 0 and math.max(C.radius, b) or 0
    layoutBorder(w.edge, w.panel, b, r)
    -- the low health border is drawn even without a border of its own
    layoutBorder(w.lowEdge, w.lowEdgeF, math.max(1, b), r)
    ns.BlizzardUI.LayoutRoundRect(w.bg, w.panel, b, math.max(0, r - b))
    tintAll(borderParts(w.edge), C.borderColor, C.borderOpacity)
    tintAll(w.bg, C.bgColor, C.bgOpacity)
    w.lowParts = borderParts(w.lowEdge)
    tintAll(w.lowParts, LOW, 1)

    w.shadow:ClearAllPoints()
    w.shadow:SetPoint("TOPLEFT", w.panel, "TOPLEFT", -SHADOW, SHADOW)
    w.shadow:SetPoint("BOTTOMRIGHT", w.panel, "BOTTOMRIGHT", SHADOW, -SHADOW)
    w.shadow:SetShown(C.shadow)
    tint(w.shadow, { 0, 0, 0 }, C.shadowOpacity)
    for _, g in ipairs({ w.combat, w.low }) do
        g:ClearAllPoints()
        g:SetPoint("TOPLEFT", w, "TOPLEFT", -SHADOW, SHADOW)
        g:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", SHADOW, -SHADOW)
    end
    -- tinting sets a texture's alpha too: the glow starts out hidden again
    tint(w.combat, COMBAT, 1)
    w.combat:SetAlpha(0)
    tint(w.low, LOW, 1)

    -- bars
    local tex = ns.BarTexture(C.texture)
    local by = panelY + b + PAD
    put(w, w.hp, bx0, by, U.width, h1)
    put(w, w.lag, bx0, by, U.width, h1)
    w.hp:SetStatusBarTexture(tex)
    w.lag:SetStatusBarTexture(tex)
    w.lagBg:SetTexture(tex)
    w.lagBg:SetVertexColor(0, 0, 0, 0.5)
    w.pp:SetShown(h2 > 0)
    if h2 > 0 then
        put(w, w.pp, bx0, by + h1 + GAP, U.width, h2)
        w.pp:SetStatusBarTexture(tex)
        w.ppBg:SetTexture(tex)
        w.ppBg:SetVertexColor(0, 0, 0, 0.5)
    end
    -- the bars fill toward the portrait's far side either way
    w.hp:SetReverseFill(false)
    w.lag:SetReverseFill(false)

    -- texts in the health bar: name on the left, the number on the right
    setFonts(w)
    w.name:ClearAllPoints()
    w.name:SetPoint("LEFT", w.hp, "LEFT", 4, 0)
    w.hpText:ClearAllPoints()
    w.hpText:SetPoint("RIGHT", w.hp, "RIGHT", -4, 0)
    w.name:SetWidth(math.max(10, U.width * 0.62))
    w.ppText:ClearAllPoints()
    w.ppText:SetPoint("CENTER", w.pp, "CENTER", 0, 0)
    w.ppText:SetShown(h2 >= 7)

    -- portrait
    w.pf:SetShown(P > 0)
    if P > 0 then
        local shape = ns.BlizzardUI.RoundTexture(style == "round" and 50 or C.portraitRadius)
        put(w, w.pf, 0, math.floor((H - P) / 2), P, P)
        w.pBorder:SetTexture(shape)
        w.pBorder:SetAllPoints()
        w.pBg:SetTexture(shape)
        w.pMask:SetTexture(shape, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        local pb = math.max(1, b)
        for _, t in ipairs({ w.pBg, w.portrait, w.pMask, w.hit, w.pFlash }) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", w.pf, "TOPLEFT", pb, -pb)
            t:SetPoint("BOTTOMRIGHT", w.pf, "BOTTOMRIGHT", -pb, pb)
        end
        tint(w.pBg, { 0, 0, 0 }, 0.8)
        -- the hit and the flash are colored at full and shown through their alpha
        w.hit:SetTexture(WHITE)
        tint(w.hit, LOW, 1)
        w.hit:SetAlpha(0)
        w.pFlash:SetTexture(WHITE)
        w.pFlash:SetAlpha(0)
        -- older clients draw the portrait round already: square ones show its middle
        local z = style == "square" and 0.15 or 0.04
        w.portrait:SetTexCoord(z, 1 - z, z, 1 - z)
    end

    -- the level on a small round badge at the portrait's outer bottom corner, or
    -- in front of the name without a portrait
    w.badge:SetShown(P > 0)
    if P > 0 then
        local s = math.max(14, math.floor(P * 0.34))
        put(w, w.badge, -2, math.floor((H - P) / 2) + P - s + 2, s, s)
        local round = ns.BlizzardUI.RoundTexture(50)
        w.badgeRing:SetTexture(round)
        tint(w.badgeRing, C.borderColor, 1)
        w.badgeBg:SetTexture(round)
        w.badgeBg:ClearAllPoints()
        w.badgeBg:SetPoint("TOPLEFT", w.badge, "TOPLEFT", 1, -1)
        w.badgeBg:SetPoint("BOTTOMRIGHT", w.badge, "BOTTOMRIGHT", -1, 1)
        tint(w.badgeBg, { 0.06, 0.06, 0.06 }, 0.95)
        w.level:SetParent(w.badge)
        w.level:ClearAllPoints()
        w.level:SetPoint("CENTER", w.badge, "CENTER", 0, 0)
    else
        w.level:SetParent(w.top)
        w.level:ClearAllPoints()
        w.level:SetPoint("LEFT", w.hp, "LEFT", 4, 0)
    end

    -- PvP badge: at the portrait's top outer corner (the level sits at the bottom one),
    -- or at the panel's outer end without a portrait
    local ps = math.max(16, math.floor((P > 0 and P or Hp) * 0.42))
    if P > 0 then
        put(w, w.pvp, -math.floor(ps * 0.35), math.floor((H - P) / 2) - math.floor(ps * 0.2), ps, ps)
    else
        put(w, w.pvp, -math.floor(ps * 0.6), math.floor((H - ps) / 2), ps, ps)
    end

    -- the ornament: twice the portrait, around it; without one, at the frame's end
    local size = P > 0 and P * 2 or Hp * 2
    local cx = P > 0 and P / 2 or 0
    local cy = P > 0 and H / 2 or H / 2
    put(w, w.wings, cx - size / 2, cy - size / 2, size, size)
    w.wings:SetTexture(w.side == "right" and WINGS.right or WINGS.left)
    w.wingMask:SetTexture(w.side == "right" and WINGS.right or WINGS.left, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    w.wingMask:SetAllPoints(w.wings)
    w.shine:SetAllPoints(w.wings)
    local g = size * 1.15
    put(w, w.wingGlow, cx - g / 2, cy - g / 2, g, g)
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

local function unitOf(w)
    return w.blizz.unit or w.u.unit
end

local function plain(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v == nil or isSecret(v) then return false end
    end
    return true
end

-- Name and health number share the health bar: the number takes what it needs and
-- the name the rest; when that leaves the name less than NAME_SHARE of the bar
-- (small frames), the number makes way. Secret numbers can't be measured: they're
-- counted at a typical width.
local NAME_SHARE = 0.45

local function fitTexts(w)
    local bw = w.hp:GetWidth()
    if not bw or bw <= 0 then return end
    local room = bw - (w.nameX or 4) - 4
    local hasName = cfg().names
    local tw = w.hpText:GetStringWidth() or 0
    if isSecret(tw) then tw = bw * 0.4 end
    local fits = not hasName or tw <= 0 or (room - tw - 6) >= bw * NAME_SHARE
    w.hpText:SetShown(fits)
    w.name:SetWidth(math.max(10, (fits and tw > 0) and (room - tw - 6) or room))
end

function UnitFrames:UpdateHealth(w, animate)
    local unit, A, C = unitOf(w), cfg().anim, cfg()
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    w.hp:SetMinMaxValues(0, max or 1)
    w.hp:SetValue(cur or 0)
    w.lag:SetMinMaxValues(0, max or 1)
    local isPlain = plain(cur, max)
    if isPlain and animate and A.damage and w.lagValue and cur < w.lagValue then
        -- the lost part stays a moment, then runs after the bar
        if not w.lagHold then w.lagHold = LAG_HOLD end
    else
        w.lagValue, w.lagHold = isPlain and cur or nil, nil
        w.lag:SetValue(cur or 0)
    end
    if isPlain and animate and A.heal and w.lastHP and cur > w.lastHP and max > 0 then
        w.healFrom, w.healTo, w.healMax, w.healT = w.lastHP, cur, max, 0
    end
    w.lastHP = isPlain and cur or nil

    local c = healthColor(unit)
    w.hp:SetStatusBarColor(c[1], c[2], c[3], 1)
    w.lag:SetStatusBarColor(lerp(c[1], 1, 0.75), lerp(c[2], 0.9, 0.6), lerp(c[3], 0.8, 0.6), 0.9)
    w.portrait:SetDesaturated(dead(unit) and true or false)

    if dead(unit) then
        local s = UnitIsConnected and Safe(UnitIsConnected(unit)) == false and L["Offline"]
            or Safe(UnitIsGhost(unit)) and L["Ghost"] or L["Dead"]
        w.hpText:SetText(s)
    else
        ns.Resources.SetText(w.hpText, C.healthText, cur, max, true, unit)
    end
    fitTexts(w)

    -- low health: worked out here when readable, by the client when not
    w.lowColor = nil
    if not A.lowHealth or dead(unit) then
        w.lowOn = false
    elseif isPlain then
        w.lowOn = max > 0 and cur > 0 and cur / max <= A.lowAt
    else
        w.lowColor = lowColorSecret(unit)
        w.lowOn = w.lowColor ~= nil
    end
    local apply = w.lowColor and function(t)
        pcall(t.SetVertexColor, t, w.lowColor:GetRGBA())
    end or function(t) tint(t, LOW, 1) end
    apply(w.low)
    for _, t in ipairs(w.lowParts) do apply(t) end
end

function UnitFrames:UpdatePower(w)
    local unit, C = unitOf(w), cfg()
    if not w.pp:IsShown() then return end
    local pt = UnitPowerType(unit)
    local cur, max = UnitPower(unit, pt), UnitPowerMax(unit, pt)
    w.pp:SetMinMaxValues(0, max or 1)
    w.pp:SetValue(cur or 0)
    local c = powerColor(unit)
    w.pp:SetStatusBarColor(c[1], c[2], c[3], 1)
    if w.ppText:IsShown() then ns.Resources.SetText(w.ppText, C.powerText, cur, max, false, unit) end
end

function UnitFrames:UpdateName(w)
    local unit = unitOf(w)
    if cfg().names then
        if not pcall(w.name.SetText, w.name, UnitName(unit)) then w.name:SetText("") end
    else
        w.name:SetText("")
    end
    local level = Safe(UnitLevel(unit))
    if level and level < 0 then
        w.level:SetText("??")
        w.level:SetTextColor(1, 0.2, 0.1)
    elseif level and level > 0 then -- 0: not known yet
        w.level:SetText(level)
        if w.u.key == "player" then
            w.level:SetTextColor(1, 0.82, 0)
        else
            w.level:SetTextColor(levelColor(level))
        end
    else
        w.level:SetText("")
    end
    -- without a portrait the level sits in front of the name
    w.nameX = 4
    if not w.pf:IsShown() then
        local lw = w.level:GetText() ~= "" and math.ceil(w.level:GetStringWidth()) + 4 or 0
        w.nameX = 4 + lw
        w.name:ClearAllPoints()
        w.name:SetPoint("LEFT", w.hp, "LEFT", w.nameX, 0)
    end
    fitTexts(w)
end

function UnitFrames:UpdatePortrait(w)
    if not w.pf:IsShown() then return end
    local unit = unitOf(w)
    -- the third argument (no masking) is ignored where the client doesn't know it
    SetPortraitTexture(w.portrait, unit, true)
end

function UnitFrames:UpdateClass(w)
    local C = cfg()
    local E = C.elite
    -- your own frame can wear an ornament of your choice
    local cls
    if w.u.key == "player" and E.self ~= "none" then
        cls = E.self
    elseif E.enabled then
        cls = classification(unitOf(w))
    end
    w.cls = cls
    local show = cls ~= nil
    w.wings:SetShown(show)
    w.shine:SetShown(show and C.elite.shine)
    w.wingGlow:SetShown(show and C.elite.glow and (cls == "rare" or cls == "rareelite" or cls == "boss"))
    if show then
        local wing, border = classColors(cls)
        tint(w.wings, wing, 1)
        tint(w.shine, { lerp(wing[1], 1, 0.6), lerp(wing[2], 1, 0.6), lerp(wing[3], 1, 0.6) }, 1)
        tint(w.wingGlow, wing, 1)
        tint(w.pBorder, border, 1)
        tint(w.badgeRing, border, 1)
    else
        tint(w.pBorder, C.borderColor, C.border and C.borderOpacity or 0)
        tint(w.badgeRing, C.borderColor, 1)
    end
end

-- Whether r is (part of) Blizzard's PvP badge: by its name or key, its atlas, or
-- its picture. The names differ between clients, the picture doesn't.
local function looksPvP(r)
    local function has(get, ...)
        local ok, v = pcall(get, r)
        if not ok or type(v) ~= "string" or isSecret(v) then return false end
        v = v:lower()
        for i = 1, select("#", ...) do
            if v:find(select(i, ...), 1, true) then return true end
        end
        return false
    end
    return (r.GetName and has(r.GetName, "pvp", "prestige"))
        or (r.GetParentKey and has(r.GetParentKey, "pvp", "prestige"))
        or (r.GetAtlas and has(r.GetAtlas, "pvp", "honorsystem"))
        or (r.GetTextureFilePath and has(r.GetTextureFilePath, "ui-pvp"))
        or false
end

-- Hides every PvP badge in Blizzard's frame (not in ours), however the client names it.
local function hideBlizzardPvP(w)
    -- none of our frames: the target frame holds the target of target's, with our
    -- own PvP badge in it
    local function scan(f, depth)
        if isOurs(f) or depth > 6 then return end
        for _, r in ipairs({ f:GetRegions() }) do
            if r:GetObjectType() == "Texture" and looksPvP(r) then hideFor(w, r) end
        end
        for _, c in ipairs({ f:GetChildren() }) do
            if not isOurs(c) then
                if looksPvP(c) then hideFor(w, c) else scan(c, depth + 1) end
            end
        end
    end
    scan(w.blizz, 0)
end

function UnitFrames:UpdatePvP(w)
    hideBlizzardPvP(w) -- Blizzard sets its picture only once the unit is flagged
    local unit = unitOf(w)
    local kind
    -- only for players and what they control: some clients report every mob as
    -- flagged, with a faction
    local playerSide = Safe(UnitIsPlayer(unit)) or (UnitPlayerControlled and Safe(UnitPlayerControlled(unit)))
    if not playerSide then
        kind = nil
    elseif UnitIsPVPFreeForAll and Safe(UnitIsPVPFreeForAll(unit)) then
        kind = "FFA"
    elseif Safe(UnitIsPVP(unit)) then
        local faction = Safe((UnitFactionGroup(unit)))
        if faction == "Alliance" or faction == "Horde" then kind = faction end
    end
    w.pvp:SetShown(kind ~= nil)
    if kind then w.pvp:SetTexture(PVP_TEXTURE .. kind) end
end

function UnitFrames:UpdateCombat(w)
    w.inCombat = cfg().anim.combat and Safe(UnitAffectingCombat(unitOf(w))) and true or false
end

-- Runs fn(w), so a part failing doesn't take the rest of the update with it; the
-- first error of each part is told once in chat and kept for /wl debug.
local reported = {}
local function try(label, fn, w, ...)
    local ok, err = pcall(fn, ...)
    if ok then return end
    w.errors = w.errors or {}
    w.errors[label] = tostring(err)
    if not reported[label] then
        reported[label] = true
        ns.Print("unit frames: " .. label .. " failed (" .. w.u.key .. "): " .. tostring(err))
    end
end

function UnitFrames:Update(w, animate)
    if not w:IsShown() then return end
    try("name", self.UpdateName, w, self, w)
    try("portrait", self.UpdatePortrait, w, self, w)
    try("ornament", self.UpdateClass, w, self, w)
    try("health", self.UpdateHealth, w, self, w, animate)
    try("power", self.UpdatePower, w, self, w)
    try("combat", self.UpdateCombat, w, self, w)
    try("pvp", self.UpdatePvP, w, self, w)
    try("hiding", rehide, w, w)
end

---------------------------------------------------------------------------
-- Animations
---------------------------------------------------------------------------

function UnitFrames.OnUpdate(w, dt)
    local now = GetTime()
    if w.u.hideAll then
        w.rehideT = (w.rehideT or 0) + dt
        if w.rehideT >= 1 then
            w.rehideT = 0
            try("hiding", rehide, w, w)
        end
    end
    if w.u.poll then
        w.pollT = (w.pollT or 0) + dt
        if w.pollT >= POLL then
            w.pollT = 0
            UnitFrames:Poll(w)
        end
    end

    -- damage trail
    if w.lagHold then
        w.lagHold = w.lagHold - dt
        if w.lagHold <= 0 and w.lagValue and w.lastHP then
            w.lagValue = w.lagValue + (w.lastHP - w.lagValue) * math.min(1, dt * LAG_SPEED * 2)
            if w.lagValue - w.lastHP < 0.5 then
                w.lagValue, w.lagHold = w.lastHP, nil
            end
        end
        if w.lagValue then w.lag:SetValue(w.lagValue) end
    end

    -- heal: the part gained flashes
    if w.healT then
        w.healT = w.healT + dt
        local p = w.healT / HEAL_FLASH
        if p >= 1 or not w.healMax or w.healMax <= 0 then
            w.healT = nil
            w.heal:SetAlpha(0)
        else
            local width = w.hp:GetWidth()
            local x0 = width * math.min(1, w.healFrom / w.healMax)
            local x1 = width * math.min(1, w.healTo / w.healMax)
            w.heal:ClearAllPoints()
            w.heal:SetPoint("TOPLEFT", w.hp, "TOPLEFT", x0, 0)
            w.heal:SetSize(math.max(1, x1 - x0), w.hp:GetHeight())
            w.heal:SetVertexColor(0.5, 1, 0.5, 1)
            w.heal:SetAlpha(0.8 * (1 - p) * (1 - p))
        end
    end

    -- in combat: a soft glow that breathes
    local target = w.inCombat and (0.35 + 0.15 * math.sin(now * 2.5)) or 0
    local cur = w.combat:GetAlpha()
    w.combat:SetAlpha(cur + (target - cur) * math.min(1, dt * 6))

    -- low health: the border and a glow pulse red
    -- (the frames pulse; whether red shows at all is the textures' color)
    local pulse = w.lowOn and (0.55 + 0.45 * math.abs(math.sin(now * 3))) or 0
    w.lowGlowF:SetAlpha(pulse)
    w.lowEdgeF:SetAlpha(pulse)

    -- the ornament: a glint running over it, a glow breathing behind it
    if w.cls then
        local cycle = w.cls == "boss" and 1.4 or (w.cls == "elite" and 2.6 or 2)
        local off = (now / cycle) % 1
        w.shine:SetTexCoord(off, off + 0.4, 0, 1)
        if w.wingGlow:IsShown() then
            local strength = w.cls == "boss" and 0.55 or 0.35
            w.wingGlow:SetAlpha(strength * (0.6 + 0.4 * math.sin(now * (w.cls == "boss" and 4 or 2.2))))
        end
    end

    -- hit: the portrait shakes and flashes red
    local dx = 0
    if w.hitT then
        w.hitT = w.hitT + dt
        local p = w.hitT / HIT_TIME
        if p >= 1 then
            w.hitT = nil
            w.hit:SetAlpha(0)
        else
            dx = 3 * math.sin(w.hitT * 70) * (1 - p)
            w.hit:SetAlpha(0.6 * (1 - p))
        end
    end
    if dx ~= 0 or w.shaken then
        w.shaken = dx ~= 0 or nil
        local y = math.floor((w.H - w.P) / 2)
        put(w, w.pf, dx * (w.side == "right" and -1 or 1), y, w.P, w.P)
    end

    -- new target: slides and fades in, the portrait flashes
    if w.enterT then
        w.enterT = w.enterT + dt
        local p = math.min(1, w.enterT / ENTER_TIME)
        local e = 1 - (1 - p) ^ 3
        local slide = (1 - e) * ENTER_SLIDE * (w.side == "right" and 1 or -1)
        w:SetPoint("CENTER", w.blizz, "CENTER", w.anchorX + slide, w.anchorY)
        w:SetAlpha(p)
        if p >= 1 then w.enterT = nil end
    end
    if w.flashT then
        w.flashT = w.flashT + dt
        local p = w.flashT / PORTRAIT_FLASH
        if p >= 1 then
            w.flashT = nil
            w.pFlash:SetAlpha(0)
        else
            w.pFlash:SetAlpha(0.7 * (1 - p))
        end
    end
end

-- A frame without events: a new unit gets a full update, the same one its values,
-- and twice a second the rest too: right after a switch the client may not know
-- the name, level or portrait yet, and no event says when it does.
local FULL_EVERY = 0.5

function UnitFrames:Poll(w)
    local unit = unitOf(w)
    local guid = UnitExists(unit) and Safe(UnitGUID(unit)) or nil
    local now = GetTime()
    if guid == nil or guid ~= w.guid or now - (w.fullAt or 0) >= FULL_EVERY then
        if guid ~= w.guid then w.lagValue, w.lastHP, w.lagHold, w.healT = nil, nil, nil, nil end
        w.guid, w.fullAt = guid, now
        self:Update(w, true)
    else
        self:UpdateHealth(w, true)
        self:UpdatePower(w)
        self:UpdateCombat(w)
    end
end

function UnitFrames:Hit(w)
    if not cfg().anim.hit or not w.pf:IsShown() then return end
    w.hitT = 0
end

function UnitFrames:Enter(w)
    if not cfg().anim.targetChange then return end
    w.enterT, w.flashT = 0, 0
    w:SetAlpha(0)
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

local function wanted(u)
    local C = cfg()
    return C.enabled and C[u.key].enabled
end

function UnitFrames:Apply()
    if not self.ready then return end
    for _, u in ipairs(UNITS) do
        local blizz = _G[u.frame]
        if blizz then
            local w = frames[u.key]
            if wanted(u) then
                w = w or create(u, blizz)
                frames[u.key] = w
                for _, r in ipairs(blizzardParts(u, blizz)) do hideFor(w, r) end
                layout(w)
                w:Show()
                w:SetAlpha(1)
                self:Update(w, false)
            elseif w then
                w:Hide()
                for _, r in ipairs(blizzardParts(u, blizz)) do unhide(r) end
                for r in pairs(w.extra or {}) do unhide(r) end
                w.extra = nil
            end
        end
    end
end

-- frames showing unit right now
local function each(unit, fn)
    for _, w in pairs(frames) do
        if w:IsShown() and unitOf(w) == unit then fn(w) end
    end
end

local function all(fn)
    for _, w in pairs(frames) do
        if w:IsShown() then fn(w) end
    end
end

local UNIT_EVENTS = {
    UNIT_HEALTH = function(w) UnitFrames:UpdateHealth(w, true) end,
    UNIT_HEALTH_FREQUENT = function(w) UnitFrames:UpdateHealth(w, true) end,
    UNIT_MAXHEALTH = function(w) UnitFrames:UpdateHealth(w, true) end,
    UNIT_POWER_UPDATE = function(w) UnitFrames:UpdatePower(w) end,
    UNIT_POWER_FREQUENT = function(w) UnitFrames:UpdatePower(w) end,
    UNIT_MAXPOWER = function(w) UnitFrames:UpdatePower(w) end,
    UNIT_DISPLAYPOWER = function(w) UnitFrames:UpdatePower(w) end,
    UNIT_NAME_UPDATE = function(w) UnitFrames:UpdateName(w) end,
    UNIT_LEVEL = function(w) UnitFrames:UpdateName(w) end,
    UNIT_PORTRAIT_UPDATE = function(w) UnitFrames:UpdatePortrait(w) end,
    UNIT_MODEL_CHANGED = function(w) UnitFrames:UpdatePortrait(w) end,
    UNIT_CLASSIFICATION_CHANGED = function(w) UnitFrames:UpdateClass(w) end,
    UNIT_FACTION = function(w) UnitFrames:UpdateHealth(w, false); UnitFrames:UpdatePvP(w) end,
    UNIT_FLAGS = function(w)
        UnitFrames:UpdateCombat(w)
        UnitFrames:UpdateHealth(w, false)
        UnitFrames:UpdatePvP(w) -- flagging for PvP comes as a flag change
    end,
    UNIT_CONNECTION = function(w) UnitFrames:Update(w, false) end,
}

---------------------------------------------------------------------------
-- Debug (/wl debug): the target of target's unit, and everything that shows over
-- its frame, ours or not, so parts a client names differently can be found
---------------------------------------------------------------------------

local function describe(r)
    local function get(m)
        local ok, v = pcall(function() return r[m] and r[m](r) end)
        return ok and type(v) == "string" and not isSecret(v) and v or nil
    end
    local p = r:GetParent()
    local s = r:GetObjectType() .. " " .. (nameOf(r) or "?") .. " (in " .. (p and nameOf(p) or "?") .. ")"
    if r:GetObjectType() == "FontString" then
        local ok, t = pcall(r.GetText, r)
        s = s .. ' "' .. (ok and t and not isSecret(t) and t or "?") .. '"'
    elseif r:GetObjectType() == "Texture" then
        local path = get("GetTextureFilePath") or get("GetAtlas")
        if path then s = s .. " " .. path end
    end
    return s
end

function UnitFrames:Debug()
    if not cfg().enabled then
        ns.Print("unit frames: off")
        return
    end
    local w = frames.targettarget
    if not (w and w:IsVisible()) then
        ns.Print("unit frames: target of target not shown (target something that has a target)")
        return
    end
    local unit = unitOf(w)
    ns.Print(("target of target: unit %s, exists %s, name %s, level %s"):format(tostring(unit),
        tostring(Safe(UnitExists(unit))), tostring(Safe(UnitName(unit)) or "secret/none"),
        tostring(Safe(UnitLevel(unit)) or "secret/none")))
    -- our own parts: shown, alpha, hidden by us, text
    local function state(label, r)
        local ok, t = pcall(r.GetText or function() return nil end, r)
        ns.Print(("  ours %s: shown %s, visible %s, alpha %.2f, hidden by us %s%s"):format(label,
            tostring(r:IsShown()), tostring(r:IsVisible()), r:GetAlpha(), tostring(hidden[r] ~= nil),
            (ok and type(t) == "string" and not isSecret(t)) and (' "' .. t .. '"') or ""))
    end
    state("portrait", w.portrait)
    state("name", w.name)
    state("level", w.level)
    state("health text", w.hpText)
    ns.Print(("  levels: Blizzard's frame %d, ours %d (portrait %d, texts %d); position %s"):format(
        w.blizz:GetFrameLevel(), w:GetFrameLevel(), w.pf:GetFrameLevel(), w.top:GetFrameLevel(),
        screenRect(w, w) and "readable" or "not readable"))
    local any = false
    for label, err in pairs(w.errors or {}) do
        any = true
        ns.Print("  error in " .. label .. ": " .. err)
    end
    if not any then ns.Print("  no errors") end

    -- everything of Blizzard's still showing in its frame
    local n = 0
    local function scan(f, depth, path)
        if depth > 8 or n >= 40 or isOurs(f) then return end
        for _, r in ipairs({ f:GetRegions() }) do
            local t = r:GetObjectType()
            if (t == "FontString" or t == "Texture") and r:IsVisible() and r:GetAlpha() > 0 then
                n = n + 1
                local ok, layer, sub = pcall(r.GetDrawLayer, r)
                ns.Print(("  BLIZZARD %s [%s %s, frame level %d] in %s"):format(describe(r),
                    ok and tostring(layer) or "?", ok and tostring(sub) or "", f:GetFrameLevel(), path))
            end
        end
        for _, c in ipairs({ f:GetChildren() }) do
            if c:IsVisible() then
                -- (names may be secret: only readable ones go into the path)
                scan(c, depth + 1, path .. "/" .. (nameOf(c) or "?"))
            end
        end
    end
    ns.Print("Blizzard's parts still showing in " .. tostring(w.blizz:GetName()) .. ":")
    scan(w.blizz, 0, tostring(w.blizz:GetName()))
    if n == 0 then ns.Print("  none") end
end

function UnitFrames:Init()
    local ev = CreateFrame("Frame")
    for name in pairs(UNIT_EVENTS) do pcall(ev.RegisterEvent, ev, name) end
    for _, name in ipairs({ "UNIT_COMBAT", "UNIT_PET", "UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE",
                            "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UNIT_TARGET",
                            "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }) do
        pcall(ev.RegisterEvent, ev, name)
    end
    ev:SetScript("OnEvent", function(_, event, unit, action)
        if not cfg().enabled then return end
        unit = Safe(unit)
        local fn = UNIT_EVENTS[event]
        if fn then
            if unit then each(unit, fn) end
        elseif event == "UNIT_COMBAT" then
            if unit and Safe(action) == "WOUND" then each(unit, function(w) UnitFrames:Hit(w) end) end
        elseif NEW_UNIT[event] then
            local key = NEW_UNIT[event]
            local w = frames[key]
            if w and w:IsShown() then
                w.lagValue, w.lastHP, w.lagHold, w.healT = nil, nil, nil, nil
                self:Update(w, false)
                if UnitExists(key) then self:Enter(w) end
            end
            -- the target's target changes along with it
            local tot = frames.targettarget
            if event == "PLAYER_TARGET_CHANGED" and tot and tot:IsShown() then self:Poll(tot) end
        elseif event == "UNIT_TARGET" then
            local tot = frames.targettarget
            if unit == "target" and tot and tot:IsShown() then self:Poll(tot) end
        elseif event == "UNIT_PET" or event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
            -- Blizzard swaps the frames' units first
            C_Timer.After(0, function() all(function(w) self:Update(w, false) end) end)
        else
            all(function(w) self:Update(w, false) end)
        end
    end)
    -- the pet frame's unit and visibility change without an event of its own
    if PetFrame then PetFrame:HookScript("OnShow", function() all(function(w) self:Update(w, false) end) end) end
    self.ready = true
    self:Apply()
end
