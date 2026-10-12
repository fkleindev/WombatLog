local ADDON, ns = ...
local BlizzardUI = {}
ns.BlizzardUI = BlizzardUI
local XPBar = ns.XPBar

-- Changes to Blizzard's own UI: hiding its XP bar, and a flat look for its action
-- buttons. Every client names these frames a little differently, so whatever isn't
-- there is skipped. Nothing is touched until a setting asks for it.

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CROP = 0.08 -- trimmed off each icon edge, which Blizzard's border used to cover

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
-- Action bars
---------------------------------------------------------------------------

local BUTTONS = {
    { "ActionButton", 12 }, { "MultiBarBottomLeftButton", 12 }, { "MultiBarBottomRightButton", 12 },
    { "MultiBarRightButton", 12 }, { "MultiBarLeftButton", 12 },
    { "MultiBar5Button", 12 }, { "MultiBar6Button", 12 }, { "MultiBar7Button", 12 },
    { "BonusActionButton", 12 }, { "PetActionButton", 10 },
    { "StanceButton", 10 }, { "ShapeshiftButton", 10 },
}

local function eachButton(fn)
    for _, set in ipairs(BUTTONS) do
        for i = 1, set[2] do
            local name = set[1] .. i
            local btn = _G[name]
            if btn then fn(btn, name) end
        end
    end
end

-- A button's part by its key (newer UIs) or its global name (older ones).
local function part(btn, name, key, suffix)
    return btn[key] or _G[name .. (suffix or key)]
end

-- The bar art: the gryphons and the bar's background.
local function artRegions()
    local list = {}
    local names = { "MainMenuBarLeftEndCap", "MainMenuBarRightEndCap" }
    for i = 0, 3 do
        names[#names + 1] = "MainMenuBarTexture" .. i
        names[#names + 1] = "MainMenuMaxLevelBar" .. i
    end
    for _, n in ipairs(names) do
        if _G[n] then list[#list + 1] = _G[n] end
    end
    local bar = MainActionBar or MainMenuBar
    if bar then
        for _, k in ipairs({ "EndCaps", "BorderArt" }) do
            if bar[k] then list[#list + 1] = bar[k] end
        end
    end
    return list
end

-- Blizzard's thick border, kept hidden whenever Blizzard puts it back.
local function hideBorder(btn)
    local t = btn:GetNormalTexture()
    if t then t:SetAlpha(0) end
    local name = btn:GetName()
    for _, k in ipairs({ "NormalTexture", "NormalTexture2" }) do
        local r = name and _G[name .. k]
        if r then r:SetAlpha(0) end
    end
end

-- Flat hover, pressed and active states over the icon.
local function flatStates(btn, icon)
    local function flat(tex, r, g, b, a, blend)
        if not tex then return end
        tex:SetTexture(WHITE)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetVertexColor(r, g, b, a)
        tex:SetBlendMode(blend)
        tex:ClearAllPoints()
        tex:SetAllPoints(icon)
    end
    btn:SetHighlightTexture(WHITE)
    flat(btn:GetHighlightTexture(), 1, 1, 1, 0.15, "ADD")
    btn:SetPushedTexture(WHITE)
    flat(btn:GetPushedTexture(), 0, 0, 0, 0.4, "BLEND")
    if btn.SetCheckedTexture then
        btn:SetCheckedTexture(WHITE)
        flat(btn:GetCheckedTexture(), 1, 0.82, 0, 0.35, "ADD")
    end
end

local function outline(fs)
    if not fs then return end
    local font, size = fs:GetFont()
    if font then fs:SetFont(font, size, "OUTLINE") end
end

local function skin(btn, name)
    local icon = part(btn, name, "icon", "Icon")
    if not icon then return end
    btn.wlSkinned = true

    if btn.IconMask and icon.RemoveMaskTexture then icon:RemoveMaskTexture(btn.IconMask) end
    icon:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    for _, k in ipairs({ "SlotArt", "SlotBackground" }) do
        if btn[k] then btn[k]:SetAlpha(0) end
    end

    -- a dark square for empty slots and a thin border
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)
    for i, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                            { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = btn:CreateTexture(nil, "ARTWORK", nil, 7)
        t:SetColorTexture(0, 0, 0, 1)
        t:SetPoint(side[1], btn, side[1])
        t:SetPoint(side[2], btn, side[2])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
    end

    hideBorder(btn)
    flatStates(btn, icon)
    hooksecurefunc(btn, "SetNormalTexture", hideBorder)
    if btn.SetNormalAtlas then hooksecurefunc(btn, "SetNormalAtlas", hideBorder) end
    if btn.UpdateButtonArt then
        hooksecurefunc(btn, "UpdateButtonArt", function(b)
            hideBorder(b)
            flatStates(b, icon)
        end)
    end

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
    eachButton(function(btn, name)
        if not btn.wlSkinned then skin(btn, name) end
    end)
    self.skinned = true
end

-- Hidden parts are set back to visible only once WombatLog has hidden them, so a
-- setting nobody changed never touches Blizzard's UI.
local touched = {}
local function show(key, regionList, visible)
    if visible and not touched[key] then return end
    touched[key] = true
    for _, r in ipairs(regionList) do r:SetAlpha(visible and 1 or 0) end
end

function BlizzardUI:ApplyActionBars()
    local A = ns.db.blizzard.actionBars
    if A.enabled then self:SkinButtons() end
    show("art", artRegions(), not A.hideArt)
    local hotkeys, names = {}, {}
    eachButton(function(btn, name)
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
    self.ready = true
    self:Apply()
end

function BlizzardUI:Apply()
    if not self.ready then return end
    self:UpdateXPBar()
    self:ApplyActionBars()
end
