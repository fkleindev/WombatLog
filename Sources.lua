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

local IGNORE_CASTS = { [6603] = true } -- Auto Attack (melee swings come from PLAYER_SWING)
-- Ranged auto attacks: matched like spells (so their hits get a name), but they never
-- get a "Cast" row of their own.
local AUTO_SHOTS = { [75] = true, [5019] = true } -- Auto Shot, Shoot (wands)
local TICK = 3 -- most damage-over-time effects tick every 3 s from when they're applied

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

-- /wl trace: raw events with timestamps, to see what the client actually sends.
local function trace(fmt, ...)
    if ns.trace then ns.Print(string.format("|cff888888%.3f|r " .. fmt, GetTime() % 1000, ...)) end
end

-- What we've learned about each spell from unambiguous hits (account-wide):
-- school, typical cast-to-hit delay, hits, and casts that never hit (misses).
local function getProfile(spellID, create)
    local all = WombatLogDB and WombatLogDB.spellProfiles
    if not all or not spellID then return nil end
    local p = all[spellID]
    if not p and create then
        p = { hits = 0, misses = 0 }
        all[spellID] = p
    end
    return p
end

-- Buffs, seals, auras: cast again and again but never followed by a hit.
local function neverHits(p)
    return p and p.hits == 0 and p.misses >= 4
end

