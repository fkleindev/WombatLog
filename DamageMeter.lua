local ADDON, ns = ...

-- Blizzard's own damage meter (C_DamageMeter, Midnight/Forever). Since the Forever
-- release UNIT_COMBAT amounts are secret, so the addon can't add up its own totals;
-- the meter's current session still has your damage, healing and damage taken.
-- Its values can be secret in combat as well: they're only ever drawn (SetAmountText),
-- and stored or compared only when readable.
local DamageMeter = {}
ns.DamageMeter = DamageMeter

local function available()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum
        and Enum.DamageMeterSessionType and Enum.DamageMeterType) then
        return false
    end
    if C_DamageMeter.IsDamageMeterAvailable then
        local ok, yes = pcall(C_DamageMeter.IsDamageMeterAvailable)
        if ok and ns.Safe(yes) == false then return false end
    end
    return true
end

-- kind: "DamageDone" | "HealingDone" | "DamageTaken"
-- Returns your total and per-second amount in the current session (either may be
-- secret), or nil when the meter isn't there or has no row for you.
function DamageMeter:Player(kind)
    if not available() then return nil end
    local typ = Enum.DamageMeterType[kind]
    if typ == nil then return nil end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, Enum.DamageMeterSessionType.Current, typ)
    if not ok or type(session) ~= "table" then return nil end
    -- the session is secret in combat; the amounts inside may be too, isLocalPlayer never is.
    -- Read it under pcall: whatever the client refuses simply means no numbers.
    local ok2, mine, total, perSecond = pcall(function()
        for _, src in ipairs(session.combatSources or {}) do
            if ns.Safe(src.isLocalPlayer) == true then
                return true, src.totalAmount, src.amountPerSecond
            end
        end
        return false
    end)
    if ok2 and mine == true then return total, perSecond end
    return nil
end

-- Readable numbers only (for the fight summary and history), else nil.
function DamageMeter:PlayerReadable(kind)
    local total, perSecond = self:Player(kind)
    return ns.Safe(total), ns.Safe(perSecond)
end
