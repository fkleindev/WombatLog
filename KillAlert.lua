local ADDON, ns = ...
local KillAlert = {}
ns.KillAlert = KillAlert
local Safe = ns.Safe
local L = ns.L
local XPBar = ns.XPBar

-- A rewarding pop-up when a mob you fought dies: "+342 XP" counting up, the mob's
-- name, your XP bar filling (optional), a multi-kill counter and a sound. Quests
-- you turn in get the same pop-up with the quest's name.
--
-- Where kills come from:
--   all clients     the XP message ("X dies, you gain N experience."); when it can't
--                   be read, the XP comes from your XP bar's change instead
--   Classic         the combat log's PARTY_KILL (also kills without XP)
--   Forever/Retail  no kill event without XP: your target dying after you hit it

local GLOW = "Interface\\AddOns\\WombatLog\\Media\\Glow"
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local QUEST_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"
local MERGE = 1.2        -- signals this close belong to one kill (death, XP message, XP bar)
local MULTI_WINDOW = 4   -- kills this close count as a multi-kill
local COUNT_UP = 0.5     -- seconds the XP number counts up
local POP = 0.25
local BURST_TIME = 0.6
local FADE_OUT = 0.5
local HIT_MEMORY = 30    -- a target you hit this recently counts as yours when it dies
local QUEST_WINDOW = 3   -- an XP message this long after the quest window closed is the quest's

local SAMPLE = { name = "Defias Thug", xp = 342, rested = 171 }
local SAMPLE_QUEST = { name = "The Defias Brotherhood", xp = 1250 }

---------------------------------------------------------------------------
-- XP message parsing (in the client's language)
---------------------------------------------------------------------------

-- "%s dies, you gain %d experience." -> a Lua pattern with two captures
local function toPattern(fmt)
    fmt = fmt:gsub("%.$", "")
    -- mark the placeholders (also numbered ones like %1$s), escape the rest, then
    -- turn the marks into captures
    fmt = fmt:gsub("%%%d%$s", "\001"):gsub("%%%d%$d", "\002")
    fmt = fmt:gsub("%%s", "\001"):gsub("%%d", "\002")
    fmt = fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("\001", "(.-)"):gsub("\002", "(%%d+)")
    return "^" .. fmt
end

local killPattern

-- Mob name and XP from a kill message; nil for XP without a kill (quests).
local function parseKill(msg)
    if not killPattern then
        killPattern = toPattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.")
    end
    local a, b, rest = msg:match(killPattern .. "(.*)$")
    if not a then
        a, b, rest = msg:match("^(.-) dies, you gain (%d+) experience(.*)$")
    end
    if not a then return nil end
    local name, xp = a, tonumber(b)
    if tonumber(a) and not tonumber(b) then name, xp = b, tonumber(a) end -- languages with swapped order
    local rested = rest and tonumber(rest:match("(%d+)"))
    return name, xp, rested
end

local questPattern

-- XP from a message without a kill ("You gain 1250 experience."), or nil.
local function parseQuestXP(msg)
    if not questPattern then
        questPattern = toPattern(COMBATLOG_XPGAIN_QUEST or "You gain %d experience.")
    end
    local xp = msg:match(questPattern)
    if not xp then xp = msg:match("^You gain (%d+) experience") end
    return tonumber(xp)
end

---------------------------------------------------------------------------
-- XP bar
---------------------------------------------------------------------------

local xpFraction = XPBar.Fraction

local lastXP, lastMax
local lastUpdate -- { t, from, to, leveled, delta } of the latest XP bar change

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function setScaleAnim(anim, from, to)
    if anim.SetScaleFrom then
        anim:SetScaleFrom(from, from); anim:SetScaleTo(to, to)
    else
        anim:SetFromScale(from, from); anim:SetToScale(to, to)
    end
end

local function CreateFrames()
    local f = CreateFrame("Frame", "WombatLogKillAlert", UIParent)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local cfg = ns.db.killAlert
        local s = UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        local cx, cy = f:GetCenter()
        cfg.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        cfg.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    end)
    f:SetSize(300, 100)
    f:Hide()

    -- glow ring behind everything, sized by hand (a Scale animation on it while
    -- the content scales can be drawn across the whole screen)
    f.burst = f:CreateTexture(nil, "BACKGROUND")
    f.burst:SetTexture(GLOW)
    f.burst:SetBlendMode("ADD")
    f.burst:SetPoint("CENTER", f, "CENTER", 0, 6)
    f.burst:SetSize(100, 100)
    f.burst:Hide()

    -- the content pops in as one piece
    local c = CreateFrame("Frame", nil, f)
    c:SetAllPoints()
    f.content = c

    f.amount = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.skull = c:CreateTexture(nil, "ARTWORK")
    f.skull:SetTexture(SKULL)
    f.skull:SetPoint("RIGHT", f.amount, "LEFT", -8, 0)
    f.name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.name:SetPoint("TOP", f.amount, "BOTTOM", 0, -3)
    f.banner = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.banner:SetPoint("BOTTOM", f.amount, "TOP", 0, 4)

    f.bar = XPBar.Create(c)
    f.bar:SetPoint("TOP", f.name, "BOTTOM", 0, -5)

    f.pop = c:CreateAnimationGroup()
    local grow = f.pop:CreateAnimation("Scale")
    setScaleAnim(grow, 1.7, 1)
    grow:SetDuration(POP); grow:SetSmoothing("OUT")

    f.overlay = f:CreateTexture(nil, "BORDER")
    f.overlay:SetAllPoints()
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlayText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.overlayText:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.overlayText:SetText(L["WombatLog kill alert - drag to move"])
    f.overlay:Hide()
    f.overlayText:Hide()
    return f