-- Shipped facts about class spells (SpellData.lua, generated from the game's data):
-- { schoolMask, flags, tickSeconds, tickSchool }. They take precedence over anything
-- learned; learning only covers what isn't in the table (pets, items, racials).
local function spellData(id)
    return id and ns.SPELL_DATA and ns.SPELL_DATA[id]
end

local function has(d, flag)
    return d[2]:find(flag, 1, true) ~= nil
end

-- Higher is a better fit; nil rules the action out for this hit.
-- dotLikely: the hit lines up with one of your DoTs ticking, so a spell we know
-- nothing about yet shouldn't claim it (and learn the wrong school from it).
local function score(a, age, school, dotLikely)
    if a.isSwing then
        if school ~= 1 or age > SWING_WINDOW then return nil end
        return 2 + (2 - math.min(2, math.abs(age - 0.05) / 0.25))
    end
    local d = spellData(a.spellID)
    if d then
        -- utility (marks, slows, seals) and pure DoTs/channels never land a direct hit
        if has(d, "x") or not (has(d, "d") or has(d, "h") or has(d, "u")) then return nil end
        local s = 0
        if has(d, "d") and not has(d, "u") then
            if bit.band(d[1], school) == 0 then return nil end -- wrong school
            s = s + 3
        end
        local p = getProfile(a.spellID)
        if p and p.delay then
            s = s + (2 - math.min(2, math.abs(age - p.delay) / 0.25))
        elseif has(d, "n") or (has(d, "w") and not has(d, "p")) then
            -- melee abilities land right away (on-next-swing ones with the swing)
            s = s + (2 - math.min(2, math.abs(age - 0.05) / 0.25)) + (has(d, "n") and 1 or 0)
        end
        return s
    end
    local p = getProfile(a.spellID)
    if neverHits(p) then return nil end
    if dotLikely and not (p and p.school) then return nil end
    local s = 0
    if p and p.school then
        if bit.band(p.school, school) == 0 then return nil end -- wrong school
        s = s + 3
    end
    if p and p.delay then
        s = s + (2 - math.min(2, math.abs(age - p.delay) / 0.25))
    end
    return s
end

-- Finds the swing/cast most likely behind a hit landing now. Hits arrive in cast
-- order, so among equal fits the oldest wins, and every hit uses up its action.
-- A used action only gets another hit (AoE, multi-hit) when nothing unused fits;
-- in a group never, since others may be hitting the same target.
-- Returns the action and whether it was the only candidate.
local function matchAction(school, grouped, spellsOnly, dotLikely)
    local now = GetTime()
    local best, bestScore, open = nil, nil, 0
    for _, a in ipairs(actions) do
        local age = now - a.t
        if age <= SPELL_WINDOW and not (spellsOnly and a.isSwing) and not (grouped and a.matched) then
            local s = score(a, age, school, dotLikely)
            if s then
                if a.matched then s = s - 10 else open = open + 1 end
                if not bestScore or s > bestScore then best, bestScore = a, s end
            end
        end
    end
    if not best then return nil end
    local unambiguous = open == 1 and not best.matched
    best.matched = true

    -- learn from clear cases only
    if unambiguous and not best.isSwing then
        local p = getProfile(best.spellID, true)
        local delay = now - best.t
        p.school = school
        p.delay = p.delay and (p.delay * 0.7 + delay * 0.3) or delay
        p.hits = p.hits + 1
    end
    return best
end

-- Hits you landed recently, so a cast that got no hit of its own can be merged into one.
local recentHits = {}

local function rememberHit(e, a)
    local now = GetTime()
    recentHits[#recentHits + 1] = { e = e, a = a, t = now }
    while recentHits[1] and now - recentHits[1].t > SPELL_WINDOW * 2 do table.remove(recentHits, 1) end
end

local lastSwing = 0

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

-- Auras seen in UNIT_AURA payloads (target: only debuffs you applied), by instance ID.
local auraCache = { player = {}, target = {} }
local auraSeq = 0

-- Your recent casts by spell ID. Auras applied in combat are often secret on
-- Forever, so a DoT may never show up in auraCache; its cast still tells us which
-- spell it was and when its tick clock started.
local dotCasts = {}
local DOT_MAX_AGE = 30
local TRAVEL = 1.2 -- a cast's DoT starts when the projectile lands, up to this much later

-- Which of your DoTs on the target most likely produced a tick landing now.
-- Read from the caches: querying the target's auras in combat errors on Forever.
-- A DoT fits when it started a whole number of tick intervals ago and its learned
-- tick school matches; one that ticks in another school (or a mark that never
-- ticks) loses. Among equal fits the most recently applied wins.
-- Returns the candidate, how many line up in time, and its score.
local function tickDebuff(school)
    local now = GetTime()
    local best, bestScore, aligned = nil, nil, 0

    local function consider(c, fromCast)
        local d = spellData(c.spellId)
        local p = c.spellId and getProfile(c.spellId)
        local s, period, travel = 0, TICK, TRAVEL
        if d then
            -- known: only real DoTs/channels tick, in their own school and interval
            if not has(d, "o") or bit.band(d[4] or d[1], school) == 0 then return end
            s, period = 2, d[3] or TICK
            travel = has(d, "p") and TRAVEL or 0.3
        elseif p and p.tickSchool then
            s = bit.band(p.tickSchool, school) ~= 0 and 2 or nil
        elseif fromCast and p and p.hits > 0 and p.school and bit.band(p.school, school) == 0 then
            s = nil -- a direct-damage spell of another school
        end
        if not s then return end
        local age = now - c.t
        local phase = age % period
        local fits
        if fromCast then
            fits = age >= period - 0.2 and (phase <= travel or phase >= period - 0.2)
        else
            fits = age >= period - 0.4 and math.min(phase, period - phase) <= 0.4
        end
        if fits then
            s = s + 4 -- timing counts more than a learned school
            aligned = aligned + 1
        end
        s = s + c.seq * 1e-6 -- tie: the most recent one
        if not bestScore or s > bestScore then best, bestScore = c, s end
    end

    local seen = {}
    for _, a in pairs(auraCache.target) do
        consider(a, false)
        if a.spellId then seen[a.spellId] = true end
    end
    for id, c in pairs(dotCasts) do
        if now - c.t > DOT_MAX_AGE then
            dotCasts[id] = nil
        elseif not seen[id] then
            consider(c, true) -- readable aura timing beats cast timing
        end
    end
    return best, aligned, bestScore
end

-- Labels an unmatched tick. A DoT's tick school is learned only after it was the
-- one and only timing fit on two separate applications, so a coincidence (a mark
-- whose timer happens to line up once) can't teach the wrong school.
local function myTargetDebuff(school)
    local best, aligned, s = tickDebuff(school)
    if not best then
        trace("tick -> no DoT candidate")
        return nil
    end
    if aligned == 1 and s >= 4 and best.spellId and not spellData(best.spellId) then
        local p = getProfile(best.spellId, true)
        if p.lastVote ~= best.seq then
            p.lastVote = best.seq
            p.tickVotes = p.tickVotes or {}
            p.tickVotes[school] = (p.tickVotes[school] or 0) + 1
            if p.tickVotes[school] >= 2 then p.tickSchool = school end
        end
    end
    local name, icon = best.name, best.icon
    if not name and best.spellId then
        local info = ns.SpellInfo(best.spellId)
        name, icon = info and info.name, info and info.icon
    end
    trace("tick -> %s (spell %s, %d timing fits, score %.1f)", name or "?", tostring(best.spellId), aligned, s)
    return name, icon, best.spellId
end

-- True when a hit lines up with a DoT whose learned tick school matches.
-- (Score 6 = school match + timing; an unlearned DoT never pushes a spell aside.)
local function looksLikeTick(school)
    local best, _, s = tickDebuff(school)
    return best ~= nil and s >= 6
end

-- Active "Seal of ..." on you (paladin on-hit procs).
local function activeSeal()
    for _, a in pairs(auraCache.player) do
        if a.name:find("^Seal of") then return a.name, a.icon end
    end
end

local function labelUnmatched(e, school)
    if e.kind ~= "heal" and school ~= 1 and GetTime() - lastSwing <= 0.15 then
        -- spell damage together with a swing: an on-hit proc
        local seal, icon = activeSeal()
        e.name = seal or ((ns.SCHOOL_NAMES[school] or "Spell") .. " proc")
        e.icon = icon or ICON_SPELL
        return
    end
    if e.kind == "heal" then
        e.name, e.icon = "Heal", ICON_HEAL
    elseif school == 1 then
        if Safe(UnitExists("pet")) then
            e.name, e.icon = "Pet", ICON_PET
        else
            e.name, e.icon = "Melee", ICON_MELEE
        end
    else
        local name, icon, spellId = myTargetDebuff(school)
        e.name = name or ((ns.SCHOOL_NAMES[school] or "Spell") .. " damage")
        e.icon = icon or ICON_SPELL
        e.spellID = name and spellId or nil -- keeps DoT ticks under the spell in stats
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

    local a = matchAction(school, grouped, e.kind == "heal", e.kind ~= "heal" and looksLikeTick(school))
    local mine = a ~= nil or not grouped
    if not mine and ns.db.behaviour.strict then return end
    e.dim = not mine

    if a then labelFromAction(e, a) else labelUnmatched(e, school) end
    if mine then
        if e.kind ~= "avoid" then rememberHit(e, a) end
        ns.OnOutgoing(e)
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
            rememberHit(e, a)
            ns.OnOutgoing(e)
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
    trace("UNIT_COMBAT %s %s %s %d school %d", unit, action, flag or "-", amount, school)
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
    lastSwing = GetTime()
    trace("PLAYER_SWING")
    remember({ t = lastSwing, isSwing = true })
end)

-- A damage spell whose window ran out without a hit of its own: if another action's
-- hit landed in that window, the client most likely reported both as one hit.
-- Returns the hit entry to merge into.
local function mergeHost(a, p)
    local d = spellData(a.spellID)
    if d then
        if not has(d, "d") then return nil end -- only spells with direct damage can hide in a hit
    elseif not p or p.hits == 0 then
        return nil
    end
    for i = #recentHits, 1, -1 do
        local h = recentHits[i]
        -- no school check: a combined hit reports only one school
        if h.t >= a.t and h.t - a.t <= SPELL_WINDOW and h.a ~= a and not h.e.dim then
            return h.e
        end
    end
end

ns.Listen("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    spellID = Safe(spellID)
    if not spellID or IGNORE_CASTS[spellID] then return end
    local a = { t = GetTime(), spellID = spellID, pet = Safe(unit) == "pet", auto = AUTO_SHOTS[spellID] }
    remember(a)
    local info = ns.SpellInfo(spellID) -- warm the cache before the hit lands
    trace("CAST %s (%d)%s", info and info.name or "?", spellID, a.pet and " pet" or "")
    if a.pet then return end
    if not a.auto then
        auraSeq = auraSeq + 1
        dotCasts[spellID] = { spellId = spellID, t = a.t, seq = auraSeq }
    end
    C_Timer.After(SPELL_WINDOW, function()
        if a.matched or a.auto then return end -- an unmatched auto shot simply missed
        local p = getProfile(spellID, true)
        p.misses = p.misses + 1
        local name = (ns.SpellInfo(spellID) or {}).name
        local host = name and mergeHost(a, p)
        if host then
            -- one reported hit, two abilities: show both names on that row
            local oldKey = ns.Stats.SpellKey(host)
            host.combined = (host.combined or 1) + 1
            host.name = (host.name or "?") .. " + " .. name
            -- both icons on the row, too
            local info = ns.SpellInfo(spellID)
            host.extraIcons = host.extraIcons or {}
            table.insert(host.extraIcons, info and info.icon or ICON_SPELL)
            host.spellID, host.pending = nil, nil
            ns.Stats:Recombine(host, oldKey)
            ns.Display:RefreshEntry(host)
            trace("merged %s into %s", name, host.name)
            return
        end
        -- Casts that never produce a hit (buffs, utility, CC) get their own row.
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

local function onAuraAdded(unit, aura)
    aura = ns.SafeTable(aura)
    if not aura then return end
    local id, name = Safe(aura.auraInstanceID), Safe(aura.name)
    if not id or not name then return end
    local harmful = Safe(aura.isHarmful)
    local src = Safe(aura.sourceUnit)
    local duration = Safe(aura.duration) or 0
    local mine = src == "player" or src == "pet"

    -- every buff gained on you (any source) can trigger a proc alert
    if unit == "player" and not harmful then
        ns.Alerts:OnPlayerAura(name, Safe(aura.icon), Safe(aura.spellId))
    end

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
    auraSeq = auraSeq + 1
    auraCache[unit][id] = { name = name, icon = icon, seq = auraSeq, t = GetTime(), spellId = Safe(aura.spellId) }
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

    -- a re-applied DoT restarts its tick timer
    local updated = unit == "target" and ns.SafeTable(info.updatedAuraInstanceIDs)
    if updated then
        for _, id in ipairs(updated) do
            local cached = auraCache.target[Safe(id) or 0]
            if cached then cached.t = GetTime() end
        end
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
    wipe(dotCasts)
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
