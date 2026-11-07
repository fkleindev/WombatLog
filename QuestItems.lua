local ADDON, ns = ...
local QuestItems = {}
ns.QuestItems = QuestItems
local Safe, SafeTable = ns.Safe, ns.SafeTable
local L = ns.L

-- Items a quest in your log still asks for that aren't quest items themselves: the
-- cloth, ore or meat you bring to a turn-in. The game lets you sell those like
-- anything else, so they get a small quest mark in the bags, a line in the tooltip
-- naming the quest, and at a merchant a right-click asks before it sells one. If one
-- goes anyway (dragged onto the merchant, or from a bag the right-click isn't
-- covered in), you're offered to buy it back.
--
-- What a quest asks for comes from its objectives of the type "item": by item ID where
-- the client gives it (Retail), otherwise by the item's name ("Linen Cloth: 3/10"),
-- which is the same text as the item's own in every language. Real quest items (the
-- item class "Quest") are left alone; the game marks those itself and won't buy them.
--
-- Bags: the game's own (single bags and the combined bag), Bagnon, AdiBags and
-- Baganator. The tooltip line and the buy-back offer work with any bag addon.

local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local QUEST_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Questitem or 12
local SCAN_DELAY = 0.2
local ALLOW_TIME = 2     -- seconds after "Sell anyway" in which a sale isn't questioned

local Container = C_Container
local numSlots = Container and Container.GetContainerNumSlots or GetContainerNumSlots
local slotLink = Container and Container.GetContainerItemLink or GetContainerItemLink
local useSlot = Container and Container.UseContainerItem or UseContainerItem
local pickupSlot = Container and Container.PickupContainerItem or PickupContainerItem
local itemInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local byID, byName = {}, {}  -- itemID / lowercase name -> { { title, have, need }, ... }
local merchantOpen = false
local allowUntil = 0
local carried = {}           -- at a merchant: itemID -> how many marked ones are in the bags
local refreshPending, scanPending = false, false

---------------------------------------------------------------------------
-- What the quests ask for
---------------------------------------------------------------------------

-- "3/10 Linen Cloth" (Retail) or "Linen Cloth: 3/10" (Classic) -> "Linen Cloth"
local function itemName(text)
    local s = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")
    s = s:gsub("%s*:?%s*%(?%d+%s*/%s*%d+%)?%s*$", "")
    s = strtrim(s)
    return s ~= "" and s or nil
end

local function add(list, key, entry)
    local t = list[key]
    if not t then
        t = {}
        list[key] = t
    end
    t[#t + 1] = entry
end

local function addObjective(title, text, objectID, have, need)
    text = Safe(text)
    if type(text) ~= "string" then return end
    have, need = Safe(have), Safe(need)
    if type(have) ~= "number" or type(need) ~= "number" then
        local a, b = text:match("(%d+)%s*/%s*(%d+)")
        have, need = tonumber(a), tonumber(b)
    end
    local entry = { title = title, have = have, need = need }
    objectID = Safe(objectID)
    if type(objectID) == "number" and objectID > 0 then add(byID, objectID, entry) end
    local name = itemName(text)
    if name then add(byName, name:lower(), entry) end
end

local function readQuest(id, title, index)
    local objs = C_QuestLog and C_QuestLog.GetQuestObjectives and SafeTable(C_QuestLog.GetQuestObjectives(id))
    if objs and #objs > 0 then
        for _, o in ipairs(objs) do
            o = SafeTable(o)
            if o and Safe(o.type) == "item" then
                addObjective(title, o.text, o.objectID, o.numFulfilled, o.numRequired)
            end
        end
    elseif index and GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
        for j = 1, Safe(GetNumQuestLeaderBoards(index)) or 0 do
            local text, kind = GetQuestLogLeaderBoard(j, index)
            if Safe(kind) == "item" then addObjective(title, text) end
        end
    end
end

function QuestItems:Scan()
    scanPending = false
    byID, byName = {}, {}
    local QP, seen = ns.QuestProgress, {}
    for i = 1, QP.NumLogEntries() do
        local id, title = QP.LogEntry(i)
        if id and not seen[id] then
            seen[id] = true
            readQuest(id, title or "?", i)
        end
    end
    -- quests under a collapsed header (Classic), which the log doesn't list
    for id, q in pairs(QP.Known()) do
        if not seen[id] then
            seen[id] = true
            readQuest(id, q.title or "?", nil)
        end
    end
    self:Refresh()
end

local function requestScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, function() QuestItems:Scan() end)
end

