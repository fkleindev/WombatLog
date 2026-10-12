local ADDON, ns = ...
local BlizzardUI = {}
ns.BlizzardUI = BlizzardUI
local XPBar = ns.XPBar

-- Changes to Blizzard's own UI: hiding its XP bar, and a modern look for its action
-- buttons and bars. Every client names these frames a little differently, so whatever
-- isn't there is skipped. Nothing is touched until a setting asks for it.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local CORNER = MEDIA .. "Corner"
local GLOW = MEDIA .. "Glow"
local SHADOW = 10        -- px the shadow reaches past a button or bar
local GCD = 2            -- cooldowns up to this long get no "ready" flash

---------------------------------------------------------------------------
-- XP bar
---------------------------------------------------------------------------

-- The bar, and whether it is shared: on the newer UIs the same spot shows your
-- reputation at max level, so it is only hidden while you level.
local xpBar, xpShared
local xpHidden = false

local function findXPBar()
    if MainStatusTrackingBarContainer then return MainStatusTrackingBarContainer, true end
    if StatusTrackingBarManager then return StatusTrackingBarManager, true end
    if MainMenuExpBar then return MainMenuExpBar, false end
end

local function wantXPHidden()
    return ns.db.blizzard.hideXPBar and (not xpShared or not XPBar.AtMaxLevel())
end

function BlizzardUI:UpdateXPBar()
    if not xpBar then return end
    if wantXPHidden() then
        xpHidden = true
        xpBar:Hide()
    elseif xpHidden then
        xpHidden = false
        -- the old bar is gone at max level by itself; elsewhere Blizzard decides again
        if xpShared or not XPBar.AtMaxLevel() then xpBar:Show() end
        if StatusTrackingBarManager and StatusTrackingBarManager.UpdateBarsShown then
            pcall(StatusTrackingBarManager.UpdateBarsShown, StatusTrackingBarManager)
        end
        if MainMenuBar_UpdateExperienceBars then pcall(MainMenuBar_UpdateExperienceBars) end
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- The rounded square for a corner radius in percent of the side (Media/Round00-50).
local function roundTexture(pct)
    local step = math.max(0, math.min(50, math.floor((pct or 0) / 5 + 0.5) * 5))
    return MEDIA .. ("Round%02d"):format(step)
end

local function setScaleAnim(a, from, to)
    if a.SetScaleFrom then
        a:SetScaleFrom(from, from); a:SetScaleTo(to, to)
    else
        a:SetFromScale(from, from); a:SetToScale(to, to)
    end
end

local function anim(group, kind, duration, order, smoothing)
    local a = group:CreateAnimation(kind)
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

local function tint(tex, c, a)
    tex:SetVertexColor(c[1], c[2], c[3], a)
end

-- Four strips around frame, inset from its edges, leaving out r px at each corner.
local function newStrips(frame, layer, sub)
    local s = {}
    for i = 1, 4 do
        s[i] = frame:CreateTexture(nil, layer, nil, sub)
        s[i]:SetTexture(WHITE)
    end
    return s
end

local function layoutStrips(s, frame, size, r)
    local top, bottom, left, right = s[1], s[2], s[3], s[4]
    for _, t in ipairs(s) do t:ClearAllPoints() end
    -- the side strips stop short of the top and bottom ones, so no pixel is drawn twice
    local side = math.max(r, size)
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", r, 0)
    top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -r, -size)
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", r, 0)
    bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -r, size)
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -side)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", size, side)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -side)
    right:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", -size, side)
end

-- A filled rectangle with rounded corners in any size: a middle band, two side bands
-- and four quarter discs.
local function newRoundRect(frame, layer, sub)
    local p = {}
    for i = 1, 7 do p[i] = frame:CreateTexture(nil, layer, nil, sub) end
    for i = 1, 3 do p[i]:SetTexture(WHITE) end
    for i = 4, 7 do p[i]:SetTexture(CORNER) end
    p[4]:SetTexCoord(0, 1, 1, 0) -- top left
    p[5]:SetTexCoord(1, 0, 1, 0) -- top right
    p[6]:SetTexCoord(0, 1, 0, 1) -- bottom left (the texture as drawn)
    p[7]:SetTexCoord(1, 0, 0, 1) -- bottom right
    return p
