local ADDON, ns = ...
local Alerts = {}
ns.Alerts = Alerts

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local FADE_OUT = 0.4
local RECENT_AURAS = 15

local CRIT_SAMPLE = { kind = "damage", amount = 1248, name = "Fireball", icon = "Interface\\Icons\\Spell_Fire_Fireball02" }
local PROC_SAMPLE = { name = "Clearcasting", icon = "Interface\\Icons\\Spell_Shadow_ManaBurn" }

---------------------------------------------------------------------------
-- Sounds
---------------------------------------------------------------------------

local CUSTOM_SOUNDS = {
    { value = "wl:chime", text = "WombatLog: Chime", file = MEDIA .. "Sounds\\CritChime.ogg" },
    { value = "wl:coin", text = "WombatLog: Coin", file = MEDIA .. "Sounds\\CritCoin.ogg" },
    { value = "wl:impact", text = "WombatLog: Impact", file = MEDIA .. "Sounds\\CritImpact.ogg" },
    { value = "wl:record", text = "WombatLog: Record fanfare", file = MEDIA .. "Sounds\\Record.ogg" },
    { value = "wl:proc", text = "WombatLog: Proc ping", file = MEDIA .. "Sounds\\Proc.ogg" },
}

-- Chime raised step by step for crit streaks of 2, 3 and 4+.
local STREAK_SOUNDS = {
    [2] = MEDIA .. "Sounds\\CritStreak2.ogg",
    [3] = MEDIA .. "Sounds\\CritStreak3.ogg",
    [4] = MEDIA .. "Sounds\\CritStreak4.ogg",
}

-- Only offered when the client's SOUNDKIT table actually has the key.
local BUILTIN_SOUNDS = {
    { "UI_EPICLOOT_TOAST", "Epic loot toast" },
    { "UI_LEGENDARY_LOOT_TOAST", "Legendary loot toast" },
    { "IG_QUEST_LIST_COMPLETE", "Quest complete" },
    { "READY_CHECK", "Ready check" },
    { "RAID_WARNING", "Raid warning" },
    { "MAP_PING", "Map ping" },
}

local function sharedMedia()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

