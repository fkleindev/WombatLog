local ADDON, ns = ...
local QuestProgress = {}
ns.QuestProgress = QuestProgress
local Safe, SafeTable = ns.Safe, ns.SafeTable
local L = ns.L
local XPBar = ns.XPBar

-- A card that pops up when a quest moves on: the quest's name and all its objectives,
-- the one that just changed lit up with a "+1", and a bar for every "kill X" or
-- "collect X" objective that fills from the old count to the new one. When the last
-- objective is done the card says so. Several quests at once stack, newest on top.
--
-- Progress comes from the quest log itself, not from the yellow message on screen or
-- the chat: every log event, the objectives are read again and compared with what
-- they were. That works the same in every language and on every client:
--   Retail (and MoP)  C_QuestLog.GetInfo / GetQuestObjectives, bonus objectives' percent
--   Classic           GetQuestLogTitle, and GetQuestObjectives or the leaderboard
--                     texts ("Kobold Vermin slain: 3/10"). Quests under a collapsed
--                     header aren't listed there, so they are read by their ID.
-- Anything the game hands out as a secret value is skipped for that read.
--
-- A quest with a time limit keeps its card up, on top of the stack, until it is turned
-- in, given up or the time runs out: the time left next to the title and a bar under it
-- that runs empty, yellow in the last minute and pulsing red in the last seconds.
--   Retail            C_QuestLog.GetTimeAllowed (total and elapsed)
--   Classic           GetQuestTimers / GetQuestIndexForTimer (only the time left: the
--                     total is the most that was ever left, so after a reload mid-quest
--                     the bar starts full)

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local CORNER = MEDIA .. "Corner"
local GLOW = MEDIA .. "Glow"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local DONE_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"
local PAD = 8
local RADIUS = 8
local GAP = 4            -- between two cards, and below the XP tracker
local SCAN_DELAY = 0.1   -- the log's events come in bursts: one read after them
local SETTLE = 5         -- seconds after logging in: the log fills in without pop-ups
local FADE_IN = 0.15
local FADE_OUT = 0.5
local SLIDE = 10         -- px a new card slides down while it fades in
local MOVE_SPEED = 12    -- how fast the cards move to their place in the stack
local FLASH = 0.8        -- the changed objective's row flashes this long
local DELTA_HOLD = 1.5   -- the "+1" stays this long, then fades
local DELTA_FADE = 0.5
local POP = 0.35         -- the check mark of an objective just done pops this long
local BAR_FADE = 0.2     -- a full bar fades out this long (once its time is up)...
local BAR_SHRINK = 0.3   -- ...and its row closes up over this, starting halfway through the fade
local BURST_TIME = 0.8
local MAX_CARDS = 5
local SAMPLE_ID = -1
local SAMPLE_TIMER_ID = -2
local WARN_AT = 60       -- seconds left: the time turns yellow
local ALERT_AT = 15      -- and red, pulsing
local EXPIRED_HOLD = 3   -- a timer at 0:00 stays this long before its card lets go
local WARN_COLOR = { 1.00, 0.82, 0.18 }
local ALERT_COLOR = { 1.00, 0.27, 0.22 }

---------------------------------------------------------------------------
-- Reading the quest log
---------------------------------------------------------------------------

local hasInfo = C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries and true
local hasObjectives = C_QuestLog and C_QuestLog.GetQuestObjectives and true

local function numLogEntries()
    local n
    if hasInfo then
        n = C_QuestLog.GetNumQuestLogEntries()
    elseif GetNumQuestLogEntries then
        n = GetNumQuestLogEntries()
    end
    return Safe(n) or 0
end

-- The quest at line i of the log: its ID and title, or nil for headers and hidden quests.
local function logEntry(i)
    if hasInfo then
        local info = SafeTable(C_QuestLog.GetInfo(i))
        if not info or Safe(info.isHeader) or Safe(info.isHidden) then return nil end
        return Safe(info.questID), Safe(info.title)
    elseif GetQuestLogTitle then
        local title, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
        if Safe(isHeader) then return nil end
        return Safe(id), Safe(title)
    end
end

-- for QuestItems, which reads the same log
QuestProgress.NumLogEntries = numLogEntries
QuestProgress.LogEntry = logEntry

-- "3/10 Kobold Vermin slain" (Retail) or "Kobold Vermin slain: 3/10" (Classic) without
-- the count, which the card shows on its own.
local function stripCount(text)
    local s = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")
    s = s:gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    s = s:gsub("%s*%(%d+%%%)%s*$", "")
    return s ~= "" and s or text
end

-- One objective as { text, have, need, done, percent }, or nil while the game hasn't
-- loaded it yet (or hides it).
local function objective(id, text, kind, done, have, need)
    text = Safe(text)
    if type(text) ~= "string" or text == "" then return nil end
    kind, have, need = Safe(kind), Safe(have), Safe(need)
    done = Safe(done) and true or false
    local percent = kind == "progressbar"
    if percent then
        -- bonus objectives fill a bar instead of counting
        have = GetQuestProgressBarPercent and Safe(GetQuestProgressBarPercent(id))
        if done then have = 100 end
        if not have then return nil end
        have, need = math.floor(have + 0.5), 100
    end
    if type(have) ~= "number" or type(need) ~= "number" then
        local a, b = text:match("(%d+)%s*/%s*(%d+)")
        have, need = tonumber(a), tonumber(b)
    end
    return { text = stripCount(text), have = have, need = need, done = done, percent = percent }
end