end

function KillAlert:Init()
    self.frame = CreateFrames()
    self.frame:SetScript("OnUpdate", function(_, dt) self:Step(dt) end)
    lastXP, lastMax = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    self:Apply()
end

function KillAlert:Apply()
    local f = self.frame
    if not f then return end
    local K = ns.db.killAlert
    local B = K.bar
    f:SetScale(K.scale)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", K.x, K.y)

    local numberFont, nameFont, outline, nameOutline = ns.AlertFonts(K)
    ns.SetFont(f.amount, numberFont, K.size, outline)
    ns.SetFont(f.name, nameFont, math.max(10, math.floor(K.size * 0.45)), nameOutline)
    f.name:SetTextColor(0.9, 0.9, 0.9)
    ns.SetFont(f.banner, numberFont, math.max(11, math.floor(K.size * 0.5)), outline)
    f.skull:SetSize(K.size, K.size)

    -- XP bar
    local w = B.width > 0 and B.width or K.size * 6
    local h = B.height > 0 and B.height or math.max(4, math.floor(K.size * 0.2))
    f:SetSize(math.max(240, K.size * 8, w + 20), K.size * 3.4)
    XPBar.Apply(f.bar, B, w, h, B.useTextColor and K.color or B.color, numberFont, nameOutline)

    local c = K.color
    f.burst:SetVertexColor(c[1], c[2], c[3], 1)
    self.burstBase = K.size * 7
    if not K.enabled and not ns.db.questAlert.enabled and not self.unlocked then f:Hide() end
    if self.unlocked then self:ShowSample(true) end
end

---------------------------------------------------------------------------
-- Showing a kill
---------------------------------------------------------------------------