end

local function layoutRoundRect(p, frame, inset, r)
    local mid, left, right, tl, tr, bl, br = unpack(p)
    for _, t in ipairs(p) do t:ClearAllPoints() end
    mid:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + r, -inset)
    mid:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset - r, inset)
    local rounded = r > 0
    for i = 2, 7 do p[i]:SetShown(rounded) end
    if not rounded then return end
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset - r)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", inset + r, inset + r)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset - r)
    right:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", -inset - r, inset + r)
    for _, c in ipairs({ tl, tr, bl, br }) do c:SetSize(r, r) end
    tl:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    tr:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
    bl:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
    br:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
end

local function tintAll(list, c, a)
    for _, t in ipairs(list) do tint(t, c, a) end
end

---------------------------------------------------------------------------
-- Action buttons
---------------------------------------------------------------------------

local function settings()
    return ns.db.blizzard.actionBars
end

-- The micro menu's buttons are whole pictures with a stone frame: only this part of
-- each (left, right, top, bottom, as a share of the picture) is kept. Classic UIs draw
-- the button in the lower part of a tall picture; newer ones fill it.
local MICRO_CROP = {
    classic = { 0.18, 0.82, 0.52, 0.90 },
    modern = { 0, 1, 0, 1 }, -- free-standing icons already, nothing to cut
}

local BAG_NAMES = {
    "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot",
    "CharacterBag2Slot", "CharacterBag3Slot", "CharacterReagentBag0Slot",
}
local MICRO_NAMES = {
    "CharacterMicroButton", "SpellbookMicroButton", "PlayerSpellsMicroButton", "TalentMicroButton",
    "ProfessionMicroButton", "AchievementMicroButton", "QuestLogMicroButton",
    "SocialsMicroButton", "GuildMicroButton", "LFGMicroButton", "LFDMicroButton", "PVPMicroButton",
    "CollectionsMicroButton", "EJMicroButton", "WorldMapMicroButton",
    "HousingMicroButton", "StoreMicroButton", "MainMenuMicroButton", "HelpMicroButton",
}

-- prefix and count (or a list of names), the bar it belongs to, the kind of button,
-- and the setting that turns it on besides the modern buttons themselves
local BUTTONS = {
    { "ActionButton", 12, "main" }, { "BonusActionButton", 12, "main" },
    { "MultiBarBottomLeftButton", 12, "bottomLeft" }, { "MultiBarBottomRightButton", 12, "bottomRight" },
    { "MultiBarRightButton", 12, "right" }, { "MultiBarLeftButton", 12, "left" },
    { "MultiBar5Button", 12, "bar5" }, { "MultiBar6Button", 12, "bar6" }, { "MultiBar7Button", 12, "bar7" },
    { "PetActionButton", 10, "pet" },
    { "StanceButton", 10, "stance" }, { "ShapeshiftButton", 10, "stance" },
    { BAG_NAMES, nil, "bags", "bag", "bags" },
    { MICRO_NAMES, nil, "micro", "micro", "micro" },
}

-- fn(btn, name, group, kind) for every button there is; onlyOn: just the ones whose
-- bar is switched on.
local function eachButton(fn, onlyOn)
    local A = settings()
    for _, set in ipairs(BUTTONS) do
        local kind, switch = set[4] or "action", set[5]
        if not onlyOn or not switch or A[switch] then
            if type(set[1]) == "table" then
                for _, name in ipairs(set[1]) do
                    local btn = _G[name]
                    if btn then fn(btn, name, set[3], kind) end
                end
            else
                for i = 1, set[2] do
                    local name = set[1] .. i
                    local btn = _G[name]
                    if btn then fn(btn, name, set[3], kind) end
                end
            end
        end
    end
