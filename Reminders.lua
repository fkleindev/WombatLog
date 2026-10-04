local ADDON, ns = ...
local Reminders = {}
ns.Reminders = Reminders
local Safe, SafeTable = ns.Safe, ns.SafeTable

-- Icons that light up while one of your listed spells wants attention:
--   "usable": known, usable right now and off cooldown (Riposte after a parry,
--             Overpower after a dodge, Execute on a low target, ...)
--   "buff":   its buff on you is missing or about to run out (Battle Shout,
--             Arcane Intellect, armors, ...)
--   "debuff": your debuff of that name on your hostile target is missing or about
--             to run out (DoTs, Sunder Armor, Hunter's Mark, Faerie Fire, ...)
--   "interrupt": usable while your hostile target is casting something you can
--             interrupt (Kick, Pummel, Counterspell, Earth Shock, ...)

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local GLOW = MEDIA .. "Glow"
local GRADIENT = MEDIA .. "Gradient" -- white, alpha 1 -> 0 left to right
local WHITE = "Interface\\Buttons\\WHITE8X8"
local CHECK_EVERY = 0.2
local GCD = 1.5 -- a cooldown this short is the global cooldown, not the spell's own
local SOUND_THROTTLE = 1

-- Offered in the settings, by spell ID so names follow the client's language.
-- Only the ones you know are listed.
Reminders.SUGGESTIONS = {
    WARRIOR = {
        { 7384, "usable" }, { 6572, "usable" }, { 5308, "usable" }, { 6673, "buff" },
        { 7386, "debuff" }, { 772, "debuff" }, { 1160, "debuff" }, { 6343, "debuff" },
        { 6552, "interrupt" }, { 72, "interrupt" },
    },
    ROGUE = { { 14251, "usable" }, { 8647, "debuff" }, { 1766, "interrupt" } },
    HUNTER = {
        { 1495, "usable" }, { 19306, "usable" }, { 13165, "buff" }, { 19506, "buff" },
        { 1130, "debuff" }, { 1978, "debuff" }, { 147362, "interrupt" },
    },
    MAGE = { { 1459, "buff" }, { 168, "buff" }, { 7302, "buff" }, { 6117, "buff" }, { 2139, "interrupt" } },
    PRIEST = { { 1243, "buff" }, { 588, "buff" }, { 589, "debuff" }, { 15487, "interrupt" } },
    DRUID = {
        { 1126, "buff" }, { 467, "buff" }, { 770, "debuff" }, { 8921, "debuff" }, { 5570, "debuff" },
        { 106839, "interrupt" },
    },
    WARLOCK = { { 687, "buff" }, { 706, "buff" }, { 172, "debuff" }, { 980, "debuff" }, { 348, "debuff" } },
    SHAMAN = { { 324, "buff" }, { 8050, "debuff" }, { 8042, "interrupt" }, { 57994, "interrupt" } },
    PALADIN = { { 19740, "buff" }, { 25780, "buff" }, { 96231, "interrupt" } },
    DEATHKNIGHT = { { 47528, "interrupt" } },
    DEMONHUNTER = { { 183752, "interrupt" } },
    MONK = { { 116705, "interrupt" } },
    EVOKER = { { 351338, "interrupt" } },
}

-- Abilities that only become usable after something happened in combat. On Forever
-- and Retail the game hides whether a spell is usable while you fight, but the
-- events themselves are readable: they open a window instead.
-- [spell ID] = { "in" (an attack on you) or "out" (your attack), outcomes }
local REACTIVE = {
    [14251] = { "in", { PARRY = true } },                            -- Riposte
    [19306] = { "in", { PARRY = true } },                            -- Counterattack
    [6572] = { "in", { PARRY = true, DODGE = true, BLOCK = true } }, -- Revenge
    [7384] = { "out", { DODGE = true } },                            -- Overpower
    [1495] = { "out", { DODGE = true } },                            -- Mongoose Bite
}
local REACTIVE_WINDOW = 5
if ns.isRetail then REACTIVE = {} end -- none of these is reactive there any more

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

-- Reactive rules by spell name (names follow the client's language).
local reactiveByName
local function reactiveRule(name)
    if not reactiveByName then
        local map, complete = {}, true
        for id, rule in pairs(REACTIVE) do
            local info = ns.SpellInfo(id)
            if info then map[info.name] = rule else complete = false end
        end
        if not complete then return map[name] end -- spell data still loading: try again later
        reactiveByName = map
    end
    return reactiveByName[name]
end

local reactiveOpen = {} -- spell name -> time its window closes

-- Seconds of the spell's own cooldown left (the global cooldown counts as ready).
-- false when the target is out of range (nil when the client can't tell)
local function inRange(spell)
    local r
    if C_Spell and C_Spell.IsSpellInRange then
        r = Safe((C_Spell.IsSpellInRange(spell, "target")))
    elseif IsSpellInRange then
        r = Safe((IsSpellInRange(spell, "target")))
    end
    if r == nil then return nil end
    return r == true or r == 1
end

-- How long the spell's buff or debuff lasts, from the shipped spell data.
local function auraDuration(id)
    local d = id and ns.SPELL_DATA and ns.SPELL_DATA[id]
    return d and d[5]
end

-- The spell's own cooldown from the shipped spell data (talents aren't included).
local function spellCooldown(id)
    local d = id and ns.SPELL_DATA and ns.SPELL_DATA[id]
    return d and d[6]
end

-- When the game hides cooldowns (in combat on Forever and Retail), your own casts
-- tell when a spell is ready again: spell name -> time its cooldown ends.
local readyAt = {}

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

-- Auras on a unit as far as the client lets us read them: expiration time by name
-- (math.huge without a duration). Returns nil when they're hidden: in combat on
-- Forever and Retail, reading auras even errors ("cannot be accessed when secret").
-- Classic clients can always read them.
local function readAuras(unit, filter)
    local auras = {}
    for i = 1, 40 do
        local auraName, expires
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok then return nil end
            if not a then break end
            a = SafeTable(a)
            if not a then return nil end
            auraName, expires = Safe(a.name), Safe(a.expirationTime)
        elseif UnitAura then
            local ok, n, _, _, _, _, exp = pcall(UnitAura, unit, i, filter)
            if not ok then return nil end
            if n == nil then break end
            auraName, expires = Safe(n), Safe(exp)
        else
            return nil
        end
        if auraName == nil then return nil end
        auras[auraName] = (not expires or expires == 0) and math.huge or expires
    end
    return auras
end

-- Last readable state per buff name: expiration time, or false when it was missing.
-- While buffs are hidden, reminders go on from this (and from your own casts).
local buffCache = {}

-- Seconds left on your buff with this name: nil when missing, math.huge when it
-- has no duration. unknown is true when it can't be told at all.
local function remaining(expires)
    if not expires then return nil end
    local left = expires - GetTime()
    if left <= 0 then return nil end
    return left
end

local function buffLeft(name, buffs)
    local expires
    if buffs then
        expires = buffs[name] or false
        buffCache[name] = expires
    else
        expires = buffCache[name]
        if expires == nil then return nil, true end
    end
    return remaining(expires)
end

-- The same for your debuffs, per target. A target we never saw your debuff on
-- (and you didn't cast it on) simply doesn't have it, so while hidden, an
-- unknown debuff counts as missing.
local debuffCache = {} -- target key -> { [name] = expiration or false, seen = time, cast = { [name] = time } }
local MAX_TARGETS = 40
local LANDING = 1.5 -- a debuff you just cast may not be on the target yet (travel time)

local function targetKey()
    return Safe(UnitGUID("target")) or "target"
end

local function targetCache(key)
    local c = debuffCache[key]
    if not c then
        -- forget the targets not seen for longest
        local n, oldest, oldestKey = 0, nil, nil
        for k, v in pairs(debuffCache) do
            n = n + 1
            if not oldest or v.seen < oldest then oldest, oldestKey = v.seen, k end
        end
        if n >= MAX_TARGETS then debuffCache[oldestKey] = nil end
        c = {}
        debuffCache[key] = c
    end
    c.seen = GetTime()
    return c
end

local function debuffLeft(name, debuffs, key)
    local c = targetCache(key)
    local expires
    if debuffs then
        expires = debuffs[name] or false
        local castAt = c.cast and c.cast[name]
        if expires or not castAt or GetTime() - castAt > LANDING then
            c[name] = expires
        else
            expires = c[name] -- still on its way
        end
    else
        expires = c[name]
    end
    return remaining(expires)
end

-- An attackable, living target to put debuffs on.
local function hostileTarget()
    if not Safe(UnitExists("target")) then return false end
    if Safe(UnitIsDead("target")) then return false end
    return Safe(UnitCanAttack("player", "target")) == true
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

local function anim(group, kind, target, duration, order, smoothing)
    local a = group:CreateAnimation(kind)
    if target then a:SetTarget(target) end
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

-- Tinted fade, strongest at the given side (like the log rows' shine).
local function fade(tex, side)
    tex:SetTexture(GRADIENT)
    if side == "right" then tex:SetTexCoord(1, 0, 0, 1) else tex:SetTexCoord(0, 1, 0, 1) end
    tex:SetBlendMode("ADD")
end

local function CreateIcon(parent)
    local b = CreateFrame("Frame", nil, parent)
    -- a real size from the start: effects on a frame without one can be drawn
    -- across the whole screen (Style sets the configured size)
    b:SetSize(40, 40)
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

    -- effects for coming up: a white flash over the icon, a light sweep across it
    -- and a ring of glow bursting outwards
    -- (each stays hidden unless its animation plays)
    b.flash = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.flash:SetTexture(WHITE)
    b.flash:SetBlendMode("ADD")
    b.flash:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    b.flash:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b.flash:SetAlpha(0)
    b.flash:Hide()
    b.burst = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.burst:SetTexture(GLOW)
    b.burst:SetBlendMode("ADD")
    b.burst:SetPoint("CENTER", b, "CENTER")
    b.burst:SetSize(100, 100)
    b.burst:SetAlpha(0)
    b.burst:Hide()
    local clip = CreateFrame("Frame", nil, b)
    clip:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    clip:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    if clip.SetClipsChildren then clip:SetClipsChildren(true) end
    b.shine = CreateFrame("Frame", nil, clip)
    b.shine:SetSize(28, 40)
    b.shine:SetPoint("LEFT", clip, "LEFT", -28, 0)
    b.shine:SetAlpha(0)
    b.shine:Hide()
    b.shineLeft = b.shine:CreateTexture(nil, "OVERLAY")
    b.shineLeft:SetPoint("TOPLEFT"); b.shineLeft:SetPoint("BOTTOMRIGHT", b.shine, "BOTTOM")
    fade(b.shineLeft, "right")
    b.shineRight = b.shine:CreateTexture(nil, "OVERLAY")
    b.shineRight:SetPoint("TOPRIGHT"); b.shineRight:SetPoint("BOTTOMLEFT", b.shine, "BOTTOM")
    fade(b.shineRight, "left")

    -- the glow breathes while the reminder is up
    b.pulse = b.glow:CreateAnimationGroup()
    b.pulse:SetLooping("BOUNCE")
    local beat = anim(b.pulse, "Alpha", nil, 0.6, 1, "IN_OUT")
    beat:SetFromAlpha(0.25); beat:SetToAlpha(0.9)

    -- coming up: drops in big and snaps to size, flashes, sweeps and bursts
    b.inAnim = b:CreateAnimationGroup()
    local grow = anim(b.inAnim, "Scale", nil, 0.28, 1, "OUT")
    setScaleAnim(grow, 2.2, 1)
    local appear = anim(b.inAnim, "Alpha", nil, 0.12, 1)
    appear:SetFromAlpha(0); appear:SetToAlpha(1)
    b.appear = appear

    b.flashAnim = b.flash:CreateAnimationGroup()
    local flash = anim(b.flashAnim, "Alpha", nil, 0.4, 1, "OUT")
    flash:SetFromAlpha(0.9); flash:SetToAlpha(0)
    b.flashAnim:SetScript("OnFinished", function() b.flash:SetAlpha(0); b.flash:Hide() end)

    -- the ring is sized by hand in OnUpdate (StepBurst): a Scale animation on it
    -- while the icon itself scales could get drawn across the whole screen

    b.shineAnim = b.shine:CreateAnimationGroup()
    local sIn = anim(b.shineAnim, "Alpha", nil, 0.06, 1)
    sIn:SetFromAlpha(0); sIn:SetToAlpha(1)
    b.shineMove = anim(b.shineAnim, "Translation", nil, 0.42, 1, "IN_OUT")
    local sOut = anim(b.shineAnim, "Alpha", nil, 0.1, 1)
    sOut:SetFromAlpha(1); sOut:SetToAlpha(0); sOut:SetStartDelay(0.32)
    b.shineAnim:SetScript("OnFinished", function() b.shine:SetAlpha(0); b.shine:Hide() end)

    -- going away: a last flash, then it shrinks and fades
    b.outAnim = b:CreateAnimationGroup()
    if b.outAnim.SetToFinalAlpha then b.outAnim:SetToFinalAlpha(true) end
    local shrink = anim(b.outAnim, "Scale", nil, 0.22, 1, "IN")
    setScaleAnim(shrink, 1, 0.3)
    local vanish = anim(b.outAnim, "Alpha", nil, 0.22, 1, "IN")
    vanish:SetFromAlpha(1); vanish:SetToAlpha(0)
    b.outAnim:SetScript("OnFinished", function()
        if b.leaving then Reminders:Release(b) end
    end)

    b:Hide()
    return b
end

local function StopEffects(b)
    b.inAnim:Stop(); b.flashAnim:Stop(); b.shineAnim:Stop(); b.outAnim:Stop()
    b.burstT = nil
    b.flash:SetAlpha(0); b.burst:SetAlpha(0); b.shine:SetAlpha(0)
    b.flash:Hide(); b.burst:Hide(); b.shine:Hide()
end

local BURST_TIME = 0.55

-- One frame of the glow ring: grows from 0.4x to 1.8x while it fades out.
local function StepBurst(b, dt)
    b.burstT = b.burstT + dt
    local p = math.min(1, b.burstT / BURST_TIME)
    if p >= 1 then
        b.burstT = nil
        b.burst:Hide()
        return
    end
    local eased = 1 - (1 - p) * (1 - p) -- fast at first, then slower
    local size = (b.burstBase or 100) * (0.4 + 1.4 * eased)
    b.burst:SetSize(size, size)
    b.burst:SetAlpha(1 - p * p)
    b.burst:Show()
end

local function PlayIn(b, alpha)
    b.appear:SetToAlpha(alpha)
    b.inAnim:Play()
    b.flash:Show(); b.flashAnim:Play()
    b.burstT = 0 -- StepBurst grows and fades it
    b.shine:Show(); b.shineAnim:Play()
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local SLIDE_SPEED = 14 -- icons glide to their new place when others come or go

local function Place(b)
    b:ClearAllPoints()
    b:SetPoint("CENTER", b:GetParent(), "CENTER", b.x, 0)
end

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
    self.byKey = {} -- reminder key -> its icon (also while it animates out)
    self.pool = {}
    self.shown = {} -- entry text -> true while its reminder is up
    local clock = 0
    f:SetScript("OnUpdate", function(_, dt)
        clock = clock + dt
        if clock >= CHECK_EVERY then
            clock = 0
            self:Update()
        end
        local k = math.min(1, dt * SLIDE_SPEED)
        for _, b in pairs(self.byKey) do
            if b.burstT then StepBurst(b, dt) end
            if b.x ~= b.tx then
                b.x = math.abs(b.tx - b.x) < 0.5 and b.tx or b.x + (b.tx - b.x) * k
                Place(b)
            end
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
    for _, b in pairs(self.byKey) do b.styled = nil end
    for _, b in ipairs(self.pool) do b.styled = nil end
    self:Update()
end

local function Style(b, R)
    local A = ns.db.appearance
    b:SetSize(R.size, R.size)
    b.glow:SetSize(R.size * 2.2, R.size * 2.2)
    b.glow:SetVertexColor(R.color[1], R.color[2], R.color[3], 1)
    b.glow:SetShown(R.glow)
    b.burstBase = R.size * 2.6
    b.burst:SetSize(b.burstBase, b.burstBase)
    b.burst:SetVertexColor(R.color[1], R.color[2], R.color[3], 1)
    local band = math.floor(R.size * 0.7)
    b.shine:SetSize(band, R.size)
    b.shine:ClearAllPoints()
    b.shine:SetPoint("LEFT", b.shine:GetParent(), "LEFT", -band, 0)
    b.shineMove:SetOffset(R.size + band, 0)
    for _, t in ipairs({ b.shineLeft, b.shineRight }) do t:SetVertexColor(1, 1, 1, 0.7) end
    ns.SetFont(b.name, A.nameFont, math.max(9, math.floor(R.size * 0.3)), "OUTLINE")
    b.name:SetShown(R.showName)
    ns.SetFont(b.hotkey, A.amountFont, math.max(9, math.floor(R.size * 0.34)), "OUTLINE")
    b.styled = true
end

-- An icon that went away (or finished going away) goes back to the pool.
function Reminders:Release(b)
    StopEffects(b)
    b.pulse:Stop()
    b:Hide()
    b:SetAlpha(1)
    b.leaving = nil
    if b.key and self.byKey[b.key] == b then self.byKey[b.key] = nil end
    b.key = nil
    self.pool[#self.pool + 1] = b
end

-- list: { name, icon, castable, key, new } in display order, centered as a row.
-- With animations on, new icons pop in with a flash, leaving ones shrink away and
-- the rest glide to their new places.
function Reminders:Render(list)
    local R = ns.db.reminders
    local f = self.frame
    local animate = R.animate
    local n = #list
    local width = n * R.size + math.max(0, n - 1) * R.spacing
    local keep = {}
    for i, d in ipairs(list) do
        keep[d.key] = true
        local b = self.byKey[d.key]
        local fresh = false
        if b and b.leaving then
            -- came back while going away: catch it
            StopEffects(b)
            b.leaving = nil
        elseif not b then
            b = table.remove(self.pool) or CreateIcon(f)
            b.key = d.key
            self.byKey[d.key] = b
            fresh = true
        end
        if not b.styled then Style(b, R) end
        b.tx = -width / 2 + (i - 1) * (R.size + R.spacing) + R.size / 2
        if fresh or not animate or not b.x then b.x = b.tx end
        Place(b)

        b.icon:SetTexture(d.icon or 134400)
        b.name:SetText(d.name or "")
        b.hotkey:SetText(d.hotkey or "")
        -- known but not castable right now (no mana, on cooldown): dimmed
        local c = d.castable and R.color or { 0.5, 0.5, 0.5 }
        b.border:SetColorTexture(c[1], c[2], c[3], 1)
        if b.icon.SetDesaturated then b.icon:SetDesaturated(not d.castable) end
        local alpha = d.castable and 1 or 0.7
        b:SetAlpha(alpha)
        if R.glow and d.castable then
            if not b.pulse:IsPlaying() then b.pulse:Play() end
        else
            b.pulse:Stop()
            b.glow:SetAlpha(R.glow and 0.25 or 0)
        end
        if fresh then
            b:Show()
            if animate and d.new then PlayIn(b, alpha) end
        end
    end
    for key, b in pairs(self.byKey) do
        if not keep[key] and not b.leaving then
            if animate and b:IsShown() then
                StopEffects(b)
                b.pulse:Stop()
                b.leaving = true
                b.outAnim:Play()
            else
                self:Release(b)
            end
        end
    end
end

-- What should be lit right now.
function Reminders:Collect()
    local R = ns.db.reminders
    local list = {}
    if not R.enabled then return list end
    if Safe(UnitIsDeadOrGhost("player")) or Safe(UnitOnTaxi("player")) then return list end
    local inCombat = Safe(UnitAffectingCombat("player")) and true or false

    local buffs, buffsRead = nil, false
    local debuffs, debuffsRead, tkey = nil, false, nil
    local hostile = hostileTarget()
    local casting -- checked once, only when an interrupt reminder needs it
    for _, entry in ipairs(R.list) do
        local name, icon, id = resolve(entry.spell)
        local known = name and (knows(id) or knows(tonumber(entry.spell)))
        if known and self:IsMine(entry) and (inCombat or not self.CombatOnly(entry)) then
            local spell = id or name
            -- In combat on Forever and Retail both can be secret (nil here). The
            -- cooldown then comes from your last cast and the spell data; a reactive
            -- ability follows its trigger. Usability includes the resource cost, so
            -- when it is secret, resources can't be checked (they're secret too).
            local usable = isUsable(spell)
            local cd = cooldownLeft(spell)
            if cd == nil then cd = math.max(0, (readyAt[name] or 0) - GetTime()) end
            if usable == nil and reactiveRule(name) then
                usable = (reactiveOpen[name] or 0) > GetTime()
            end
            local castable = usable ~= false and cd == 0
            local show = false
            if entry.mode == "usable" then
                show = castable
            elseif entry.mode == "interrupt" then
                if hostile and castable then
                    if casting == nil then casting = targetCasting() end
                    show = casting
                    if show and inRange(spell) == false then castable = false end
                end
            elseif entry.mode == "debuff" then
                if hostile then
                    if not debuffsRead then
                        debuffs, debuffsRead, tkey = readAuras("target", "HARMFUL|PLAYER"), true, targetKey()
                    end
                    local left = debuffLeft(name, debuffs, tkey)
                    show = left == nil or (R.debuffRefreshAt > 0 and left < R.debuffRefreshAt)
                    if castable and inRange(spell) == false then castable = false end
                end
            else
                if not buffsRead then buffs, buffsRead = readAuras("player", "HELPFUL"), true end
                local left, unknown = buffLeft(name, buffs)
                if left == nil then
                    show = not unknown -- missing (but don't nag when we can't tell)
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
    for _, b in pairs(self.byKey) do self:Release(b) end -- so the samples pop in again
    self:Update()
end

-- Your casts keep the caches right while auras are hidden: a buff you recast is on
-- you, a debuff you cast is on your target, for the spell's duration (or until the
-- auras are readable again).
ns.Listen("UNIT_SPELLCAST_SUCCEEDED", function(_, _, spellID)
    spellID = Safe(spellID)
    local info = ns.SpellInfo(spellID)
    if not info then return end
    local duration = auraDuration(spellID)
    local expires = duration and GetTime() + duration or math.huge
    reactiveOpen[info.name] = nil -- used up
    local cooldown = spellCooldown(spellID)
    readyAt[info.name] = cooldown and GetTime() + cooldown or nil
    for _, entry in ipairs(ns.db.reminders.list) do
        if (resolve(entry.spell)) == info.name then
            if entry.mode == "buff" then
                buffCache[info.name] = expires
            elseif entry.mode == "debuff" and hostileTarget() then
                local c = targetCache(targetKey())
                c[info.name] = expires
                c.cast = c.cast or {}
                c.cast[info.name] = GetTime()
            end
        end
    end
end, "player")

-- /wl debug: what the game lets us read for each reminder right now. Run it in
-- combat to see which values are secret.
function Reminders:Debug()
    local function show(v)
        if v ~= nil and issecretvalue and issecretvalue(v) then return "|cffff8080secret|r" end
        return tostring(v)
    end
    local list = ns.db.reminders.list
    if #list == 0 then
        ns.Print("spell reminders: none in the list")
        return
    end
    local power = UnitPower("player")
    ns.Print("spell reminders (" .. (Safe(UnitAffectingCombat("player")) and "in combat" or "out of combat")
        .. "), your power: " .. show(power))
    for _, entry in ipairs(list) do
        local name, _, id = resolve(entry.spell)
        if not name then
            ns.Print("  " .. entry.spell .. ": not found")
        else
            local spell = id or name
            local usable, cdStart, cdDur
            if C_Spell and C_Spell.IsSpellUsable then
                usable = C_Spell.IsSpellUsable(spell)
            elseif IsUsableSpell then
                usable = IsUsableSpell(spell)
            end
            if C_Spell and C_Spell.GetSpellCooldown then
                local c = C_Spell.GetSpellCooldown(spell)
                if c and issecrettable and issecrettable(c) then
                    cdStart = c -- the whole table is secret
                elseif c then
                    local ok = pcall(function() cdStart, cdDur = c.startTime, c.duration end)
                    if not ok then cdStart = "error" end
                end
            elseif GetSpellCooldown then
                cdStart, cdDur = GetSpellCooldown(spell)
            end
            local tracked = math.max(0, (readyAt[name] or 0) - GetTime())
            ns.Print(string.format("  %s (%s, id %s): usable %s, cooldown %s/%s, own cast: %.1fs left, data cooldown %s",
                name, entry.mode, tostring(id), show(usable), show(cdStart), show(cdDur), tracked,
                tostring(spellCooldown(id))))
        end
    end
end

---------------------------------------------------------------------------
-- Enemy casts (for interrupt reminders)
---------------------------------------------------------------------------

-- Casts seen in the combat log (Classic): GUID -> time the cast should end. Older
-- Classic clients don't always show other units' casts through UnitCastingInfo.
local enemyCasts = {}
local CAST_GUESS = 3 -- when a cast's length is unknown

local function castTime(spellId, spellName)
    local ms
    local key = (spellId and spellId > 0) and spellId or spellName
    if not key then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = SafeTable(C_Spell.GetSpellInfo(key))
        ms = info and Safe(info.castTime)
    elseif GetSpellInfo then
        ms = select(4, GetSpellInfo(key))
    end
    if ms and ms > 0 then return ms / 1000 end
end

function Reminders:OnEnemyCast(guid, spellId, spellName)
    if not guid then return end
    enemyCasts[guid] = GetTime() + math.min(10, castTime(spellId, spellName) or CAST_GUESS)
    self:Update()
end

function Reminders:OnEnemyCastEnd(guid)
    if guid and enemyCasts[guid] then
        enemyCasts[guid] = nil
        self:Update()
    end
end

-- One value from the cast APIs: true if there is one (secret counts), false if not.
local function present(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return true end
    return v ~= nil
end

-- Is your target casting or channeling something you can interrupt? On Forever
-- and Retail the details can be secret in combat: any cast then counts, and an
-- unknown "can't be interrupted" counts as interruptible.
local function targetCasting()
    local name, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("target")
    if present(name) then return Safe(notInterruptible) ~= true end
    local cname, _, _, _, _, _, cNotInterruptible = UnitChannelInfo("target")
    if present(cname) then return Safe(cNotInterruptible) ~= true end
    local guid = Safe(UnitGUID("target"))
    local ends = guid and enemyCasts[guid]
    if ends then
        if GetTime() < ends then return true end
        enemyCasts[guid] = nil
    end
    return false
end

-- React right away when the target starts or stops casting (interrupts are urgent).
for _, ev in ipairs({
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP",
}) do
    ns.Listen(ev, function()
        if Reminders.frame then Reminders:Update() end
    end, "target")
end

-- An attack on you ("in") or yours ("out") was parried, dodged or blocked: opens
-- the window of the reactive abilities it enables. Called by both combat sources.
function Reminders:OnAvoid(dir, outcome)
    for id, rule in pairs(REACTIVE) do
        if rule[1] == dir and rule[2][outcome] then
            local info = ns.SpellInfo(id)
            if info then reactiveOpen[info.name] = GetTime() + REACTIVE_WINDOW end
        end
    end
end

-- Without a readable GUID all targets share one entry: start it fresh per target.
ns.Listen("PLAYER_TARGET_CHANGED", function()
    debuffCache.target = nil
end)

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

-- The list is part of the profile, which all your characters may share, so every
-- reminder belongs to the class that added it. Older ones without a class go to
-- the first class that knows the spell.
local function playerClass()
    return select(2, UnitClass("player"))
end

function Reminders:IsMine(entry)
    if entry.class then return entry.class == playerClass() end
    local name, _, id = resolve(entry.spell)
    if name and (knows(id) or knows(tonumber(entry.spell))) then
        entry.class = playerClass()
        return true
    end
    return false
end

-- Indexes (into the whole list) of this class's reminders, in list order.
function Reminders:Visible()
    local out = {}
    for i, entry in ipairs(ns.db.reminders.list) do
        if self:IsMine(entry) then out[#out + 1] = i end
    end
    return out
end

function Reminders:Find(text)
    local l = (text or ""):lower()
    for i, entry in ipairs(ns.db.reminders.list) do
        if entry.spell:lower() == l and self:IsMine(entry) then return i end
    end
end

-- when: nil follows "Only in combat" on the General tab, or "combat" / "always".
function Reminders.CombatOnly(entry)
    if entry.when == "combat" then return true end
    if entry.when == "always" then return false end
    return ns.db.reminders.combatOnly
end

function Reminders:SetWhen(index, when)
    local entry = ns.db.reminders.list[index]
    if entry then entry.when = when end
    self:Update()
end

-- key: optional text shown on the icon, the key you press for it ("Q", "S-2")
local function cleanKey(key)
    key = strtrim(key or "")
    return key ~= "" and key or nil
end

function Reminders:Add(text, mode, key)
    text = strtrim(text or "")
    if text == "" or self:Find(text) then return false end
    mode = (mode == "buff" or mode == "debuff" or mode == "interrupt") and mode or "usable"
    table.insert(ns.db.reminders.list, { spell = text, mode = mode, key = cleanKey(key), class = playerClass() })
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

local NEXT_MODE = { usable = "buff", buff = "debuff", debuff = "interrupt", interrupt = "usable" }

function Reminders:ToggleMode(index)
    local entry = ns.db.reminders.list[index]
    if entry then entry.mode = NEXT_MODE[entry.mode] or "usable" end
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