---------------------------------------------------------------------------
-- Which item is that
---------------------------------------------------------------------------

local function linkID(link)
    return tonumber(link:match("item:(%d+)"))
end

-- The quests that need the item behind link, or nil.
function QuestItems.Needed(link)
    link = Safe(link)
    if type(link) ~= "string" then return nil end
    local id = linkID(link)
    if not id then return nil end
    local class = select(6, itemInstant(id))
    if class == QUEST_CLASS then return nil end
    if byID[id] then return byID[id] end
    local name = link:match("%[(.-)%]")
    if not name then return nil end
    -- crafting reagents on Retail carry their quality star inside the brackets
    name = strtrim((name:gsub("|A.-|a", ""):gsub("|T.-|t", "")))
    return byName[name:lower()]
end

-- "Cloth for the Guard (3/10)", one per quest.
local function questText(entries, sep)
    local parts = {}
    for i, e in ipairs(entries) do
        if e.have and e.need then
            parts[i] = ("%s (%d/%d)"):format(e.title, e.have, e.need)
        else
            parts[i] = e.title
        end
    end
    return table.concat(parts, sep or ", ")
end

---------------------------------------------------------------------------
-- Asking before a sale, and buying back
---------------------------------------------------------------------------

StaticPopupDialogs.WOMBATLOG_SELL_QUEST_ITEM = {
    text = "%s",
    button1 = "Sell anyway",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, data)
        if not merchantOpen or Safe(slotLink(data.bag, data.slot)) ~= data.link then return end
        allowUntil = GetTime() + ALLOW_TIME
        useSlot(data.bag, data.slot)
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs.WOMBATLOG_BUYBACK_QUEST_ITEM = {
    text = "%s",
    button1 = "Buy back",
    button2 = "Keep it sold",
    OnAccept = function(_, data)
        if merchantOpen and GetBuybackItemLink(data.index) == data.link then
            BuybackItem(data.index)
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function askSell(bag, slot)
    local link = Safe(slotLink(bag, slot))
    local entries = link and QuestItems.Needed(link)
    if not entries then return useSlot(bag, slot) end
    local d = StaticPopupDialogs.WOMBATLOG_SELL_QUEST_ITEM
    d.button1 = L["Sell anyway"]
    local text = L["%s is needed for %s. Sell anyway?"]:format(link, questText(entries))
    StaticPopup_Show("WOMBATLOG_SELL_QUEST_ITEM", text, nil, { bag = bag, slot = slot, link = link })
end

local function offerBuyback(index, link, entries)
    local d = StaticPopupDialogs.WOMBATLOG_BUYBACK_QUEST_ITEM
    d.button1, d.button2 = L["Buy back"], L["Keep it sold"]
    local text = L["You sold %s, which is needed for %s. Buy it back?"]:format(link, questText(entries))
    StaticPopup_Show("WOMBATLOG_BUYBACK_QUEST_ITEM", text, nil, { index = index, link = link })
end

-- At a merchant: how many of each marked item are in the bags.
local function countCarried()
    local counts = {}
    for bag = 0, LAST_BAG do
        for slot = 1, Safe(numSlots(bag)) or 0 do
            local link = Safe(slotLink(bag, slot))
            if link and QuestItems.Needed(link) then
                local id = linkID(link)
                local info = Container and Container.GetContainerItemInfo and SafeTable(Container.GetContainerItemInfo(bag, slot))
                local n = info and Safe(info.stackCount)
                if not n and GetContainerItemInfo then n = Safe(select(2, GetContainerItemInfo(bag, slot))) end
                counts[id] = (counts[id] or 0) + (tonumber(n) or 1)
            end
        end
    end
    return counts
end

-- A marked item fewer in the bags and the same item newest on the buy-back list: sold.
local function checkSold()
    local cfg = ns.db.questItems
    if not (merchantOpen and cfg.enabled and cfg.sellGuard) then return end
    local now = countCarried()
    if GetTime() > allowUntil then
        local index = GetNumBuybackItems and GetNumBuybackItems() or 0
        local link = index > 0 and GetBuybackItemLink(index)
        local id = link and linkID(link)
        if id and (now[id] or 0) < (carried[id] or 0) then
            local entries = QuestItems.Needed(link)
            if entries then offerBuyback(index, link, entries) end
        end
    end
    carried = now
end

---------------------------------------------------------------------------
-- Bag buttons
---------------------------------------------------------------------------

local function guardOnClick(self, button)
    if button == "RightButton" then
        askSell(self.bag, self.slot)
        return
    end
    local link = Safe(slotLink(self.bag, self.slot))
    if link and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink and ChatEdit_InsertLink(link) then return end
    if link and IsModifiedClick("DRESSUP") and DressUpItemLink then
        DressUpItemLink(link)
        return
    end
    pickupSlot(self.bag, self.slot)
end

local function guardOnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(self.bag, self.slot)
    GameTooltip:Show()
end

-- At a merchant, a marked item's button gets a cover that catches the right-click and
-- asks first; left-click, dragging and the tooltip work as on the button below.
local function guard(button, bag, slot, on)
    local g = button.wlSellGuard
    if not on then
        if g then g:Hide() end
        return
    end
    if not g then
        g = CreateFrame("Button", nil, button)
        g:SetAllPoints()
        g:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        g:RegisterForDrag("LeftButton")
        g:SetScript("OnClick", guardOnClick)
        g:SetScript("OnDragStart", function(self) pickupSlot(self.bag, self.slot) end)
        g:SetScript("OnReceiveDrag", function(self) pickupSlot(self.bag, self.slot) end)
        g:SetScript("OnEnter", guardOnEnter)
        g:SetScript("OnLeave", function() GameTooltip:Hide() end)
        local hl = g:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        button.wlSellGuard = g
    end
    g.bag, g.slot = bag, slot
    g:SetFrameLevel(button:GetFrameLevel() + 5)
    g:Show()
end

local function markTexture(button)
    local t = button.wlQuestMark
    if not t then
        t = button:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetTexture(QUEST_ICON)
        t:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        button.wlQuestMark = t
    end
    local w = button:GetWidth()
    local size = math.floor(((w and w > 0) and w or 37) * 0.42 + 0.5)
    t:SetSize(size, size)
    return t
end

-- Marks one bag button. bag and slot: where it sits in your bags (nil when the bag
-- addon shows something else, e.g. another character's bags); link: what it shows.
local function mark(button, bag, slot, link)
    local cfg = ns.db.questItems
    link = Safe(link)
    if not link and bag and slot then link = Safe(slotLink(bag, slot)) end
    local needed = cfg.enabled and link and QuestItems.Needed(link)
    if needed then
        markTexture(button):Show()
    elseif button.wlQuestMark then
        button.wlQuestMark:Hide()
    end
    -- the cover only over the slot that really holds that item right now
    local live = needed and bag and slot and bag >= 0 and bag <= LAST_BAG
        and Safe(slotLink(bag, slot)) == link
    guard(button, bag, slot, live and merchantOpen and cfg.sellGuard and not InCombatLockdown())
end

local function blizzardButtons(fn)
    local function frame(f)
        if not f or not f:IsShown() then return end
        if f.EnumerateValidItems then
            for _, b in f:EnumerateValidItems() do
                fn(b, b.GetBagID and b:GetBagID() or f:GetID(), b:GetID())
            end
        else
            local name = f:GetName()
            for j = 1, f.size or 0 do
                local b = name and _G[name .. "Item" .. j]
                if b then fn(b, f:GetID(), b:GetID()) end
            end
        end
    end
    frame(ContainerFrameCombinedBags)
    for i = 1, NUM_CONTAINER_FRAMES or 13 do frame(_G["ContainerFrame" .. i]) end
end

-- Bag addons, once all addons are loaded. Each in a pcall: a newer version that
-- changed its insides only loses the marks, not the rest of the addon.
local addonButtons = {} -- Bagnon and AdiBags buttons seen: button -> true
local baganator = false

local function hookBagAddons()
    -- Bagnon (and the other Wildpants bags): their item class
    for _, name in ipairs({ "Bagnon", "Combuctor" }) do
        local A = _G[name]
        if type(A) == "table" and type(A.Item) == "table" and A.Item.Update then
            pcall(hooksecurefunc, A.Item, "Update", function(b)
                addonButtons[b] = "wildpants"
                local info = b.info
                local link = info and (info.hyperlink or info.link)
                local bag = b.GetBag and b:GetBag()
                if type(bag) ~= "number" then bag = nil end
                mark(b, bag, bag and b:GetID(), link)
            end)
        end
    end
    -- AdiBags: tells everyone with AceEvent when a button changes
    local AceEvent = LibStub and LibStub("AceEvent-3.0", true)
    if AceEvent and C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("AdiBags")
        or AceEvent and IsAddOnLoaded and IsAddOnLoaded("AdiBags") then
        local listener = {}
        AceEvent:Embed(listener)
        listener:RegisterMessage("AdiBags_UpdateButton", function(_, b)
            if type(b) ~= "table" or not b.bag then return end
            addonButtons[b] = "adibags"
            mark(b, b.bag, b.slot)
        end)
    end
    -- Baganator: a corner widget of its own
    local API = Baganator and Baganator.API
    if API and API.RegisterCornerWidget then
        baganator = pcall(API.RegisterCornerWidget, L["Needed for a quest (WombatLog)"], "wombatlog_questitems",
            function(corner, details)
                return ns.db.questItems.enabled and details and QuestItems.Needed(details.itemLink) and true or false
            end,
            function()
                local f = CreateFrame("Frame")
                f:SetSize(15, 15)
                local t = f:CreateTexture(nil, "OVERLAY")
                t:SetAllPoints()
                t:SetTexture(QUEST_ICON)
                f.padding = 0
                return f
            end,
            { corner = "top_left", priority = 1 })
    end
end

function QuestItems:Refresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        blizzardButtons(mark)
        for b, kind in pairs(addonButtons) do
            if b:IsVisible() then
                if kind == "adibags" then
                    if b.bag then mark(b, b.bag, b.slot) end
                elseif b.Update then
                    pcall(b.Update, b)
                end
            end
        end
        if baganator and Baganator.API.RequestItemButtonsRefresh then
            pcall(Baganator.API.RequestItemButtonsRefresh)
        end
    end)
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function addTooltip(tt, show)
    local cfg = ns.db and ns.db.questItems
    if not (cfg and cfg.enabled and cfg.tooltip) or not tt.GetItem then return end
    local _, link = tt:GetItem()
    local entries = QuestItems.Needed(link)
    if not entries then return end
    for _, e in ipairs(entries) do
        tt:AddLine(("|T%s:0|t %s"):format(QUEST_ICON, questText({ e })), 1, 0.82, 0)
    end
    if show then tt:Show() end
end

local function hookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt)
            if tt == GameTooltip or tt == ItemRefTooltip then pcall(addTooltip, tt) end
        end)
    else
        for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
            if tt and tt:HasScript("OnTooltipSetItem") then
                tt:HookScript("OnTooltipSetItem", function(self) pcall(addTooltip, self, true) end)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function QuestItems:Init()
    hookTooltips()
    if ContainerFrame_Update then
        hooksecurefunc("ContainerFrame_Update", function() QuestItems:Refresh() end)
    end
    local frames = { ContainerFrameCombinedBags }
    for i = 1, NUM_CONTAINER_FRAMES or 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
    for _, f in pairs(frames) do
        if f.UpdateItems then hooksecurefunc(f, "UpdateItems", function() QuestItems:Refresh() end) end
        f:HookScript("OnShow", function() QuestItems:Refresh() end)
    end
    requestScan()
end

function QuestItems:Apply()
    self:Refresh()
end

ns.Listen("PLAYER_LOGIN", hookBagAddons)
ns.Listen("QUEST_LOG_UPDATE", requestScan)
ns.Listen("QUEST_ACCEPTED", requestScan)
ns.Listen("QUEST_REMOVED", requestScan)
ns.Listen("QUEST_TURNED_IN", requestScan)
ns.Listen("BAG_UPDATE_DELAYED", function()
    QuestItems:Refresh()
    -- the buy-back list catches up a moment after the bags
    if merchantOpen then C_Timer.After(0.3, checkSold) end
end)
ns.Listen("MERCHANT_SHOW", function()
    merchantOpen = true
    carried = countCarried()
    QuestItems:Refresh()
end)
ns.Listen("MERCHANT_CLOSED", function()
    merchantOpen = false
    StaticPopup_Hide("WOMBATLOG_SELL_QUEST_ITEM")
    StaticPopup_Hide("WOMBATLOG_BUYBACK_QUEST_ITEM")
    QuestItems:Refresh()
end)
ns.Listen("PLAYER_REGEN_DISABLED", function() QuestItems:Refresh() end)
