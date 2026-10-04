local ADDON, ns = ...

-- Classic clients (Era, TBC, Mists) still give addons COMBAT_LOG_EVENT_UNFILTERED:
-- every hit with its real source, target, spell and flags. Here the feed comes
-- straight from it, with nothing to guess. Forever and Retail use Sources.lua.
if not ns.useCombatLog then return end

local ICONS, AVOID_OUT, AVOID_IN = ns.ICONS, ns.AVOID_OUT, ns.AVOID_IN
local CAST_WINDOW = 3 -- a cast with no hit, heal, miss or aura of its own by then gets a "Cast" row
local IGNORE_CASTS = { [6603] = true, [75] = true, [5019] = true } -- Auto Attack, Auto Shot, Shoot
local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1
local TYPE_PET = COMBATLOG_OBJECT_TYPE_PET or 0x1000
local NO_FLAGS = 0

local playerGUID, petGUID

local function refreshGUIDs()
    playerGUID = UnitGUID("player")
    petGUID = UnitGUID("pet")
end

local function trace(fmt, ...)
    if ns.trace then ns.Print(string.format("|cff888888%.3f|r " .. fmt, GetTime() % 1000, ...)) end
end

local function spellData(id)
    return id and ns.SPELL_DATA and ns.SPELL_DATA[id]
end

-- Name and icon for a combat log spell (Classic Era may report spell ID 0).
local function label(e, spellId, spellName, pet)
    local info = spellId and spellId > 0 and ns.SpellInfo(spellId)
    e.name = (info and info.name) or spellName or "?"
    e.icon = (info and info.icon) or (spellName and GetSpellTexture and GetSpellTexture(spellName)) or ICONS.spell
    e.spellID = spellId and spellId > 0 and spellId or nil
    if pet then e.name = "Pet: " .. e.name end
end

-- One key per DoT on one target, so the same DoT on two mobs gets two rows.
local function dotKey(destGUID, spellId, spellName)
    return (destGUID or "?") .. ":" .. ((spellId and spellId > 0) and spellId or spellName or "?")
end

local function flagOf(resisted, blocked, absorbed, glancing, crushing)
    if glancing then return "GLANCING" end
    if crushing then return "CRUSHING" end
    if (absorbed or 0) > 0 then return "ABSORB" end
    if (blocked or 0) > 0 then return "BLOCK_REDUCED" end
    if (resisted or 0) > 0 then return "RESIST_REDUCED" end
end

---------------------------------------------------------------------------
-- DoTs: when each of yours runs out, for the pinned rows
---------------------------------------------------------------------------

local dots = {} -- dotKey -> { expires, lastTick, period }

local UNITS = { "target", "focus", "mouseover", "pettarget" }

local function unitFor(guid)
    for _, u in ipairs(UNITS) do
        if UnitGUID(u) == guid then return u end
    end
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitGUID(u) == guid then return u end
    end
end

-- Expiration time of your debuff on that unit, if the client shows it.
local function auraExpires(unit, spellId, spellName)
    for i = 1, 40 do
        local name, id, expires
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL|PLAYER")
            if not a then return nil end
            name, id, expires = a.name, a.spellId, a.expirationTime
        elseif UnitAura then
            local n, _, _, _, _, exp, _, _, _, sid = UnitAura(unit, i, "HARMFUL|PLAYER")
            if not n then return nil end
            name, id, expires = n, sid, exp
        else
            return nil
        end
        if (spellId > 0 and id == spellId) or (spellId == 0 and name == spellName) then
            return expires and expires > 0 and expires or nil
        end
    end
end

local function trackDot(destGUID, spellId, spellName)
    local key = dotKey(destGUID, spellId, spellName)
    local d = dots[key] or {}
    dots[key] = d
    local unit = unitFor(destGUID)
    local ok, expires = false, nil
    if unit then ok, expires = pcall(auraExpires, unit, spellId or 0, spellName) end
    local data = spellData(spellId)
    d.expires = (ok and expires) or (data and data[5] and GetTime() + data[5]) or nil
end

---------------------------------------------------------------------------
-- Casts with no hit of their own (buffs, utility, CC) get a "Cast" row
---------------------------------------------------------------------------

local casts = {} -- spell ID or name -> cast entry waiting for its effect

local function castKey(spellId, spellName)
    return (spellId and spellId > 0) and spellId or spellName
end

local function used(spellId, spellName)
    local c = casts[castKey(spellId, spellName)]
    if c then c.used = true end
