local ADDON, ns = ...
local QuestTracker = {}
ns.QuestTracker = QuestTracker
local Safe, SafeTable = ns.Safe, ns.SafeTable
local L = ns.L
local XPBar = ns.XPBar

-- A modern list of the quests you watch, in place of the game's quest tracker: each
-- quest with its objectives and a bar for every count, the quest you follow on top and
-- marked. Quests and objectives come and go with a fade and a glide, progress fills
-- the bars and lights the objective up, a quest that gets done flashes.
--
--   Click            follow the quest (Retail: the arrow and waypoint; elsewhere
--                    WombatLog's own, kept per character, which the quest progress
--                    cards follow too)
--   Shift-click      open it in the quest log
--   Right-click      a menu: follow, open, share, fold, stop watching
--   The arrow        folds the quest to its title; the header folds the whole list
--
-- The compact view puts each quest on one line with one bar for all of it; only the
-- quest you follow shows its objectives. Retail also lists the world quests you watch
-- and the bonus objectives around you.
--
-- Quest items get buttons of their own beside the list. Item buttons are secure: the
-- game won't let them move or change in combat, and nothing they hang on may move
-- either. So they live on their own bar, placed next to the list out of combat; the
-- list itself stays free to fold and animate in a fight.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local CORNER = MEDIA .. "Corner"
local GLOW = MEDIA .. "Glow"
local CHEVRON = MEDIA .. "Chevron"
local LINES = MEDIA .. "Lines"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local DONE_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"
local PAD = 8
local RADIUS = 8
local GAP = 6             -- between two quests
local INDENT = 18         -- objectives under the title
local REFRESH_DELAY = 0.1 -- the log's events come in bursts: one read after them
local SETTLE = 4          -- seconds after logging in: progress isn't animated yet
local FADE_SPEED = 7      -- quests coming and going
local LEAVE_SPEED = 3     -- a quest turned in goes slower, so its flash shows
local MOVE_SPEED = 12     -- quests gliding to their place
local OPEN_SPEED = 11     -- folding and unfolding
local HOVER_SPEED = 12
local SLIDE = 10          -- px a new quest slides down while it fades in
local FLASH = 0.8         -- a changed objective's row flashes this long...
local LIT_TIME = 4        -- ...and stays lit this long
local DELTA_HOLD = 1.5    -- the "+1" stays this long, then fades
local DELTA_FADE = 0.5
local POP = 0.35          -- a check mark pops this long
local BURST_TIME = 1.1
local MAX_ITEMS = 8
local ITEM_POLL = 0.2     -- item cooldowns, range and counts
local SAMPLE_ID = -11
local FAIL_COLOR = { 1.00, 0.30, 0.25 }
local WARN_AT, ALERT_AT = 60, 15
local WARN_COLOR = { 1.00, 0.82, 0.18 }

local entries = {}        -- questID -> what is shown of it (also while it fades out)
local order = {}          -- the shown quests' IDs, top to bottom
local blockPool = {}
local itemButtons = {}
local refreshPending = false
local readyAt = math.huge -- progress animates from then on

local function cfg() return ns.db.questTracker end

local function ease(k) return k * k * (3 - 2 * k) end

local function approach(v, to, step, snap)
    local d = to - v
    if math.abs(d) <= (snap or 0.002) then return to end
    return v + d * math.min(1, step)
end

