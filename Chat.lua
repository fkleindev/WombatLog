local ADDON, ns = ...
local Chat = {}
ns.Chat = Chat
local L = ns.L
local Safe, isSecret = ns.Safe, ns.IsSecret

-- The game's chat windows in WombatLog's look: a rounded panel with border and
-- shadow behind each window, flat tabs with a mark under the active one, the input
-- box below in our look (its border in the color of the channel you type in), and
-- the game's buttons replaced by one menu button and a jump to the newest line.
-- Messages can get short channel names, a timestamp, the sender's level, clickable
-- web links and your name highlighted; whispers can play a sound. Panel and text
-- fade when nothing happens.
--
-- The windows stay the game's (tabs, channels, settings, the combat log): only
-- their look changes, and switching off gives it back.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local GRADIENT = MEDIA .. "Gradient"
local CHEVRON = MEDIA .. "Chevron"
local LINES = MEDIA .. "Lines"
local TAB_H = 24             -- px of the panel above a window, for its tabs
local SHADOW = 12

local function cfg() return ns.db.chat end
local function tint(t, c, a) t:SetVertexColor(c[1], c[2], c[3], a or 1) end
local function tintAll(list, c, a) for _, t in ipairs(list) do tint(t, c, a) end end

local function call(fn, ...)
    if not fn then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return select(2, unpack(r))
end

---------------------------------------------------------------------------
-- Keeping the game's art invisible
---------------------------------------------------------------------------

local hidden = {}            -- texture -> true

-- The game shows these textures again on mouseover (by alpha, by showing them, or
-- with a fade animation): hidden and see-through, they stay away.
local function keepHidden(t)
    if not t or hidden[t] then return end
    hidden[t] = t:IsShown() and "shown" or "hidden"
    t.wlHidden = true
    t:SetAlpha(0)
    t:Hide()
    if not t.wlHideHook then
        t.wlHideHook = true
        hooksecurefunc(t, "SetAlpha", function(self, a)
            if self.wlHidden and a ~= 0 then self:SetAlpha(0) end
        end)
        hooksecurefunc(t, "Show", function(self) if self.wlHidden then self:Hide() end end)
        hooksecurefunc(t, "SetShown", function(self, on) if self.wlHidden and on then self:Hide() end end)
    end
end

local function unhideAll()
    for t, was in pairs(hidden) do
        t.wlHidden = nil
        t:SetAlpha(1)
        t:SetShown(was == "shown")
    end
    wipe(hidden)
end

-- Every texture of f that isn't ours (and isn't one of keep).
local function hideTextures(f, keep)
    for _, r in ipairs({ f:GetRegions() }) do
        if r.IsObjectType and r:IsObjectType("Texture") and not r.wlOurs and not (keep and keep[r]) then
            keepHidden(r)
        end
    end
end

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------

local function chatFrames()
    local list = {}
    if CHAT_FRAMES then
        for _, name in ipairs(CHAT_FRAMES) do
            local f = _G[name]
            if f then list[#list + 1] = f end
        end
    else
        for i = 1, NUM_CHAT_WINDOWS or 10 do
            local f = _G["ChatFrame" .. i]
            if f then list[#list + 1] = f end
        end
    end
    return list
end

local function isCombatLog(f)
    return (COMBATLOG and f == COMBATLOG) or (IsCombatLog and call(IsCombatLog, f)) or false
end

local function tabOf(f) return _G[f:GetName() .. "Tab"] end
local function editBoxOf(f) return f.editBox or _G[f:GetName() .. "EditBox"] end

local function ours(t)
    t.wlOurs = true
    return t
end

-- A frame of our own just under owner (same strata, one level lower), shown with
-- it. Our art lives there rather than on the game's frames: the game goes over all
-- of a chat window's textures on mouseover and would recolor ours.
local function underlay(owner)
    local u = CreateFrame("Frame", nil, UIParent)
    u.owner = owner
    u.wlOn = true
    owner:HookScript("OnShow", function() if u.wlOn then u:Show() end end)
    owner:HookScript("OnHide", function() u:Hide() end)
    return u
end

local function placeUnderlay(u)
    local owner = u.owner
    u:SetFrameStrata(owner:GetFrameStrata())
    u:SetFrameLevel(math.max(0, owner:GetFrameLevel() - 1))
    u:SetShown(u.wlOn and owner:IsVisible())
end

-- The panel: placed around a box that reaches past the window by the padding and
-- the tab row.
local function newPanel(f)
    local B = ns.BlizzardUI
    local p = {}
    p.box = CreateFrame("Frame", nil, f)
    p.under = underlay(f)
    local u = p.under
    -- the shadow only outside the panel: soft strips along its edges, a quarter of
    -- the glow at each corner (a full glow behind it would darken the whole panel)
    p.shadows = {}
    for i = 1, 8 do
        local t = ours(u:CreateTexture(nil, "BACKGROUND", nil, -8))
        t:SetTexture(i <= 4 and GRADIENT or GLOW)
        p.shadows[i] = t
    end
    p.strips = B.NewStrips(u, "BACKGROUND", -7)
    p.corners = B.NewRoundRect(u, "BACKGROUND", -7)
    p.bg = B.NewRoundRect(u, "BACKGROUND", -6)
    for _, list in ipairs({ p.strips, p.corners, p.bg }) do
        for _, t in ipairs(list) do ours(t) end
    end
    -- jump to the newest line, while scrolled up
    p.down = CreateFrame("Button", nil, p.box)
    p.down:SetSize(18, 18)
    p.down.icon = p.down:CreateTexture(nil, "ARTWORK")
    p.down.icon:SetAllPoints()
    p.down.icon:SetTexture(CHEVRON)
    p.down.icon:SetVertexColor(1, 0.82, 0.2)
    p.down:SetScript("OnClick", function() f:ScrollToBottom() end)
    p.down:Hide()
    -- the menu
    p.menu = CreateFrame("Button", nil, p.box)
    p.menu:SetSize(16, 16)
    p.menu.icon = p.menu:CreateTexture(nil, "ARTWORK")
    p.menu.icon:SetAllPoints()
    p.menu.icon:SetTexture(LINES)
    p.menu.icon:SetVertexColor(0.8, 0.8, 0.8)
    p.menu:SetScript("OnClick", function(self) Chat:ToggleMenu(self, f) end)
    p.menu:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 0.82, 0.2) end)
    p.menu:SetScript("OnLeave", function(self) self.icon:SetVertexColor(0.8, 0.8, 0.8) end)
    p.alpha = 1
    return p