end

local function onCast(spellId, spellName)
    if IGNORE_CASTS[spellId] then return end
    local key = castKey(spellId, spellName)
    if not key then return end
    local c = { spellId = spellId, spellName = spellName }
    casts[key] = c
    C_Timer.After(CAST_WINDOW, function()
        if casts[key] == c then casts[key] = nil end
        if c.used then return end
        local e = { kind = "cast", dir = "out" }
        label(e, spellId, spellName)
        ns.Emit(e)
    end)
end

---------------------------------------------------------------------------
-- Your hits, heals and misses
---------------------------------------------------------------------------

local function outgoingDamage(sub, destGUID, spellId, spellName, pet, amount, school, resisted, blocked, absorbed, critical, glancing, crushing)
    local e = {
        kind = "damage", dir = "out", amount = amount, school = school, crit = critical and true or false,
        flag = flagOf(resisted, blocked, absorbed, glancing, crushing),
    }
    if sub == "SWING_DAMAGE" then
        if pet then e.name, e.icon = "Pet", ICONS.pet else e.name, e.icon = "Melee", ICONS.melee end
    else
        label(e, spellId, spellName, pet)
        used(spellId, spellName)
    end
    if sub == "SPELL_PERIODIC_DAMAGE" then
        local key = dotKey(destGUID, spellId, spellName)
        local d = dots[key] or {}
        dots[key] = d
        local now = GetTime()
        if d.lastTick and now - d.lastTick > 0.5 and now - d.lastTick < 10 then d.period = now - d.lastTick end
        d.lastTick = now
        local data = spellData(spellId)
        e.tick, e.pinKey, e.dotEnd = true, key, d.expires
        e.tickPeriod = d.period or (data and data[3]) or nil
    end
    trace("%s %s %d%s", sub, e.name or "?", amount, e.crit and " crit" or "")
    ns.OnOutgoing(e)
    ns.Emit(e)
end

local function outgoingMiss(sub, spellId, spellName, pet, missType)
    if not pet then ns.Reminders:OnAvoid("out", missType) end
    local e = { kind = "avoid", dir = "out", tag = AVOID_OUT[missType] or missType }
    if sub == "SWING_MISSED" then
        if pet then e.name, e.icon = "Pet", ICONS.pet else e.name, e.icon = "Melee", ICONS.melee end
    else
        label(e, spellId, spellName, pet)
        used(spellId, spellName)
    end
    ns.OnOutgoing(e)
    ns.Emit(e)
end

---------------------------------------------------------------------------
-- Auras on you
---------------------------------------------------------------------------

local shownAuras = {} -- auras on you that got a row, so their fading gets one too

local function auraOnPlayer(sub, sourceIsMe, spellId, spellName, auraType)
    local key = castKey(spellId, spellName)
    if sub == "SPELL_AURA_APPLIED" then
        local e = { dir = "in" }
        label(e, spellId, spellName)
        if auraType == "BUFF" then
            ns.Alerts:OnPlayerAura(e.name, e.icon, e.spellID)
            if not sourceIsMe then return end
            e.kind = "buff"
        else
            e.kind = "debuffIn"
        end
        if key then shownAuras[key] = { name = e.name, icon = e.icon } end
        ns.Emit(e)
    elseif sub == "SPELL_AURA_REMOVED" then
        local a = key and shownAuras[key]
        if a then
            shownAuras[key] = nil
            ns.Emit({ kind = "fade", dir = "in", name = a.name, icon = a.icon })
        end
    end
end

---------------------------------------------------------------------------
-- The combat log
---------------------------------------------------------------------------

