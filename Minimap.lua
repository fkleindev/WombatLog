local ADDON, ns = ...
local MinimapButton = {}
ns.Minimap = MinimapButton
local L = ns.L

local ICON = "Interface\\Icons\\inv_pet_beaver"

local function updatePosition(b)
    local angle = math.rad(ns.db.minimap.angle)
    local r = Minimap:GetWidth() / 2 + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

-- Shared by the minimap button and the addon compartment.
local function onClick(button)
    if button == "RightButton" then
        ns.Config:Open()
    elseif IsShiftKeyDown() then
        ns.RunTest()
    else
        ns.Report:ToggleJournal()
    end
end

local function fillTooltip(tt)
    tt:AddLine("WombatLog")
    local last = ns.Stats.last
    if last and not last.test then
        tt:AddDoubleLine(L["Last fight"], ns.Short(last.dps) .. " DPS, " .. ns.Stats.FormatDuration(last.duration), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if ns.db.session.enabled then
        local i = ns.Stats:SessionInfo()
        if i then
            tt:AddDoubleLine(L["Session"], ns.Stats.FormatDuration(i.elapsed) .. ", " .. L["%d kills"]:format(i.kills), 0.8, 0.8, 0.8, 1, 1, 1)
            if not i.atMax and i.xpPerHour and i.xpPerHour > 0 then
                tt:AddDoubleLine(L["XP per hour"], ns.Full(i.xpPerHour), 0.8, 0.8, 0.8, 1, 1, 1)
                tt:AddDoubleLine(L["Time to level"], i.timeToLevel and ns.Stats.FormatDuration(i.timeToLevel) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    end
    tt:AddLine(" ")
    tt:AddLine(L["Click: journal   Right-click: settings   Shift-click: test"], 0.6, 0.8, 1)
end

function MinimapButton:Init()
    local b = CreateFrame("Button", "WombatLogMinimapButton", Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("TOPLEFT", 7, -6)
    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53, 53)
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetPoint("TOPLEFT")

    -- drag around the minimap edge
    local function follow(self)
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
        updatePosition(self)
    end
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", follow)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function(_, button) onClick(button) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        fillTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self.button = b
    self:Apply()
end

function MinimapButton:Apply()
    local b = self.button
    if not b then return end
    b:SetShown(ns.db.minimap.enabled)
    updatePosition(b)
end

-- Addon compartment (the addon list button by the minimap), declared in the TOC.
function WombatLog_OnAddonCompartmentClick(_, button)
    onClick(button)
end

function WombatLog_OnAddonCompartmentEnter(_, menuButton)
    GameTooltip:SetOwner(menuButton or UIParent, "ANCHOR_LEFT")
    fillTooltip(GameTooltip)
    GameTooltip:Show()
end

function WombatLog_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
