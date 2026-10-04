local ADDON, ns = ...
local Reminders = {}
ns.Reminders = Reminders
local Safe, SafeTable = ns.Safe, ns.SafeTable

-- Icons that light up while one of your listed spells wants attention:
--   "usable": known, usable right now and off cooldown (Riposte after a parry,
--             Overpower after a dodge, Execute on a low target, ...)
--   "buff":   its buff on you is missing or about to run out (Battle Shout,
--             Arcane Intellect, armors, ...)

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local CHECK_EVERY = 0.2
local GCD = 1.5 -- a cooldown this short is the global cooldown, not the spell's own
local SOUND_THROTTLE = 1

-- Offered in the settings, by spell ID so names follow the client's language.
-- Only the ones you know are listed.
Reminders.SUGGESTIONS = {
    WARRIOR = { { 7384, "usable" }, { 6572, "usable" }, { 5308, "usable" }, { 6673, "buff" } },
    ROGUE = { { 14251, "usable" } },
    HUNTER = { { 1495, "usable" }, { 19306, "usable" }, { 13165, "buff" }, { 19506, "buff" } },
    MAGE = { { 1459, "buff" }, { 168, "buff" }, { 7302, "buff" }, { 6117, "buff" } },
    PRIEST = { { 1243, "buff" }, { 588, "buff" } },
    DRUID = { { 1126, "buff" }, { 467, "buff" } },
    WARLOCK = { { 687, "buff" }, { 706, "buff" } },
    SHAMAN = { { 324, "buff" } },
    PALADIN = { { 19740, "buff" }, { 25780, "buff" } },
}

local SAMPLE = {
    { name = "Riposte", icon = "Interface\\Icons\\Ability_Warrior_Challange", castable = true, hotkey = "Q" },
    { name = "Battle Shout", icon = "Interface\\Icons\\Ability_Warrior_BattleShout", castable = false, hotkey = "S-2" },
}

---------------------------------------------------------------------------
-- Spell state (works with both the modern C_Spell API and the older globals)
---------------------------------------------------------------------------

-- Name, icon and spell ID of a list entry ("Riposte" or "14251"); nil if the client
-- doesn't know it (by name, only spells in your spellbook resolve).
local function resolve(text)
    local key = tonumber(text) or text
    if C_Spell and C_Spell.GetSpellInfo then
        local info = SafeTable(C_Spell.GetSpellInfo(key))
        if info and Safe(info.name) then
            return info.name, Safe(info.iconID) or 134400, Safe(info.spellID)
        end
    elseif GetSpellInfo then
        local name, _, icon, _, _, _, id = GetSpellInfo(key)
        if name then return name, icon or 134400, id end
    end
end

local function knows(id)
    if not id then return false end
    if not IsPlayerSpell and not IsSpellKnown then return true end -- can't tell: trust the name lookup
    if IsPlayerSpell and Safe(IsPlayerSpell(id)) then return true end
    if IsSpellKnown and Safe(IsSpellKnown(id)) then return true end
    return false
end

-- true/false, or nil when the client keeps it secret
local function isUsable(spell)
    if C_Spell and C_Spell.IsSpellUsable then return Safe((C_Spell.IsSpellUsable(spell))) end
    if IsUsableSpell then return Safe((IsUsableSpell(spell))) end
end

-- Seconds of the spell's own cooldown left (the global cooldown counts as ready).
local function cooldownLeft(spell)
    local start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local c = SafeTable(C_Spell.GetSpellCooldown(spell))
        if c then start, duration = Safe(c.startTime), Safe(c.duration) end
    elseif GetSpellCooldown then
        start, duration = GetSpellCooldown(spell)
        start, duration = Safe(start), Safe(duration)
    end
    if not start or not duration then return nil end
    if duration <= GCD then return 0 end
    return math.max(0, start + duration - GetTime())
end

-- Seconds left on your buff with this name: nil when missing, math.huge when it
-- has no duration. unreadable is true when the client hid buff names from us.
local function buffLeft(name)
    local unreadable = false
    for i = 1, 40 do
        local auraName, expires
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not a then break end
            a = SafeTable(a)
            auraName, expires = a and Safe(a.name), a and Safe(a.expirationTime)
            if not a then unreadable = true end
        elseif UnitBuff then
            local n, _, _, _, _, exp = UnitBuff("player", i)
            if not n then break end
            auraName, expires = Safe(n), Safe(exp)
        else
            return nil, true
        end
        if auraName == nil then
            unreadable = true
        elseif auraName == name then
            if not expires or expires == 0 then return math.huge end
            return expires - GetTime()
        end
    end
    return nil, unreadable
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

local function setScaleAnim(anim, from, to)
    if anim.SetScaleFrom then
        anim:SetScaleFrom(from, from); anim:SetScaleTo(to, to)
    else
        anim:SetFromScale(from, from); anim:SetToScale(to, to)
    end
end