-- k = { kind, name, xp, rested, multi, leveled, from, to }; kind "kill" or "quest"
function KillAlert:Render()
    local k, K, f = self.kill, ns.db.killAlert, self.frame
    local quest = k.kind == "quest"
    local Q = ns.db.questAlert
    local c = quest and Q.color or K.color
    if quest or (K.showXP and k.xp) then
        f.amount:SetText(L["+%s XP"]:format(ns.Full(math.floor(k.shownXP + 0.5))))
    else
        f.amount:SetText(L["KILL"])
    end
    f.amount:SetTextColor(c[1], c[2], c[3])
    f.skull:SetTexture(quest and QUEST_ICON or SKULL)
    local name
    if quest then
        name = Q.showName and k.name or ""
    else
        name = K.showName and ns.EventName(k.name) or ""
        if K.showXP and k.rested and k.rested > 0 then
            name = name .. (name ~= "" and "  " or "") .. "|cff9999ff(" .. L["+%s rested"]:format(ns.Full(k.rested)) .. ")|r"
        end
    end
    f.name:SetText(name)
    f.name:SetShown(name ~= "")

    local banner
    if k.leveled then
        banner = L["LEVEL UP!"]
    elseif not quest and K.multiKill and k.multi >= 2 then
        banner = L["x%d KILLS"]:format(k.multi)
    end
    f.banner:SetText(banner or "")
    f.banner:SetTextColor(1, 0.82, 0.18)
    f.banner:SetShown(banner ~= nil)

    local barOn = not quest and K.showBar and k.from ~= nil
    f.bar:SetShown(barOn)
    if barOn then
        f.bar:ClearAllPoints()
        f.bar:SetPoint("TOP", f.name:IsShown() and f.name or f.amount, "BOTTOM", 0, -5)
        XPBar.Render(f.bar, K.bar, k.shownBar, k.from, k.age)
    else
        f.bar.glow:Hide()
    end
    -- keep skull and text centered as a group
    f.amount:ClearAllPoints()
    f.amount:SetPoint("CENTER", f, "CENTER", (K.size + 8) / 2, K.size * 0.3)
end

function KillAlert:Show(k, fresh)
    local f, K = self.frame, ns.db.killAlert
    self.kill = k
    k.age = 0
    k.shownXP = k.shownXP or 0
    k.shownBar = k.from or 0
    local c = k.kind == "quest" and ns.db.questAlert.color or K.color
    f.burst:SetVertexColor(c[1], c[2], c[3], 1)
    f:SetAlpha(1)
    f:Show()
    self:Render()
    if fresh then
        f.pop:Stop(); f.pop:Play()
        self.burstT = 0
    end
end

-- One frame: count the XP up, fill the bar, grow the ring, then fade out.
function KillAlert:Step(dt)
    local f, k = self.frame, self.kill
    if self.burstT then
        self.burstT = self.burstT + dt
        local p = math.min(1, self.burstT / BURST_TIME)
        if p >= 1 then
            self.burstT = nil
            f.burst:Hide()
        else
            local eased = 1 - (1 - p) * (1 - p)
            local size = (self.burstBase or 200) * (0.3 + 1.2 * eased)
            f.burst:SetSize(size, size * 0.6)
            f.burst:SetAlpha(1 - p * p)
            f.burst:Show()
        end
    end
    if not k then return end
    k.age = k.age + dt
    local changed = false
    if k.xp and k.shownXP < k.xp then
        k.xpAge = (k.xpAge or 0) + dt
        local p = math.min(1, k.xpAge / COUNT_UP)
        k.shownXP = k.xp * (1 - (1 - p) * (1 - p))
        changed = true
    end
    if k.to and k.shownBar ~= k.to then
        local d = k.to - k.shownBar
        local speed = ns.db.killAlert.bar.speed
        k.shownBar = math.abs(d) < 0.002 and k.to or k.shownBar + d * math.min(1, dt * speed)
        changed = true
    end
    if changed then
        self:Render()
    elseif f.bar:IsShown() then
        XPBar.RenderEffects(f.bar, ns.db.killAlert.bar, k.shownBar, k.from, k.age)
    end
    if self.unlocked then return end
    local life = ns.db.killAlert.duration
    if k.age > life then
        local a = 1 - (k.age - life) / FADE_OUT
        if a <= 0 then
            self.kill = nil
            f:Hide()
        else
            f:SetAlpha(a)
        end
    end
end

local function playSound(multi)
    local K = ns.db.killAlert
    if not K.sound then return end
    ns.Alerts.PlayRaised(K.soundChoice, K.channel, K.risingPitch and multi or 1)
end

-- Fills the bar range from the latest XP bar change, if it belongs to this kill.
local function applyXPUpdate(k, now)
    local u = lastUpdate
    if u and math.abs(now - u.t) <= MERGE and not k.hasUpdate then
        k.hasUpdate = true
        k.from, k.to, k.leveled = u.from, u.to, u.leveled or k.leveled
        k.shownBar = u.from
        if not k.xp and u.delta and u.delta > 0 then k.xp = u.delta end
    end