-- Per character: the quest WombatLog follows (clients without the game's own), the
-- quests folded up, and whether the whole list is folded.
local function char()
    local all = WombatLogDB and WombatLogDB.charData
    if not all or not ns.charKey then return { collapsed = {} } end
    all[ns.charKey] = all[ns.charKey] or {}
    local c = all[ns.charKey]
    c.questTracker = c.questTracker or {}
    c.questTracker.collapsed = c.questTracker.collapsed or {}
    return c.questTracker
end

---------------------------------------------------------------------------
-- Reading the quests
---------------------------------------------------------------------------

local hasSuperTrack = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.SetSuperTrackedQuestID

local function logIndex(id)
    if type(id) ~= "number" or id <= 0 then return nil end
    local i
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        i = Safe(C_QuestLog.GetLogIndexForQuestID(id))
    elseif GetQuestLogIndexByID then
        i = Safe(GetQuestLogIndexByID(id))
    end
    if type(i) == "number" and i > 0 then return i end
end

-- The quest's level, whether it is complete or failed, and whether it can be turned
-- in from the tracker (Retail).
local function questState(id, index)
    local level, complete, failed, auto
    if index and C_QuestLog and C_QuestLog.GetInfo then
        local info = SafeTable(C_QuestLog.GetInfo(index))
        if info then
            level, auto = Safe(info.level), Safe(info.isAutoComplete)
        end
    elseif index and GetQuestLogTitle then
        local _, lvl, _, _, _, done = GetQuestLogTitle(index)
        level, done = Safe(lvl), Safe(done)
        complete, failed = done == 1, done == -1
    end
    if C_QuestLog and C_QuestLog.IsComplete then
        complete = complete or Safe(C_QuestLog.IsComplete(id))
    end
    if C_QuestLog and C_QuestLog.IsFailed then
        failed = failed or Safe(C_QuestLog.IsFailed(id))
    end
    return level, complete and true or false, failed and true or false, auto and true or false
end

local function bonusTitle(id, fallback)
    local t
    if C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID then t = Safe((C_TaskQuest.GetQuestInfoByQuestID(id))) end
    if not t and C_QuestLog and C_QuestLog.GetTitleForQuestID then t = Safe((C_QuestLog.GetTitleForQuestID(id))) end
    return t or fallback
end

-- The quests watched in the game's tracker, in its order.
local function watchedQuests()
    local ids, seen = {}, {}
    local function add(id)
        id = Safe(id)
        if type(id) == "number" and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    if C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex then
        for i = 1, Safe(C_QuestLog.GetNumQuestWatches()) or 0 do add(C_QuestLog.GetQuestIDForQuestWatchIndex(i)) end
    elseif GetNumQuestWatches and GetQuestIndexForWatch then
        for i = 1, Safe(GetNumQuestWatches()) or 0 do
            local index = Safe(GetQuestIndexForWatch(i))
            if index then add((ns.QuestProgress.LogEntry(index))) end
        end
    end
    return ids, seen
end

-- Retail: the world quests you watch and the bonus objectives where you are.
local function bonusQuests(seen)
    local list = {}
    local function add(id, name)
        id = Safe(id)
        if type(id) == "number" and id > 0 and not seen[id] then
            seen[id] = true
            list[#list + 1] = { id = id, name = name }
        end
    end
    if C_QuestLog and C_QuestLog.GetNumWorldQuestWatches and C_QuestLog.GetQuestIDForWorldQuestWatchIndex then
        for i = 1, Safe(C_QuestLog.GetNumWorldQuestWatches()) or 0 do add(C_QuestLog.GetQuestIDForWorldQuestWatchIndex(i)) end
    end
    if GetTasksTable and GetTaskInfo then
        for _, id in ipairs(SafeTable(GetTasksTable()) or {}) do
            id = Safe(id)
            if id then
                local inArea, _, _, name = GetTaskInfo(id)
                if Safe(inArea) then add(id, Safe(name)) end
            end
        end
    end
    return list
end

-- The quest's item, which the log offers to use, or nil.
local function questItem(id, index, complete)
    if not (index and GetQuestLogSpecialItemInfo) then return nil end
    local link, icon, _, showDone = GetQuestLogSpecialItemInfo(index)
    link, icon, showDone = Safe(link), Safe(icon), Safe(showDone)
    if type(link) ~= "string" then return nil end
    if complete and not showDone then return nil end
    return { link = link, icon = icon, index = index }
end

-- The quest as { id, title, objectives, complete }: from what the quest progress read,
-- or read now.
local function readQuest(id, name)
    local q = ns.QuestProgress.Known()[id]
    if q then return q end
    local index = logIndex(id)
    local title = index and select(2, ns.QuestProgress.LogEntry(index)) or bonusTitle(id, name)
    if not title then return nil end
    return ns.QuestProgress.Snapshot(id, title, index)
end

---------------------------------------------------------------------------
-- The quest you follow
---------------------------------------------------------------------------

-- WombatLog's own, on clients without the game's (for the quest progress cards).
function QuestTracker:OwnFocus()
    if hasSuperTrack or not (ns.db and cfg().enabled) then return nil end
    return char().focus
end

function QuestTracker:Focus()
    if self.sampleFocus then return SAMPLE_ID end
    if hasSuperTrack then
        local id = Safe(C_SuperTrack.GetSuperTrackedQuestID())
        return (type(id) == "number" and id > 0) and id or nil
    end
    return char().focus
end

function QuestTracker:SetFocus(id)
    -- the test's sample quest is followed on its own, without touching the real one
    if id == SAMPLE_ID then
        self.sampleFocus = true
    elseif self.sampleFocus and not id then
        self.sampleFocus = nil
    else
        self.sampleFocus = nil
        if hasSuperTrack then
            pcall(C_SuperTrack.SetSuperTrackedQuestID, id or 0)
        else
            char().focus = id
        end
    end
    self:Refresh()
    if ns.QuestProgress.UpdatePins then ns.QuestProgress:UpdatePins() end
end

---------------------------------------------------------------------------
-- Things to do with a quest
---------------------------------------------------------------------------

local function openQuest(id)
    if QuestMapFrame_OpenToQuestDetails then
        if pcall(QuestMapFrame_OpenToQuestDetails, id) then return end
    end
    local index = logIndex(id)
    if QuestLogFrame then
        if not QuestLogFrame:IsShown() then pcall(ShowUIPanel, QuestLogFrame) end
        if index then
            if QuestLog_SetSelection then pcall(QuestLog_SetSelection, index)
            elseif SelectQuestLogEntry then pcall(SelectQuestLogEntry, index) end
            if QuestLog_Update then pcall(QuestLog_Update) end
        end
    elseif ToggleQuestLog then
        pcall(ToggleQuestLog)
    end
end

local function canShare(id)
    if not (IsInGroup and IsInGroup()) or id <= 0 then return false end
    if C_QuestLog and C_QuestLog.IsPushableQuest then return Safe(C_QuestLog.IsPushableQuest(id)) and true or false end
    return GetQuestLogPushable ~= nil and logIndex(id) ~= nil
end

local function shareQuest(id)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then
        pcall(C_QuestLog.SetSelectedQuest, id)
    elseif SelectQuestLogEntry and logIndex(id) then
        pcall(SelectQuestLogEntry, logIndex(id))
    end
    if QuestLogPushQuest then pcall(QuestLogPushQuest) end
end

local function untrack(id)
    if C_QuestLog and C_QuestLog.RemoveWorldQuestWatch and C_QuestLog.IsWorldQuest and Safe(C_QuestLog.IsWorldQuest(id)) then
        pcall(C_QuestLog.RemoveWorldQuestWatch, id)
    elseif C_QuestLog and C_QuestLog.RemoveQuestWatch then
        pcall(C_QuestLog.RemoveQuestWatch, id)
    elseif RemoveQuestWatch and logIndex(id) then
        pcall(RemoveQuestWatch, logIndex(id))
        if QuestWatch_Update then pcall(QuestWatch_Update) end
    end
    QuestTracker:RequestRefresh()
end

function QuestTracker:ToggleCollapsed(id)
    local c = char().collapsed
    c[id] = not c[id] or nil
    self:Refresh()
end

function QuestTracker:IsClosed()
    return (char().closed or (cfg().collapseInCombat and self.inCombat)) and true or false
end

function QuestTracker:ToggleClosed()
    char().closed = not char().closed or nil
    self:UpdateHeader()
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

-- A dark rounded rectangle behind frame (the same as the quest progress cards').
local function roundedPanel(frame, layer)
    local function piece(tex)
        local t = frame:CreateTexture(nil, "BACKGROUND", nil, layer or -8)
        t:SetTexture(tex or WHITE)
        t:SetVertexColor(0, 0, 0, 1)
        return t
    end
    local mid, top, bottom = piece(), piece(), piece()
    mid:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -RADIUS)
    mid:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, RADIUS)
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", RADIUS, 0)
    top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -RADIUS, -RADIUS)
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", RADIUS, 0)
    bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -RADIUS, RADIUS)
    local pieces = { mid, top, bottom }
    for _, c in ipairs({ { "BOTTOMLEFT", 0, 1, 0, 1 }, { "BOTTOMRIGHT", 1, 0, 0, 1 },
                         { "TOPLEFT", 0, 1, 1, 0 }, { "TOPRIGHT", 1, 0, 1, 0 } }) do
        local t = piece(CORNER)
        t:SetTexCoord(c[2], c[3], c[4], c[5])
        t:SetSize(RADIUS, RADIUS)
        t:SetPoint(c[1], frame, c[1])
        pieces[#pieces + 1] = t
    end
    return pieces
end

local function iconButton(parent, tex, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetTexture(tex)
    b.tex:SetAllPoints()
    return b
end

local function CreateRow(body)
    local r = CreateFrame("Frame", nil, body)
    r.flash = r:CreateTexture(nil, "BACKGROUND", nil, -6)
    r.flash:SetTexture(WHITE)
    r.flash:SetBlendMode("ADD")
    r.flash:SetAllPoints()
    r.flash:SetAlpha(0)
    r.dot = r:CreateTexture(nil, "ARTWORK")
    r.dot:SetTexture(WHITE)
    r.dot:SetSize(4, 4)
    r.check = r:CreateTexture(nil, "ARTWORK")
    r.check:SetTexture(CHECK)
    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.label:SetJustifyH("LEFT")
    r.label:SetWordWrap(false)
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.count:SetJustifyH("RIGHT")
    r.delta = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.delta:SetPoint("RIGHT", r.count, "LEFT", -4, 0)
    r.bar = XPBar.Create(r)
    r.B = {}
    return r
end

local function onBlockClick(b, button)
    local e = b.entry
    if not e or e.leaving then return end
    if button == "RightButton" then
        QuestTracker:OpenMenu(e, b)
    elseif IsShiftKeyDown() then
        if e.id > 0 then openQuest(e.id) end
    elseif e.complete and e.auto and ShowQuestComplete then
        pcall(ShowQuestComplete, e.id)
    else
        QuestTracker:SetFocus(QuestTracker:Focus() ~= e.id and e.id or nil)
    end
end

function QuestTracker:ShowTooltip(e, owner)
    if not cfg().tooltip then return end
    local right = (self.holder:GetCenter() or 0) > UIParent:GetWidth() / 2
    GameTooltip:SetOwner(owner, right and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.title or "", 1, 0.82, 0.18, true)
    for _, s in ipairs(e.objs) do
        local count = s.percent and ((s.have or 0) .. "%") or (s.need and s.need > 1 and s.have and (s.have .. "/" .. s.need)) or ""
        local c = s.done and 0.5 or 1
        GameTooltip:AddDoubleLine(s.text, count, c, c, c, c, c, c)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Click: follow  ·  Shift-click: quest log  ·  Right-click: more"], 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function CreateBlock()
    local b = CreateFrame("Button", nil, QuestTracker.content)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onBlockClick)
    b:SetScript("OnEnter", function(self) if self.entry then QuestTracker:ShowTooltip(self.entry, self) end end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- behind: a light on hover, a tint and a stripe for the quest you follow, flashes
    b.hl = b:CreateTexture(nil, "BACKGROUND", nil, -6)
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 1)
    b.hl:SetAlpha(0)
    b.focusBg = b:CreateTexture(nil, "BACKGROUND", nil, -7)
    b.focusBg:SetAllPoints()
    b.focusBg:SetTexture(WHITE)
    b.accent = b:CreateTexture(nil, "BORDER")
    b.accent:SetTexture(WHITE)
    b.accent:SetPoint("TOPLEFT")
    b.accent:SetPoint("BOTTOMLEFT")
    b.accent:SetWidth(2)
    b.flash = b:CreateTexture(nil, "BORDER", nil, 1)
    b.flash:SetTexture(WHITE)
    b.flash:SetBlendMode("ADD")
    b.flash:SetAllPoints()
    b.flash:SetAlpha(0)
    b.burst = b:CreateTexture(nil, "BORDER", nil, 2)
    b.burst:SetTexture(GLOW)
    b.burst:SetBlendMode("ADD")
    b.burst:Hide()

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.title = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.title:SetJustifyH("LEFT")
    b.title:SetWordWrap(false)
    b.time = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.time:SetJustifyH("RIGHT")
    b.chev = iconButton(b, CHEVRON, 12)
    b.chev:SetScript("OnClick", function() if b.entry then QuestTracker:ToggleCollapsed(b.entry.id) end end)

    -- the objectives, in a frame that folds by clipping them
    b.body = CreateFrame("Frame", nil, b)
    if b.body.SetClipsChildren then b.body:SetClipsChildren(true) end
    b.body:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.status = b.body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.status:SetJustifyH("LEFT")
    b.tbar = XPBar.Create(b.body)
    b.TB = {}
    b.mini = XPBar.Create(b.body)
    b.MB = {}
    b.rows = {}
    return b
end

local function releaseBlock(b)
    b:Hide()
    b.entry = nil
    b.burst:Hide()
    b.tbar.glow:Hide()
    b.mini.glow:Hide()
    for _, r in ipairs(b.rows) do r.bar.glow:Hide() end
    blockPool[#blockPool + 1] = b
end

local function CreateMenu()
    local m = CreateFrame("Frame", "WombatLogQuestMenu", UIParent)
    m:SetFrameStrata("DIALOG")
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    m.bg = roundedPanel(m)
    for _, t in ipairs(m.bg) do t:SetAlpha(0.92) end
    m.items = {}
    m:Hide()
    m:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() then self:Hide() end
    end)
    m:SetScript("OnShow", function(self) pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    m:SetScript("OnHide", function(self) self:UnregisterAllEvents() end)
    tinsert(UISpecialFrames, "WombatLogQuestMenu")
    return m
end

-- A small menu at the cursor: { { text, fn }, ... }
function QuestTracker:ShowMenu(list)
    local m = self.menu or CreateMenu()
    self.menu = m
    local size = math.max(10, cfg().textSize)
    local font = ns.AlertFonts(cfg())
    local h, w = 20, 60
    for i, item in ipairs(list) do
        local b = m.items[i]
        if not b then
            b = CreateFrame("Button", nil, m)
            b.hl = b:CreateTexture(nil, "HIGHLIGHT")
            b.hl:SetAllPoints()
            b.hl:SetColorTexture(1, 1, 1, 0.1)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            b.text:SetPoint("LEFT", 10, 0)
            b.text:SetJustifyH("LEFT")
            m.items[i] = b
        end
        ns.SetFont(b.text, font, size, "")
        b.text:SetText(item[1])
        b:SetScript("OnClick", function()
            m:Hide()
            item[2]()
        end)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", m, "TOPLEFT", 4, -4 - (i - 1) * h)
        b:SetHeight(h)
        b:Show()
        w = math.max(w, math.ceil(b.text:GetStringWidth()) + 20)
    end
    for i = #list + 1, #m.items do m.items[i]:Hide() end
    for i = 1, #list do m.items[i]:SetWidth(w) end
    m:SetSize(w + 8, #list * h + 8)
    local x, y = GetCursorPosition()
    local s = m:GetEffectiveScale()
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s - 4, y / s + 4)
    m:Show()
end

function QuestTracker:OpenMenu(e)
    GameTooltip:Hide()
    local id = e.id
    local list = {}
    if self:Focus() == id then
        list[#list + 1] = { L["Stop following"], function() self:SetFocus(nil) end }
    else
        list[#list + 1] = { L["Follow"], function() self:SetFocus(id) end }
    end
    if id > 0 then list[#list + 1] = { L["Open in quest log"], function() openQuest(id) end } end
    if canShare(id) then list[#list + 1] = { L["Share"], function() shareQuest(id) end } end
    list[#list + 1] = { char().collapsed[id] and L["Unfold"] or L["Fold"], function() self:ToggleCollapsed(id) end }
    if id > 0 and not e.bonus then list[#list + 1] = { L["Stop watching"], function() untrack(id) end } end
    self:ShowMenu(list)
end

local function CreateHolder()
    local h = CreateFrame("Frame", "WombatLogQuestTracker", UIParent)
    h:SetFrameStrata("LOW")
    h:SetClampedToScreen(true)
    h:SetMovable(true)
    h:SetSize(250, 40)
    h.bg = roundedPanel(h)

    -- header: the title and the number of quests, the compact switch and the fold arrow
    local head = CreateFrame("Button", nil, h)
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head:RegisterForClicks("LeftButtonUp")
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnClick", function() if not QuestTracker.unlocked then QuestTracker:ToggleClosed() end end)
    head:SetScript("OnDragStart", function() if QuestTracker.unlocked then h:StartMoving() end end)
    head:SetScript("OnDragStop", function()
        h:StopMovingOrSizing()
        if not QuestTracker.unlocked then return end
        local c = cfg()
        local s = UIParent:GetEffectiveScale() / h:GetEffectiveScale()
        c.x = math.floor(h:GetCenter() - UIParent:GetWidth() * s / 2 + 0.5)
        c.y = math.floor(h:GetTop() - UIParent:GetHeight() * s / 2 + 0.5)
        QuestTracker:Anchor()
        QuestTracker:PlaceItemBar()
    end)
    head.hl = head:CreateTexture(nil, "BACKGROUND", nil, -6)
    head.hl:SetAllPoints()
    head.hl:SetColorTexture(1, 1, 1, 1)
    head.hl:SetAlpha(0)
    head.title = head:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    head.title:SetPoint("LEFT", PAD + 2, 0)
    head.count = head:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    head.count:SetPoint("LEFT", head.title, "RIGHT", 6, 0)
    head.chev = iconButton(head, CHEVRON, 12)
    head.chev:SetPoint("RIGHT", -PAD, 0)
    head.chev:SetScript("OnClick", function() QuestTracker:ToggleClosed() end)
    head.compact = iconButton(head, LINES, 12)
    head.compact:SetPoint("RIGHT", head.chev, "LEFT", -8, 0)
    head.compact:SetScript("OnClick", function()
        cfg().compact = not cfg().compact
        QuestTracker:Refresh()
        if ns.Config then ns.Config:RefreshAll() end
    end)
    head.compact:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["Compact view"])
        GameTooltip:Show()
    end)
    head.compact:SetScript("OnLeave", function() GameTooltip:Hide() end)
    head.line = head:CreateTexture(nil, "ARTWORK")
    head.line:SetColorTexture(1, 1, 1, 0.1)
    head.line:SetHeight(1)
    head.line:SetPoint("BOTTOMLEFT", PAD, 0)
    head.line:SetPoint("BOTTOMRIGHT", -PAD, 0)
    h.head = head

    -- the quests, in a frame that folds the list by clipping it
    local content = CreateFrame("Frame", nil, h)
    if content.SetClipsChildren then content:SetClipsChildren(true) end
    content:SetPoint("TOPLEFT", head, "BOTTOMLEFT", PAD, -4)
    h.content = content
    h.more = h:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    h.more:SetPoint("TOPLEFT", content, "BOTTOMLEFT", 2, -2)

    h.overlay = h:CreateTexture(nil, "OVERLAY")
    h.overlay:SetAllPoints()
    h.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    h.overlay:Hide()
    h.overlayText = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.overlayText:SetPoint("BOTTOM", h, "TOP", 0, 2)
    h.overlayText:SetText(L["WombatLog quest tracker - drag the header to move"])
    h.overlayText:Hide()
    h:Hide()
    return h
end

---------------------------------------------------------------------------
-- Objectives
---------------------------------------------------------------------------

local function fraction(o, have)
    if o.need and o.need > 0 and have then return math.max(0, math.min(1, have / o.need)) end
    return o.done and 1 or 0
end

local function hasBar(o)
    return o.percent or (o.need and o.need > 1) or false
end

local function countText(o)
    if o.percent then return (o.have or 0) .. "%" end
    if o.need and o.need > 1 and o.have then return o.have .. "/" .. o.need end
    return ""
end

-- One bar for the whole quest: how far its objectives are, on average.
local function overall(objs)
    if #objs == 0 then return nil end
    local sum = 0
    for _, s in ipairs(objs) do sum = sum + (s.done and 1 or fraction(s, s.have)) end
    return sum / #objs
end

-- Takes the quest's latest objectives into e; with animate, what moved on lights up.
local function takeObjectives(e, q, animate)
    local changed = false
    for i, o in ipairs(q.objectives) do
        local s = e.objs[i]
        local before
        if s and animate then
            if (o.have and s.have and o.have > s.have) or (o.done and not s.done) then before = s.have or 0 end
        elseif not s and animate and e.hadObjectives then
            before = 0 -- a new stage of the quest
        end
        if not s then
            s = { value = before and fraction(o, before) or fraction(o, o.have) }
            e.objs[i] = s
        end
        if before then
            s.from = s.value
            s.changeAge = 0
            if o.have then
                local recent = s.deltaAge and s.deltaAge < DELTA_HOLD + DELTA_FADE
                s.delta = (recent and s.delta or 0) + (o.have - before)
                s.deltaAge = 0
            end
            if o.done and not s.done then s.doneAge = 0 end
            changed = true
        end
        s.target = fraction(o, o.have)
        s.text, s.have, s.need, s.done, s.percent = o.text, o.have, o.need, o.done, o.percent
        s.from = s.from or s.value
    end
    for i = #e.objs, #q.objectives + 1, -1 do e.objs[i] = nil end
    e.hadObjectives = #q.objectives > 0
    local m = e.mini
    local v = overall(e.objs) or 0
    if not m then
        e.mini = { value = v, from = v, target = v }
    elseif v ~= m.target then
        m.from, m.target = m.value, v
        if animate and v > m.value then m.changeAge = 0 end
    end
    return changed
end

---------------------------------------------------------------------------
-- Laying out a quest
---------------------------------------------------------------------------

local function titleColor(e)
    local c = cfg()
    if e.failed then return FAIL_COLOR end
    if c.levelColors and e.level and e.level > 0 and GetQuestDifficultyColor then
        local d = GetQuestDifficultyColor(e.level)
        if type(d) == "table" and d.r then return { d.r, d.g, d.b } end
    end
    return c.titleColor
end

local function barSettings(B, c, segments)
    for k, v in pairs(c.bar) do B[k] = v end
    B.segments = segments or 0
    B.rested, B.percent = false, false
end

-- Lays out e's block from its objectives and the settings: the title line, and in
-- the body what this quest shows (its objectives, one bar, or a line saying it's done).
function QuestTracker:Fill(e)
    local c = cfg()
    local b = e.block
    local font, _, _, outline = ns.AlertFonts(c)
    local size = c.textSize
    local lineH = size + 6
    local W = c.width - PAD * 2
    b:SetWidth(W)
    b.body:SetWidth(W)

    -- title line
    local iconS = size + 2
    b.icon:SetTexture(e.complete and DONE_ICON or QUEST_ICON)
    b.icon:SetSize(iconS, iconS)
    b.icon:ClearAllPoints()
    b.icon:SetPoint("CENTER", b, "TOPLEFT", 6 + iconS / 2, -lineH / 2)
    ns.SetFont(b.title, font, size + 1, outline)
    local tc = titleColor(e)
    b.title:SetTextColor(tc[1], tc[2], tc[3])
    local title = e.title or ""
    if c.showLevel and e.level and e.level > 0 then title = "[" .. e.level .. "] " .. title end
    b.title:SetText(title)
    b.title:ClearAllPoints()
    b.title:SetPoint("LEFT", b, "TOPLEFT", 10 + iconS, -lineH / 2)
    b.chev:SetSize(size - 1, size - 1)
    b.chev:ClearAllPoints()
    b.chev:SetPoint("CENTER", b, "TOPRIGHT", -(size / 2 + 2), -lineH / 2)
    local timeW = 0
    b.time:SetShown(e.timer and true or false)
    if e.timer then
        ns.SetFont(b.time, font, size, outline)
        b.time:SetText(e.timer.total >= 3600 and "00:00:00" or "00:00")
        timeW = math.ceil(b.time:GetStringWidth()) + 6
        b.timeStr = nil
        b.time:ClearAllPoints()
        b.time:SetPoint("RIGHT", b, "TOPRIGHT", -(size + 6), -lineH / 2)
    end
    b.title:SetWidth(math.max(20, W - 10 - iconS - timeW - size - 8))
    e.headH = lineH

    -- body
    b.body:ClearAllPoints()
    b.body:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -lineH)
    local focus = self:Focus() == e.id
    local mode = (e.complete or e.failed) and "status"
        or (c.compact and not focus) and "mini" or "full"
    e.mode = mode
    local y = 0
    local rowW = W - INDENT - 4

    b.status:SetShown(mode == "status")
    if mode == "status" then
        ns.SetFont(b.status, font, size, outline)
        local col = e.failed and FAIL_COLOR or c.doneColor
        b.status:SetTextColor(col[1], col[2], col[3])
        b.status:SetText(e.failed and L["Failed"] or (e.auto and L["Click to complete"]) or L["Ready to turn in"])
        b.status:ClearAllPoints()
        b.status:SetPoint("TOPLEFT", b.body, "TOPLEFT", INDENT, -2)
        y = size + 6
    end

    local timed = e.timer and mode ~= "status"
    b.tbar:SetShown(timed and true or false)
    b.tbar.glow:Hide()
    if timed then
        barSettings(b.TB, c)
        XPBar.Apply(b.tbar, b.TB, rowW, math.max(3, c.bar.height), c.barColor, font, outline)
        b.tbar:ClearAllPoints()
        b.tbar:SetPoint("TOPLEFT", b.body, "TOPLEFT", INDENT, -(y + 2))
        y = y + math.max(3, c.bar.height) + 6
    end

    local miniShown = mode == "mini" and #e.objs > 0
    b.mini:SetShown(miniShown)
    if not miniShown then b.mini.glow:Hide() end
    if miniShown then
        barSettings(b.MB, c)
        XPBar.Apply(b.mini, b.MB, rowW, c.bar.height, c.barColor, font, outline)
        b.mini:ClearAllPoints()
        b.mini:SetPoint("TOPLEFT", b.body, "TOPLEFT", INDENT, -(y + 1))
        y = y + c.bar.height + 5
    end

    local n = mode == "full" and #e.objs or 0
    for i = 1, n do
        local s = e.objs[i]
        local r = b.rows[i] or CreateRow(b.body)
        b.rows[i] = r
        r:Show()
        r:SetWidth(rowW + INDENT - 6)
        ns.SetFont(r.label, font, size, outline)
        ns.SetFont(r.count, font, size, outline)
        ns.SetFont(r.delta, font, size, outline)
        local hc = c.highlightColor
        r.flash:SetVertexColor(hc[1], hc[2], hc[3], 1)
        r.delta:SetTextColor(hc[1], hc[2], hc[3])
        local rowLine = size + 4
        r.dot:ClearAllPoints()
        r.dot:SetPoint("CENTER", r, "TOPLEFT", INDENT - 6, -rowLine / 2)
        r.check:ClearAllPoints()
        r.check:SetPoint("CENTER", r, "TOPLEFT", INDENT - 6, -rowLine / 2)
        r.label:ClearAllPoints()
        r.label:SetPoint("LEFT", r, "TOPLEFT", INDENT, -rowLine / 2)
        r.count:ClearAllPoints()
        r.count:SetPoint("RIGHT", r, "TOPRIGHT", -2, -rowLine / 2)
        r.count:SetText(countText(s))
        r.label:SetText(s.text)
        local countW = math.ceil(r.count:GetStringWidth())
        local deltaW = 0
        if s.deltaAge then
            r.delta:SetText("+" .. (s.delta or 0) .. (s.percent and "%" or ""))
            deltaW = math.ceil(r.delta:GetStringWidth()) + 4
        end
        r.label:SetWidth(math.max(20, rowW - countW - deltaW - 8))
        local h = rowLine
        s.bar = hasBar(s) and not s.done
        r.bar:SetShown(s.bar and true or false)
        if s.bar then
            barSettings(r.B, c, (c.bar.segments and not s.percent and s.need <= XPBar.MAX_SEGMENTS) and s.need or 0)
            XPBar.Apply(r.bar, r.B, rowW - 2, c.bar.height, c.barColor, font, outline)
            r.bar:ClearAllPoints()
            r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", INDENT, -rowLine)
            h = h + c.bar.height + 3
        else
            r.bar.glow:Hide()
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", b.body, "TOPLEFT", 0, -y)
        r:SetHeight(h)
        y = y + h + 1
    end
    for i = n + 1, #b.rows do
        b.rows[i]:Hide()
        b.rows[i].bar.glow:Hide()
    end
    if y > 0 then y = y + 3 end
    e.fullH = y
    e.targetBodyH = char().collapsed[e.id] and 0 or y
    e.bodyH = e.bodyH or e.targetBodyH
    e.foldK = e.foldK or (char().collapsed[e.id] and 0 or 1)
    self:Render(e, 0)
end

---------------------------------------------------------------------------
-- What moves
---------------------------------------------------------------------------

local function formatTime(left)
    local s = math.ceil(left)
    if s >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
    end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- One frame of e's block: hover, focus, folding, fills, lights, the timer, the flash.
function QuestTracker:Render(e, dt)
    local c = cfg()
    local b = e.block
    local size = c.textSize
    local hc, dc = c.highlightColor, c.doneColor

    local hovered = (b:IsMouseOver() or self.hoverItem == e.id) and not e.leaving
    e.hoverK = approach(e.hoverK or 0, hovered and 1 or 0, dt * HOVER_SPEED)
    b.hl:SetAlpha(0.06 * e.hoverK)
    local focused = self:Focus() == e.id
    e.focusK = approach(e.focusK or (focused and 1 or 0), focused and 1 or 0, dt * HOVER_SPEED)
    local fc = c.focusColor
    b.focusBg:SetVertexColor(fc[1], fc[2], fc[3], 0.10 * e.focusK)
    b.accent:SetVertexColor(fc[1], fc[2], fc[3], e.focusK)

    -- the fold arrow: points down when open, right when folded; shows on hover
    local folded = char().collapsed[e.id] and true or false
    e.foldK = approach(e.foldK or 1, folded and 0 or 1, dt * OPEN_SPEED)
    b.chev.tex:SetRotation((1 - e.foldK) * math.pi / 2)
    b.chev:SetAlpha(math.max(e.hoverK, folded and 0.55 or 0) * 0.9)
    e.bodyH = approach(e.bodyH or 0, e.targetBodyH or 0, dt * OPEN_SPEED, 0.3)
    b.body:SetHeight(math.max(0.01, e.bodyH))
    b:SetHeight(e.headH + e.bodyH)

    -- a new quest, a progress, a quest done: the block lights up and fades back
    local flash = 0
    if e.newAge and e.newAge < FLASH then flash = 0.18 * (1 - e.newAge / FLASH) end
    b.flash:SetVertexColor(hc[1], hc[2], hc[3], 1)
    b.flash:SetAlpha(flash)

    for i, s in ipairs(e.objs) do
        local r = b.rows[i]
        if r and r:IsShown() then
            local lit = s.changeAge ~= nil
            local rf = 0
            if lit then
                rf = s.changeAge < FLASH and (0.1 + 0.3 * (1 - s.changeAge / FLASH))
                    or 0.1 * math.max(0, 1 - (s.changeAge - FLASH) / (LIT_TIME - FLASH))
            end
            r.flash:SetAlpha(rf)
            local tc = s.done and dc or (lit and hc) or nil
            if tc then
                r.label:SetTextColor(tc[1], tc[2], tc[3])
                r.count:SetTextColor(tc[1], tc[2], tc[3])
            else
                r.label:SetTextColor(0.85, 0.85, 0.85)
                r.count:SetTextColor(0.85, 0.85, 0.85)
            end
            local da = 0
            if s.deltaAge and s.delta and s.delta > 0 then
                da = s.deltaAge < DELTA_HOLD and 1 or math.max(0, 1 - (s.deltaAge - DELTA_HOLD) / DELTA_FADE)
            end
            r.delta:SetAlpha(da)
            r.dot:SetShown(not s.done)
            r.dot:SetVertexColor(0.85, 0.85, 0.85, 1)
            r.check:SetShown(s.done)
            if s.done then
                local k = s.doneAge and math.max(0, 1 - s.doneAge / POP) or 0
                local cs = (size + 2) * (1 + 0.9 * k)
                r.check:SetSize(cs, cs)
            end
            if s.bar then
                XPBar.Render(r.bar, r.B, s.value, s.from, s.changeAge or math.huge, 0, lit and hc or nil)
            end
        end
    end

    local m = e.mini
    if m and b.mini:IsShown() then
        XPBar.Render(b.mini, b.MB, m.value, m.from, m.changeAge or math.huge, 0, m.changeAge and hc or nil)
    end

    local t = e.timer
    if t then
        local now = GetTime()
        local left = math.max(0, t.expires - now)
        local s = formatTime(left)
        if s ~= b.timeStr then
            b.time:SetText(s)
            b.timeStr = s
        end
        local col, a = nil, 1
        if left < ALERT_AT then
            col, a = FAIL_COLOR, 0.55 + 0.45 * math.abs(math.cos(now * math.pi * 1.5))
        elseif left < WARN_AT then
            col = WARN_COLOR
        end
        if col then b.time:SetTextColor(col[1], col[2], col[3]) else b.time:SetTextColor(1, 1, 1) end
        b.time:SetAlpha(a)
        if b.tbar:IsShown() then
            b.tbar.color = col or c.barColor
            local v = t.total > 0 and math.min(1, left / t.total) or 0
            XPBar.Render(b.tbar, b.TB, v, v, math.huge, 0, nil)
            b.tbar:SetAlpha(a)
        end
    end

    if e.burstT then
        local p = math.min(1, e.burstT / BURST_TIME)
        local w = c.width * (0.5 + 1.0 * (1 - (1 - p) * (1 - p)))
        local g = e.failed and FAIL_COLOR or c.doneColor
        b.burst:SetVertexColor(g[1], g[2], g[3], 1)
        b.burst:ClearAllPoints()
        b.burst:SetPoint("CENTER", b.title, "CENTER")
        b.burst:SetSize(w, w * 0.35)
        b.burst:SetAlpha(0.9 * (1 - p * p))
        b.burst:SetShown(p < 1)
    else
        b.burst:Hide()
    end
end

-- Ages the lights and moves the fills of e by dt.
local function age(e, dt)
    local speed = cfg().bar.speed
    for _, s in ipairs(e.objs) do
        if s.value ~= s.target then s.value = approach(s.value, s.target, dt * speed) end
        if s.changeAge then
            s.changeAge = s.changeAge + dt
            if s.changeAge > LIT_TIME then s.changeAge = nil end
        end
        if s.deltaAge then
            s.deltaAge = s.deltaAge + dt
            if s.deltaAge > DELTA_HOLD + DELTA_FADE then s.deltaAge, s.delta = nil, nil end
        end
        if s.doneAge then
            s.doneAge = s.doneAge + dt
            if s.doneAge > POP then s.doneAge = nil end
        end
    end
    local m = e.mini
    if m then
        if m.value ~= m.target then m.value = approach(m.value, m.target, dt * speed) end
        if m.changeAge then
            m.changeAge = m.changeAge + dt
            if m.changeAge > LIT_TIME then m.changeAge = nil end
        end
    end
    if e.newAge then
        e.newAge = e.newAge + dt
        if e.newAge > FLASH then e.newAge = nil end
    end
    if e.burstT then
        e.burstT = e.burstT + dt
        if e.burstT > BURST_TIME then e.burstT = nil end
    end
end

-- One frame: quests fade in and out and glide to their place, bodies fold, the list
-- folds, and the panel follows what is shown.
function QuestTracker:Step(dt)
    if dt > 0.1 then dt = 0.1 end
    local c = cfg()
    local h = self.holder
    self.openK = approach(self.openK or 1, self:IsClosed() and 0 or 1, dt * OPEN_SPEED)
    h.head.chev.tex:SetRotation((1 - self.openK) * math.pi / 2)
    h.head.hl:SetAlpha(h.head:IsMouseOver() and 0.05 or 0)
    h.head.line:SetAlpha(self.openK)

    -- the shown quests, top to bottom, and where each goes
    local y, hidden, visibleH = 0, 0, nil
    for _, id in ipairs(order) do
        local e = entries[id]
        e.k = approach(e.k or 0, 1, dt * FADE_SPEED, 0.01)
        local height = e.headH + (e.bodyH or 0)
        if visibleH == nil and y > 0 and y + height > c.maxHeight then visibleH = y - GAP end
        e.overflow = visibleH ~= nil
        if e.overflow then hidden = hidden + 1 end
        e.ty = y
        y = y + (height + GAP) * ease(e.k)
    end
    local total = math.max(0, y - GAP)
    visibleH = math.min(visibleH or total, total)

    for id, e in pairs(entries) do
        if e.leaving then
            e.k = approach(e.k, 0, dt * (e.burstT and LEAVE_SPEED or FADE_SPEED), 0.01)
            if e.k <= 0 then
                releaseBlock(e.block)
                entries[id] = nil
            end
        end
        if entries[id] then
            age(e, dt)
            local b = e.block
            if e.ty then
                if not e.curY then e.curY = e.ty - SLIDE end
                e.curY = approach(e.curY, e.ty, dt * MOVE_SPEED, 0.3)
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", h.content, "TOPLEFT", 0, -(e.curY or 0))
            local a = ease(e.k)
            if e.overflow and not e.leaving then a = 0 end
            b:SetAlpha(a)
            b:SetShown(a > 0.01)
            if a > 0.01 then self:Render(e, dt) end
        end
    end

    -- the panel: header, the list as far as it's open, the "more" line
    local headH = c.textSize + 12
    h.head:SetHeight(headH)
    local listH = visibleH * self.openK
    h.content:SetSize(c.width - PAD * 2, math.max(0.01, listH))
    local moreShown = hidden > 0 and self.openK > 0.5
    h.more:SetShown(moreShown)
    if moreShown then h.more:SetText(L["%d more"]:format(hidden)) end
    local bottom = (listH > 0.5 and (listH + 4 + PAD) or 2) + (moreShown and (c.textSize + 4) or 0)
    h:SetHeight(headH + bottom)

    -- the whole tracker: there while there's something to show
    local want = (#order > 0 or self.unlocked) and 1 or 0
    self.alphaK = approach(self.alphaK or 0, want, dt * FADE_SPEED, 0.01)
    h:SetAlpha(ease(self.alphaK))
    if self.alphaK <= 0 and want == 0 and not next(entries) then h:Hide() end
end

---------------------------------------------------------------------------
-- Reading it all in
---------------------------------------------------------------------------

function QuestTracker:RequestRefresh()
    if refreshPending or not self.holder then return end
    refreshPending = true
    C_Timer.After(REFRESH_DELAY, function() QuestTracker:Refresh() end)
end

function QuestTracker:OnScan()
    self:RequestRefresh()
end

function QuestTracker:Refresh()
    refreshPending = false
    local h = self.holder
    if not h then return end
    local c = cfg()
    local animate = GetTime() >= readyAt
    local list = {}
    if self.sample then list[#list + 1] = { id = SAMPLE_ID } end
    if c.enabled then
        local ids, seen = watchedQuests()
        for _, id in ipairs(ids) do list[#list + 1] = { id = id } end
        if c.bonus then
            for _, q in ipairs(bonusQuests(seen)) do list[#list + 1] = { id = q.id, name = q.name, bonus = true } end
        end
    end

    -- WombatLog's own focus lets go of a quest that's gone
    local focus = self:Focus()
    if not hasSuperTrack and focus and focus > 0 then
        local still = false
        for _, item in ipairs(list) do
            if item.id == focus then still = true end
        end
        if not still and not ns.QuestProgress.Known()[focus] then char().focus, focus = nil, nil end
    end

    -- the quest you follow on top, then the watched ones, then the bonus objectives
    local sorted = {}
    for _, item in ipairs(list) do if item.id == focus then sorted[#sorted + 1] = item end end
    for _, item in ipairs(list) do if item.id ~= focus and not item.bonus then sorted[#sorted + 1] = item end end
    for _, item in ipairs(list) do if item.id ~= focus and item.bonus then sorted[#sorted + 1] = item end end

    local keep = {}
    wipe(order)
    for _, item in ipairs(sorted) do
        local id = item.id
        local q = id == SAMPLE_ID and self.sample or readQuest(id, item.name)
        local e = entries[id]
        if q or e then
            if not e then
                local b = table.remove(blockPool) or CreateBlock()
                e = { id = id, objs = {}, block = b, k = 0 }
                b.entry = e
                b:SetAlpha(0)
                entries[id] = e
                if animate then e.newAge = 0 end
            end
            e.leaving = nil -- watched again while it was fading out: it comes back
            e.bonus = item.bonus
            if q then
                local index = id > 0 and logIndex(id) or nil
                local level, complete, failed, auto = nil, q.complete, false, false
                if id > 0 then
                    local lvl, done, fail, isAuto = questState(id, index)
                    level, complete, failed, auto = lvl, q.complete or done, fail, isAuto
                end
                if animate and (complete or failed) and not (e.complete or e.failed) and e.title then e.burstT = 0 end
                e.title, e.level, e.complete, e.failed, e.auto = q.title, level, complete, failed, auto
                e.item = id > 0 and questItem(id, index, complete) or nil
                e.timer = id > 0 and ns.QuestProgress.Timer(id) or nil
                takeObjectives(e, q, animate and e.title ~= nil)
            end
            keep[id] = true
            order[#order + 1] = id
        end
    end
    for id, e in pairs(entries) do
        if not keep[id] and not e.leaving then
            e.leaving = true
            -- turned in: it goes with a flash
            if e.complete and animate then e.burstT = 0 end
        end
    end
    for _, e in pairs(entries) do self:Fill(e) end
    self:UpdateHeader()
    if #order > 0 or self.unlocked then h:Show() end
    self:UpdateItems()
end

function QuestTracker:UpdateHeader()
    local h = self.holder
    if not h then return end
    local c = cfg()
    local font, _, _, outline = ns.AlertFonts(c)
    ns.SetFont(h.head.title, font, c.textSize + 1, outline)
    ns.SetFont(h.head.count, font, c.textSize, outline)
    ns.SetFont(h.more, font, c.textSize - 1, outline)
    h.head.title:SetText(L["Quests"])
    h.head.title:SetTextColor(1, 0.82, 0.18)
    local n = 0
    for _, id in ipairs(order) do if id ~= SAMPLE_ID then n = n + 1 end end
    h.head.count:SetText(n > 0 and n or "")
    h.head.count:SetTextColor(0.7, 0.7, 0.7)
    h.more:SetTextColor(0.7, 0.7, 0.7)
    local s = c.textSize
    h.head.chev:SetSize(s - 1, s - 1)
    h.head.compact:SetSize(s - 1, s - 1)
    h.head.compact:SetAlpha(c.compact and 1 or 0.4)
end

---------------------------------------------------------------------------
-- Quest item buttons
---------------------------------------------------------------------------

-- Secure buttons act on the press or on the release, as the game's "cast on key down"
-- setting says; a button listening for the other one does nothing. So each listens
-- for the one the setting asks for (not both: older clients would use the item twice).
local function registerClicks(b)
    local down = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
    b:RegisterForClicks(down and "AnyDown" or "AnyUp")
end

local function CreateItemButton(i)
    local name = "WombatLogQuestItem" .. i
    local b = CreateFrame("Button", name, QuestTracker.itemBar, "SecureActionButtonTemplate")
    registerClicks(b)
    b:SetAttribute("type", "item")
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0, 0, 0, 0.85)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.cd = CreateFrame("Cooldown", name .. "Cooldown", b, "CooldownFrameTemplate")
    b.cd:SetAllPoints(b.icon)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b.icon)
    hl:SetColorTexture(1, 1, 1, 0.15)
    b:SetScript("OnEnter", function(self)
        QuestTracker.hoverItem = self.questID
        GameTooltip:SetOwner(self, cfg().itemSide == "left" and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
        if self.link then pcall(GameTooltip.SetHyperlink, GameTooltip, self.link) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        QuestTracker.hoverItem = nil
        GameTooltip:Hide()
    end)
    itemButtons[i] = b
    return b
end

-- The item buttons for the shown quests. Secure buttons can't change in combat: then
-- this waits until the fight is over.
function QuestTracker:UpdateItems()
    if not self.itemBar then return end
    if InCombatLockdown() then
        self.itemsPending = true
        return
    end
    self.itemsPending = nil
    local c = cfg()
    local list = {}
    if c.enabled and c.items then
        for _, id in ipairs(order) do
            local e = entries[id]
            if e and e.item and #list < MAX_ITEMS then list[#list + 1] = e end
        end
    end
    local s = c.itemSize
    for i, e in ipairs(list) do
        local b = itemButtons[i] or CreateItemButton(i)
        registerClicks(b) -- the setting may have changed since
        local itemID = e.item.link:match("item:(%d+)")
        b:SetAttribute("item", itemID and ("item:" .. itemID) or e.item.link)
        b.link, b.questID, b.index = e.item.link, e.id, e.item.index
        b.icon:SetTexture(e.item.icon)
        b:SetSize(s, s)
        b:ClearAllPoints()
        b:SetPoint("TOP", self.itemBar, "TOP", 0, -(i - 1) * (s + 4))
        b:Show()
    end
    for i = #list + 1, #itemButtons do
        itemButtons[i]:Hide()
        itemButtons[i].link, itemButtons[i].questID = nil, nil
    end
    self.itemCount = #list
    self:PlaceItemBar()
end

-- Next to the list, by the screen's coordinates: the bar mustn't hang on the list,
-- or the list couldn't move in combat.
function QuestTracker:PlaceItemBar()
    local bar, h = self.itemBar, self.holder
    if not bar then return end
    if InCombatLockdown() then
        self.itemsPending = true
        return
    end
    local c = cfg()
    local n = self.itemCount or 0
    bar:SetScale(c.scale)
    local left, top, right = h:GetLeft(), h:GetTop(), h:GetRight()
    if n == 0 or not left or not h:IsShown() then
        bar:Hide()
        return
    end
    local s = c.itemSize
    bar:SetSize(s, n * (s + 4) - 4)
    bar:ClearAllPoints()
    local y = top - (c.textSize + 12) - 4
    if c.itemSide == "left" then
        bar:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left - 6, y)
    else
        bar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right + 6, y)
    end
    bar:Show()
end

-- Cooldowns, range and stack counts of the item buttons.
local function pollItems()
    for _, b in ipairs(itemButtons) do
        if b:IsShown() and b.link then
            if b.index and GetQuestLogSpecialItemCooldown then
                local start, duration = GetQuestLogSpecialItemCooldown(b.index)
                start, duration = Safe(start), Safe(duration)
                if start and duration and duration > 0 then
                    pcall(b.cd.SetCooldown, b.cd, start, duration)
                else
                    b.cd:Hide()
                end
            end
            local inRange = b.index and IsQuestLogSpecialItemInRange and Safe(IsQuestLogSpecialItemInRange(b.index))
            if inRange == 0 then b.icon:SetVertexColor(1, 0.3, 0.3) else b.icon:SetVertexColor(1, 1, 1) end
            local n = GetItemCount and Safe(GetItemCount(b.link)) or (C_Item and C_Item.GetItemCount and Safe(C_Item.GetItemCount(b.link)))
            b.count:SetText((type(n) == "number" and n > 1) and n or "")
        end
    end
end

---------------------------------------------------------------------------
-- Settings, test and positioning
---------------------------------------------------------------------------

function QuestTracker:Anchor()
    local c, h = cfg(), self.holder
    h:ClearAllPoints()
    h:SetPoint("TOP", UIParent, "CENTER", c.x, c.y)
end

function QuestTracker:Init()
    self.holder = CreateHolder()
    self.content = self.holder.content
    self.holder:SetScript("OnUpdate", function(_, dt) self:Step(dt) end)
    self.itemBar = CreateFrame("Frame", "WombatLogQuestItemBar", UIParent)
    self.itemBar:SetFrameStrata("LOW")
    self.itemBar:Hide()
    local t = 0
    self.itemBar:SetScript("OnUpdate", function(_, dt)
        t = t + dt
        if t >= ITEM_POLL then
            t = 0
            pollItems()
        end
    end)
    self.inCombat = Safe(UnitAffectingCombat("player")) and true or false
    readyAt = GetTime() + SETTLE
    self.openK = self:IsClosed() and 0 or 1
    self:Apply()
end

function QuestTracker:Apply()
    local h = self.holder
    if not h then return end
    local c = cfg()
    h:SetScale(c.scale)
    h:SetWidth(c.width)
    for _, t in ipairs(h.bg) do t:SetAlpha(c.bgOpacity) end
    self:Anchor()
    self:Refresh()
    if ns.BlizzardUI and ns.BlizzardUI.UpdateQuestTracker then ns.BlizzardUI:UpdateQuestTracker() end
end

local function sampleQuest(step)
    local kills = ({ 3, 6, 8 })[step]
    local candles = ({ 1, 4, 5 })[step]
    local done = step == 3
    return {
        id = SAMPLE_ID, title = L["Kobold Camp Cleanup"], complete = done,
        objectives = {
            { text = L["Kobold Vermin slain"], have = kills, need = 8, done = kills >= 8 },
            { text = L["Wax Candles"], have = candles, need = 5, done = candles >= 5 },
            { text = L["Kobold camp found"], done = step >= 2 },
        },
    }
end

-- Settings button: a sample quest comes in, moves on, gets done and is turned in, one
-- step per press.
function QuestTracker:Test()
    self.testStep = ((self.testStep or 0) % 4) + 1
    if self.testStep == 4 then
        self.sample, self.sampleFocus = nil, nil
    else
        self.sample = sampleQuest(self.testStep)
    end
    self:Refresh()
end

function QuestTracker:SetLocked(locked)
    self.unlocked = not locked or nil
    local h = self.holder
    h.overlay:SetShown(not locked)
    h.overlayText:SetShown(not locked)
    if not locked then h:Show() end
    self:Refresh()
    if ns.Config then ns.Config:RefreshAll() end
end

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------

local function request() QuestTracker:RequestRefresh() end

ns.Listen("QUEST_WATCH_LIST_CHANGED", request)
ns.Listen("SUPER_TRACKING_CHANGED", request)
ns.Listen("ZONE_CHANGED", request)
ns.Listen("ZONE_CHANGED_NEW_AREA", request)
ns.Listen("PLAYER_ENTERING_WORLD", request)
ns.Listen("BAG_UPDATE_DELAYED", request)

-- "cast on key down" switched: the item buttons listen for the other click
ns.Listen("CVAR_UPDATE", function(name)
    if type(name) == "string" and name:lower() == "actionbuttonusekeydown" then QuestTracker:UpdateItems() end
end)

ns.Listen("PLAYER_REGEN_DISABLED", function()
    QuestTracker.inCombat = true
    if QuestTracker.menu then QuestTracker.menu:Hide() end
end)

ns.Listen("PLAYER_REGEN_ENABLED", function()
    QuestTracker.inCombat = false
    if QuestTracker.itemsPending then QuestTracker:UpdateItems() end
end)

-- Classic: watching a quest from the quest log (shift-click) doesn't always say so
for _, name in ipairs({ "AddQuestWatch", "RemoveQuestWatch" }) do
    if type(_G[name]) == "function" then hooksecurefunc(name, request) end
end