local function CreateIcon(parent)
    local b = CreateFrame("Frame", nil, parent)
    b.glow = b:CreateTexture(nil, "BACKGROUND")
    b.glow:SetTexture(GLOW)
    b.glow:SetPoint("CENTER")
    b.border = b:CreateTexture(nil, "ARTWORK")
    b.border:SetTexture(WHITE)
    b.border:SetAllPoints()
    b.icon = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.name:SetPoint("TOP", b, "BOTTOM", 0, -3)
    -- the key to press, in the corner like on an action button
    b.hotkey = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight", 2)
    b.hotkey:SetPoint("TOPRIGHT", b, "TOPRIGHT", -3, -3)
    b.hotkey:SetJustifyH("RIGHT")

    -- the glow breathes while the reminder is up
    b.pulse = b.glow:CreateAnimationGroup()
    b.pulse:SetLooping("BOUNCE")
    local beat = b.pulse:CreateAnimation("Alpha")
    beat:SetFromAlpha(0.25); beat:SetToAlpha(0.9); beat:SetDuration(0.6); beat:SetSmoothing("IN_OUT")

    b.pop = b:CreateAnimationGroup()
    local grow = b.pop:CreateAnimation("Scale")
    setScaleAnim(grow, 1.5, 1)
    grow:SetDuration(0.2); grow:SetSmoothing("OUT")
    b:Hide()
    return b
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function Reminders:Init()
    local f = CreateFrame("Frame", "WombatLogReminders", UIParent)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local cfg = ns.db.reminders
        local s = UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        local cx, cy = f:GetCenter()
        cfg.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        cfg.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    end)

    f.overlay = f:CreateTexture(nil, "BACKGROUND")
    f.overlay:SetAllPoints()
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlayText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.overlayText:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.overlayText:SetText("WombatLog spell reminders - drag to move")
    f.overlay:Hide()
    f.overlayText:Hide()

    self.frame = f
    self.icons = {}
    self.shown = {} -- entry text -> true while its reminder is up
    local clock = 0
    f:SetScript("OnUpdate", function(_, dt)
        clock = clock + dt
        if clock >= CHECK_EVERY then
            clock = 0
            self:Update()
        end
    end)
    self:Apply()
end

function Reminders:Apply()
    local f = self.frame
    if not f then return end
    local R = ns.db.reminders
    f:SetScale(R.scale)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", R.x, R.y)
    f:SetSize(R.size * 3, R.size + 20)
    f:Show() -- the OnUpdate check needs it; icons hide themselves
    for _, b in ipairs(self.icons) do b.styled = nil end
    self:Update()
end

local function Style(b, R)
    local A = ns.db.appearance
    b:SetSize(R.size, R.size)
    b.glow:SetSize(R.size * 2.2, R.size * 2.2)
    b.glow:SetVertexColor(R.color[1], R.color[2], R.color[3], 1)
    b.glow:SetShown(R.glow)
    ns.SetFont(b.name, A.nameFont, math.max(9, math.floor(R.size * 0.3)), "OUTLINE")
    b.name:SetShown(R.showName)
    ns.SetFont(b.hotkey, A.amountFont, math.max(9, math.floor(R.size * 0.34)), "OUTLINE")
    b.styled = true
end

-- list: { name, icon, castable, key, new } in display order, centered as a row.
function Reminders:Render(list)
    local R = ns.db.reminders
    local f = self.frame
    local n = #list
    local width = n * R.size + math.max(0, n - 1) * R.spacing
    for i, d in ipairs(list) do
        local b = self.icons[i]
        if not b then
            b = CreateIcon(f)
            self.icons[i] = b
        end
        if not b.styled then Style(b, R) end
        b:ClearAllPoints()
        b:SetPoint("LEFT", f, "CENTER", -width / 2 + (i - 1) * (R.size + R.spacing), 0)
        b.icon:SetTexture(d.icon or 134400)
        b.name:SetText(d.name or "")
        b.hotkey:SetText(d.hotkey or "")
        -- known but not castable right now (no mana, on cooldown): dimmed
        local c = d.castable and R.color or { 0.5, 0.5, 0.5 }
        b.border:SetColorTexture(c[1], c[2], c[3], 1)
        if b.icon.SetDesaturated then b.icon:SetDesaturated(not d.castable) end
        b:SetAlpha(d.castable and 1 or 0.7)
        if b.key ~= d.key then
            b.key = d.key
            if d.new then b.pop:Play() end
        end
        if R.glow and d.castable then
            if not b.pulse:IsPlaying() then b.pulse:Play() end
        else
            b.pulse:Stop()
            b.glow:SetAlpha(R.glow and 0.25 or 0)
        end
        b:Show()
    end
    for i = n + 1, #self.icons do
        local b = self.icons[i]
        b.key = nil
        b.pulse:Stop()
        b:Hide()
    end
end