-- The quest's objectives, or nil when they can't be read right now. index: its line in
-- the log, for clients without GetQuestObjectives.
local function readObjectives(id, index)
    local objs = hasObjectives and SafeTable(C_QuestLog.GetQuestObjectives(id))
    if objs and #objs > 0 then
        local list = {}
        for i, o in ipairs(objs) do
            o = SafeTable(o)
            list[i] = o and objective(id, o.text, o.type, o.finished, o.numFulfilled, o.numRequired)
            if not list[i] then return nil end
        end
        return list
    end
    if index and GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
        local list = {}
        for j = 1, Safe(GetNumQuestLeaderBoards(index)) or 0 do
            local text, kind, done = GetQuestLogLeaderBoard(j, index)
            list[j] = objective(id, text, kind, done)
            if not list[j] then return nil end
        end
        return list
    end
    return objs and {} or nil -- a quest without objectives, or unknown
end

local function snapshot(id, title, index)
    local objs = readObjectives(id, index)
    if not objs then return nil end
    local complete = #objs > 0
    for _, o in ipairs(objs) do
        if not o.done then complete = false end
    end
    if not complete and #objs > 0 and C_QuestLog and C_QuestLog.IsComplete then
        complete = Safe(C_QuestLog.IsComplete(id)) and true or false
    end
    return { id = id, title = title, objectives = objs, complete = complete }
end

-- What moved on from old to q: { [objective] = its count before }, and whether the
-- quest just got complete.
local function diff(old, q)
    local changes, any = {}, false
    local hadAny = #old.objectives > 0 -- objectives that only now loaded are no progress
    for i, o in ipairs(q.objectives) do
        local p = old.objectives[i]
        if p then
            if (o.have and p.have and o.have > p.have) or (o.done and not p.done) then
                changes[i] = p.have or 0
                any = true
            end
        elseif hadAny then
            changes[i] = 0 -- a new stage of the quest
            any = true
        end
    end
    return any and changes or nil, (q.complete and not old.complete) or false
end

local known = {}         -- questID -> its latest snapshot
local settleUntil = 0
local scanPending = false
local timers = {}        -- questID -> { expires = GetTime() it runs out, total = seconds }
local timerTotals = {}   -- Classic: questID -> the most time ever left
local sampleTimer        -- the "Test timer" card's

-- The quests seen in the log: questID -> { id, title, ... }. Also the ones under a
-- collapsed header (Classic), which the log itself doesn't list.
function QuestProgress.Known() return known end

-- The time limits of the quests in the log. A timer that only moved by rounding keeps
-- its old end, so the countdown doesn't jitter.
local function readTimers()
    local list, now = {}, GetTime()
    local function add(id, left, total)
        if type(left) ~= "number" or type(total) ~= "number" or total <= 0 then return end
        local expires = now + left
        local old = timers[id]
        if old and math.abs(old.expires - expires) < 1.5 then expires = old.expires end
        list[id] = { expires = expires, total = total }
    end
    if C_QuestLog and C_QuestLog.GetTimeAllowed then
        for id in pairs(known) do
            local total, elapsed = C_QuestLog.GetTimeAllowed(id)
            total, elapsed = Safe(total), Safe(elapsed)
            if type(total) == "number" and type(elapsed) == "number" then
                add(id, total - elapsed, total)
            end
        end
    elseif GetQuestTimers and GetQuestIndexForTimer then
        local secs = { GetQuestTimers() }
        for i = 1, select("#", GetQuestTimers()) do
            local left = tonumber(Safe(secs[i]))
            local index = Safe(GetQuestIndexForTimer(i))
            local id = index and logEntry(index)
            if id and left then
                timerTotals[id] = math.max(timerTotals[id] or 0, left)
                add(id, left, timerTotals[id])
            end
        end
    end
    timers = list
end

-- The quest you follow, whose card stays up while the option is on: the focused one
-- (Retail: the one with the arrow and waypoint). Clients without that know only the
-- quests watched in the tracker; there it is the first of them.
local function focusedQuest()
    local cfg = ns.db.questProgress
    if not (cfg.enabled and cfg.focusedQuest) then return nil end
    local id
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
        id = Safe(C_SuperTrack.GetSuperTrackedQuestID())
    elseif C_QuestLog and C_QuestLog.GetQuestIDForQuestWatchIndex then
        id = Safe(C_QuestLog.GetQuestIDForQuestWatchIndex(1))
    elseif GetQuestIndexForWatch then
        local index = Safe(GetQuestIndexForWatch(1))
        id = index and logEntry(index)
    end
    if type(id) == "number" and id > 0 and known[id] then return id end
end

-- The timer a quest's card shows, or nil.
local function activeTimer(id)
    if id == SAMPLE_TIMER_ID then return sampleTimer end
    local cfg = ns.db.questProgress
    if not (cfg.enabled and cfg.timedQuests) then return nil end
    local t = timers[id]
    if t and t.expires > GetTime() - EXPIRED_HOLD then return t end
end

