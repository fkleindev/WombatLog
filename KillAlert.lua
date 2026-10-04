local ADDON, ns = ...
local KillAlert = {}
ns.KillAlert = KillAlert
local Safe = ns.Safe

-- A rewarding pop-up when a mob you fought dies: "+342 XP" counting up, the mob's
-- name, your XP bar filling, a multi-kill counter and a sound.
--
-- Where kills come from:
--   all clients     the XP message ("X dies, you gain N experience."); when it can't
--                   be read, the XP comes from your XP bar's change instead
--   Classic         the combat log's PARTY_KILL (also kills without XP)
--   Forever/Retail  no kill event without XP: your target dying after you hit it

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local MERGE = 1.2        -- signals this close belong to one kill (death, XP message, XP bar)
local MULTI_WINDOW = 4   -- kills this close count as a multi-kill
local COUNT_UP = 0.5     -- seconds the XP number counts up
local POP = 0.25
local BURST_TIME = 0.6
local FADE_OUT = 0.5
local HIT_MEMORY = 30    -- a target you hit this recently counts as yours when it dies

local SAMPLE = { name = "Defias Thug", xp = 342, rested = 171 }

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

---------------------------------------------------------------------------
-- XP bar
---------------------------------------------------------------------------

local function xpFraction()
    local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    if not xp or not max or max <= 0 then return nil end
    return xp / max
end

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

    f.bar = CreateFrame("StatusBar", nil, c)
    f.bar:SetStatusBarTexture(WHITE)
    f.bar:SetMinMaxValues(0, 1)
    f.bar:SetPoint("TOP", f.name, "BOTTOM", 0, -5)
    f.barBg = f.bar:CreateTexture(nil, "BACKGROUND")
    f.barBg:SetAllPoints()
    f.barBg:SetColorTexture(0, 0, 0, 0.55)
    f.barSpark = f.bar:CreateTexture(nil, "OVERLAY")
    f.barSpark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    f.barSpark:SetBlendMode("ADD")

    f.pop = c:CreateAnimationGroup()
    local grow = f.pop:CreateAnimation("Scale")
    setScaleAnim(grow, 1.7, 1)
    grow:SetDuration(POP); grow:SetSmoothing("OUT")

    f.overlay = f:CreateTexture(nil, "BORDER")
    f.overlay:SetAllPoints()
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlayText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.overlayText:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.overlayText:SetText("WombatLog kill alert - drag to move")
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
    local K, A = ns.db.killAlert, ns.db.appearance
    f:SetScale(K.scale)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", K.x, K.y)
    f:SetSize(math.max(240, K.size * 8), K.size * 3.4)
    ns.SetFont(f.amount, A.amountFont, K.size, "THICKOUTLINE")
    ns.SetFont(f.name, A.nameFont, math.max(10, math.floor(K.size * 0.45)), "OUTLINE")
    f.name:SetTextColor(0.9, 0.9, 0.9)
    ns.SetFont(f.banner, A.amountFont, math.max(11, math.floor(K.size * 0.5)), "THICKOUTLINE")
    f.skull:SetSize(K.size, K.size)
    f.bar:SetSize(K.size * 6, math.max(4, math.floor(K.size * 0.2)))
    f.barSpark:SetSize(10, f.bar:GetHeight() * 3)
    local c = K.color
    f.bar:SetStatusBarColor(c[1], c[2], c[3], 0.95)
    f.burst:SetVertexColor(c[1], c[2], c[3], 1)
    self.burstBase = K.size * 7
    if not K.enabled and not self.unlocked then f:Hide() end
    if self.unlocked then self:ShowSample(true) end
end

---------------------------------------------------------------------------
-- Showing a kill
---------------------------------------------------------------------------

-- k = { name, xp, rested, multi, leveled, from, to }
function KillAlert:Render()
    local k, K, f = self.kill, ns.db.killAlert, self.frame
    local c = K.color
    if K.showXP and k.xp then
        f.amount:SetText("+" .. ns.Full(math.floor(k.shownXP + 0.5)) .. " XP")
    else
        f.amount:SetText("KILL")
    end
    f.amount:SetTextColor(c[1], c[2], c[3])
    local name = K.showName and k.name or ""
    if K.showXP and k.rested and k.rested > 0 then
        name = name .. (name ~= "" and "  " or "") .. "|cff9999ff(+" .. ns.Full(k.rested) .. " rested)|r"
    end
    f.name:SetText(name)
    f.name:SetShown(name ~= "")

    local banner
    if k.leveled then
        banner = "LEVEL UP!"
    elseif K.multiKill and k.multi >= 2 then
        banner = "x" .. k.multi .. " KILLS"
    end
    f.banner:SetText(banner or "")
    f.banner:SetTextColor(1, 0.82, 0.18)
    f.banner:SetShown(banner ~= nil)

    local barOn = K.showBar and k.from ~= nil
    f.bar:SetShown(barOn)
    if barOn then
        f.bar:ClearAllPoints()
        f.bar:SetPoint("TOP", f.name:IsShown() and f.name or f.amount, "BOTTOM", 0, -5)
        f.bar:SetValue(k.shownBar)
        f.barSpark:SetPoint("CENTER", f.bar, "LEFT", k.shownBar * f.bar:GetWidth(), 0)
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
        k.shownBar = math.abs(d) < 0.002 and k.to or k.shownBar + d * math.min(1, dt * 6)
        changed = true
    end
    if changed then self:Render() end
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
    local same = k and now - k.t <= MERGE
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
    k = { t = now, name = name, guid = guid, xp = xp, rested = rested, fromMessage = xp ~= nil, multi = multi }
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

---------------------------------------------------------------------------
-- Test and positioning
---------------------------------------------------------------------------

function KillAlert:ShowSample(steady)
    local frac = xpFraction() or 0.4
    local k = {
        t = GetTime(), name = SAMPLE.name, xp = SAMPLE.xp, rested = SAMPLE.rested, multi = 1,
        from = math.max(0, frac - 0.08), to = frac,
    }
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

ns.Listen("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    msg = Safe(msg)
    if not msg then
        -- hidden message: still a kill, its XP comes from the XP bar
        KillAlert:OnKill(nil, nil, nil, nil)
        return
    end
    local name, xp, rested = parseKill(msg)
    if name then KillAlert:OnKill(name, nil, xp, rested) end
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
