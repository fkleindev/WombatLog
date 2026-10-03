local ADDON, ns = ...
local Safe = ns.Safe

-- Forever blocks COMBAT_LOG_EVENT_UNFILTERED, so the feed is rebuilt from
-- UNIT_COMBAT (player/target), PLAYER_SWING, UNIT_SPELLCAST_SUCCEEDED and UNIT_AURA.
-- UNIT_COMBAT has no source, so hits on the target are attributed to you by timing.

local SWING_WINDOW = 0.4  -- a target hit this soon after your swing is yours
local SPELL_WINDOW = 1.5  -- travel time allowance after a successful cast
local MAX_ACTIONS = 24

local I = "Interface\\Icons\\"
local ICON_MELEE  = I .. "INV_Sword_04"
local ICON_TAKEN  = I .. "Ability_Warrior_DefensiveStance"
local ICON_HEAL   = I .. "Spell_Holy_Heal"
local ICON_PET    = I .. "Ability_Hunter_BeastTaming"
local ICON_SPELL  = I .. "Spell_Nature_StarFall"
local ICON_KILL   = I .. "Ability_Rogue_Eviscerate"

local IGNORE_CASTS = { [6603] = true, [75] = true } -- Auto Attack, Auto Shot

local AVOID_OUT = {
    MISS = "MISS", DODGE = "DODGE", PARRY = "PARRY", BLOCK = "BLOCK", RESIST = "RESIST",
    IMMUNE = "IMMUNE", EVADE = "EVADE", DEFLECT = "DEFLECT", REFLECT = "REFLECT", ABSORB = "ABSORB",
}
local AVOID_IN = {
    MISS = "MISSED", DODGE = "DODGED", PARRY = "PARRIED", BLOCK = "BLOCKED", RESIST = "RESISTED",
    IMMUNE = "IMMUNE", EVADE = "EVADED", DEFLECT = "DEFLECTED", REFLECT = "REFLECTED", ABSORB = "ABSORBED",
}

---------------------------------------------------------------------------
-- Recent actions (swings and casts) used for attribution
---------------------------------------------------------------------------

local actions = {}