-- What should be lit right now.
function Reminders:Collect()
    local R = ns.db.reminders
    local list = {}
    if not R.enabled then return list end
    if R.combatOnly and not Safe(UnitAffectingCombat("player")) then return list end
    if Safe(UnitIsDeadOrGhost("player")) or Safe(UnitOnTaxi("player")) then return list end

    for _, entry in ipairs(R.list) do
        local name, icon, id = resolve(entry.spell)
        local known = name and (knows(id) or knows(tonumber(entry.spell)))
        if known then
            local spell = id or name
            local usable = isUsable(spell)
            local cd = cooldownLeft(spell)
            local castable = usable == true and cd == 0
            local show = false
            if entry.mode == "usable" then
                show = castable
            else
                local left, unreadable = buffLeft(name)
                if left == nil then
                    show = not unreadable -- missing (but don't nag when buffs are hidden from us)
                else
                    show = R.refreshAt > 0 and left < R.refreshAt
                end
            end
            if show then
                list[#list + 1] = {
                    key = entry.spell, name = name, icon = icon, castable = castable,
                    hotkey = entry.key, sound = entry.sound,
                }
            end
        end
    end
    return list
end

function Reminders:Update()
    if not self.frame then return end
    local list
    if self.unlocked or (self.testUntil and GetTime() < self.testUntil) then
        list = {}
        for i, s in ipairs(SAMPLE) do list[i] = { key = "sample" .. i, name = s.name, icon = s.icon, castable = s.castable, hotkey = s.hotkey } end
    else
        self.testUntil = nil
        list = self:Collect()
    end

    -- a reminder that just came up pops in, and may play its sound
    local R = ns.db.reminders
    local now, sound = GetTime(), nil
    local shown = {}
    for _, d in ipairs(list) do
        shown[d.key] = true
        if not self.shown[d.key] then
            d.new = true
            sound = sound or self.SoundFor(d.sound)
        end
    end
    self.shown = shown
    if sound and not self.unlocked and now - (self.lastSound or 0) >= SOUND_THROTTLE then
        self.lastSound = now
        ns.Alerts.PlaySound(sound, R.channel)
    end
    self:Render(list)
end

-- A reminder's own sound: nil follows the default (General tab), "none" stays silent.
-- A sound picked for one reminder plays even with the default sound off.
function Reminders.SoundFor(choice)
    if choice == "none" then return nil end
    if choice then return choice end
    local R = ns.db.reminders
    return R.sound and R.soundChoice or nil
end

function Reminders:SetSound(index, sound)
    local entry = ns.db.reminders.list[index]
    if entry then entry.sound = sound end
end

function Reminders:SetLocked(locked)
    self.unlocked = not locked
    local f = self.frame
    f:EnableMouse(not locked)
    f.overlay:SetShown(not locked)
    f.overlayText:SetShown(not locked)
    self:Update()
    if ns.Config then ns.Config:RefreshAll() end
end

-- Settings button: sample icons for a few seconds.
function Reminders:Test()
    self.testUntil = GetTime() + 4
    self.shown = {}
    self:Update()
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

function Reminders:Find(text)
    local l = (text or ""):lower()
    for i, entry in ipairs(ns.db.reminders.list) do
        if entry.spell:lower() == l then return i end
    end
end

-- key: optional text shown on the icon, the key you press for it ("Q", "S-2")
local function cleanKey(key)
    key = strtrim(key or "")
    return key ~= "" and key or nil
end

function Reminders:Add(text, mode, key)
    text = strtrim(text or "")
    if text == "" or self:Find(text) then return false end
    table.insert(ns.db.reminders.list, { spell = text, mode = mode == "buff" and "buff" or "usable", key = cleanKey(key) })
    self:Update()
    return true
end

function Reminders:Remove(index)
    table.remove(ns.db.reminders.list, index)
    self:Update()
end

function Reminders:SetKey(index, key)
    local entry = ns.db.reminders.list[index]
    if entry then entry.key = cleanKey(key) end
    self:Update()
end

function Reminders:ToggleMode(index)
    local entry = ns.db.reminders.list[index]
    if entry then entry.mode = entry.mode == "buff" and "usable" or "buff" end
    self:Update()
end

-- Name and icon for showing a list entry in the settings (works for unknown spells too).
function Reminders.Describe(text)
    local name, icon = resolve(text)
    if not name and tonumber(text) then
        local info = ns.SpellInfo(tonumber(text))
        name, icon = info and info.name, info and info.icon
    end
    return name or text, icon or 134400
end

-- Class suggestions you know and haven't listed yet: { text, name, icon, mode }.
function Reminders:Suggestions()
    local _, class = UnitClass("player")
    local out = {}
    for _, s in ipairs(self.SUGGESTIONS[class] or {}) do
        local info = ns.SpellInfo(s[1])
        local name = info and info.name
        if name then
            local _, _, id = resolve(name)
            if (knows(s[1]) or knows(id)) and not self:Find(name) then
                out[#out + 1] = { text = name, name = name, icon = info.icon, mode = s[2] }
            end
        end
    end
    return out
end
