local ADDON, ns = ...
local BagSlots = {}
ns.BagSlots = BagSlots
local Safe, SafeTable = ns.Safe, ns.SafeTable
local L = ns.L

-- Bags as items: in the bags, the bank's bag slots and the bag bar their icon shows how
-- many slots they have, and for special bags (herbs, soul shards, leather, a quiver, ...)
-- a small icon of what they take, so a bag for the wrong profession stands out.
--
-- The kind comes from the item's subclass. The number of slots isn't in the item info;
-- it is read from the item's tooltip ("16 Slot Bag", in the game's own words in every
-- language), once per item. An item the client hasn't loaded yet is tried again when it
-- arrives.

local itemInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local CONTAINER = Enum and Enum.ItemClass and Enum.ItemClass.Container or 1
local QUIVER = Enum and Enum.ItemClass and Enum.ItemClass.Quiver or 11
local FONT = "Fonts\\FRIZQT__.TTF"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_Bag_08"

-- what a bag takes: its icon (from a spell or item the game has everywhere) and colour
local KINDS = {
    bag            = { color = { 1, 1, 1 } },
    soul           = { item = 6265, color = { 0.75, 0.4, 1 } },
    herb           = { spell = 2366, color = { 0.35, 0.95, 0.35 } },
    enchanting     = { spell = 7411, color = { 0.65, 0.6, 1 } },
    engineering    = { spell = 4036, color = { 1, 0.6, 0.2 } },
    gem            = { spell = 25229, color = { 0.3, 0.9, 1 } },
    mining         = { spell = 2575, color = { 0.85, 0.7, 0.5 } },
    leatherworking = { spell = 2108, color = { 0.9, 0.6, 0.3 } },
    inscription    = { spell = 45357, color = { 0.45, 0.7, 1 } },
    fishing        = { spell = 7620, color = { 0.3, 0.85, 0.85 } },
    cooking        = { spell = 2550, color = { 1, 0.85, 0.35 } },
    reagent        = { texture = "Interface\\Icons\\INV_Misc_Bag_10_Green", color = { 0.45, 1, 0.65 } },
    quiver         = { item = 2101, color = { 0.95, 0.85, 0.6 } },
    ammo           = { item = 2102, color = { 0.95, 0.85, 0.6 } },
}
BagSlots.KINDS = KINDS

local CONTAINER_KINDS = {
    [0] = "bag", "soul", "herb", "enchanting", "engineering", "gem", "mining",
    "leatherworking", "inscription", "fishing", "cooking", "reagent",
}
local QUIVER_KINDS = { [2] = "quiver", [3] = "ammo" }

local function kindIcon(kind)
    local k = KINDS[kind]
    if not k then return FALLBACK_ICON end
    if k.icon == nil then
        local icon
        if k.spell then
            local get = C_Spell and C_Spell.GetSpellTexture or GetSpellTexture
            local ok, t = pcall(get, k.spell)
            icon = ok and Safe(t) or nil
        elseif k.item then
            icon = Safe(select(5, itemInstant(k.item)))
        end
        k.icon = icon or k.texture or FALLBACK_ICON
    end
    return k.icon
end

---------------------------------------------------------------------------
-- Slots from the tooltip
---------------------------------------------------------------------------

-- "%d Slot %s" -> "^(%d+) Slot .+$"
local SLOTS_PATTERN
do
    local fmt = CONTAINER_SLOTS or "%d Slot %s"
    fmt = fmt:gsub("%%%d%$", "%%")
    fmt = fmt:gsub("%%d", "\1"):gsub("%%s", "\2")
    fmt = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%0")
    SLOTS_PATTERN = "^" .. fmt:gsub("\1", "(%%d+)"):gsub("\2", ".+") .. "$"
end

local scanTip
local function tooltipLines(link)
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
        data = ok and SafeTable(data)
        if not data then return nil end
        local out = {}
        for i, line in ipairs(data.lines or {}) do
            line = SafeTable(line)
            out[i] = line and Safe(line.leftText)
        end
        return out
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "WombatLogBagScanTooltip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    pcall(scanTip.SetHyperlink, scanTip, link)
    local out = {}
    for i = 1, scanTip:NumLines() do
        local fs = _G["WombatLogBagScanTooltipTextLeft" .. i]
        out[i] = fs and Safe(fs:GetText())
    end
    scanTip:Hide()
    return out