end

-- Gradient.tga fades from left (opaque) to right; turned so it fades outward.
local function layoutShadow(list, box, on, opacity)
    local S = SHADOW
    local top, bottom, left, right, tl, tr, bl, br = unpack(list)
    for _, t in ipairs(list) do
        t:ClearAllPoints()
        t:SetShown(on)
        t:SetVertexColor(0, 0, 0, opacity)
    end
    top:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, S)
    top:SetTexCoord(1, 0, 0, 0, 1, 1, 0, 1)
    bottom:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, -S)
    bottom:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
    left:SetPoint("TOPRIGHT", box, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", -S, 0)
    left:SetTexCoord(1, 0, 1, 1, 0, 0, 0, 1)
    right:SetPoint("TOPLEFT", box, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", S, 0)
    right:SetTexCoord(0, 1, 0, 1)
    for _, c in ipairs({ tl, tr, bl, br }) do c:SetSize(S, S) end
    tl:SetPoint("BOTTOMRIGHT", box, "TOPLEFT", 0, 0)
    tl:SetTexCoord(0, 0.5, 0, 0.5)
    tr:SetPoint("BOTTOMLEFT", box, "TOPRIGHT", 0, 0)
    tr:SetTexCoord(0.5, 1, 0, 0.5)
    bl:SetPoint("TOPRIGHT", box, "BOTTOMLEFT", 0, 0)
    bl:SetTexCoord(0, 0.5, 0.5, 1)
    br:SetPoint("TOPLEFT", box, "BOTTOMRIGHT", 0, 0)
    br:SetTexCoord(0.5, 1, 0.5, 1)
end

local function panelTextures(p)
    local list = {}
    for _, t in ipairs(p.shadows) do list[#list + 1] = t end
    for _, l in ipairs({ p.strips, p.corners, p.bg }) do
        for _, t in ipairs(l) do list[#list + 1] = t end
    end
    return list
end

local function layoutPanel(f)
    local C, B, p = cfg(), ns.BlizzardUI, f.wlPanel
    local pad = C.padding
    p.under.wlOn = true
    placeUnderlay(p.under)
    p.box:ClearAllPoints()
    p.box:SetPoint("TOPLEFT", f, "TOPLEFT", -pad, pad + TAB_H)
    p.box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", pad, -pad)
    local b = C.border and C.borderSize or 0
    local r = C.radius > 0 and math.max(C.radius, b) or 0
    B.LayoutStrips(p.strips, p.box, b, r)
    B.LayoutRoundRect(p.corners, p.box, 0, r)
    for i = 1, 3 do p.corners[i]:Hide() end
    for _, t in ipairs(p.strips) do t:SetShown(b > 0) end
    for i = 4, 7 do p.corners[i]:SetShown(b > 0 and r > 0) end
    local edge = {}
    for _, t in ipairs(p.strips) do edge[#edge + 1] = t end
    for i = 4, 7 do edge[#edge + 1] = p.corners[i] end
    tintAll(edge, C.borderColor, C.borderOpacity)
    p.bg[1]:Show()
    B.LayoutRoundRect(p.bg, p.box, b, math.max(0, r - b))
    tintAll(p.bg, C.bgColor, C.bgOpacity)
    layoutShadow(p.shadows, p.box, C.shadow, C.shadowOpacity)
    p.down:ClearAllPoints()
    p.down:SetPoint("BOTTOMRIGHT", p.box, "BOTTOMRIGHT", -4, 4)
    p.menu:ClearAllPoints()
    p.menu:SetPoint("TOPRIGHT", p.box, "TOPRIGHT", -6, -4)
    p.menu:SetShown(C.hideButtons)
    for _, t in ipairs(panelTextures(p)) do t:Show() end
    for _, t in ipairs(p.shadows) do t:SetShown(C.shadow) end
    for i = 1, 3 do p.corners[i]:Hide() end
    for _, t in ipairs(p.strips) do t:SetShown(b > 0) end
    for i = 4, 7 do p.corners[i]:SetShown(b > 0 and r > 0) end
end

local function setPanelAlpha(f, a)
    local p = f.wlPanel
    if not p then return end
    p.alpha = a
    -- the whole frame fades: a texture's own alpha is its color's (the opacity you set)
    p.under:SetAlpha(a)
    p.menu:SetAlpha(a)
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

local function glowOf(tab) return tab.glow or _G[tab:GetName() .. "Glow"] end

local function textOf(tab)
    return tab.Text or _G[tab:GetName() .. "Text"] or (tab.GetFontString and tab:GetFontString())
end

local function styleTab(tab, selected)
    local C = cfg()
    if not tab.wlLine then
        tab.wlLine = ours(tab:CreateTexture(nil, "OVERLAY"))
        tab.wlLine:SetTexture("Interface\\Buttons\\WHITE8X8")
        tab.wlLine:SetHeight(2)
        tab.wlLine:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 6, 2)
        tab.wlLine:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -6, 2)
        tab.wlHover = ours(tab:CreateTexture(nil, "HIGHLIGHT"))
        tab.wlHover:SetTexture("Interface\\Buttons\\WHITE8X8")
        tab.wlHover:SetPoint("TOPLEFT", tab, "TOPLEFT", 4, -6)
        tab.wlHover:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -4, 2)
        tab.wlHover:SetVertexColor(1, 1, 1, 0.06)
    end
    local keep = {}
    local glow = glowOf(tab)
    if glow then keep[glow] = true end
    for _, k in ipairs({ "conversationIcon", "ConversationIcon" }) do
        if tab[k] then keep[tab[k]] = true end
    end
    hideTextures(tab, keep)
    if selected == nil then selected = tab.wlSelected end
    tab.wlSelected = selected
    tab.wlLine:SetShown(selected and true or false)
    tint(tab.wlLine, C.accentColor, 1)
    tab.wlHover:Show()
    local text = textOf(tab)
    if text then
        if selected then
            text:SetTextColor(1, 1, 1)
        else
            text:SetTextColor(0.65, 0.65, 0.65)
        end
    end
    if glow then tint(glow, C.accentColor, 1) end
end

local function unstyleTab(tab)
    if tab.wlLine then
        tab.wlLine:Hide()
        tab.wlHover:Hide()
    end
end

local function selectedIn(f)
    if f.isDocked and GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow then
        return call(FCFDock_GetSelectedWindow, GENERAL_CHAT_DOCK) == f
    end
    return true
end

---------------------------------------------------------------------------
-- The input box
---------------------------------------------------------------------------

local function chatColor(box)
    local kind = box.GetAttribute and box:GetAttribute("chatType")
    if not kind then return nil end
    if kind == "CHANNEL" then
        local n = box:GetAttribute("channelTarget")
        kind = n and ("CHANNEL" .. n) or kind
    end
    local info = ChatTypeInfo and ChatTypeInfo[kind]
    if info and info.r then return { info.r, info.g, info.b } end
end

local function styleEditBox(f)
    local C, B = cfg(), ns.BlizzardUI
    local box = editBoxOf(f)
    if not box then return end
    if not box.wlBack then
        local u = underlay(box)
        box.wlUnder = u
        box.wlBack = {
            strips = B.NewStrips(u, "BACKGROUND", -7),
            corners = B.NewRoundRect(u, "BACKGROUND", -7),
            bg = B.NewRoundRect(u, "BACKGROUND", -6),
        }
        for _, l in pairs(box.wlBack) do
            for _, t in ipairs(l) do ours(t) end
        end
    end
    box.wlUnder.wlOn = true
    placeUnderlay(box.wlUnder)
    hideTextures(box)
    local name = box:GetName()
    for _, k in ipairs({ "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }) do
        keepHidden(name and _G[name .. k])
    end
    for _, k in ipairs({ "focusLeft", "focusMid", "focusRight", "Left", "Mid", "Right" }) do
        if type(box[k]) == "table" and box[k].SetAlpha then keepHidden(box[k]) end
    end
    local k = box.wlBack
    local b = C.border and C.borderSize or 0
    local r = C.radius > 0 and math.max(C.radius, b) or 0
    B.LayoutStrips(k.strips, box, math.max(1, b), r)
    B.LayoutRoundRect(k.corners, box, 0, r)
    for i = 1, 3 do k.corners[i]:Hide() end
    for _, t in ipairs(k.strips) do t:Show() end
    for i = 4, 7 do k.corners[i]:SetShown(r > 0) end
    k.bg[1]:Show()
    B.LayoutRoundRect(k.bg, box, math.max(1, b), math.max(0, r - b))
    tintAll(k.bg, C.bgColor, math.max(C.bgOpacity, 0.75))
    Chat.TintEditBox(box)
    -- below the panel, as wide as it
    local p = f.wlPanel
    ns.Borrow.Remember(box)
    ns.Borrow.KeepPlaced(box, function(e)
        e:ClearAllPoints()
        e:SetPoint("TOPLEFT", p.box, "BOTTOMLEFT", 0, -4)
        e:SetPoint("TOPRIGHT", p.box, "BOTTOMRIGHT", 0, -4)
    end)
    if C.historyKeys and box.SetAltArrowKeyMode then box:SetAltArrowKeyMode(false) end
end

function Chat.TintEditBox(box)
    local k = box and box.wlBack
    if not k or not Chat.active then return end
    local C = cfg()
    local c = chatColor(box) or C.borderColor
    local edge = {}
    for _, t in ipairs(k.strips) do edge[#edge + 1] = t end
    for i = 4, 7 do edge[#edge + 1] = k.corners[i] end
    tintAll(edge, c, 1)
end

local function unstyleEditBox(f)
    local box = editBoxOf(f)
    if not box then return end
    if box.wlUnder then
        box.wlUnder.wlOn = false
        box.wlUnder:Hide()
    end
    ns.Borrow.GiveBack(box)
    if box.SetAltArrowKeyMode then box:SetAltArrowKeyMode(true) end
end

---------------------------------------------------------------------------
-- The game's buttons
---------------------------------------------------------------------------

local BUTTONS = {
    "ChatFrameMenuButton", "ChatFrameChannelButton", "ChatFrameToggleVoiceDeafenButton",
    "ChatFrameToggleVoiceMuteButton", "QuickJoinToastButton", "FriendsMicroButton", "TextToSpeechButtonFrame",
    "ChatMenuButton", "ChatFrameMenuButtonFrame",
}

local function hideButtons(f)
    local name = f:GetName()
    ns.Borrow.Tuck(_G[name .. "ButtonFrame"])
    ns.Borrow.Tuck(f.ScrollBar)
    ns.Borrow.Tuck(f.ScrollToBottomButton)
    ns.Borrow.Tuck(_G[name .. "ButtonFrameBottomButton"])
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

-- Levels of players the game told us about: your group, guild, friends, whoever
-- you targeted or hovered.
local levels = {}

local function short(name)
    if not name then return nil end
    if Ambiguate then
        local ok, n = pcall(Ambiguate, name, "none")
        if ok and n then return n end
    end
    return (name:match("^([^%-]+)"))
end

local function learn(name, level)
    name, level = Safe(name), Safe(level)
    if type(name) ~= "string" or type(level) ~= "number" or level <= 0 then return end
    levels[short(name)] = level
end

local function learnUnit(unit)
    if not call(UnitIsPlayer, unit) then return end
    learn(call(UnitName, unit), call(UnitLevel, unit))
end

-- Short names of the group channels; numbered ones get their name's capitals.
local CHANNELS = {
    PARTY = "P", PARTY_LEADER = "PL", RAID = "R", RAID_LEADER = "RL", RAID_WARNING = "RW",
    GUILD = "Gu", OFFICER = "O", INSTANCE_CHAT = "I", INSTANCE_CHAT_LEADER = "IL",
    BATTLEGROUND = "BG", BATTLEGROUND_LEADER = "BGL",
}

local function shortChannel(id, shown)
    local key = id:match("([%u_]+)$")
    if key and CHANNELS[key] then return CHANNELS[key] end
    local num, name = shown:match("^(%d+)%.%s*(.+)$")
    if not num then return nil end
    name = name:gsub("%s+%-.*$", "")
    local caps = name:gsub("[^%u]", "")
    if caps == "" then caps = name:sub(1, 1):upper() end
    return caps
end

-- fn on the parts of text outside links (|H...|h[...]|h), links as they are
local function outsideLinks(text, fn)
    local out, pos = {}, 1
    while true do
        local s, e = text:find("|H.-|h.-|h", pos)
        if not s then break end
        out[#out + 1] = fn(text:sub(pos, s - 1))
        out[#out + 1] = text:sub(s, e)
        pos = e + 1
    end
    out[#out + 1] = fn(text:sub(pos))
    return table.concat(out)
end

local URL_PATTERNS = {
    "https?://[%w%-%._~:/%?#%[%]@!%$&'%*%+,;=%%]+",
    "www%.[%w%-]+%.[%w%-%._~:/%?#@!%$&'%*%+,;=%%]+",
}

local function linkURLs(seg)
    for _, pat in ipairs(URL_PATTERNS) do
        local out, pos = {}, 1
        while true do
            local s, e = seg:find(pat, pos)
            if not s then break end
            local url = seg:sub(s, e):gsub("[%.,;:!%?%)]+$", "")
            e = s + #url - 1
            out[#out + 1] = seg:sub(pos, s - 1)
            out[#out + 1] = "|cff4fb4ff|Hwlurl:" .. url .. "|h[" .. url .. "]|h|r"
            pos = e + 1
        end
        out[#out + 1] = seg:sub(pos)
        seg = table.concat(out)
        if seg:find("|Hwlurl:") then return seg end
    end
    return seg
end

local mentioned = false

local function highlightName(seg)
    local me = Chat.myName
    if not me or me == "" then return seg end
    local lower, low = seg:lower(), me:lower()
    local out, pos = {}, 1
    while true do
        local s, e = lower:find(low, pos, true)
        if not s then break end
        local before, after = lower:sub(s - 1, s - 1), lower:sub(e + 1, e + 1)
        if not before:find("[%w]") and not after:find("[%w]") then
            local c = cfg().mentionColor
            out[#out + 1] = seg:sub(pos, s - 1)
            out[#out + 1] = ("|cff%02x%02x%02x%s|r"):format(c[1] * 255, c[2] * 255, c[3] * 255, seg:sub(s, e))
            mentioned = true
        else
            out[#out + 1] = seg:sub(pos, e)
        end
        pos = e + 1
    end
    out[#out + 1] = seg:sub(pos)
    return table.concat(out)
end

local function levelColor(level)
    local get = GetQuestDifficultyColor or GetDifficultyColor
    local c = get and call(get, level)
    if c and c.r then return ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "c0c0c0"
end

local function gameTimestamps()
    local v = GetCVar and call(GetCVar, "showTimestamps")
    return v and v ~= "none" and v ~= ""
end

-- A message on its way into a window, in our words.
local function transform(f, text)
    local C = cfg()
    if C.shortChannels then
        text = text:gsub("(|Hchannel:([^|]-)|h)%[(.-)%](|h)", function(open, id, shown, close)
            local s = shortChannel(id, shown)
            return s and (open .. "[" .. s .. "]" .. close) or nil
        end)
    end
    if C.level then
        text = text:gsub("(|Hplayer:([^|]-)|h)%[(.-)%](|h)", function(open, data, shown, close)
            local level = levels[short(data:match("^([^:]+)"))]
            if not level then return nil end
            return open .. "[" .. shown .. "|cff" .. levelColor(level) .. ":" .. level .. "|r]" .. close
        end)
    end
    mentioned = false
    if C.urls or C.mention then
        text = outsideLinks(text, function(seg)
            if C.urls then seg = linkURLs(seg) end
            if C.mention then seg = outsideLinks(seg, highlightName) end
            return seg
        end)
    end
    if mentioned and C.mentionSound and (GetTime() - (Chat.lastMentionSound or 0)) > 2 then
        Chat.lastMentionSound = GetTime()
        ns.Alerts.PlaySound(C.mentionSoundChoice, "Master")
    end
    if C.timestamps and not gameTimestamps() then
        text = "|cff808080" .. date(C.timeFormat) .. "|r " .. text
    end
    return text
end

local function wrapAddMessage(f)
    if f.wlAddMessage then return end
    local orig = f.AddMessage
    f.wlAddMessage = orig
    f.AddMessage = function(self, text, ...)
        if Chat.active then
            self.wlActivity = GetTime()
            if type(text) == "string" and not isSecret(text) and not isCombatLog(self) then
                local ok, out = pcall(transform, self, text)
                if ok and out then text = out end
            end
        end
        return orig(self, text, ...)
    end
end

---------------------------------------------------------------------------
-- Copying: a web link, the whole window
---------------------------------------------------------------------------

local function plain(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    return text
end

local function copyPanel(name, w, h, multi)
    local B = ns.BlizzardUI
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    local bg = B.NewRoundRect(f, "BACKGROUND", -6)
    B.LayoutRoundRect(bg, f, 0, 6)
    tintAll(bg, { 0.05, 0.05, 0.07 }, 0.95)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -10)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    local box = CreateFrame("EditBox", nil, f)
    box:SetFontObject(ChatFontNormal)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function() f:Hide() end)
    if multi then
        local sf = CreateFrame("ScrollFrame", nil, f)
        sf:SetPoint("TOPLEFT", 12, -32)
        sf:SetPoint("BOTTOMRIGHT", -12, 12)
        box:SetMultiLine(true)
        box:SetWidth(w - 24)
        sf:SetScrollChild(box)
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local v = self:GetVerticalScroll() - delta * 40
            self:SetVerticalScroll(math.max(0, math.min(v, self:GetVerticalScrollRange())))
        end)
        f.scroll = sf
    else
        box:SetPoint("TOPLEFT", 12, -32)
        box:SetPoint("BOTTOMRIGHT", -12, 12)
        box:SetScript("OnEnterPressed", function() f:Hide() end)
    end
    f.box = box
    f:Hide()
    tinsert(UISpecialFrames, name)
    return f
end

function Chat:ShowURL(url)
    if not self.urlFrame then self.urlFrame = copyPanel("WombatLogChatURL", 420, 64) end
    local f = self.urlFrame
    f.title:SetText(L["Press Ctrl+C to copy the link"])
    f:Show()
    f.box:SetText(url)
    f.box:SetFocus()
    f.box:HighlightText()
end

function Chat:CopyWindow(frame)
    if not self.copyFrame then self.copyFrame = copyPanel("WombatLogChatCopy", 560, 380, true) end
    local f = self.copyFrame
    local lines = {}
    local n = frame.GetNumMessages and frame:GetNumMessages() or 0
    for i = 1, n do
        local text = call(frame.GetMessageInfo, frame, i)
        if type(text) == "string" and not isSecret(text) then lines[#lines + 1] = plain(text) end
    end
    f.title:SetText(L["Chat text - Ctrl+A, Ctrl+C to copy"])
    f:Show()
    f.box:SetText(table.concat(lines, "\n"))
    f.box:SetFocus()
    f.box:HighlightText()
    C_Timer.After(0, function() f.scroll:SetVerticalScroll(f.scroll:GetVerticalScrollRange()) end)
end

---------------------------------------------------------------------------
-- The menu
---------------------------------------------------------------------------

function Chat:ToggleMenu(anchor, frame)
    local m = self.menuFrame
    if not m then
        m = CreateFrame("Frame", nil, UIParent)
        m:SetFrameStrata("DIALOG")
        m:SetClampedToScreen(true)
        local bg = ns.BlizzardUI.NewRoundRect(m, "BACKGROUND", -6)
        m.bg = bg
        m.buttons = {}
        m:Hide()
        m:SetScript("OnUpdate", function(self, elapsed)
            if self:IsMouseOver() or (self.anchor and self.anchor:IsMouseOver()) then
                self.idle = 0
            else
                self.idle = (self.idle or 0) + elapsed
                if self.idle > 1.5 then self:Hide() end
            end
        end)
        self.menuFrame = m
    end
    if m:IsShown() and m.anchor == anchor then
        m:Hide()
        return
    end
    local items = {
        { L["Copy chat"], function() Chat:CopyWindow(frame) end },
    }
    if ToggleFriendsFrame then items[#items + 1] = { L["Social"], function() ToggleFriendsFrame() end } end
    if ToggleChannelFrame then items[#items + 1] = { L["Channels"], function() ToggleChannelFrame() end } end
    -- the game's emote and language menu, where it's a frame of its own (Classic)
    if ChatMenu and ChatMenu.Show then
        items[#items + 1] = { L["Emotes and languages"], function()
            ChatMenu:ClearAllPoints()
            ChatMenu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
            ChatMenu:Show()
        end }
    end
    local w = 150
    for i, it in ipairs(items) do
        local b = m.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, m)
            b:SetHeight(20)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 8, 0)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.08)
            m.buttons[i] = b
        end
        b:SetPoint("TOPLEFT", m, "TOPLEFT", 4, -4 - (i - 1) * 20)
        b:SetPoint("RIGHT", m, "RIGHT", -4, 0)
        b.text:SetText(it[1])
        b:SetScript("OnClick", function()
            m:Hide()
            it[2]()
        end)
        b:Show()
    end
    for i = #items + 1, #m.buttons do m.buttons[i]:Hide() end
    m:SetSize(w, 8 + #items * 20)
    ns.BlizzardUI.LayoutRoundRect(m.bg, m, 0, 5)
    tintAll(m.bg, { 0.05, 0.05, 0.07 }, 0.95)
    m:ClearAllPoints()
    m:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
    m.anchor, m.idle = anchor, 0
    m:Show()
end

---------------------------------------------------------------------------
-- Styling and restoring
---------------------------------------------------------------------------

local styled = {}            -- window -> true

local function style(f)
    local C = cfg()
    if not f.wlPanel then f.wlPanel = newPanel(f) end
    styled[f] = true
    -- the game's background goes, ours comes; newer clients keep parts of it in
    -- frames of their own on the window
    hideTextures(f)
    local name = f:GetName()
    for _, c in ipairs({ f:GetChildren() }) do
        if c ~= f.wlPanel.box and c ~= editBoxOf(f) and not c:IsMouseEnabled() and not c:IsObjectType("Button") then
            hideTextures(c)
        end
    end
    for _, k in ipairs(CHAT_FRAME_TEXTURES or {}) do
        local t = _G[name .. k]
        if t and t.IsObjectType and t:IsObjectType("Texture") then keepHidden(t) end
    end
    layoutPanel(f)
    local tab = tabOf(f)
    if tab and C.tabs then styleTab(tab, selectedIn(f)) end
    if C.editBox then styleEditBox(f) end
    if C.hideButtons then hideButtons(f) end
    -- fading text
    if f.wlTimeVisible == nil and f.GetTimeVisible then
        f.wlTimeVisible = f:GetTimeVisible()
        f.wlFading = f.GetFading and f:GetFading()
    end
    if f.SetFading then
        f:SetFading(C.fade)
        if C.fade and f.SetTimeVisible then f:SetTimeVisible(C.fadeTime) end
    end
    wrapAddMessage(f)
    f.wlActivity = GetTime()
end

local function unstyle(f)
    local p = f.wlPanel
    if p then
        p.under.wlOn = false
        p.under:Hide()
        p.down:Hide()
        p.menu:Hide()
    end
    local tab = tabOf(f)
    if tab then unstyleTab(tab) end
    unstyleEditBox(f)
    if f.wlTimeVisible and f.SetTimeVisible then f:SetTimeVisible(f.wlTimeVisible) end
    if f.wlFading ~= nil and f.SetFading then f:SetFading(f.wlFading) end
    f.wlTimeVisible, f.wlFading = nil, nil
    styled[f] = nil
end

-- Names in class colors: the game does it per kind of message when asked.
local colorSaved

local function setClassColors(on)
    if not ChatTypeInfo then return end
    if on then
        colorSaved = colorSaved or {}
        for kind, info in pairs(ChatTypeInfo) do
            if type(info) == "table" then
                if colorSaved[kind] == nil then colorSaved[kind] = info.colorNameByClass or false end
                info.colorNameByClass = true
            end
        end
    elseif colorSaved then
        for kind, was in pairs(colorSaved) do
            if ChatTypeInfo[kind] then ChatTypeInfo[kind].colorNameByClass = was or nil end
        end
        colorSaved = nil
    end
end

function Chat:StyleAll()
    for _, f in ipairs(chatFrames()) do style(f) end
end

function Chat:Apply()
    if not (ns.db and self.ready) then return end
    local C = cfg()
    if C.enabled then
        self.active = true
        if not C.tabs then
            for _, f in ipairs(chatFrames()) do
                local tab = tabOf(f)
                if tab then unstyleTab(tab) end
            end
        end
        if not C.editBox then
            for _, f in ipairs(chatFrames()) do unstyleEditBox(f) end
        end
        -- textures and buttons hidden before come back, the wanted ones go again
        unhideAll()
        for _, f in ipairs(chatFrames()) do
            if not C.hideButtons then
                for _, part in ipairs({ _G[f:GetName() .. "ButtonFrame"], f.ScrollBar, f.ScrollToBottomButton }) do
                    if part then ns.Borrow.GiveBack(part) end
                end
            end
        end
        if C.hideButtons then
            for _, n in ipairs(BUTTONS) do ns.Borrow.Tuck(_G[n]) end
        else
            for _, n in ipairs(BUTTONS) do if _G[n] then ns.Borrow.GiveBack(_G[n]) end end
        end
        self:StyleAll()
        setClassColors(C.classColors)
    elseif self.active then
        self.active = false
        for f in pairs(styled) do unstyle(f) end
        unhideAll()
        for _, f in ipairs(chatFrames()) do
            for _, part in ipairs({ _G[f:GetName() .. "ButtonFrame"], f.ScrollBar, f.ScrollToBottomButton }) do
                if part then ns.Borrow.GiveBack(part) end
            end
        end
        for _, n in ipairs(BUTTONS) do if _G[n] then ns.Borrow.GiveBack(_G[n]) end end
        setClassColors(false)
    end
end

---------------------------------------------------------------------------
-- Fading and the jump button
---------------------------------------------------------------------------

local function busy(f)
    local p = f.wlPanel
    if p and p.box:IsMouseOver() then return true end
    local box = editBoxOf(f)
    if box and box:IsShown() and box:HasFocus() then return true end
    local tab = tabOf(f)
    if tab and tab:IsMouseOver() then return true end
    return GetTime() - (f.wlActivity or 0) < cfg().fadeTime
end

local driver = CreateFrame("Frame")
local tick = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if not Chat.active then return end
    tick = tick + elapsed
    if tick < 0.05 then return end
    local step = tick
    tick = 0
    local C = cfg()
    for f in pairs(styled) do
        -- our art follows the window's and the input box's layer
        if f.wlPanel then placeUnderlay(f.wlPanel.under) end
        local box = editBoxOf(f)
        if box and box.wlUnder then placeUnderlay(box.wlUnder) end
        if f:IsShown() and f.wlPanel then
            local want = (not C.fade or busy(f)) and 1 or C.fadeAlpha
            local p = f.wlPanel
            if p.alpha ~= want then
                local speed = step / 0.6
                local a = p.alpha < want and math.min(want, p.alpha + speed) or math.max(want, p.alpha - speed)
                setPanelAlpha(f, a)
            end
            local atBottom = not f.AtBottom or f:AtBottom()
            p.down:SetShown(not atBottom)
        end
    end
end)

---------------------------------------------------------------------------
-- Init and events
---------------------------------------------------------------------------

-- /wl debug: what's left of the game's art on the first window
function Chat:Debug()
    if not self.active then
        ns.Print("chat: off")
        return
    end
    local f = ChatFrame1
    local shown = {}
    local function look(frame, label)
        for _, r in ipairs({ frame:GetRegions() }) do
            if r.IsObjectType and r:IsObjectType("Texture") and not r.wlOurs and r:IsShown() and r:GetAlpha() > 0 then
                shown[#shown + 1] = label .. ":" .. tostring(r:GetName() or r:GetDebugName() or "?")
            end
        end
    end
    look(f, "window")
    for _, c in ipairs({ f:GetChildren() }) do
        if c:IsShown() then look(c, tostring(c:GetName() or c:GetDebugName() or "child")) end
    end
    ns.Print(("chat: %d of the game's textures still showing%s"):format(#shown,
        #shown > 0 and (": " .. table.concat(shown, ", ", 1, math.min(#shown, 8))) or ""))
    local box = editBoxOf(f)
    local k = box and box.wlBack
    local tab = tabOf(f)
    ns.Print(("chat: input box %s, ours %s, its background %s; tab %s, its text %s"):format(
        box and (box:GetName() or "?") or "none", k and "yes" or "no",
        k and (k.bg[1]:IsShown() and ("shown, alpha " .. string.format("%.2f", k.bg[1]:GetAlpha() * box:GetEffectiveAlpha())) or "hidden") or "-",
        tab and (tab:IsShown() and string.format("shown, alpha %.2f", tab:GetEffectiveAlpha()) or "hidden") or "none",
        tab and textOf(tab) and (textOf(tab):GetText() or "empty") or "none"))
end

function Chat:Init()
    self.ready = true
    self.myName = Safe(UnitName("player"))
    -- web links open a box to copy them from
    if not self.itemRefWrapped and SetItemRef then
        self.itemRefWrapped = true
        local orig = SetItemRef
        SetItemRef = function(link, ...)
            if type(link) == "string" and link:sub(1, 6) == "wlurl:" then
                Chat:ShowURL(link:sub(7))
                return
            end
            return orig(link, ...)
        end
    end
    -- the game restyles tabs and the input box: ours on top again
    if FCFTab_UpdateColors then
        hooksecurefunc("FCFTab_UpdateColors", function(tab, selected)
            if Chat.active and cfg().tabs and tab then styleTab(tab, selected) end
        end)
    end
    if ChatEdit_UpdateHeader then
        hooksecurefunc("ChatEdit_UpdateHeader", function(box) Chat.TintEditBox(box) end)
    end
    for _, fn in ipairs({ "FCF_OpenTemporaryWindow", "FCF_OpenNewWindow", "FCF_DockFrame", "FCF_UnDockFrame",
                          "FCF_SetWindowName", "FCF_RestorePositionAndDimensions" }) do
        if type(_G[fn]) == "function" then
            hooksecurefunc(fn, function()
                if Chat.active then C_Timer.After(0, function() Chat:StyleAll() end) end
            end)
        end
    end
    self:Apply()
end

-- whispers: a sound
local function onWhisper()
    local C = ns.db and cfg()
    if not (Chat.active and C.whisperSound) then return end
    if GetTime() - (Chat.lastWhisper or 0) < 1 then return end
    Chat.lastWhisper = GetTime()
    ns.Alerts.PlaySound(C.whisperSoundChoice, "Master")
end
ns.Listen("CHAT_MSG_WHISPER", onWhisper)
ns.Listen("CHAT_MSG_BN_WHISPER", onWhisper)

-- levels of players around you
local function learnGroup()
    local n = call(GetNumGroupMembers) or 0
    local raid = call(IsInRaid)
    for i = 1, n do learnUnit(raid and ("raid" .. i) or ("party" .. i)) end
end
ns.Listen("GROUP_ROSTER_UPDATE", learnGroup)
ns.Listen("PLAYER_TARGET_CHANGED", function() learnUnit("target") end)
ns.Listen("UPDATE_MOUSEOVER_UNIT", function() learnUnit("mouseover") end)
ns.Listen("GUILD_ROSTER_UPDATE", function()
    for i = 1, call(GetNumGuildMembers) or 0 do
        local name, _, _, level = call(GetGuildRosterInfo, i)
        learn(name, level)
    end
end)
ns.Listen("FRIENDLIST_UPDATE", function()
    local F = C_FriendList
    if not (F and F.GetNumFriends) then return end
    for i = 1, call(F.GetNumFriends) or 0 do
        local info = call(F.GetFriendInfoByIndex, i)
        if type(info) == "table" then learn(info.name, info.level) end
    end
end)
ns.Listen("PLAYER_ENTERING_WORLD", function()
    learnGroup()
    learnUnit("player")
    if Chat.active then C_Timer.After(1, function() Chat:StyleAll() end) end
end)
ns.Listen("UPDATE_CHAT_WINDOWS", function()
    if Chat.active then C_Timer.After(0, function() Chat:StyleAll() end) end
end)