end

-- Any kill signal. Signals close together merge into one kill.
function KillAlert:OnKill(name, guid, xp, rested)
    local K = ns.db and ns.db.killAlert
    if not K or not K.enabled or not self.frame or self.unlocked then return end
    local now = GetTime()
    local k = self.pending or self.kill
    local same = k and k.kind ~= "quest" and now - k.t <= MERGE
        and (not guid or not k.guid or guid == k.guid)
        and not (xp and k.xp and k.fromMessage) -- two XP messages are two kills
    if same then
        k.name = k.name or name
        k.guid = k.guid or guid
        if xp and not k.fromMessage then
            k.xp, k.rested, k.fromMessage = xp, rested, true
        end
        applyXPUpdate(k, now)
        if k == self.pending then
            if k.xp then self:Release(k) end
        else
            self:Render()
        end
        return
    end

    -- a new kill
    local multi = 1
    if self.lastKill and now - self.lastKill <= MULTI_WINDOW then multi = (self.lastMulti or 1) + 1 end
    self.lastKill, self.lastMulti = now, multi
    k = { kind = "kill", t = now, name = name, guid = guid, xp = xp, rested = rested, fromMessage = xp ~= nil, multi = multi }
    local frac = xpFraction()
    k.from, k.to = frac, frac
    applyXPUpdate(k, now)
    if not k.xp and not K.noXpKills then
        -- only kills that give XP: wait a moment for the XP to arrive
        self.pending = k
        C_Timer.After(MERGE, function()
            if self.pending == k then self.pending = nil end
        end)
        return
    end
    self:Show(k, true)
    playSound(multi)
end

-- A waiting kill (only kills with XP are shown) got its XP: show it now.
function KillAlert:Release(k)
    self.pending = nil
    self:Show(k, true)
    playSound(k.multi)
end

-- A quest turned in. The XP message and QUEST_TURNED_IN both report it: whichever
-- comes second fills in what the first lacked.
function KillAlert:OnQuest(title, xp)
    local Q = ns.db and ns.db.questAlert
    if not Q or not Q.enabled or not self.frame or self.unlocked then return end
    local now = GetTime()
    local k = self.kill
    if k and k.kind == "quest" and now - k.t <= MERGE and (not title or not k.name or title == k.name) then
        k.name = k.name or title
        if not k.xp or k.xp <= 0 then k.xp = xp end
        self:Render()
        return
    end
    if not xp or xp <= 0 then return end
    self:Show({ kind = "quest", t = now, name = title, xp = xp, multi = 1 }, true)
    if Q.sound then ns.Alerts.PlaySound(Q.soundChoice, Q.channel) end
end

---------------------------------------------------------------------------
-- Test and positioning
---------------------------------------------------------------------------

function KillAlert:ShowSample(steady, kind)
    local frac = xpFraction() or 0.4
    local k = {
        kind = "kill", t = GetTime(), name = SAMPLE.name, xp = SAMPLE.xp, rested = SAMPLE.rested, multi = 1,
        from = math.max(0, frac - 0.08), to = frac,
    }
    if kind == "quest" then
        k = { kind = "quest", t = GetTime(), name = SAMPLE_QUEST.name, xp = SAMPLE_QUEST.xp, multi = 1 }
    end
    if steady then k.shownXP, k.shownBar = k.xp, k.to end
    self:Show(k, not steady)
    if steady then k.shownBar = k.to; self:Render() end
end

-- Settings button: a sample kill with its sound.
function KillAlert:Test()
    if self.unlocked then self:SetLocked(true) end
    self:ShowSample(false)
    playSound(1)
end

-- Settings button: a sample quest with its sound.
function KillAlert:TestQuest()
    if self.unlocked then self:SetLocked(true) end
    self:ShowSample(false, "quest")
    local Q = ns.db.questAlert
    if Q.sound then ns.Alerts.PlaySound(Q.soundChoice, Q.channel) end
end