end

-- A button's part by its key (newer UIs) or its global name (older ones).
local function part(btn, name, key, suffix)
    return btn[key] or _G[name .. (suffix or key)]
end

-- The frames holding each kind of bar. Newer UIs draw a bar's frame, background and
-- dividers as the bar frame's own textures, plus keyed art like BorderArt.
local BAR_FRAMES = {
    action = { "MainActionBar", "MainMenuBar", "MultiBarBottomLeft", "MultiBarBottomRight",
               "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7",
               "StanceBar", "PetActionBar" },
    bags = { "BagsBar" },
    micro = { "MicroMenu", "MicroMenuContainer" },
}
local ART_KEYS = { "EndCaps", "BorderArt", "BackgroundArt" }

-- The art of one kind of bar: the gryphons, backgrounds, frames and dividers.
local function artRegions(kind)
    local list = {}
    local function add(r)
        if r then list[#list + 1] = r end
    end
    if kind == "action" then
        -- the classic UI's main bar art
        add(MainMenuBarLeftEndCap); add(MainMenuBarRightEndCap)
        for i = 0, 3 do
            add(_G["MainMenuBarTexture" .. i]); add(_G["MainMenuMaxLevelBar" .. i])
        end
    end
    for _, n in ipairs(BAR_FRAMES[kind]) do
        local bar = _G[n]
        if bar then
            for _, k in ipairs(ART_KEYS) do add(bar[k]) end
            for _, r in ipairs({ bar:GetRegions() }) do
                if r:GetObjectType() == "Texture" then add(r) end
            end
            -- frames drawn as nine-slices (edges with dividers between the buttons)
            for _, child in ipairs({ bar:GetChildren() }) do
                if child.TopEdge or child.BottomEdge or child.LeftEdge then add(child) end
            end
        end
    end
    return list
end

-- A texture's vertex alpha is its alpha, so a new vertex color from Blizzard (empty
-- slots' grid) would show it again: hidden once more right after.
local function keepHidden(t)
    t:SetAlpha(0)
    if not t.wlHidden then
        t.wlHidden = true
        hooksecurefunc(t, "SetVertexColor", function(self) self:SetAlpha(0) end)
    end
end

-- Blizzard's thick border, kept hidden whenever Blizzard puts it back.
local function hideBorder(btn)
    local t = btn:GetNormalTexture()
    if t then keepHidden(t) end
    local name = btn:GetName()
    for _, k in ipairs({ "NormalTexture", "NormalTexture2" }) do
        local r = name and _G[name .. k]
        if r then keepHidden(r) end
    end
end

-- t on the button's face, inset by the border.
local function inset(t, face, size)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", face, "TOPLEFT", size, -size)
    t:SetPoint("BOTTOMRIGHT", face, "BOTTOMRIGHT", -size, size)
end

local function borderSize()
    local B = settings().button
    return B.border and B.borderSize or 0
end

local function addMask(w, t)
    if t and not w.masked[t] then
        w.masked[t] = true
        t:AddMaskTexture(w.mask)
    end
end

-- The micro button's face: a square in the button, where its picture is shown.
local function layoutFace(btn)
    local w = btn.wl
    if not w or w.kind ~= "micro" then return end
    local bw, bh = btn:GetSize()
    local f = w.face
    f:ClearAllPoints()
    if w.style == "classic" then
        local s = math.max(1, bw - 4)
        f:SetSize(s, s)
        f:SetPoint("BOTTOM", btn, "BOTTOM", 0, 2)
    else
        local s = math.max(1, math.min(bw, bh) - 4)
        f:SetSize(s, s)
        f:SetPoint("CENTER", btn, "CENTER")
    end
end

local MICRO_PICTURES = {
    { "GetNormalTexture", "SetNormalTexture", "SetNormalAtlas" },
    { "GetPushedTexture", "SetPushedTexture", "SetPushedAtlas" },
    { "GetDisabledTexture", "SetDisabledTexture", "SetDisabledAtlas" },
}

-- Cuts a picture down to the crop's share of the coordinates Blizzard gave it (t.wlBase).
local function cut(t, c)
    local l, r, top, bottom = unpack(t.wlBase)
    t.wlCutting = true
    t:SetTexCoord(l + (r - l) * c[1], l + (r - l) * c[2], top + (bottom - top) * c[3], top + (bottom - top) * c[4])
    t.wlCutting = nil
end

-- The coordinates Blizzard gave a picture: from SetTexCoord (4 or 8 numbers) or, after
-- an atlas, read back.
local function baseFrom(t, ...)
    local n = select("#", ...)
    if n >= 8 then
        local ulx, uly, _, lly, urx = ...
        t.wlBase = { ulx, urx, uly, lly }
    elseif n >= 4 then
        t.wlBase = { ... }
    else
        local ulx, uly, _, lly, urx = t:GetTexCoord()
        t.wlBase = { ulx, urx, uly, lly }
    end
end

-- The micro button's pictures, cut down to the part inside the stone frame, on its
-- face. Blizzard may set a picture's coordinates itself (a sheet, an atlas): the cut
-- is taken from those, and taken again whenever Blizzard sets new ones.
local function placeMicro(btn)
    local w = btn.wl
    if not w then return end
    local size = borderSize()
    local c = MICRO_CROP[w.style]
    for _, m in ipairs(MICRO_PICTURES) do
        local t = btn[m[1]] and btn[m[1]](btn)
        if t then
            if not t.wlBase then baseFrom(t) end
            if not t.wlCutHook then
                t.wlCutHook = true
                hooksecurefunc(t, "SetTexCoord", function(self, ...)
                    if self.wlCutting then return end
                    baseFrom(self, ...)
                    cut(self, MICRO_CROP[w.style])
                end)
                -- an atlas set on the picture itself brings its own coordinates
                hooksecurefunc(t, "SetAtlas", function(self)
                    baseFrom(self)
                    cut(self, MICRO_CROP[w.style])
                end)
            end
            cut(t, c)
            inset(t, w.face, size)
            addMask(w, t)
        end
    end
    local hl = btn:GetHighlightTexture()
    if hl then hl:SetAlpha(0) end
    for _, k in ipairs({ "Background", "PushedBackground" }) do
        if btn[k] then keepHidden(btn[k]) end
    end
    local portrait = btn.Portrait or (btn == CharacterMicroButton and MicroButtonPortrait)
    if portrait then
        inset(portrait, w.face, size)
        addMask(w, portrait)
    end
end

-- The look from the settings: shape, border, background, contents, states and shadow.
local function restyle(btn)
    local w = btn.wl
    local B = settings().button
    local tex = roundTexture(B.radius)
    local rounded = B.radius > 0
    local size = borderSize()
    local face = w.face
    layoutFace(btn)

    w.shadow:SetShown(B.shadow)
    tint(w.shadow, { 0, 0, 0 }, B.shadowOpacity)

    -- square: strips around a full background, as see-through as set; rounded: the
    -- border's shape behind a background inset by its width
    for _, s in ipairs(w.strips) do s:SetShown(B.border and not rounded) end
    layoutStrips(w.strips, face, size, 0)
    tintAll(w.strips, B.borderColor, B.borderOpacity)
    w.border:SetShown(B.border and rounded)
    w.border:SetTexture(tex)
    tint(w.border, B.borderColor, B.borderOpacity)
    local bgInset = rounded and size or 0
    w.bg:SetTexture(tex)
    inset(w.bg, face, bgInset)
    tint(w.bg, B.bgColor, B.bgOpacity)

    w.mask:SetTexture(tex, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    inset(w.mask, face, size)

    local function flat(t, c, a, blend)
        if not t then return end
        t:SetTexture(tex)
        t:SetTexCoord(0, 1, 0, 1)
        tint(t, c, a)
        t:SetBlendMode(blend)
        inset(t, face, size)
    end
    if w.kind == "micro" then
        -- the pictures are Blizzard's, pressed and disabled ones included
        placeMicro(btn)
    else
        local icon = w.icon
        local z = B.zoom
        icon:SetTexCoord(z, 1 - z, z, 1 - z)
        inset(icon, face, size)
        hideBorder(btn)
        btn:SetPushedTexture(tex)
        flat(btn:GetPushedTexture(), B.pushedColor, B.pushedOpacity, "BLEND")
        if btn.SetCheckedTexture then
            btn:SetCheckedTexture(tex)
            flat(btn:GetCheckedTexture(), B.checkedColor, B.checkedOpacity, "ADD")
        end
        btn:SetHighlightTexture(tex)
        local hl = btn:GetHighlightTexture()
        if hl then hl:SetAlpha(0) end
    end
    -- the hover light is WombatLog's own, so it can fade. A texture's vertex alpha is
    -- its alpha, so these two are colored at full and shown through SetAlpha alone.
    flat(w.hover, B.hoverColor, 1, "ADD")
    w.fadeIn:SetToAlpha(B.hoverOpacity)
    w.fadeOut:SetFromAlpha(B.hoverOpacity)
    w.hover:SetAlpha(w.hovered and B.hoverOpacity or 0)
    flat(w.flash, { 1, 1, 1 }, 1, "ADD")
    w.flash:SetAlpha(0)

    local cd = w.cooldown
    if cd and not InCombatLockdown() then
        cd:ClearAllPoints()
        cd:SetAllPoints(w.icon)
        -- a rounded swipe; its own color must be set, or the white texture shows as is.
        -- Square buttons keep Blizzard's swipe untouched.
        if cd.SetSwipeTexture and cd.SetSwipeColor and (rounded or w.swipe) then
            w.swipe = rounded or nil
            pcall(cd.SetSwipeTexture, cd, rounded and tex or WHITE)
            pcall(cd.SetSwipeColor, cd, 0, 0, 0, 0.8)
        end
    end
end

local function outline(fs)
    if not fs then return end
    local font, size = fs:GetFont()
    if font then fs:SetFont(font, size, "OUTLINE") end
end

-- The hover light fades in and out, or just switches.
local function hover(btn, on)
    local w = btn.wl
    w.hovered = on
    w.hoverIn:Stop(); w.hoverOut:Stop()
    if settings().anim.hover then
        (on and w.hoverIn or w.hoverOut):Play()
    else
        w.hover:SetAlpha(on and settings().button.hoverOpacity or 0)
    end
end

local function press(btn)
    local w = btn.wl
    if w.press and settings().anim.press then
        w.press:Stop()
        w.press:Play()
    end
end

local function skin(btn, name, kind)
    local w = { kind = kind, masked = {} }
    if kind == "micro" then
        w.style = (MicroMenu or MicroMenuContainer) and "modern" or "classic"
        w.face = CreateFrame("Frame", nil, btn)
    else
        w.icon = part(btn, name, "icon", "Icon") or _G[name .. "IconTexture"]
        if not w.icon then return end
        w.face = btn
        w.cooldown = part(btn, name, "cooldown", "Cooldown")
    end
    btn.wl = w
    local face, icon = w.face, w.icon

    for _, k in ipairs({ "IconMask", "CircleMask", "SquareMask" }) do
        if icon and btn[k] and icon.RemoveMaskTexture then icon:RemoveMaskTexture(btn[k]) end
    end
    for _, k in ipairs({ "SlotArt", "SlotBackground" }) do
        if btn[k] then btn[k]:SetAlpha(0) end
    end
    -- a bag slot's frame (newer UIs draw it as the icon's border)
    if kind == "bag" then
        local border = part(btn, name, "IconBorder")
        if border then keepHidden(border) end
    end

    w.shadow = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    w.shadow:SetTexture(GLOW)
    w.shadow:SetPoint("TOPLEFT", face, "TOPLEFT", -SHADOW, SHADOW)
    w.shadow:SetPoint("BOTTOMRIGHT", face, "BOTTOMRIGHT", SHADOW, -SHADOW)
    w.border = btn:CreateTexture(nil, "BACKGROUND", nil, -7)
    w.border:SetAllPoints(face)
    w.bg = btn:CreateTexture(nil, "BACKGROUND", nil, -6)
    w.strips = newStrips(btn, "ARTWORK", 7)
    w.mask = btn:CreateMaskTexture()
    addMask(w, icon)
    w.hover = btn:CreateTexture(nil, "OVERLAY", nil, 5)
    w.hover:SetAlpha(0)
    w.flash = btn:CreateTexture(nil, "OVERLAY", nil, 6)
    w.flash:SetAlpha(0)

    -- hover: fades in and out (to the opacity restyle sets)
    w.hoverIn = w.hover:CreateAnimationGroup()
    w.fadeIn = anim(w.hoverIn, "Alpha", 0.12)
    w.fadeIn:SetFromAlpha(0); w.fadeIn:SetToAlpha(1)
    w.hoverIn:SetScript("OnFinished", function() w.hover:SetAlpha(settings().button.hoverOpacity) end)
    w.hoverOut = w.hover:CreateAnimationGroup()
    w.fadeOut = anim(w.hoverOut, "Alpha", 0.2)
    w.fadeOut:SetFromAlpha(1); w.fadeOut:SetToAlpha(0)
    w.hoverOut:SetScript("OnFinished", function() w.hover:SetAlpha(0) end)
    btn:HookScript("OnEnter", function(b) hover(b, true) end)
    btn:HookScript("OnLeave", function(b) hover(b, false) end)

    if kind == "micro" then
        -- Blizzard puts its pictures back on every state change: cut them again
        for _, m in ipairs(MICRO_PICTURES) do
            local get = m[1]
            if btn[m[2]] then
                -- a new file keeps the coordinates it had (SetTexCoord sets new ones)
                hooksecurefunc(btn, m[2], function(b)
                    placeMicro(b)
                end)
            end
            if btn[m[3]] then
                hooksecurefunc(btn, m[3], function(b)
                    local t = b[get](b)
                    if t then t.wlBase = nil end -- the atlas's own coordinates
                    placeMicro(b)
                end)
            end
        end
        for _, m in ipairs({ "SetHighlightTexture", "SetHighlightAtlas" }) do
            if btn[m] then hooksecurefunc(btn, m, placeMicro) end
        end
        btn:HookScript("OnMouseDown", placeMicro)
        btn:HookScript("OnMouseUp", placeMicro)
        btn:HookScript("OnSizeChanged", restyle)
        return
    end

    -- press: the icon dips in and springs back
    w.press = icon:CreateAnimationGroup()
    setScaleAnim(anim(w.press, "Scale", 0.06, 1, "OUT"), 1, 0.88)
    setScaleAnim(anim(w.press, "Scale", 0.12, 2, "OUT"), 1, 1 / 0.88)
    hooksecurefunc(btn, "SetButtonState", function(b, state)
        if state == "PUSHED" then press(b) end
    end)
    btn:HookScript("OnMouseDown", press)

    -- ready: a flash when a cooldown longer than the global one ends
    w.ready = w.flash:CreateAnimationGroup()
    local flash = anim(w.ready, "Alpha", 0.45, 1, "OUT")
    flash:SetFromAlpha(0.8); flash:SetToAlpha(0)
    w.ready:SetScript("OnFinished", function() w.flash:SetAlpha(0) end)
    local cd = w.cooldown
    if cd then
        hooksecurefunc(cd, "SetCooldown", function(c, _, duration)
            c.wlDuration = ns.Safe(duration)
        end)
        pcall(cd.HookScript, cd, "OnCooldownDone", function(c)
            if settings().anim.cooldown and (c.wlDuration or 0) > GCD then
                w.ready:Stop()
                w.ready:Play()
            end
        end)
    end

    hooksecurefunc(btn, "SetNormalTexture", hideBorder)
    if btn.SetNormalAtlas then hooksecurefunc(btn, "SetNormalAtlas", hideBorder) end
    if btn.UpdateButtonArt then hooksecurefunc(btn, "UpdateButtonArt", restyle) end

    outline(part(btn, name, "HotKey"))
    outline(part(btn, name, "Count"))
    outline(part(btn, name, "Name"))
end

function BlizzardUI:SkinButtons()
    if InCombatLockdown() then
        self.pending = true -- styled once the fight is over
        return
    end
    self.pending = nil
    eachButton(function(btn, name, _, kind)
        if not btn.wl then skin(btn, name, kind) end
        if btn.wl then restyle(btn) end
    end, true)
    self.skinned = true
end

---------------------------------------------------------------------------
-- Bars: a panel behind each one
---------------------------------------------------------------------------

local panels = {}
local ticker

local function getPanel(group)
    local p = panels[group]
    if p then return p end
    p = CreateFrame("Frame", nil, UIParent)
    p.shadow = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.shadow:SetTexture(GLOW)
    p.shadow:SetPoint("TOPLEFT", p, "TOPLEFT", -SHADOW * 2, SHADOW * 2)
    p.shadow:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", SHADOW * 2, -SHADOW * 2)
    p.strips = newStrips(p, "BACKGROUND", -7)
    p.bg = newRoundRect(p, "BACKGROUND", -6)
    -- the border's corners: quarter discs the background's own corners sit on
    p.edge = newRoundRect(p, "BACKGROUND", -7)
    panels[group] = p
    return p
end

-- Looks: the border as strips and quarter discs, the background inside it.
local function stylePanel(p)
    local R = settings().bar
    local size = R.border and R.borderSize or 0
    local r = R.radius > 0 and math.max(R.radius, size) or 0
    p.shadow:SetShown(R.shadow)
    tint(p.shadow, { 0, 0, 0 }, R.shadowOpacity)

    layoutStrips(p.strips, p, size, r)
    for _, s in ipairs(p.strips) do s:SetShown(R.border) end
    tintAll(p.strips, R.borderColor, R.borderOpacity)
    -- only the corner discs of the border's shape are used
    layoutRoundRect(p.edge, p, 0, r)
    for i = 1, 3 do p.edge[i]:Hide() end
    for i = 4, 7 do p.edge[i]:SetShown(R.border and r > 0) end
    tintAll(p.edge, R.borderColor, R.borderOpacity)

    layoutRoundRect(p.bg, p, size, math.max(0, r - size))
    tintAll(p.bg, R.bgColor, R.bgOpacity)
end

-- Every panel around the buttons of its bar that are on screen.
function BlizzardUI:UpdatePanels()
    local pad = settings().bar.padding
    local ui = UIParent:GetEffectiveScale()
    local boxes = {}
    eachButton(function(btn, _, group)
        if not btn:IsVisible() then return end
        -- a micro button's visible part is its face
        local area = btn.wl and btn.wl.face or btn
        local l, b, w, h = area:GetRect()
        if not l then return end
        local s = area:GetEffectiveScale() / ui
        l, b, w, h = l * s, b * s, w * s, h * s
        local box = boxes[group]
        if not box then
            box = { l = l, b = b, r = l + w, t = b + h, btn = btn }
            boxes[group] = box
        else
            box.l, box.b = math.min(box.l, l), math.min(box.b, b)
            box.r, box.t = math.max(box.r, l + w), math.max(box.t, b + h)
        end
    end, true)
    for group, p in pairs(panels) do
        if not boxes[group] then p:Hide() end
    end
    for group, box in pairs(boxes) do
        local p = getPanel(group)
        if not p.styled then
            stylePanel(p)
            p.styled = true
        end
        p:SetFrameStrata(box.btn:GetFrameStrata())
        p:SetFrameLevel(math.max(0, box.btn:GetFrameLevel() - 1))
        p:ClearAllPoints()
        p:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", box.l - pad, box.b - pad)
        p:SetSize(box.r - box.l + pad * 2, box.t - box.b + pad * 2)
        p:Show()
    end
end

function BlizzardUI:ApplyPanels()
    local A = settings()
    local on = A.enabled and A.bar.enabled
    if on then
        for _, p in pairs(panels) do stylePanel(p) end
        self:UpdatePanels()
        -- bars move, show and hide (Edit Mode, vehicles, forms): follow them
        ticker = ticker or C_Timer.NewTicker(0.5, function() self:UpdatePanels() end)
    else
        if ticker then ticker:Cancel(); ticker = nil end
        for _, p in pairs(panels) do p:Hide() end
    end
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

-- Hidden parts are set back to visible only once WombatLog has hidden them, so a
-- setting nobody changed never touches Blizzard's UI.
local touched = {}
local function show(key, regionList, visible)
    if visible and not touched[key] then return end
    touched[key] = true
    for _, r in ipairs(regionList) do r:SetAlpha(visible and 1 or 0) end
end

function BlizzardUI:ApplyArt()
    local A = settings()
    show("art", artRegions("action"), not A.hideArt)
    -- the modern bag bar and micro menu go without Blizzard's frames behind them
    show("bagArt", artRegions("bags"), not (A.enabled and A.bags))
    show("microArt", artRegions("micro"), not (A.enabled and A.micro))
end

-- Bars lay themselves out again (Edit Mode, more buttons, a new row) and take new
-- dividers from a pool then: hidden again right after.
local artQueued
function BlizzardUI:QueueArt()
    if artQueued then return end
    artQueued = true
    C_Timer.After(0, function()
        artQueued = nil
        self:ApplyArt()
    end)
end

local LAYOUT_METHODS = { "UpdateDividers", "UpdateGridLayout", "Layout", "UpdateSize" }

function BlizzardUI:HookBarLayouts()
    for _, list in pairs(BAR_FRAMES) do
        for _, n in ipairs(list) do
            local bar = _G[n]
            if bar then
                for _, m in ipairs(LAYOUT_METHODS) do
                    if type(bar[m]) == "function" then
                        hooksecurefunc(bar, m, function() self:QueueArt() end)
                    end
                end
            end
        end
    end
end

function BlizzardUI:ApplyActionBars()
    local A = settings()
    if A.enabled then self:SkinButtons() end
    self:ApplyPanels()
    self:ApplyArt()
    local hotkeys, names = {}, {}
    eachButton(function(btn, name, _, kind)
        if kind ~= "action" then return end
        hotkeys[#hotkeys + 1] = part(btn, name, "HotKey")
        names[#names + 1] = part(btn, name, "Name")
    end)
    show("hotkeys", hotkeys, A.hotkeys)
    show("names", names, A.macroNames)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function BlizzardUI:Init()
    xpBar, xpShared = findXPBar()
    if xpBar then
        xpBar:HookScript("OnShow", function(f)
            if wantXPHidden() then f:Hide() end
        end)
    end
    local function update() self:UpdateXPBar() end
    ns.Listen("PLAYER_XP_UPDATE", update)
    ns.Listen("ENABLE_XP_GAIN", update)
    ns.Listen("DISABLE_XP_GAIN", update)
    -- the new level is only readable a moment later
    ns.Listen("PLAYER_LEVEL_UP", function() C_Timer.After(1, update) end)
    ns.Listen("PLAYER_REGEN_ENABLED", function()
        if self.pending then self:ApplyActionBars() end
    end)
    self:HookBarLayouts()
    -- the bars' first layout can come after login
    ns.Listen("PLAYER_ENTERING_WORLD", function() C_Timer.After(1, function() self:ApplyArt() end) end)
    self.ready = true
    self:Apply()
end

function BlizzardUI:Apply()
    if not self.ready then return end
    self:UpdateXPBar()
    self:ApplyActionBars()
end