function Alerts.SoundOptions()
    local list = {}
    for _, s in ipairs(CUSTOM_SOUNDS) do list[#list + 1] = s end
    if SOUNDKIT then
        for _, s in ipairs(BUILTIN_SOUNDS) do
            if SOUNDKIT[s[1]] then
                list[#list + 1] = { value = "kit:" .. s[1], text = "WoW: " .. s[2] }
            end
        end
    end
    local LSM = sharedMedia()
    if LSM then
        for _, name in ipairs(LSM:List("sound")) do
            if name ~= "None" then
                list[#list + 1] = { value = "lsm:" .. name, text = "SharedMedia: " .. name }
            end
        end
    end
    return list
end

local function play(value, channel)
    local kind, key = (value or ""):match("^(%a+):(.+)$")
    if kind == "wl" then
        for _, s in ipairs(CUSTOM_SOUNDS) do
            if s.value == value then return PlaySoundFile(s.file, channel) end
        end
    elseif kind == "kit" and SOUNDKIT and SOUNDKIT[key] then
        return PlaySound(SOUNDKIT[key], channel)
    elseif kind == "lsm" then
        local LSM = sharedMedia()
        local path = LSM and LSM:Fetch("sound", key, true)
        if path then return PlaySoundFile(path, channel) end
    end
    -- unknown or missing sound: fall back to the default chime
    PlaySoundFile(CUSTOM_SOUNDS[1].file, channel)
end
Alerts.PlaySound = play -- also used by the spell reminders

function Alerts:PlayConfigured()
    local S = ns.db.alerts.sound
    play(S.sound, S.channel)
end

function Alerts:PlayProcSound()
    local P = ns.db.procs
    play(P.soundChoice, P.channel)
end

function Alerts:PlayRecordSound()
    play("wl:record", ns.db.alerts.sound.channel)
end

---------------------------------------------------------------------------
-- Alert frame (used for crits and procs)
---------------------------------------------------------------------------

local function setScaleAnim(anim, from, to)
    if anim.SetScaleFrom then
        anim:SetScaleFrom(from, from); anim:SetScaleTo(to, to)
    else
        anim:SetFromScale(from, from); anim:SetToScale(to, to)
    end
end

local AlertFrame = {}
AlertFrame.__index = AlertFrame

-- getCfg returns the settings table with size, scale, x, y, duration, showIcon, glow.
local function CreateAlertFrame(globalName, label, getCfg, sample)
    local self = setmetatable({ getCfg = getCfg, sample = sample }, AlertFrame)
    local f = CreateFrame("Frame", globalName, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local cfg = getCfg()
        local s = UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        local cx, cy = f:GetCenter()
        cfg.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        cfg.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    end)
    f:Hide()
    self.frame = f

    f.glow = f:CreateTexture(nil, "BACKGROUND")
    f.glow:SetTexture(GLOW)
    f.glow:SetPoint("CENTER")
    f.glow:SetAlpha(0)

    -- content is what pops; the glow bursts separately behind it
    local c = CreateFrame("Frame", nil, f)
    c:SetAllPoints()

    f.amount = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.iconBorder = c:CreateTexture(nil, "ARTWORK")
    f.iconBorder:SetTexture(WHITE)
    f.icon = c:CreateTexture(nil, "ARTWORK", nil, 1)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon:SetPoint("CENTER", f.iconBorder)
    f.iconBorder:SetPoint("RIGHT", f.amount, "LEFT", -10, 0)
    f.name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.name:SetPoint("TOP", f.amount, "BOTTOM", 0, -2)
    f.banner = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.banner:SetPoint("BOTTOM", f.amount, "TOP", 0, 4)

    f.overlay = f:CreateTexture(nil, "BORDER")
    f.overlay:SetAllPoints()
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlayText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.overlayText:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.overlayText:SetText("WombatLog " .. label .. " - drag to move")
    f.overlay:Hide()
    f.overlayText:Hide()

    -- pop in, hold, fade out
    local show = f:CreateAnimationGroup()
    local fadeIn = show:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(0.08); fadeIn:SetOrder(1)
    local pop = show:CreateAnimation("Scale")
    pop:SetTarget(c)
    setScaleAnim(pop, 1.6, 1)
    pop:SetDuration(0.18); pop:SetSmoothing("OUT"); pop:SetOrder(1)
    local fadeOut = show:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(FADE_OUT); fadeOut:SetOrder(2)
    show:SetScript("OnFinished", function()
        if not self.unlocked then
            f:Hide()
            self.pulse:Stop()
        end
    end)
    self.showAnim, self.fadeOut = show, fadeOut

    local burst = f.glow:CreateAnimationGroup()
    local grow = burst:CreateAnimation("Scale")
    setScaleAnim(grow, 0.5, 1.6)
    grow:SetDuration(0.6); grow:SetSmoothing("OUT")
    local glowFade = burst:CreateAnimation("Alpha")
    glowFade:SetFromAlpha(0.9); glowFade:SetToAlpha(0); glowFade:SetDuration(0.6)
    self.burstAnim = burst

    -- banner pulse for long streaks
    local pulse = f.banner:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local beat = pulse:CreateAnimation("Scale")
    setScaleAnim(beat, 1, 1.15)
    beat:SetDuration(0.25)
    self.pulse = pulse

    return self
end

function AlertFrame:Apply()
    local f = self.frame
    local V, A = self.getCfg(), ns.db.appearance

    f:SetScale(V.scale)
    f:SetSize(math.max(260, V.size * 6), V.size * 2.4)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", V.x, V.y)

    ns.SetFont(f.amount, A.amountFont, V.size, "THICKOUTLINE")
    ns.SetFont(f.name, A.nameFont, math.max(10, math.floor(V.size * 0.36)), "OUTLINE")
    f.name:SetTextColor(0.9, 0.9, 0.9)

    local iconSize = math.floor(V.size * 1.1)
    f.iconBorder:SetSize(iconSize + 2, iconSize + 2)
    f.icon:SetSize(iconSize, iconSize)
    f.iconBorder:SetShown(V.showIcon)
    f.icon:SetShown(V.showIcon)
    f.name:SetShown(V.showName ~= false)

    -- keep icon + text centered as a group
    f.amount:ClearAllPoints()
    f.amount:SetPoint("CENTER", f, "CENTER", V.showIcon and (iconSize + 12) / 2 or 0, 6)

    f.glow:SetSize(V.size * 6, V.size * 3.2)
    self.fadeOut:SetStartDelay(math.max(0, V.duration - FADE_OUT))

    if self.unlocked and self.lastData then self:Render(self.lastData) end
end

-- d = { big, small, icon, color, banner, bannerColor, bannerScale, pulse }
function AlertFrame:Render(d)
    local f = self.frame
    local V, A = self.getCfg(), ns.db.appearance
    local c = d.color
    self.lastData = d
    f.amount:SetText(d.big or "")
    f.amount:SetTextColor(c[1], c[2], c[3])
    f.iconBorder:SetColorTexture(c[1], c[2], c[3], 1)
    f.icon:SetTexture(d.icon or 134400)
    f.name:SetText(d.small or "")
    f.glow:SetVertexColor(c[1], c[2], c[3], 1)

    if d.banner then
        local bc = d.bannerColor or c
        ns.SetFont(f.banner, A.amountFont, math.floor(math.max(12, V.size * 0.42) * (d.bannerScale or 1)), "THICKOUTLINE")
        f.banner:SetText(d.banner)
        f.banner:SetTextColor(bc[1], bc[2], bc[3])
        f.banner:Show()
    else
        f.banner:Hide()
    end
    if d.pulse then self.pulse:Play() else self.pulse:Stop() end
end

function AlertFrame:Show(d)
    local f = self.frame
    self:Render(d)
    self.showAnim:Stop()
    self.burstAnim:Stop()
    f:SetAlpha(1)
    f:Show()
    if self.unlocked then return end -- keep the sample steady while positioning
    self.showAnim:Play()
    if self.getCfg().glow then self.burstAnim:Play() end
end

function AlertFrame:SetLocked(locked)
    self.unlocked = not locked
    local f = self.frame
    f:EnableMouse(not locked)
    f.overlay:SetShown(not locked)
    f.overlayText:SetShown(not locked)
    if locked then
        self.showAnim:Stop()
        self.pulse:Stop()
        f:Hide()
    else
        self:Show(self.sample())
    end
    if ns.Config then ns.Config:RefreshAll() end
end

---------------------------------------------------------------------------
-- Crit alert
---------------------------------------------------------------------------

local STREAK_COLORS = {
    { min = 5, color = { 1.00, 0.25, 0.20 } },
    { min = 3, color = { 1.00, 0.55, 0.10 } },
    { min = 0, color = { 1.00, 0.82, 0.18 } },
}

local function critColor()
    local V = ns.db.alerts.visual
    return V.useCritColor and ns.db.colors.crit or V.color
end

local function critData(e, streak, record)
    local d = {
        big = (e.kind == "heal" and "+" or "") .. ns.Full(e.amount or 0),
        small = e.name, icon = e.icon, color = critColor(),
    }
    if record then
        d.banner, d.bannerColor = "NEW RECORD!", ns.db.colors.crit
    elseif streak then
        for _, s in ipairs(STREAK_COLORS) do
            if streak >= s.min then d.bannerColor = s.color; break end
        end
        d.banner = "x" .. streak .. " CRIT STREAK"
        d.bannerScale = 1 + 0.12 * (math.min(streak, 6) - 2)
        d.pulse = streak >= 5
    end
    return d
end

---------------------------------------------------------------------------
-- Init and settings
---------------------------------------------------------------------------

function Alerts:Init()
    self.crit = CreateAlertFrame("WombatLogCritAlert", "crit alert",
        function() return ns.db.alerts.visual end,
        function() return critData(CRIT_SAMPLE, nil, false) end)
    self.proc = CreateAlertFrame("WombatLogProcAlert", "proc alert",
        function() return ns.db.procs end,
        function() return self:ProcData(PROC_SAMPLE.name, PROC_SAMPLE.icon) end)
    self.recentAuras = {}
    self:Apply()
end

function Alerts:Apply()
    if not self.crit then return end
    self.crit:Apply()
    self.proc:Apply()
    if not ns.db.procs.enabled and not self.proc.unlocked then self.proc.frame:Hide() end
end

-- Settings "Test" buttons: ignore the enabled toggles and thresholds.
function Alerts:Test()
    if self.crit.unlocked then self.crit:SetLocked(true) end
    self.crit:Show(critData(CRIT_SAMPLE, nil, false))
end

function Alerts:TestStreak(n)
    if self.crit.unlocked then self.crit:SetLocked(true) end
    self.crit:Show(critData(CRIT_SAMPLE, n, false))
    if ns.db.alerts.streak.escalatingSound then
        PlaySoundFile(STREAK_SOUNDS[math.min(n, 4)], ns.db.alerts.sound.channel)
    else
        self:PlayConfigured()
    end
end

function Alerts:TestRecord()
    if self.crit.unlocked then self.crit:SetLocked(true) end
    self.crit:Show(critData(CRIT_SAMPLE, nil, true))
    self:PlayRecordSound()
end

---------------------------------------------------------------------------
-- Triggers
---------------------------------------------------------------------------

local function qualifies(cfg, e)
    if not cfg.enabled then return false end
    if e.kind == "heal" and not cfg.heals then return false end
    return (e.amount or 0) >= cfg.minAmount
end

-- Called for your crits and for hits that beat a record, before any log filters.
function Alerts:OnHit(e)
    if not self.crit then return end
    local cfg = ns.db.alerts
    local streak = cfg.streak.enabled and e.crit and (e.streak or 0) >= cfg.streak.min and e.streak or nil
    local record = e.record and ns.db.stats.records.enabled

    if (e.crit and qualifies(cfg.visual, e)) or (record and cfg.record.banner) then
        self.crit:Show(critData(e, streak, record and cfg.record.banner))
    end

    local now = GetTime()
    if now - (self.lastSound or 0) < cfg.sound.throttle then return end
    if record and cfg.record.sound then
        self.lastSound = now
        self:PlayRecordSound()
    elseif e.crit and qualifies(cfg.sound, e) then
        self.lastSound = now
        if streak and cfg.streak.escalatingSound then
            PlaySoundFile(STREAK_SOUNDS[math.min(streak, 4)], cfg.sound.channel)
        else
            self:PlayConfigured()
        end
    end
end

---------------------------------------------------------------------------
-- Procs
---------------------------------------------------------------------------

function Alerts:ProcData(name, icon)
    local P = ns.db.procs
    return { big = P.showName and name or "", icon = icon, color = P.color }
end

function Alerts:ShowProc(name, icon)
    self.proc:Show(self:ProcData(name, icon))
    if ns.db.procs.sound then self:PlayProcSound() end
end

-- respectEnabled: used by /wl test, which must stay silent when procs are off.
function Alerts:TestProc(respectEnabled)
    if respectEnabled and not ns.db.procs.enabled then return end
    if self.proc.unlocked then self.proc:SetLocked(true) end
    self:ShowProc(PROC_SAMPLE.name, PROC_SAMPLE.icon)
end

-- Every helpful aura gained on you (any source).
function Alerts:OnPlayerAura(name, icon, spellId)
    local P = ns.db and ns.db.procs
    if not P or not P.enabled or not name or not self.proc then return end

    -- remember recent buffs so the settings can offer them for one-click adding
    for i, a in ipairs(self.recentAuras) do
        if a.name == name then table.remove(self.recentAuras, i); break end
    end
    table.insert(self.recentAuras, 1, { name = name, icon = icon, spellId = spellId })
    while #self.recentAuras > RECENT_AURAS do table.remove(self.recentAuras) end

    local lname = name:lower()
    for _, entry in ipairs(P.list) do
        if entry:lower() == lname or (spellId and tonumber(entry) == spellId) then
            self:ShowProc(name, icon)
            return
        end
    end
end

function Alerts:HasProc(text)
    local l = text:lower()
    for _, entry in ipairs(ns.db.procs.list) do
        if entry:lower() == l then return true end
    end
    return false
end

function Alerts:AddProc(text)
    text = strtrim(text or "")
    if text == "" or self:HasProc(text) then return false end
    table.insert(ns.db.procs.list, text)
    return true
end

function Alerts:RemoveProc(index)
    table.remove(ns.db.procs.list, index)
end