function QuestProgress:Scan()
    scanPending = false
    local quiet = GetTime() < settleUntil
    local updates, seen = {}, {}
    local function consider(q)
        local old = known[q.id]
        if old and not quiet then
            local changes, completed = diff(old, q)
            if changes or completed then
                updates[#updates + 1] = { q = q, changes = changes or {}, completed = completed }
            end
        end
        known[q.id] = q -- a quest seen for the first time (accepted, logged in) only goes in
    end
    for i = 1, numLogEntries() do
        local id, title = logEntry(i)
        if id and not seen[id] then
            seen[id] = true
            local q = snapshot(id, title, i)
            if q then consider(q) end
        end
    end
    -- quests the log didn't list: under a collapsed header (Classic), or gone
    for id, old in pairs(known) do
        if not seen[id] then
            if C_QuestLog and C_QuestLog.IsOnQuest and Safe(C_QuestLog.IsOnQuest(id)) == false then
                known[id] = nil
            elseif hasObjectives then
                local q = snapshot(id, old.title, nil)
                if q then consider(q) end
            end
        end
    end
    readTimers()
    if #updates > 0 then self:Report(updates) end
    self:UpdatePins()
end

local function requestScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, function() QuestProgress:Scan() end)
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

-- A dark rounded rectangle behind frame: a middle, a strip above and below it between
-- the corners, and the four corners.
local function roundedPanel(frame)
    local function piece(tex)
        local t = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
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
    -- the corner texture is the bottom left one; the others are it mirrored
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

local function CreateRow(card)
    local r = CreateFrame("Frame", nil, card)
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
    r.label:SetWordWrap(false) -- a long objective ends in "..."
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.count:SetJustifyH("RIGHT")
    r.delta = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.delta:SetPoint("RIGHT", r.count, "LEFT", -4, 0)
    r.bar = XPBar.Create(r)
    r.B = {}
    return r
end

local function CreateCard(holder)
    local c = CreateFrame("Frame", nil, holder)
    c.bg = roundedPanel(c)
    c.burst = c:CreateTexture(nil, "BORDER")
    c.burst:SetTexture(GLOW)
    c.burst:SetBlendMode("ADD")
    c.burst:Hide()
    c.banner = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.banner:SetText(L["Quest complete!"])
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.title:SetJustifyH("LEFT")
    c.title:SetWordWrap(false)
    c.time = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.time:SetJustifyH("RIGHT")
    c.tbar = XPBar.Create(c)
    c.TB = {}
    c.rows = {}
    return c
end

local function CreateHolder()
    local h = CreateFrame("Frame", "WombatLogQuestProgress", UIParent)
    h:SetFrameStrata("MEDIUM")
    h:SetClampedToScreen(true)
    h:SetMovable(true)
    h:EnableMouse(false)
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function()
        if ns.db.questProgress.anchor == "free" then h:StartMoving() end
    end)
    h:SetScript("OnDragStop", function()
        h:StopMovingOrSizing()
        local cfg = ns.db.questProgress
        if cfg.anchor ~= "free" then return end
        local s = UIParent:GetEffectiveScale() / h:GetEffectiveScale()
        local cx = h:GetCenter()
        cfg.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        cfg.y = math.floor(h:GetTop() - UIParent:GetHeight() * s / 2 + 0.5)
        QuestProgress.anchorKey = nil
        QuestProgress:Anchor()
    end)
    h:SetSize(1, 1)
    h:Hide()

    h.overlay = h:CreateTexture(nil, "OVERLAY")
    h.overlay:SetAllPoints()
    h.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    h.overlayText = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.overlayText:SetPoint("BOTTOM", h, "TOP", 0, 2)
    h.overlay:Hide()
    h.overlayText:Hide()
    return h
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

local cards = {} -- shown: the ones with a timer first, then the focused quest, then newest first
local pool = {}

local function formatTime(left)
    local s = math.ceil(left)
    if s >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
    end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- Timer cards to the top, then the focused quest, each part keeping its order.