end

local function slotsOf(link)
    local lines = tooltipLines(link)
    for i = 2, math.min(lines and #lines or 0, 8) do
        local text = lines[i]
        if type(text) == "string" then
            local n = text:match(SLOTS_PATTERN)
            if n then return tonumber(n) end
        end
    end
end

---------------------------------------------------------------------------
-- Which bag is that
---------------------------------------------------------------------------

local cache = {}     -- itemID -> { slots = n, kind = "herb" } or false (not a bag)
local waiting = false -- an item's tooltip wasn't loaded yet

-- { slots = n, kind = "herb" } for a bag (or quiver), nil for anything else.
function BagSlots.Info(link)
    link = Safe(link)
    if type(link) ~= "string" then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return nil end
    local known = cache[id]
    if known ~= nil then return known or nil end
    local _, _, _, _, _, class, sub = itemInstant(id)
    class, sub = Safe(class), Safe(sub)
    local kind = class == CONTAINER and CONTAINER_KINDS[sub] or class == QUIVER and QUIVER_KINDS[sub]
    if not kind then
        if class then cache[id] = false end
        return nil
    end
    local slots = slotsOf(link)
    if not slots then
        waiting = true
        return { kind = kind }  -- the slots once the item has loaded
    end
    local info = { slots = slots, kind = kind }
    cache[id] = info
    return info
end

---------------------------------------------------------------------------
-- Drawing on a button
---------------------------------------------------------------------------

local function buttonWidth(button)
    local w = button and button:GetWidth()
    return (w and w > 0) and w or 37
end

local function color(kind)
    local cfg = ns.db.bagSlots
    if not cfg.colorByType then return 1, 1, 1 end
    local c = KINDS[kind].color
    return c[1], c[2], c[3]
end

-- The count and the kind's icon over button, made on host (the button itself).
local function draw(button, info)
    local cfg = ns.db.bagSlots
    local m = button.wlBagSlots
    if not info then
        if m then m:Hide() end
        return
    end
    if not m then
        m = CreateFrame("Frame", nil, button)
        m:SetAllPoints(button)
        m.count = m:CreateFontString(nil, "OVERLAY")
        m.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
        m.icon = m:CreateTexture(nil, "OVERLAY", nil, 5)
        m.icon:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -2)
        m.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        m.iconBorder = m:CreateTexture(nil, "OVERLAY", nil, 4)
        m.iconBorder:SetColorTexture(0, 0, 0, 0.9)
        m.iconBorder:SetPoint("TOPLEFT", m.icon, "TOPLEFT", -1, 1)
        m.iconBorder:SetPoint("BOTTOMRIGHT", m.icon, "BOTTOMRIGHT", 1, -1)
        button.wlBagSlots = m
    end
    m:SetFrameLevel(button:GetFrameLevel() + 3)
    local w = buttonWidth(button)
    if cfg.count and info.slots then
        m.count:SetFont(FONT, math.max(8, math.floor(w * 0.36 * (cfg.size or 1) + 0.5)), "OUTLINE")
        m.count:SetText(info.slots)
        m.count:SetTextColor(color(info.kind))
        m.count:Show()
    else
        m.count:Hide()
    end
    if cfg.typeIcon and info.kind ~= "bag" then
        local size = math.floor(w * 0.36 * (cfg.size or 1) + 0.5)
        m.icon:SetSize(size, size)
        m.icon:SetTexture(kindIcon(info.kind))
        m.icon:Show()
        m.iconBorder:Show()
    else
        m.icon:Hide()
        m.iconBorder:Hide()
    end
    m:Show()
end

local function mark(button, bag, slot, link)
    local cfg = ns.db.bagSlots
    if not cfg.enabled then return draw(button, nil) end
    if not link and bag and slot then
        local get = C_Container and C_Container.GetContainerItemLink or GetContainerItemLink
        link = Safe(get(bag, slot))
    end
    draw(button, link and BagSlots.Info(link))
