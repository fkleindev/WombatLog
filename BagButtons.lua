local ADDON, ns = ...
local BagButtons = {}
ns.BagButtons = BagButtons
local Safe = ns.Safe

-- The item buttons in the bags, for the features that draw on them (quest items, bag
-- slots). Each feature registers a function (button, bag, slot, link) that is called
-- for every bag button whenever it may show something else, and draws or hides its
-- own things there. bag and slot are where the item sits in your bags, nil when the
-- bag addon shows something else (another character's bags, a cached bank); link is
-- what the button shows, nil for an empty slot or when only bag and slot are known.
--
-- Covered: the game's own bags (single bags and the combined bag), Bagnon and the
-- other Wildpants bags, and AdiBags. Baganator only takes corner widgets, which each
-- feature registers itself (BagButtons.Baganator); Refresh asks it to redraw them.

local markers = {}            -- fn(button, bag, slot, link)
local addonButtons = {}       -- Bagnon and AdiBags buttons seen: button -> kind
local baganator = false       -- a feature registered a Baganator widget
local pending = false

function BagButtons.Register(fn)
    markers[#markers + 1] = fn
end

local function dispatch(button, bag, slot, link)
    link = Safe(link)
    for _, fn in ipairs(markers) do fn(button, bag, slot, link) end
end

local function blizzardButtons()
    local function frame(f)
        if not f or not f:IsShown() then return end
        if f.EnumerateValidItems then
            for _, b in f:EnumerateValidItems() do
                dispatch(b, b.GetBagID and b:GetBagID() or f:GetID(), b:GetID())
            end
        else
            local name = f:GetName()
            for j = 1, f.size or 0 do
                local b = name and _G[name .. "Item" .. j]
                if b then dispatch(b, f:GetID(), b:GetID()) end
            end
        end
    end
    frame(ContainerFrameCombinedBags)
    for i = 1, NUM_CONTAINER_FRAMES or 13 do frame(_G["ContainerFrame" .. i]) end
end

function BagButtons.Refresh()
    if pending then return end
    pending = true
    C_Timer.After(0, function()
        pending = false
        blizzardButtons()
        for b, kind in pairs(addonButtons) do
            if b:IsVisible() then
                if kind == "adibags" then
                    if b.bag then dispatch(b, b.bag, b.slot) end
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

-- Registers a Baganator corner widget; true when Baganator took it.
function BagButtons.Baganator(label, id, onUpdate, onCreate, opts)
    local API = Baganator and Baganator.API
    if not (API and API.RegisterCornerWidget) then return false end
    local ok = pcall(API.RegisterCornerWidget, label, id, onUpdate, onCreate, opts)
    if ok then baganator = true end
    return ok
end

-- Bag addons, once all addons are loaded. Each in a pcall: a newer version that
-- changed its insides only loses the marks, not the rest of the addon.
local function hookBagAddons()
    for _, name in ipairs({ "Bagnon", "Combuctor" }) do
        local A = _G[name]
        if type(A) == "table" and type(A.Item) == "table" and A.Item.Update then
            pcall(hooksecurefunc, A.Item, "Update", function(b)
                addonButtons[b] = "wildpants"
                local info = b.info
                local link = info and (info.hyperlink or info.link)
                local bag = b.GetBag and b:GetBag()
                if type(bag) ~= "number" then bag = nil end
                dispatch(b, bag, bag and b:GetID(), link)
            end)
        end
    end
    local AceEvent = LibStub and LibStub("AceEvent-3.0", true)
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    if AceEvent and loaded and loaded("AdiBags") then
        local listener = {}
        AceEvent:Embed(listener)
        listener:RegisterMessage("AdiBags_UpdateButton", function(_, b)
            if type(b) ~= "table" or not b.bag then return end
            addonButtons[b] = "adibags"
            dispatch(b, b.bag, b.slot)
        end)
    end
end

function BagButtons:Init()
    if ContainerFrame_Update then
        hooksecurefunc("ContainerFrame_Update", BagButtons.Refresh)
    end
    local frames = { ContainerFrameCombinedBags }
    for i = 1, NUM_CONTAINER_FRAMES or 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
    for _, f in pairs(frames) do
        if f.UpdateItems then hooksecurefunc(f, "UpdateItems", BagButtons.Refresh) end
        f:HookScript("OnShow", BagButtons.Refresh)
    end
end

ns.Listen("PLAYER_LOGIN", hookBagAddons)
ns.Listen("BAG_UPDATE_DELAYED", BagButtons.Refresh)
