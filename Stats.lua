local ADDON, ns = ...
local Stats = {}
ns.Stats = Stats
local Safe = ns.Safe

local TOP_SPELLS = 10

-- Per-character data (history, records, session) lives outside the profiles.
function Stats:Init()
    local all = WombatLogDB.charData
    all[ns.charKey] = all[ns.charKey] or {}
    local c = all[ns.charKey]
    c.history = c.history or {}
    c.records = c.records or {}
    c.records.spells = c.records.spells or {}
    c.session = c.session or {}
    self.char = c
end

---------------------------------------------------------------------------
-- Current fight
---------------------------------------------------------------------------

function Stats:StartFight()
    local f = ns.fight
    f.spells = {}
    f.hits, f.crits, f.misses = 0, 0, 0
    f.streak, f.longestStreak = 0, 0
    f.newRecords = {}
    f.zone = (GetRealZoneText and GetRealZoneText()) or GetZoneText() or ""
    f.target = Safe(UnitName("target"))
end

local function spellKey(e)
    return (e.kind == "heal" and "h:" or "d:") .. (e.spellID or e.name or "?")
end
Stats.SpellKey = spellKey

-- Beating an existing record flags the entry; a spell's first hit is stored silently.
function Stats:CheckRecord(e, key)
    -- combined hits (two abilities in one reported hit) never count as records
    if not ns.db.stats.records.enabled or e.pending or e.combined then return end
    if ns.testing then
        e.record = e.forceRecord or nil
        return
    end
    local spells = self.char.records.spells
    local r = spells[key]
    if not r then
        r = { kind = e.kind }
        spells[key] = r
    end
    r.name, r.icon = e.name, e.icon or r.icon
    local field = e.crit and "crit" or "hit"
    local old = r[field]
    if not old or e.amount > old.amount then
        r[field] = { amount = e.amount, date = time() }
        e.recordUndo = { key = key, field = field, old = old } -- in case the hit turns out combined
        if old then
            e.record = true
            local list = ns.fight.newRecords
            if list then list[#list + 1] = { name = e.name, icon = e.icon, amount = e.amount, crit = e.crit, entry = e } end
        end
    end
end

-- A hit later found to contain two abilities: take back the record it set.
function Stats:UndoRecord(e)
    local u = e.recordUndo
    if not u then return end
    e.recordUndo, e.record = nil, nil
    local r = self.char.records.spells[u.key]
    if r then r[u.field] = u.old end
    local list = ns.fight.newRecords
    for i = #(list or {}), 1, -1 do
        if list[i].entry == e then table.remove(list, i) end
    end
end

local function spellEntry(f, key, e)
    local s = f.spells[key]
    if not s then
        s = { name = e.name or "?", icon = e.icon, kind = e.kind == "heal" and "heal" or "damage",
              hits = 0, crits = 0, misses = 0, total = 0, max = 0 }
        f.spells[key] = s
    end
    if not e.pending and e.name then s.name = e.name end
    s.icon = s.icon or e.icon
    return s
end

local function addHit(s, e)
    s.hits = s.hits + 1
    s.total = s.total + (e.amount or 0)
    if e.crit then s.crits = s.crits + 1 end
    if (e.amount or 0) > s.max then s.max = e.amount end
end

-- Moves a hit from its spell to its new combined name in the breakdown.
function Stats:Recombine(e, oldKey)
    self:UndoRecord(e)
    local f = ns.fight
    if not f.spells then return end
    local old = f.spells[oldKey]
    if old and old.hits > 0 then
        old.hits = old.hits - 1
        old.total = old.total - (e.amount or 0)
        if e.crit then old.crits = old.crits - 1 end
        if old.hits == 0 and old.misses == 0 then f.spells[oldKey] = nil end
    end
    addHit(spellEntry(f, spellKey(e), e), e)
end

-- Every outgoing entry that is yours: totals, spell breakdown, streak, records.
function Stats:Outgoing(e)
    local f = ns.fight
    if e.kind == "damage" then
        ns.AddStat("damage", e.amount)
    elseif e.kind == "heal" then
        ns.AddStat("healing", e.amount)
    end
    if not f.active or not f.spells then return end

    if e.kind == "avoid" then
        f.misses = f.misses + 1
        f.streak = 0
    else
        f.hits = f.hits + 1
        if e.crit then
            f.crits = f.crits + 1
            f.streak = f.streak + 1
            if f.streak > f.longestStreak then f.longestStreak = f.streak end
        else
            f.streak = 0
        end
        e.streak = f.streak
    end

    local key = spellKey(e)
    local s = spellEntry(f, key, e)
    if e.kind == "avoid" then
        s.misses = s.misses + 1
        return
    end
    addHit(s, e)

    if e.amount and e.amount > 0 then self:CheckRecord(e, key) end
end

local function sortedSpells(spells, limit)
    local list = {}
    for _, s in pairs(spells or {}) do
        if s.total > 0 then list[#list + 1] = s end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    while #list > limit do table.remove(list) end
    return list
end

function Stats:FinishFight()
    local f = ns.fight
    if not f.spells then return end
    local duration = ns.Elapsed()
    local snap = {
        time = time(), zone = f.zone, target = f.target, duration = duration,
        damage = f.damage, healing = f.healing, taken = f.taken,
        dps = f.damage / math.max(duration, 1), hps = f.healing / math.max(duration, 1),
        hits = f.hits, crits = f.crits, misses = f.misses,
        longestStreak = f.longestStreak,
        top = f.top and { name = f.top.name, amount = f.top.amount, crit = f.top.crit },
        records = {},
        spells = {},
        test = ns.testing or nil,
    }
    for _, rec in ipairs(f.newRecords or {}) do
        snap.records[#snap.records + 1] = { name = rec.name, icon = rec.icon, amount = rec.amount, crit = rec.crit }
    end
    for _, s in ipairs(sortedSpells(f.spells, TOP_SPELLS)) do
        snap.spells[#snap.spells + 1] = {
            name = s.name, icon = s.icon, kind = s.kind,
            hits = s.hits, crits = s.crits, misses = s.misses, total = s.total, max = s.max,
        }
    end
    local useful = (f.damage + f.healing) > 0

    if not ns.testing and useful then
        local S = ns.db.stats
        if S.records.enabled then
            local rec = self.char.records
            if duration >= S.records.minDpsDuration and (not rec.bestDps or snap.dps > rec.bestDps.dps) then
                snap.newBestDps = rec.bestDps ~= nil
                rec.bestDps = { dps = snap.dps, duration = duration, date = snap.time, zone = snap.zone }
            end
            if f.longestStreak > (rec.longestStreak or 0) then
                rec.longestStreak = f.longestStreak
                rec.longestStreakDate = snap.time
            end
        end
        if S.history.enabled and duration >= S.history.minDuration then
            local h = self.char.history
            table.insert(h, 1, snap)
            while #h > S.history.keep do table.remove(h) end
        end
        self:SessionFight(duration)
    end

    self.last = snap
    if useful then ns.Report:ShowSummary(snap) end
end

function Stats:ResetRecords()
    self.char.records = { spells = {} }
end

function Stats:ClearHistory()
    wipe(self.char.history)
end

---------------------------------------------------------------------------
-- Session
---------------------------------------------------------------------------

local function sessionOn()
    return ns.db and ns.db.session.enabled and Stats.char
end

function Stats:ResetSession()
    local s = self.char.session
    wipe(s)
    s.start = time()
    s.xp, s.kills, s.killXp, s.killXpCount = 0, 0, 0, 0
    s.fights, s.combatTime, s.deaths, s.levels = 0, 0, 0, 0
    s.moneyIn, s.moneyOut = 0, 0
    self.lastXP, self.lastXPMax = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    self.lastMoney = GetMoney()
end

function Stats:SessionFight(duration)
    if not sessionOn() then return end
    local s = self.char.session
    s.fights = (s.fights or 0) + 1
    s.combatTime = (s.combatTime or 0) + duration
end

-- Pairs a kill message with the XP change it caused (either may arrive first).
local KILL_WINDOW = 1.0

local function addKillXp(s, delta)
    s.killXp = s.killXp + delta
    s.killXpCount = s.killXpCount + 1
end

ns.Listen("PLAYER_ENTERING_WORLD", function(isInitialLogin)
    if not Stats.char then return end
    local s = Stats.char.session
    if isInitialLogin or not s.start then
        Stats:ResetSession() -- a fresh login starts a new session; /reload continues it
    else
        Stats.lastXP, Stats.lastXPMax = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
        Stats.lastMoney = GetMoney()
    end
end)

ns.Listen("PLAYER_XP_UPDATE", function()
    if not sessionOn() then return end
    local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
    if not xp or not max then return end
    local s = Stats.char.session
    local delta = 0
    if Stats.lastXP then
        delta = xp - Stats.lastXP
        if delta < 0 and Stats.lastXPMax then delta = (Stats.lastXPMax - Stats.lastXP) + xp end -- level-up
    end
    Stats.lastXP, Stats.lastXPMax = xp, max
    if delta <= 0 then return end
    s.xp = s.xp + delta
    local now = GetTime()
    if Stats.pendingKill and now - Stats.pendingKill <= KILL_WINDOW then
        Stats.pendingKill = nil
        addKillXp(s, delta)
    else
        Stats.lastDelta, Stats.lastDeltaTime = delta, now
    end
end)

ns.Listen("CHAT_MSG_COMBAT_XP_GAIN", function()
    if not sessionOn() then return end
    local s = Stats.char.session
    s.kills = s.kills + 1
    local now = GetTime()
    if Stats.lastDeltaTime and now - Stats.lastDeltaTime <= KILL_WINDOW then
        addKillXp(s, Stats.lastDelta)
        Stats.lastDeltaTime = nil
    else
        Stats.pendingKill = now
    end
end)

ns.Listen("PLAYER_MONEY", function()
    if not sessionOn() then return end
    local money = GetMoney()
    local s = Stats.char.session
    if Stats.lastMoney then
        local delta = money - Stats.lastMoney
        if delta > 0 then s.moneyIn = s.moneyIn + delta else s.moneyOut = s.moneyOut - delta end
    end
    Stats.lastMoney = money
end)

ns.Listen("PLAYER_DEAD", function()
    if sessionOn() then
        local s = Stats.char.session
        s.deaths = s.deaths + 1
    end
end)

ns.Listen("PLAYER_LEVEL_UP", function()
    if sessionOn() then
        local s = Stats.char.session
        s.levels = s.levels + 1
    end
end)

-- Derived session numbers for the journal, tooltip and header line.
function Stats:SessionInfo()
    local s = self.char and self.char.session
    if not s or not s.start then return nil end
    local elapsed = math.max(time() - s.start, 1)
    local info = {
        elapsed = elapsed, kills = s.kills, fights = s.fights, deaths = s.deaths, levels = s.levels,
        combatTime = s.combatTime, moneyIn = s.moneyIn, moneyOut = s.moneyOut, xp = s.xp,
    }
    local level, maxLevel = UnitLevel("player"), GetMaxPlayerLevel and GetMaxPlayerLevel()
    info.atMax = maxLevel and level and level >= maxLevel
    if not info.atMax then
        local xp, max = Safe(UnitXP("player")), Safe(UnitXPMax("player"))
        info.xpPerHour = s.xp / elapsed * 3600
        if xp and max then
            local remaining = max - xp
            info.remaining = remaining
            if info.xpPerHour > 0 then info.timeToLevel = remaining / info.xpPerHour * 3600 end
            if s.killXpCount > 0 then
                info.avgKillXp = s.killXp / s.killXpCount
                info.killsToLevel = math.ceil(remaining / info.avgKillXp)
            end
        end
        info.rested = Safe(GetXPExhaustion and GetXPExhaustion())
    end
    return info
end

function Stats.FormatDuration(seconds)
    seconds = math.floor(seconds or 0)
    if seconds >= 3600 then
        return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- One-line summary for the log header.
function Stats:SessionLine()
    local i = self:SessionInfo()
    if not i then return "" end
    if i.atMax or not i.xpPerHour then
        return string.format(ns.L["Session %s  ·  %d kills"], Stats.FormatDuration(i.elapsed), i.kills)
    end
    local ttl = i.timeToLevel and Stats.FormatDuration(i.timeToLevel) or "?"
    return string.format(ns.L["%s XP/h  ·  level in %s  ·  %d kills"], ns.Short(i.xpPerHour), ttl, i.kills)
end