function KillAlert:SetLocked(locked)
    self.unlocked = not locked
    local f = self.frame
    f:EnableMouse(not locked)
    f.overlay:SetShown(not locked)
    f.overlayText:SetShown(not locked)
    if locked then
        self.kill = nil
        f:Hide()
    else
        self:ShowSample(true)
    end
    if ns.Config then ns.Config:RefreshAll() end
end

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------

-- Tells the XP tracker where the XP it is about to show comes from.
local function markSource(kind)
    local T = ns.XPTracker
    if T and T.frame then T:MarkSource(kind) end
end

-- The quest window: its title, and whether XP right now is a quest's.
local questTitle, questOpen, questClosed

local function questRecent()
    return questTitle and (questOpen or (questClosed and GetTime() - questClosed <= QUEST_WINDOW))
end

ns.Listen("QUEST_COMPLETE", function()
    questTitle = GetTitleText and Safe(GetTitleText())
    questOpen, questClosed = true, nil
end)

ns.Listen("QUEST_FINISHED", function()
    if questOpen then questOpen, questClosed = false, GetTime() end
end)

ns.Listen("QUEST_TURNED_IN", function(questID, xp)
    questID, xp = Safe(questID), Safe(xp)
    local title = questID and C_QuestLog and C_QuestLog.GetTitleForQuestID
        and Safe(C_QuestLog.GetTitleForQuestID(questID))
    if xp and xp > 0 then markSource("quest") end
    KillAlert:OnQuest(title or (questRecent() and questTitle) or nil, xp)
end)

ns.Listen("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    msg = Safe(msg)
    if not msg then
        -- hidden message: a quest's XP or a kill whose XP comes from the XP bar
        if questRecent() then
            markSource("quest")
        else
            markSource("kill")
            KillAlert:OnKill(nil, nil, nil, nil)
        end
        return
    end
    local name, xp, rested = parseKill(msg)
    if name then
        markSource("kill")
        KillAlert:OnKill(name, nil, xp, rested)
    elseif questRecent() then
        markSource("quest")
        KillAlert:OnQuest(questTitle, parseQuestXP(msg))
    end
end)

ns.Listen("PLAYER_XP_UPDATE", function()
    local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    if not xp or not max or max <= 0 then return end
    local now = GetTime()
    if lastXP and lastMax and lastMax > 0 then
        local leveled = xp < lastXP
        local delta = leveled and (lastMax - lastXP + xp) or (xp - lastXP)
        if delta > 0 then
            lastUpdate = { t = now, from = lastXP / lastMax, to = leveled and 1 or xp / max, leveled = leveled, delta = delta }
            local k = KillAlert.pending or KillAlert.kill
            if k and now - k.t <= MERGE then
                applyXPUpdate(k, now)
                if k == KillAlert.pending then
                    if k.xp then KillAlert:Release(k) end
                else
                    KillAlert:Render()
                end
            end
        end
    end
    lastXP, lastMax = xp, max
end)

ns.Listen("PLAYER_LEVEL_UP", function()
    local k = KillAlert.kill
    if k and GetTime() - k.t <= MERGE * 2 then
        k.leveled, k.to = true, 1
        KillAlert:Render()
    end
end)

-- Forever and Retail: no kill event without XP, so your target dying after you hit it.
-- (Classic clients get PARTY_KILL from CombatLog.lua.)
if not ns.useCombatLog then
    local hits = {} -- target GUID -> time you last hit it

    function KillAlert:OnHitTarget()
        local guid = Safe(UnitGUID("target"))
        if guid then hits[guid] = GetTime() end
    end

    local function checkTarget()
        local guid = Safe(UnitGUID("target"))
        local t = guid and hits[guid]
        if not t or GetTime() - t > HIT_MEMORY then return end
        if Safe(UnitIsDead("target")) then
            hits[guid] = nil
            KillAlert:OnKill(Safe(UnitName("target")), guid, nil, nil)
        end
    end
    ns.Listen("UNIT_HEALTH", checkTarget, "target")
    ns.Listen("UNIT_FLAGS", checkTarget, "target")
else
    function KillAlert:OnHitTarget() end
end