local function onEvent()
    local _, sub, _, sourceGUID, _, sourceFlags, _, destGUID, destName, _, _, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13 =
        CombatLogGetCurrentEventInfo()
    if not playerGUID then refreshGUIDs() end

    local fromMe = sourceGUID == playerGUID
    local mine = fromMe or (sourceGUID ~= nil and bit.band(sourceFlags or NO_FLAGS, AFFILIATION_MINE) ~= 0)
    local pet = mine and not fromMe and (sourceGUID == petGUID or bit.band(sourceFlags or NO_FLAGS, TYPE_PET) ~= 0)
    local toMe = destGUID == playerGUID

    -- spell events: a1..a3 = spell ID, name, school; the rest follows
    local isSwing = sub:sub(1, 6) == "SWING_"
    local spellId, spellName
    if not isSwing and sub ~= "PARTY_KILL" and sub:sub(1, 13) ~= "ENVIRONMENTAL" then
        spellId, spellName = a1, a2
    end

    if mine then
        if sub == "SWING_DAMAGE" then
            -- amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand
            if fromMe then ns.Swing:OnSwing(a10 and true or false) end
            if not toMe then outgoingDamage(sub, destGUID, nil, nil, pet, a1, a3, a4, a5, a6, a7, a8, a9) end
            return
        elseif sub == "SWING_MISSED" then
            if fromMe then ns.Swing:OnSwing(a2 and true or false) end
            if not toMe then outgoingMiss(sub, nil, nil, pet, a1) end
            return
        elseif sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "DAMAGE_SHIELD" then
            if not toMe then
                outgoingDamage(sub, destGUID, spellId, spellName, pet, a4, a6, a7, a8, a9, a10, a11, a12)
            end
            return
        elseif sub == "SPELL_MISSED" or sub == "SPELL_PERIODIC_MISSED" or sub == "RANGE_MISSED" or sub == "DAMAGE_SHIELD_MISSED" then
            if not toMe then outgoingMiss(sub, spellId, spellName, pet, a4) end
            return
        elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
            -- amount, overhealing, absorbed, critical; your heal on yourself shows on your side
            used(spellId, spellName)
            local e = { kind = "heal", dir = toMe and "in" or "out", amount = a4, school = a3, crit = a7 and true or false }
            label(e, spellId, spellName, pet)
            ns.OnOutgoing(e)
            ns.Emit(e)
            return
        elseif sub == "SPELL_CAST_SUCCESS" then
            if fromMe then onCast(spellId, spellName) end
            return
        elseif sub == "PARTY_KILL" then
            ns.Emit({ kind = "kill", dir = "out", name = destName or "?", icon = ICONS.kill })
            return
        elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_REMOVED" then
            used(spellId, spellName)
            if not toMe and a4 == "DEBUFF" then
                if sub == "SPELL_AURA_REMOVED" then
                    local key = dotKey(destGUID, spellId, spellName)
                    dots[key] = nil
                    ns.Display:EndPin(key)
                else
                    trackDot(destGUID, spellId, spellName)
                    if sub == "SPELL_AURA_APPLIED" then
                        local e = { kind = "debuffOut", dir = "out" }
                        label(e, spellId, spellName, pet)
                        ns.Emit(e)
                    end
                end
                return
            end
        elseif sub:find("_MISSED$") == nil and sub:find("^SPELL_") then
            used(spellId, spellName) -- energize, summon, dispel, interrupt...
        end
    end

    if not toMe then return end

    -- damage, misses, heals and auras on you
    if sub == "SWING_DAMAGE" or sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "ENVIRONMENTAL_DAMAGE" then
        local amount, school, crit
        local e = { kind = "taken", dir = "in", icon = ICONS.taken }
        if sub == "SWING_DAMAGE" then
            amount, school, crit = a1, a3, a7
            e.name = "Melee hit"
        elseif sub == "ENVIRONMENTAL_DAMAGE" then
            amount, school, crit = a2, a4, false
            e.name = (a1 and (a1:sub(1, 1) .. a1:sub(2):lower())) or "Environment"
        else
            amount, school, crit = a4, a6, a10
            label(e, spellId, spellName)
        end
        e.amount, e.school, e.crit = amount, school, crit and true or false
        ns.AddStat("taken", amount)
        ns.Emit(e)
    elseif sub == "SWING_MISSED" or sub == "SPELL_MISSED" or sub == "RANGE_MISSED" or sub == "SPELL_PERIODIC_MISSED" then
        local missType = sub == "SWING_MISSED" and a1 or a4
        ns.Reminders:OnAvoid("in", missType)
        ns.Emit({ kind = "avoid", dir = "in", tag = AVOID_IN[missType] or missType, name = "Incoming", icon = ICONS.taken })
    elseif (sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL") and not mine then
        local e = { kind = "healIn", dir = "in", amount = a4, crit = a7 and true or false }
        label(e, spellId, spellName)
        ns.Emit(e)
    elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REMOVED" then
        auraOnPlayer(sub, fromMe, spellId, spellName, a4)
    end
end

ns.Listen("COMBAT_LOG_EVENT_UNFILTERED", onEvent)
ns.Listen("PLAYER_ENTERING_WORLD", refreshGUIDs)
ns.Listen("UNIT_PET", refreshGUIDs, "player")