end

-- The bag bar and the bank's bag slots: inventory slots holding a bag.
local function inventoryButtons(fn)
    for i = 0, 3 do fn(_G["CharacterBag" .. i .. "Slot"]) end
    fn(_G.CharacterReagentBag0Slot)
    for i = 1, 7 do
        fn(_G["BankFrameBag" .. i] or (BankSlotsFrame and BankSlotsFrame["Bag" .. i]))
    end
end

local function markInventory()
    if not ns.db then return end
    local cfg = ns.db.bagSlots
    inventoryButtons(function(b)
        if not b then return end
        local invSlot = b.GetInventorySlot and b:GetInventorySlot() or b:GetID()
        local link = cfg.enabled and cfg.bagBar and invSlot and invSlot > 0
            and Safe(GetInventoryItemLink("player", invSlot))
        draw(b, link and BagSlots.Info(link) or nil)
    end)
end

---------------------------------------------------------------------------
-- Baganator: two corner widgets, the count and the kind's icon
---------------------------------------------------------------------------

local function hookBaganator()
    local BB = ns.BagButtons
    BB.Baganator(L["Bag slots (WombatLog)"], "wombatlog_bagslots_count",
        function(corner, details)
            local cfg = ns.db.bagSlots
            local info = cfg.enabled and cfg.count and details and BagSlots.Info(details.itemLink)
            if not (info and info.slots) then return false end
            corner.text:SetFont(FONT, math.max(8, math.floor(13 * (cfg.size or 1) + 0.5)), "OUTLINE")
            corner.text:SetText(info.slots)
            corner.text:SetTextColor(color(info.kind))
            corner:SetSize(math.max(1, corner.text:GetStringWidth()), math.max(1, corner.text:GetStringHeight()))
            return true
        end,
        function()
            local f = CreateFrame("Frame")
            f:SetSize(14, 14)
            f.text = f:CreateFontString(nil, "OVERLAY")
            f.text:SetFont(FONT, 13, "OUTLINE")
            f.text:SetPoint("BOTTOMRIGHT")
            f.padding = 0
            return f
        end,
        { corner = "bottom_right", priority = 1 })
    BB.Baganator(L["Bag type (WombatLog)"], "wombatlog_bagslots_type",
        function(corner, details)
            local cfg = ns.db.bagSlots
            local info = cfg.enabled and cfg.typeIcon and details and BagSlots.Info(details.itemLink)
            if not info or info.kind == "bag" then return false end
            local size = math.floor(13 * (cfg.size or 1) + 0.5)
            corner:SetSize(size, size)
            corner.icon:SetTexture(kindIcon(info.kind))
            return true
        end,
        function()
            local f = CreateFrame("Frame")
            f:SetSize(13, 13)
            local border = f:CreateTexture(nil, "BACKGROUND")
            border:SetColorTexture(0, 0, 0, 0.9)
            border:SetPoint("TOPLEFT", -1, 1)
            border:SetPoint("BOTTOMRIGHT", 1, -1)
            f.icon = f:CreateTexture(nil, "OVERLAY")
            f.icon:SetAllPoints()
            f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            f.padding = 0
            return f
        end,
        { corner = "top_right", priority = 1 })
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function BagSlots:Refresh()
    ns.BagButtons.Refresh()
    markInventory()
end

function BagSlots:Init()
    ns.BagButtons.Register(mark)
    self:Refresh()
end

function BagSlots:Apply()
    self:Refresh()
end

ns.Listen("PLAYER_LOGIN", hookBaganator)
ns.Listen("BAG_UPDATE_DELAYED", markInventory)
ns.Listen("PLAYER_ENTERING_WORLD", markInventory)
ns.Listen("BANKFRAME_OPENED", function() C_Timer.After(0, markInventory) end)
ns.Listen("PLAYERBANKBAGSLOTS_CHANGED", markInventory)
ns.Listen("GET_ITEM_INFO_RECEIVED", function()
    if not waiting then return end
    waiting = false
    C_Timer.After(0.2, function() BagSlots:Refresh() end)
end)