local function sortCards()
    local timed, focus, rest = {}, {}, {}
    for _, c in ipairs(cards) do
        local list = c.timer and timed or c.focus and focus or rest
        list[#list + 1] = c
    end
    wipe(cards)
    for _, c in ipairs(timed) do cards[#cards + 1] = c end
    for _, c in ipairs(focus) do cards[#cards + 1] = c end
    for _, c in ipairs(rest) do cards[#cards + 1] = c end
end

local function fraction(o, have)
    if o.need and o.need > 0 and have then return math.max(0, math.min(1, have / o.need)) end
    return 0
end

local function hasBar(o)
    return ns.db.questProgress.bars and (o.percent or (o.need and o.need > 1)) or false
end

-- How much of an objective's bar is open: 1 shown, 0 folded away (full bars go
-- once they've been full a moment, when that option is on).
local function barOpen(s)
    return (ns.db.questProgress.bar.hideFull and s.barK) or 1
end

-- Stacks the card's rows under its header, each as tall as its bar is open, and
-- sizes the card to them.
local function placeRows(card)
    local y = card.rowsY
    for i, s in ipairs(card.objs) do
        local r = card.rows[i]
        local k = barOpen(s)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", card, "TOPLEFT", PAD - 3, -y)
        local h = r.lineH + r.barH * k
        r:SetHeight(h)
        r.bar:SetShown(s.bar and k > 0)
        if not (s.bar and k > 0) then r.bar.glow:Hide() end
        y = y + h + 1
    end
    card.height = y + PAD - 1
    card:SetHeight(card.height)
end

local function countText(o)
    if o.percent then return (o.have or 0) .. "%" end
    if o.need and o.need > 1 and o.have then return o.have .. "/" .. o.need end
    return ""
end

-- Takes the quest's latest objectives into the card: the changed ones fill from where
-- they are now (or were, for a new card) and light up.
local function takeObjectives(card, q, changes)
    for i, o in ipairs(q.objectives) do
        local s = card.objs[i]
        local before = changes[i]
        if not s then
            local start = before and fraction(o, before) or (o.done and not o.need and 1 or fraction(o, o.have))
            -- full before this card came up: its bar isn't shown at all
            s = { value = start, barK = (o.done and not before) and 0 or 1 }
            card.objs[i] = s
        end
        -- no longer done (an item went): the bar comes back
        if not o.done then s.barK, s.fullAge, s.collapseT = 1, nil, nil end
        if before then
            s.from = s.value
            s.changeAge = 0
            if o.have then
                local recent = s.deltaAge and s.deltaAge < DELTA_HOLD + DELTA_FADE
                s.delta = (recent and s.delta or 0) + (o.have - before)
                s.deltaAge = 0
            end
            if o.done and not s.done then s.doneAge = 0 end
        end
        s.target = (o.need and o.need > 0) and fraction(o, o.have) or (o.done and 1 or 0)
        s.text, s.have, s.need, s.done, s.percent = o.text, o.have, o.need, o.done, o.percent
        s.from = s.from or s.value
    end
    for i = #card.objs, #q.objectives + 1, -1 do card.objs[i] = nil end
end

-- Lays out the card from its objectives and the settings.
function QuestProgress:Fill(card)
    local cfg = ns.db.questProgress
    local font, _, outline, smallOutline = ns.AlertFonts(cfg)
    local size = cfg.textSize
    local lineH = size + 4
    local W = cfg.width
    local rowW = W - (PAD - 3) * 2
    card:SetWidth(W)
    for _, t in ipairs(card.bg) do t:SetAlpha(cfg.bgOpacity) end

    local y = PAD
    local banner = card.complete and cfg.completeBanner
    card.banner:SetShown(banner and true or false)
    if banner then
        ns.SetFont(card.banner, font, size + 3, outline)
        local g = cfg.completeColor
        card.banner:SetTextColor(g[1], g[2], g[3])
        card.banner:ClearAllPoints()
        card.banner:SetPoint("TOP", card, "TOP", 0, -y)
        card.burst:SetVertexColor(g[1], g[2], g[3], 1)
        card.burst:SetPoint("CENTER", card.banner, "CENTER")
        y = y + size + 7
    end

    card.icon:SetTexture(card.complete and DONE_ICON or QUEST_ICON)
    card.icon:SetSize(size + 2, size + 2)
    card.icon:ClearAllPoints()
    card.icon:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
    ns.SetFont(card.title, font, size + 1, smallOutline)
    card.title:SetTextColor(1, 0.82, 0.18)
    card.title:SetText(card.titleText or "")
    card.title:ClearAllPoints()
    card.title:SetPoint("LEFT", card.icon, "RIGHT", 4, 0)
    local t = card.timer
    local timeW = 0
    card.time:SetShown(t and true or false)
    card.tbar:SetShown(t and true or false)
    card.tbar.glow:Hide()
    if t then
        -- room for the longest time this timer shows
        ns.SetFont(card.time, font, size + 1, smallOutline)
        card.time:SetText(t.total >= 3600 and "00:00:00" or "00:00")
        timeW = math.ceil(card.time:GetStringWidth()) + 6
        card.timeStr = nil
        card.time:ClearAllPoints()
        card.time:SetPoint("RIGHT", card, "TOPRIGHT", -PAD, -(y + (size + 2) / 2))
    end
    card.title:SetWidth(W - PAD * 2 - size - 6 - timeW)
    y = y + lineH + 3
    if t then
        local B, cb = card.TB, cfg.bar
        for k, v in pairs(cb) do B[k] = v end
        B.segments, B.rested, B.percent, B.gainFlash, B.glow = 0, false, false, false, false
        XPBar.Apply(card.tbar, B, W - PAD * 2, cb.height, cfg.barColor, font, smallOutline)
        card.tbar:ClearAllPoints()
        card.tbar:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -y)
        y = y + cb.height + 5
    end

    for i, s in ipairs(card.objs) do
        local r = card.rows[i] or CreateRow(card)
        card.rows[i] = r
        r:Show()
        r:SetWidth(rowW)
        ns.SetFont(r.label, font, size, smallOutline)
        ns.SetFont(r.count, font, size, smallOutline)
        ns.SetFont(r.delta, font, size, smallOutline)
        local hc = cfg.highlightColor
        r.flash:SetVertexColor(hc[1], hc[2], hc[3], 1)
        r.delta:SetTextColor(hc[1], hc[2], hc[3])
        r.dot:ClearAllPoints()
        r.dot:SetPoint("CENTER", r, "TOPLEFT", 8, -lineH / 2)
        r.check:SetPoint("CENTER", r, "TOPLEFT", 8, -lineH / 2)
        r.label:ClearAllPoints()
        r.label:SetPoint("LEFT", r, "TOPLEFT", 16, -lineH / 2)
        r.count:ClearAllPoints()
        r.count:SetPoint("RIGHT", r, "TOPRIGHT", -3, -lineH / 2)
        r.count:SetText(countText(s))
        r.label:SetText(s.text)
        -- room for the count, and for the "+1" while the objective is lit
        local countW = math.ceil(r.count:GetStringWidth())
        local deltaW = 0
        if s.changeAge then
            r.delta:SetText("+" .. (s.delta or 0) .. (s.percent and "%" or ""))
            deltaW = math.ceil(r.delta:GetStringWidth()) + 4
        end
        r.label:SetWidth(math.max(20, rowW - 16 - 3 - countW - deltaW - 6))

        r.lineH, r.barH = lineH, 0
        s.bar = hasBar(s)
        if s.bar then
            local B, cb = r.B, cfg.bar
            for k, v in pairs(cb) do B[k] = v end
            B.segments = (cb.segments and not s.percent and s.need <= XPBar.MAX_SEGMENTS) and s.need or 0
            B.rested, B.percent = false, false
            XPBar.Apply(r.bar, B, rowW - 19, cb.height, s.done and cfg.doneColor or cfg.barColor, font, smallOutline)
            r.bar:ClearAllPoints()
            r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -lineH)
            r.barH = cb.height + 3
        end
    end
    for i = #card.objs + 1, #card.rows do
        card.rows[i]:Hide()
        card.rows[i].bar.glow:Hide()
    end
    card.rowsY = y
    placeRows(card)
    self:RenderCard(card)
end

-- The parts that move: fills, flashes, the "+1", the check marks, the burst.
function QuestProgress:RenderCard(card)
    local cfg = ns.db.questProgress
    local size = cfg.textSize
    local hc, dc = cfg.highlightColor, cfg.doneColor
    for i, s in ipairs(card.objs) do
        local r = card.rows[i]
        local lit = s.changeAge ~= nil
        -- the row flashes, then keeps a faint light while the card is up
        local flash = 0
        if lit then flash = 0.1 + 0.3 * math.max(0, 1 - s.changeAge / FLASH) end
        r.flash:SetAlpha(flash)

        local tc
        if s.done then tc = dc elseif lit then tc = hc end
        local dim = (not lit and not s.done and cfg.dimUnchanged) and 0.7 or 1
        if tc then
            r.label:SetTextColor(tc[1], tc[2], tc[3])
            r.count:SetTextColor(tc[1], tc[2], tc[3])
        else
            r.label:SetTextColor(dim, dim, dim)
            r.count:SetTextColor(dim, dim, dim)
        end

        local da = 0
        if s.deltaAge and s.delta and s.delta > 0 then
            da = s.deltaAge < DELTA_HOLD and 1 or math.max(0, 1 - (s.deltaAge - DELTA_HOLD) / DELTA_FADE)
        end
        r.delta:SetAlpha(da)

        r.dot:SetShown(not s.done)
        r.dot:SetVertexColor(dim, dim, dim, 1)
        r.check:SetShown(s.done)
        if s.done then
            local k = s.doneAge and math.max(0, 1 - s.doneAge / POP) or 0
            local cs = (size + 2) * (1 + 0.9 * k)
            r.check:SetSize(cs, cs)
        end

        if s.bar and s.collapseT then
            -- on its way out: fading, without the glow
            r.bar:SetAlpha(math.max(0, 1 - s.collapseT / BAR_FADE))
            r.bar.glow:Hide()
        elseif s.bar and barOpen(s) > 0 then
            r.bar:SetAlpha(1)
            XPBar.Render(r.bar, r.B, s.value, s.from, s.changeAge or math.huge, 0, lit and hc or nil)
        end
    end
    local t = card.timer
    if t then
        local now = GetTime()
        local left = math.max(0, t.expires - now)
        local s = formatTime(left)
        if s ~= card.timeStr then
            card.time:SetText(s)
            card.timeStr = s
        end
        local col, a
        if left < ALERT_AT then
            col, a = ALERT_COLOR, 0.55 + 0.45 * math.abs(math.cos(now * math.pi * 1.5))
        elseif left < WARN_AT then
            col, a = WARN_COLOR, 1
        else
            col, a = nil, 1
        end
        if col then card.time:SetTextColor(col[1], col[2], col[3]) else card.time:SetTextColor(1, 1, 1) end
        card.time:SetAlpha(a)
        card.tbar.color = col or cfg.barColor
        local v = t.total > 0 and math.min(1, left / t.total) or 0
        XPBar.Render(card.tbar, card.TB, v, v, math.huge, 0, nil)
        card.tbar:SetAlpha(a)
    end
    if card.burstT then
        local p = math.min(1, card.burstT / BURST_TIME)
        local e = 1 - (1 - p) * (1 - p)
        local w = cfg.width * (0.4 + 1.1 * e)
        card.burst:SetSize(w, w * 0.4)
        card.burst:SetAlpha(1 - p * p)
        card.burst:SetShown(p < 1)
    else
        card.burst:Hide()
    end
end

local function release(card)
    card:Hide()
    card.burst:Hide()
    card.timer, card.focus = nil, nil
    card.tbar.glow:Hide()
    for _, r in ipairs(card.rows) do r.bar.glow:Hide() end
    pool[#pool + 1] = card
end

-- Lets go of the oldest cards that aren't pinned (timer, focused quest) until at most
-- max of them are left.
local function trim(max)
    local n = 0
    for _, c in ipairs(cards) do
        if not (c.timer or c.focus) then n = n + 1 end
    end
    for i = #cards, 1, -1 do
        if n <= max then break end
        if not (cards[i].timer or cards[i].focus) then
            release(table.remove(cards, i))
            n = n - 1
        end
    end
end

-- Places the cards under each other (they glide there) and sizes the holder to them.
function QuestProgress:Layout()
    local h = self.holder
    local y = 0
    for _, c in ipairs(cards) do
        c.y = y
        if not c.curY then c.curY = y - SLIDE end
        c:ClearAllPoints()
        c:SetPoint("TOP", h, "TOP", 0, -c.curY)
        y = y + c.height + GAP
    end
    h:SetSize(ns.db.questProgress.width, math.max(1, y - GAP))
    h:SetShown(#cards > 0)
end

-- Shows q on a card, a new one on top or the one it already has, moved to the top.
-- changes: { [objective] = count before }; completed: the quest just got complete.
function QuestProgress:ShowQuest(q, changes, completed, sample)
    local cfg = ns.db.questProgress
    local card
    for i, c in ipairs(cards) do
        if c.id == q.id then
            card = table.remove(cards, i)
            break
        end
    end
    if not card then
        card = table.remove(pool) or CreateCard(self.holder)
        card.id, card.objs, card.curY, card.shownAge, card.burstT = q.id, {}, nil, 0, nil
        card:SetAlpha(0)
    end
    table.insert(cards, 1, card)
    card.timer = activeTimer(q.id)
    card.focus = q.id == focusedQuest() or nil
    sortCards()
    trim(math.max(1, math.min(MAX_CARDS, cfg.maxQuests)))
    card.sample = sample
    card.age = 0
    card.titleText = q.title
    card.complete = q.complete
    takeObjectives(card, q, changes)
    if completed and cfg.completeBanner then card.burstT = 0 end
    card:Show()
    self:Fill(card)
    self:Anchor()
    self:Layout()
end

-- One frame: fade the cards in and out, glide them, fill the bars, age the lights.
function QuestProgress:Step(dt)
    if #cards == 0 then return end
    if dt > 0.1 then dt = 0.1 end
    self:Anchor()
    local cfg = ns.db.questProgress
    local life = cfg.duration
    local speed = cfg.bar.speed
    local gone = false
    local now = GetTime()
    for _, c in ipairs(cards) do
        if c.timer and c.timer.expires < now - EXPIRED_HOLD then
            -- ran out: the card goes like any other
            if c.id == SAMPLE_TIMER_ID then sampleTimer = nil end
            c.timer = nil
            c.age = 0
            self:Fill(c)
            gone = true
        end
    end
    if gone then sortCards() end
    for i = #cards, 1, -1 do
        local c = cards[i]
        c.age = c.age + dt
        c.shownAge = c.shownAge + dt
        local a = math.min(1, c.shownAge / FADE_IN)
        local steady = (c.sample and self.unlocked) or c.timer or c.focus
        if not steady and c.age > life then a = math.min(a, 1 - (c.age - life) / FADE_OUT) end
        if a <= 0 then
            release(table.remove(cards, i))
            gone = true
        else
            c:SetAlpha(a)
            if c.curY ~= c.y then
                local d = c.y - c.curY
                c.curY = math.abs(d) < 0.5 and c.y or c.curY + d * math.min(1, dt * MOVE_SPEED)
                c:SetPoint("TOP", self.holder, "TOP", 0, -c.curY)
            end
            local folding = false
            for _, s in ipairs(c.objs) do
                if s.value ~= s.target then
                    local d = s.target - s.value
                    s.value = math.abs(d) < 0.002 and s.target or s.value + d * math.min(1, dt * speed)
                end
                -- a bar that has filled up waits a moment, then folds away
                if s.bar and s.done and s.barK > 0 and cfg.bar.hideFull and s.value == s.target then
                    if s.collapseT then
                        s.collapseT = s.collapseT + dt
                        local p = math.max(0, math.min(1, (s.collapseT - BAR_FADE / 2) / BAR_SHRINK))
                        s.barK = 1 - p * p * (3 - 2 * p)
                        if p >= 1 then s.barK, s.collapseT = 0, nil end
                        folding = true
                    else
                        s.fullAge = (s.fullAge or 0) + dt
                        if s.fullAge >= cfg.bar.hideDelay then s.collapseT = 0 end
                    end
                end
                if s.changeAge then s.changeAge = s.changeAge + dt end
                if s.deltaAge then s.deltaAge = s.deltaAge + dt end
                if s.doneAge then
                    s.doneAge = s.doneAge + dt
                    if s.doneAge > POP then s.doneAge = nil end
                end
            end
            if c.burstT then
                c.burstT = c.burstT + dt
                if c.burstT > BURST_TIME then c.burstT = nil end
            end
            if folding then
                placeRows(c)
                gone = true -- the cards under it close up
            end
            self:RenderCard(c)
        end
    end
    if gone then self:Layout() end
end

---------------------------------------------------------------------------
-- Quests with a time limit
---------------------------------------------------------------------------

-- Pins a card for every quest with a timer running and for the focused quest, and
-- lets go of the ones that lost it (turned in, given up, failed, focus moved on, or
-- the option turned off): they fade after the display time.
function QuestProgress:UpdatePins()
    if not self.holder then return end
    local changed = false
    local focus = focusedQuest()
    for _, c in ipairs(cards) do
        local f = c.id == focus or nil
        if f ~= c.focus then
            c.focus = f
            if not f then c.age = 0 end
            changed = true
        end
    end
    for _, c in ipairs(cards) do
        local t = activeTimer(c.id)
        if t ~= c.timer then
            local relayout = (t == nil) ~= (c.timer == nil)
                or (t and c.timer and (t.total >= 3600) ~= (c.timer.total >= 3600))
            c.timer = t
            if not t then c.age = 0 end -- fades after the display time
            if relayout then
                self:Fill(c)
                changed = true
            end
        end
    end
    if changed then
        sortCards()
        trim(math.max(1, math.min(MAX_CARDS, ns.db.questProgress.maxQuests)))
        self:Layout()
    end
    local now = GetTime()
    for id in pairs(timers) do
        local t = activeTimer(id)
        if t and t.expires > now and known[id] then
            local shown = false
            for _, c in ipairs(cards) do
                if c.id == id then shown = true break end
            end
            if not shown then self:ShowQuest(known[id], {}, false) end
        end
    end
    if focus and not self.unlocked then
        local shown = false
        for _, c in ipairs(cards) do
            if c.id == focus then shown = true break end
        end
        if not shown then self:ShowQuest(known[focus], {}, false) end
    end
end

---------------------------------------------------------------------------
-- Progress coming in
---------------------------------------------------------------------------

local delayed, delayedOrder = {}, {} -- held back while in combat

function QuestProgress:ShowUpdates(updates)
    local cfg = ns.db.questProgress
    local completed = false
    for _, u in ipairs(updates) do
        self:ShowQuest(u.q, u.changes, u.completed)
        completed = completed or u.completed
    end
    if completed and cfg.completeSound then
        ns.Alerts.PlaySound(cfg.completeSoundChoice, cfg.channel)
    elseif cfg.sound then
        ns.Alerts.PlaySound(cfg.soundChoice, cfg.channel)
    end
end

function QuestProgress:Report(updates)
    local cfg = ns.db and ns.db.questProgress
    if not cfg or not cfg.enabled or not self.holder or self.unlocked then return end
    if cfg.delayInCombat and Safe(UnitAffectingCombat("player")) then
        -- a quest against the clock, or the one you follow, shows right away
        local now, focus = {}, focusedQuest()
        for i = #updates, 1, -1 do
            if activeTimer(updates[i].q.id) or updates[i].q.id == focus then table.insert(now, 1, table.remove(updates, i)) end
        end
        if #now > 0 then self:ShowUpdates(now) end
        for _, u in ipairs(updates) do
            local d = delayed[u.q.id]
            if d then
                -- each objective keeps its count from before the fight
                for i, before in pairs(u.changes) do
                    if d.changes[i] == nil then d.changes[i] = before end
                end
                d.q, d.completed = u.q, d.completed or u.completed
            else
                delayed[u.q.id] = u
                delayedOrder[#delayedOrder + 1] = u.q.id
            end
        end
        return
    end
    self:ShowUpdates(updates)
end

function QuestProgress:Flush()
    if #delayedOrder == 0 then return end
    local updates = {}
    for _, id in ipairs(delayedOrder) do
        if known[id] then updates[#updates + 1] = delayed[id] end -- not turned in meanwhile
    end
    wipe(delayed)
    wipe(delayedOrder)
    local cfg = ns.db.questProgress
    if #updates > 0 and cfg.enabled and not self.unlocked then self:ShowUpdates(updates) end
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------

-- Free, or under the XP tracker (at its spot on the top edge while it is hidden).
function QuestProgress:Anchor()
    local cfg, h = ns.db.questProgress, self.holder
    local key, tracker = "free", nil
    if cfg.anchor == "tracker" then
        tracker = ns.XPTracker and ns.XPTracker.frame
        key = (tracker and tracker:IsShown()) and "tracker" or "top"
    end
    if key == self.anchorKey then return end
    self.anchorKey = key
    h:ClearAllPoints()
    if key == "tracker" then
        h:SetPoint("TOP", tracker.content, "BOTTOM", 0, -GAP)
    elseif key == "top" then
        local X = ns.db.xpTracker
        local k = X.scale / cfg.scale
        h:SetPoint("TOP", UIParent, "TOP", X.x * k, -(X.offset * k + GAP))
    else
        h:SetPoint("TOP", UIParent, "CENTER", cfg.x, cfg.y)
    end
end

---------------------------------------------------------------------------
-- Blizzard's yellow "Kobold Vermin slain: 3/10" in the middle of the screen
---------------------------------------------------------------------------

local QUEST_MESSAGES = {
    "ERR_QUEST_ADD_KILL_SII", "ERR_QUEST_ADD_ITEM_SII", "ERR_QUEST_ADD_FOUND_SII",
    "ERR_QUEST_ADD_PLAYER_KILL_SII", "ERR_QUEST_OBJECTIVE_COMPLETE_S", "ERR_QUEST_UNKNOWN_COMPLETE",
}
local questPatterns, questTypes
local blizzHidden = false

local function isQuestMessage(messageType, msg)
    if not questPatterns then
        questPatterns, questTypes = {}, {}
        for _, name in ipairs(QUEST_MESSAGES) do
            local fmt = _G[name]
            if type(fmt) == "string" and fmt ~= "" then
                questPatterns[#questPatterns + 1] = ns.FormatToPattern(fmt)
            end
            local t = _G["LE_GAME_" .. name]
            if type(t) == "number" then questTypes[t] = true end
        end
    end
    if messageType and questTypes[messageType] then return true end
    if type(msg) ~= "string" then return false end
    for _, p in ipairs(questPatterns) do
        if msg:match(p) then return true end
    end
    return false
end

-- The game's frame stops listening; everything that isn't quest progress goes on to it.
function QuestProgress:ApplyBlizzardText()
    local cfg = ns.db.questProgress
    local hide = (cfg.enabled and cfg.hideBlizzardText) and true or false
    if hide == blizzHidden or not UIErrorsFrame then return end
    if hide then
        UIErrorsFrame:UnregisterEvent("UI_INFO_MESSAGE")
    else
        UIErrorsFrame:RegisterEvent("UI_INFO_MESSAGE")
    end
    blizzHidden = hide
end

ns.Listen("UI_INFO_MESSAGE", function(...)
    if not blizzHidden then return end
    local messageType, msg
    if select("#", ...) >= 2 then messageType, msg = ... else msg = ... end
    -- a secret message can't be read: it always goes on
    if isQuestMessage(Safe(messageType), Safe(msg)) then return end
    local handler = UIErrorsFrame and UIErrorsFrame:GetScript("OnEvent")
    if handler then handler(UIErrorsFrame, "UI_INFO_MESSAGE", ...) end
end)

---------------------------------------------------------------------------
-- Settings, test and positioning
---------------------------------------------------------------------------

function QuestProgress:Init()
    self.holder = CreateHolder()
    self.holder:SetScript("OnUpdate", function(_, dt) self:Step(dt) end)
    settleUntil = GetTime() + SETTLE
    self:Apply()
    requestScan()
end

function QuestProgress:Apply()
    local h = self.holder
    if not h then return end
    local cfg = ns.db.questProgress
    h:SetScale(cfg.scale)
    self.anchorKey = nil
    self:Anchor()
    h.overlayText:SetText(cfg.anchor == "free" and L["WombatLog quest progress - drag to move"]
        or L["WombatLog quest progress - follows the XP tracker"])
    h:EnableMouse(self.unlocked and cfg.anchor == "free" or false)
    self:ApplyBlizzardText()
    if not cfg.enabled and not self.unlocked then
        for i = #cards, 1, -1 do
            if not cards[i].sample then release(table.remove(cards, i)) end
        end
    end
    for _, c in ipairs(cards) do
        local t = activeTimer(c.id)
        if c.timer and not t then c.age = 0 end
        c.timer = t
    end
    sortCards()
    trim(math.max(1, math.min(MAX_CARDS, cfg.maxQuests)))
    for _, c in ipairs(cards) do self:Fill(c) end
    self:Layout()
    self:UpdatePins()
end

local function sampleQuest(step)
    local done = step == 2
    return {
        id = SAMPLE_ID, title = L["Kobold Camp Cleanup"], complete = done,
        objectives = {
            { text = L["Kobold Vermin slain"], have = done and 10 or 5, need = 10, done = done },
            { text = L["Wax Candles"], have = done and 8 or 3, need = 8, done = done },
            { text = L["Kobold camp found"], done = true },
        },
    }
end

local function sampleCard()
    for _, c in ipairs(cards) do
        if c.id == SAMPLE_ID then return c end
    end
end

-- Settings button: a sample quest moving on; pressed again while it is up, it gets done.
function QuestProgress:Test()
    if self.unlocked then self:SetLocked(true) end
    local card = sampleCard()
    if card and self.testStep == 1 then
        self.testStep = 2
        self:ShowUpdates({ { q = sampleQuest(2), changes = { [1] = 5, [2] = 3 }, completed = true } })
    else
        if card then
            release(card)
            for i, c in ipairs(cards) do
                if c == card then table.remove(cards, i) break end
            end
        end
        self.testStep = 1
        self:ShowUpdates({ { q = sampleQuest(1), changes = { [1] = 4 }, completed = false } })
    end
end

-- Settings button: a sample quest against the clock, from yellow to red to run out.
function QuestProgress:TestTimer()
    if self.unlocked then self:SetLocked(true) end
    sampleTimer = { expires = GetTime() + 25, total = 90 }
    self:ShowQuest({
        id = SAMPLE_TIMER_ID, title = L["Escort the Caravan"], complete = false,
        objectives = { { text = L["Caravan escorted"], done = false } },
    }, {}, false)
end

function QuestProgress:SetLocked(locked)
    self.unlocked = not locked or nil
    local h = self.holder
    h.overlay:SetShown(not locked)
    h.overlayText:SetShown(not locked)
    if locked then
        local card = sampleCard()
        if card then
            for i, c in ipairs(cards) do
                if c == card then table.remove(cards, i) break end
            end
            release(card)
        end
        self:Layout()
    else
        self:ShowQuest(sampleQuest(1), {}, false, true)
    end
    self:Apply()
    if ns.Config then ns.Config:RefreshAll() end
end

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------

ns.Listen("QUEST_LOG_UPDATE", requestScan)
ns.Listen("QUEST_WATCH_UPDATE", requestScan)
ns.Listen("QUEST_WATCH_LIST_CHANGED", requestScan)
ns.Listen("SUPER_TRACKING_CHANGED", requestScan)
ns.Listen("UNIT_QUEST_LOG_CHANGED", requestScan, "player")

-- a quest taken (again) starts over: its first read only goes in
ns.Listen("QUEST_ACCEPTED", function(...)
    local n = select("#", ...)
    local id = n > 0 and Safe((select(n, ...))) -- (questID) or (logIndex, questID)
    if id then known[id], timerTotals[id] = nil, nil end
    requestScan()
end)

local function forget(id)
    id = Safe(id)
    if id then known[id], timerTotals[id] = nil, nil end
end
ns.Listen("QUEST_REMOVED", forget)
ns.Listen("QUEST_TURNED_IN", forget)

local loggedIn = false
ns.Listen("PLAYER_ENTERING_WORLD", function()
    -- only the first loading screen: the log comes in bit by bit after it
    if not loggedIn then
        loggedIn = true
        settleUntil = GetTime() + SETTLE
    end
    requestScan()
end)

ns.Listen("PLAYER_REGEN_ENABLED", function()
    C_Timer.After(0.3, function() QuestProgress:Flush() end)
end)
