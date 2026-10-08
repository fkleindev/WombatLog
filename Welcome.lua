local ADDON, ns = ...
local Welcome = {}
ns.Welcome = Welcome
local L = ns.L

-- Shown once per character on the first login with WombatLog, and on /wl welcome:
-- what the addon is, every feature with a switch, and the language.

local W, H = 600, 640
local ICON = "Interface\\Icons\\inv_pet_beaver"

local function border(f, r, g, b, a)
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
                            { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, a)
        t:SetPoint(side[1])
        t:SetPoint(side[2])
        if side[3] then t:SetWidth(side[3]) else t:SetHeight(side[4]) end
    end
end

local function version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local v = get and get(ADDON, "Version")
    if not v or v:find("^@") then return nil end -- not packaged
    return v
end

local function char()
    return WombatLogDB.charData[ns.charKey]
end

-- Crit alerts are a visual and a sound part; the switch turns both.
local critBind = {
    get = function() return ns.db.alerts.visual.enabled or ns.db.alerts.sound.enabled end,
    set = function(v)
        ns.db.alerts.visual.enabled, ns.db.alerts.sound.enabled = v, v
        ns.ApplyAll()
    end,
}

local function BuildFeatures(p)
    p:Header("Language")
    p:Dropdown("Language", ns.Config.LanguageBind(function()
        -- come back in the new language after the reload
        Welcome.reloading = true
        char().welcomed = nil
    end), ns.LocaleOptions)
    p:Note("Applies to all characters. \"Automatic\" follows the language of your game client and falls back to English.")

    p:Header("Features")
    p:Note("Switch what you want on or off. This applies to your active profile; everything else is in the settings.")
    p:Checkbox("Combat log", "behaviour.enabled")
    p:Note("A borderless, transparent feed of your hits, heals, misses, buffs and kills, with live DPS/HPS and a swing timer.")
    p:Checkbox("Crit alerts", critBind)
    p:Note("Your crits as a big number with a sound, plus crit streaks and new records.")
    p:Checkbox("Proc alerts", "procs.enabled")
    p:Note("A pop-up and a sound when one of your procs lights up.")
    p:Checkbox("Spell reminders", "reminders.enabled")
    p:Note("Icons for spells that are usable now and buffs or debuffs that need refreshing.")
    p:Checkbox("Kill alerts", "killAlert.enabled")
    p:Note("A pop-up when a mob you fought dies: the XP counting up, its name and a multi-kill counter.")
    p:Checkbox("Quest alert", "questAlert.enabled")
    p:Note("The same pop-up when you turn in a quest, with the quest's name.")
    p:Checkbox("XP tracker", "xpTracker.enabled")
    p:Note("A small XP bar at the top of the screen that grows when you get XP.")
    p:Checkbox("Swing timer", "swing.enabled")
    p:Note("Bars for your next main-hand, off-hand and ranged swing, inside the combat log.")
    p:Checkbox("Resource display", "resources.enabled")
    p:Note("Health, power, combo points and cast bar under your character.")
    p:Checkbox("Fight summary", "stats.summary.enabled")
    p:Note("A card after each fight with DPS, HPS, crit rate, biggest hit and new records.")
    p:Checkbox("Session", "session.enabled")
    p:Note("XP per hour, time and kills to the next level, deaths and money while you play.")
    p:Checkbox("Minimap button", "minimap.enabled")
    p:Note("Opens the settings and the journal. Also in the addon list by the minimap.")
end

local function CreateWindow()
    local f = CreateFrame("Frame", "WombatLogWelcome", UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "WombatLogWelcome")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.06, 0.94)
    border(f, 1, 1, 1, 0.12)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- header: icon, name, version, welcome text
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(56, 56)
    icon:SetPoint("TOPLEFT", 18, -18)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local iconFrame = CreateFrame("Frame", nil, f)
    iconFrame:SetPoint("TOPLEFT", icon, -1, 1)
    iconFrame:SetPoint("BOTTOMRIGHT", icon, 1, -1)
    border(iconFrame, 1, 0.82, 0, 0.6)

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 14, -4)
    title:SetText("WombatLog")
    local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    local v = version()
    sub:SetText(L["Welcome!"] .. (v and ("  |cff808080" .. v .. "|r") or ""))

    local intro = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    intro:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -14)
    intro:SetWidth(W - 36)
    intro:SetJustifyH("LEFT")
    intro:SetSpacing(2)
    intro:SetText(L["WombatLog shows your fights as they happen: every hit, heal and kill in a clean feed, with alerts for the moments that matter. Pick what you want below - you can change everything later in the settings."])

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 18, -150)
    line:SetPoint("TOPRIGHT", -18, -150)

    -- the features, with the settings panel's widgets
    local page = ns.Config:EmbedPage(f, 12, -156, 30, 56)
    BuildFeatures(page)

    -- footer
    local go = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    go:SetSize(140, 26)
    go:SetPoint("BOTTOMRIGHT", -16, 16)
    go:SetText(L["Let's go!"])
    go:SetScript("OnClick", function() f:Hide() end)
    local settings = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    settings:SetSize(140, 26)
    settings:SetPoint("RIGHT", go, "LEFT", -8, 0)
    settings:SetText(L["Open settings"])
    settings:SetScript("OnClick", function()
        f:Hide()
        ns.Config:Open()
    end)
    local hint = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 18, 22)
    hint:SetPoint("RIGHT", settings, "LEFT", -10, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["Open this screen again any time with /wl welcome."])

    f:SetScript("OnShow", function() ns.Config:RefreshAll() end)
    f:SetScript("OnHide", function()
        if not Welcome.reloading then char().welcomed = true end
    end)
    return f
end

function Welcome:Show()
    if not ns.Config or not ns.Config.panel then return end
    self.frame = self.frame or CreateWindow()
    self.frame:Show()
end

function Welcome:Toggle()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Show()
    end
end

-- First login of this character with WombatLog: show it once the loading is done.
function Welcome:Init()
    if char().welcomed then return end
    C_Timer.After(2, function()
        if not char().welcomed then self:Show() end
    end)
end