local function remember(a)
    actions[#actions + 1] = a
    if #actions > MAX_ACTIONS then table.remove(actions, 1) end
end

-- Finds the swing/cast most likely to have produced a hit landing now.
-- grouped: each action may claim only one hit (others may be hitting the same target).
local function matchAction(school, grouped, spellsOnly)
    local now = GetTime()
    local swing, spell
    for i = #actions, 1, -1 do
        local a = actions[i]
        local age = now - a.t
        if age > SPELL_WINDOW then break end
        if not (grouped and a.matched) then
            if a.isSwing then
                if not swing and not spellsOnly and age <= SWING_WINDOW then swing = a end
            elseif not spell then
                spell = a
            end
        end
    end
    local pick
    if school == 1 and swing and (not spell or swing.t >= spell.t) then
        pick = swing
    else
        pick = spell or swing
    end
    if pick then pick.matched = true end
    return pick
end

local function labelFromAction(e, a)
    if a.isSwing then
        e.name, e.icon = "Melee", ICON_MELEE
        return
    end
    local info = ns.SpellInfo(a.spellID)
    e.spellID = a.spellID
    if info then
        e.name, e.icon = info.name, info.icon
    else
        e.name, e.icon, e.pending = "...", ICON_SPELL, true
    end
    if a.pet then e.name = "Pet: " .. e.name end
end

-- Most recent debuff you applied to the target; best guess for unmatched DoT ticks.
local function myTargetDebuff()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    for i = 1, 40 do
        local aura = ns.SafeTable(C_UnitAuras.GetAuraDataByIndex("target", i, "HARMFUL|PLAYER"))
        if not aura then return nil end
        local name = Safe(aura.name)
        if name then return name, Safe(aura.icon) end
    end
end

local function labelUnmatched(e, school)
    if e.kind == "heal" then
        e.name, e.icon = "Heal", ICON_HEAL
    elseif school == 1 then
        if Safe(UnitExists("pet")) then
            e.name, e.icon = "Pet", ICON_PET
        else
            e.name, e.icon = "Melee", ICON_MELEE
        end
    else
        local name, icon = myTargetDebuff()
        e.name = name or ((ns.SCHOOL_NAMES[school] or "Spell") .. " damage")
        e.icon = icon or ICON_SPELL
    end
end

---------------------------------------------------------------------------
-- UNIT_COMBAT
---------------------------------------------------------------------------

local function onTarget(action, flag, amount, school)
    if Safe(UnitIsUnit("target", "player")) then return end -- already reported as "player"
    if action == "ENERGIZE" or action == "INTERRUPT" then return end

    local hostile = Safe(UnitCanAttack("player", "target"))
    if action == "HEAL" then
        if hostile == true then return end
    elseif hostile == false then
        return -- damage on a friendly target isn't yours
    end

    local grouped = IsInGroup()
    local e = { dir = "out", flag = flag, amount = amount, school = school, crit = flag == "CRITICAL" }
    if action == "HEAL" then
        e.kind = "heal"
    elseif action == "WOUND" and amount > 0 then
        e.kind = "damage"
    else
        e.kind = "avoid"
        e.tag = AVOID_OUT[action] or (action == "WOUND" and "ABSORB") or action
    end

    local a = matchAction(school, grouped, e.kind == "heal")
    local mine = a ~= nil or not grouped
    if not mine and ns.db.behaviour.strict then return end
    e.dim = not mine

    if a then labelFromAction(e, a) else labelUnmatched(e, school) end
    if mine then
        if e.kind == "damage" then ns.AddStat("damage", amount)
        elseif e.kind == "heal" then ns.AddStat("healing", amount) end
    end
    ns.Emit(e)
end

local function onPlayer(action, flag, amount, school)
    if action == "ENERGIZE" or action == "INTERRUPT" then return end
    local e = { dir = "in", flag = flag, amount = amount, school = school, crit = flag == "CRITICAL" }

    if action == "HEAL" then
        local grouped = IsInGroup()
        local a = matchAction(school, grouped, true)
        if a or not grouped then
            -- your own heal on yourself counts as outgoing healing
            e.kind = "heal"
            if a then labelFromAction(e, a) else e.name, e.icon = "Heal", ICON_HEAL end
            ns.AddStat("healing", amount)
        else
            e.kind, e.name, e.icon = "healIn", "Healed", ICON_HEAL
        end
    elseif action == "WOUND" and amount > 0 then
        e.kind = "taken"
        e.icon = ICON_TAKEN
        if school == 1 then
            e.name = "Melee hit"
        else
            e.name = (ns.SCHOOL_NAMES[school] or "Spell") .. " damage"
        end
        ns.AddStat("taken", amount)
    else
        e.kind, e.icon = "avoid", ICON_TAKEN
        e.tag = AVOID_IN[action] or (action == "WOUND" and "ABSORBED") or action
        e.name = "Incoming"
    end
    ns.Emit(e)
end

ns.Listen("UNIT_COMBAT", function(unit, action, flag, amount, school)
    unit, action = Safe(unit), Safe(action)
    if not unit or not action then return end
    flag = Safe(flag)
    amount = Safe(amount) or 0
    school = Safe(school) or 1
    if unit == "player" then
        onPlayer(action, flag, amount, school)
    elseif unit == "target" then
        onTarget(action, flag, amount, school)
    end
end, "player", "target")

---------------------------------------------------------------------------
-- Swings and casts
---------------------------------------------------------------------------

ns.Listen("PLAYER_SWING", function()
    remember({ t = GetTime(), isSwing = true })
end)

ns.Listen("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    spellID = Safe(spellID)
    if not spellID or IGNORE_CASTS[spellID] then return end
    local a = { t = GetTime(), spellID = spellID, pet = Safe(unit) == "pet" }
    remember(a)
    ns.SpellInfo(spellID) -- warm the cache before the hit lands
    if a.pet then return end
    -- Casts that never produce a hit (buffs, utility, CC) get their own row.
    C_Timer.After(SPELL_WINDOW, function()
        if a.matched then return end
        local e = { kind = "cast", dir = "out" }
        labelFromAction(e, a)
        ns.Emit(e)
    end)
end, "player", "pet")

ns.Listen("SPELL_DATA_LOAD_RESULT", function(spellID, success)
    spellID = Safe(spellID)
    if spellID and Safe(success) then
        local info = ns.SpellInfo(spellID)
        if info then ns.Display:RefreshSpell(spellID, info) end
    end
end)

---------------------------------------------------------------------------
-- Auras
---------------------------------------------------------------------------

local auraCache = { player = {}, target = {} }

local function onAuraAdded(unit, aura)
    aura = ns.SafeTable(aura)
    if not aura then return end
    local id, name = Safe(aura.auraInstanceID), Safe(aura.name)
    if not id or not name then return end
    local harmful = Safe(aura.isHarmful)
    local src = Safe(aura.sourceUnit)
    local duration = Safe(aura.duration) or 0
    local mine = src == "player" or src == "pet"

    local kind, dir
    if unit == "player" then
        if harmful then
            kind, dir = "debuffIn", "in"
        elseif mine and duration > 0 then
            kind, dir = "buff", "in"
        end
    elseif harmful and mine then
        kind, dir = "debuffOut", "out"
    end
    if not kind then return end

    local icon = Safe(aura.icon) or 134400
    auraCache[unit][id] = { name = name, icon = icon }
    ns.Emit({ kind = kind, dir = dir, name = name, icon = icon })
end

ns.Listen("UNIT_AURA", function(unit, info)
    unit = Safe(unit)
    if unit ~= "player" and unit ~= "target" then return end
    info = ns.SafeTable(info)
    if not info or Safe(info.isFullUpdate) then
        wipe(auraCache[unit])
        return
    end
    if unit == "target" and Safe(UnitIsUnit("target", "player")) then return end

    local added = ns.SafeTable(info.addedAuras)
    if added then
        for _, aura in ipairs(added) do onAuraAdded(unit, aura) end
    end

    local removed = ns.SafeTable(info.removedAuraInstanceIDs)
    if removed then
        for _, id in ipairs(removed) do
            id = Safe(id)
            local cached = id and auraCache[unit][id]
            if cached then
                auraCache[unit][id] = nil
                if unit == "player" then
                    ns.Emit({ kind = "fade", dir = "in", name = cached.name, icon = cached.icon })
                end
            end
        end
    end
end, "player", "target")

ns.Listen("PLAYER_TARGET_CHANGED", function()
    wipe(auraCache.target)
end)

---------------------------------------------------------------------------
-- Kills (the XP message is the only readable "X dies" signal left)
---------------------------------------------------------------------------

ns.Listen("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    msg = Safe(msg)
    if not msg then return end
    local victim = msg:match("^(.-) dies") or msg
    ns.Emit({ kind = "kill", dir = "out", name = victim, icon = ICON_KILL })
end)
