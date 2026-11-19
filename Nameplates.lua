local ADDON, ns = ...
local NP = {}
ns.Nameplates = NP
local L = ns.L
local Safe, SafeTable, isSecret = ns.Safe, ns.SafeTable, ns.IsSecret

-- Nameplates of our own in WombatLog's look, in place of the game's: name, level,
-- the elite ornament, health, a cast bar under it, your auras on the unit (and
-- others you list), the raid icon, quest mobs marked, the target highlighted,
-- threat colors, an execute mark and the unit frames' animations.
--
-- The game's plate stays where and what it is (clicks, stacking, the distance
-- fade): its own content just turns invisible, and ours is hung on it. Plates the
-- game keeps from addons (friendly ones in dungeons and raids) stay the game's.
-- Values may be secret on Forever and Retail in combat: bars, texts and icons take
-- them straight from the API, whatever needs maths waits until they're readable.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GLOW = MEDIA .. "Glow"
local RAID_ICONS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local ORNAMENTS = { -- the unit frames' ornament styles, the left-pointing pictures
    wings = "Wings", dragon = "OrnamentDragon", laurel = "OrnamentLaurel",
    crown = "OrnamentCrown", flames = "OrnamentFlames", rays = "OrnamentRays",
}
local STYLE_KEYS = { elite = "eliteStyle", rare = "rareStyle", rareelite = "rareEliteStyle", boss = "bossStyle" }
local COLOR_KEYS = { elite = "eliteColor", rare = "rareColor", rareelite = "rareEliteColor", boss = "bossColor" }

local PAD = 1              -- px between the panel's border and the bar
local SHADOW = 10          -- px the shadow reaches past the panel
local TARGET_GLOW = 9      -- px the target's glow reaches past it
local LAG_HOLD, LAG_SPEED = 0.35, 3
local HEAL_FLASH = 0.5
local INTERRUPTED_HOLD = 0.6
local AURA_EVERY = 0.1     -- s between two aura timer refreshes

local GREY = { 0.5, 0.5, 0.5 }
local TAPPED = { 0.55, 0.55, 0.55 }
local LOW = { 1.00, 0.12, 0.10 }
local INTERRUPTED = { 0.85, 0.15, 0.15 }

local function cfg() return ns.db.nameplates end

local function call(fn, ...)
    if not fn then return nil end
    local ok, a = pcall(fn, ...)
    if not ok then return nil end
    return Safe(a)
end

local function tint(t, c, a) t:SetVertexColor(c[1], c[2], c[3], a or 1) end
local function tintAll(list, c, a) for _, t in ipairs(list) do tint(t, c, a) end end
local function lerp(a, b, t) return a + (b - a) * t end

---------------------------------------------------------------------------
-- The game's plates
---------------------------------------------------------------------------

local function baseOf(unit)
    local base = C_NamePlate and C_NamePlate.GetNamePlateForUnit and call(C_NamePlate.GetNamePlateForUnit, unit)
    if not base then return nil end
    local ok, forbidden = pcall(base.IsForbidden, base)
    if not ok or forbidden then return nil end
    return base
end

-- The game's own content of a plate goes invisible while ours shows; Blizzard sets
-- its alpha now and then, it goes back to 0 right after.
local function hideGame(base)
    local uf = base.UnitFrame
    if not uf or uf.wlHidden then return end
    local ok, forbidden = pcall(uf.IsForbidden, uf)
    if not ok or forbidden then return end
    uf.wlHidden = true
    uf:SetAlpha(0)
    if not uf.wlHook then
        uf.wlHook = true
        hooksecurefunc(uf, "SetAlpha", function(self, a)
            if self.wlHidden and a ~= 0 then self:SetAlpha(0) end
        end)
    end
end

local function showGame(base)
    local uf = base and base.UnitFrame
    if not uf or not uf.wlHidden then return end
    uf.wlHidden = nil
    uf:SetAlpha(1)
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------

-- "hostile", "friendly" or nil (none of ours: you, objects, sides turned off)
local function sideOf(unit)
    local C = cfg()
    if call(UnitIsUnit, unit, "player") then return nil end
    if UnitIsGameObject and call(UnitIsGameObject, unit) then return nil end
    -- the other faction counts as hostile even while you can't attack it (yellow,
    -- orange when flagged), like the game's enemy plates
    if call(UnitCanAttack, "player", unit) or (UnitIsEnemy and call(UnitIsEnemy, "player", unit)) then
        return C.hostile and "hostile" or nil
    end
    return C.friendly and "friendly" or nil
end

-- Whether unit is a player on your side (not the other faction, not a duel foe).
local function alliedPlayer(unit)
    if not call(UnitIsPlayer, unit) or call(UnitCanAttack, "player", unit) then return false end
    if UnitIsFriend then return call(UnitIsFriend, "player", unit) and true or false end
    return true
end

local function dead(unit)
    return call(UnitIsDeadOrGhost, unit) or (UnitIsConnected and call(UnitIsConnected, unit) == false)
end

-- elite, rare, rareelite, boss or nil
local function classification(unit)
    if UnitIsBossMob and call(UnitIsBossMob, unit) then return "boss" end
    local c = call(UnitClassification, unit)
    if c == "worldboss" then return "boss" end
    if c == "elite" or c == "rare" or c == "rareelite" then return c end
end

local function levelColor(level)
    local get = GetCreatureDifficultyColor or GetQuestDifficultyColor
    local c = level and level > 0 and get and get(level)
    if c and c.r then return c.r, c.g, c.b end
    return 1, 0.82, 0
end

local function classColor(unit)
    if not call(UnitIsPlayer, unit) then return nil end
    local _, class = UnitClass(unit)
    class = Safe(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and { c.r, c.g, c.b } or nil
end

-- Your party (or raid) and other allied players get colors of their own, like the
-- game's plates: green for the party, blue for everyone else on your side.
local function inGroup(unit)
    return (UnitInParty and call(UnitInParty, unit)) or (UnitInRaid and call(UnitInRaid, unit) ~= nil) or false
end

local function reactionColor(unit)
    if alliedPlayer(unit) then
        local C = cfg()
        return inGroup(unit) and C.partyColor or C.friendlyPlayerColor
    end
    if UnitSelectionColor and call(UnitIsPlayer, unit) then
        -- the other faction: yellow, orange when flagged for PvP, red when attackable
        local ok, r, g, b = pcall(UnitSelectionColor, unit, true)
        r, g, b = ok and Safe(r), ok and Safe(g), ok and Safe(b)
        if r and g and b then return { r, g, b } end
    end
    local r = call(UnitReaction, unit, "player")
    local c = r and FACTION_BAR_COLORS and FACTION_BAR_COLORS[r]
    if c then return { c.r, c.g, c.b } end
    if call(UnitCanAttack, "player", unit) then return { 0.85, 0.20, 0.15 } end
    if UnitIsEnemy and call(UnitIsEnemy, "player", unit) then return { 1, 0.85, 0.1 } end
    return { 0.20, 0.75, 0.30 }
end

-- Whether you're the tank (for the threat colors).
local function isTank()
    local role = cfg().threatRole
    if role ~= "auto" then return role == "tank" end
    local r = UnitGroupRolesAssigned and call(UnitGroupRolesAssigned, "player")
    if r == "TANK" then return true end
    if r and r ~= "NONE" then return false end
    if GetSpecialization and GetSpecializationRole then
        local spec = call(GetSpecialization)
        if spec then return call(GetSpecializationRole, spec) == "TANK" end
    end
    return false
end

-- The threat color for unit, or nil (not fighting you, or the color stays normal).
local function threatColor(unit)
    local C = cfg()
    if not C.threat or call(UnitIsPlayer, unit) or not call(UnitAffectingCombat, unit) then return nil end
    local s = call(UnitThreatSituation, "player", unit)
    if s == nil then return nil end
    if isTank() then
        if s == 3 then return C.threatSafe end
        if s == 2 then return C.threatWarn end
        return C.threatDanger
    end
    if s == 3 then return C.threatDanger end
    if s >= 1 then return C.threatWarn end
    return nil
end

---------------------------------------------------------------------------
-- Our plates
---------------------------------------------------------------------------

local plates = {} -- unit -> our plate shown for it
local pool = {}   -- the game's plate -> our plate (one each, kept)

local function statusBar(parent, level)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetFrameLevel(level)
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    return b
end

local function text(parent, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    return fs
end

-- A panel of the look: shadow, border (strips and corners) and background.
local function newPanel(parent, level)
    local B = ns.BlizzardUI
    local f = CreateFrame("Frame", nil, parent)
    f:SetFrameLevel(level)
    f.shadow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.shadow:SetTexture(GLOW)
    f.edge = { strips = B.NewStrips(f, "BACKGROUND", -6), corners = B.NewRoundRect(f, "BACKGROUND", -6) }
    f.bg = B.NewRoundRect(f, "BACKGROUND", -4)
    return f
end

local function layoutPanel(f)
    local C, B = cfg(), ns.BlizzardUI
    local b = C.border and C.borderSize or 0
    local r = C.radius > 0 and math.max(C.radius, b) or 0
    B.LayoutStrips(f.edge.strips, f, b, r)
    B.LayoutRoundRect(f.edge.corners, f, 0, r)
    for i = 1, 3 do f.edge.corners[i]:Hide() end
    for _, t in ipairs(f.edge.strips) do t:SetShown(b > 0) end
    for i = 4, 7 do f.edge.corners[i]:SetShown(b > 0 and r > 0) end
    local parts = {}
    for _, t in ipairs(f.edge.strips) do parts[#parts + 1] = t end
    for i = 4, 7 do parts[#parts + 1] = f.edge.corners[i] end
    tintAll(parts, C.borderColor, C.borderOpacity)
    B.LayoutRoundRect(f.bg, f, b, math.max(0, r - b))
    tintAll(f.bg, C.bgColor, C.bgOpacity)
    f.shadow:ClearAllPoints()
    f.shadow:SetPoint("TOPLEFT", f, "TOPLEFT", -SHADOW, SHADOW)
    f.shadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", SHADOW, -SHADOW)
    f.shadow:SetShown(C.shadow)
    tint(f.shadow, { 0, 0, 0 }, C.shadowOpacity)
    return b
end

local function newAura(p)
    local a = CreateFrame("Frame", nil, p)
    a:SetFrameLevel(p:GetFrameLevel() + 8)
    a.border = a:CreateTexture(nil, "BACKGROUND")
    a.border:SetAllPoints()
    a.border:SetColorTexture(0, 0, 0, 1)
    a.icon = a:CreateTexture(nil, "ARTWORK")
    a.icon:SetPoint("TOPLEFT", 1, -1)
    a.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    a.cd = CreateFrame("Cooldown", nil, a, "CooldownFrameTemplate")
    a.cd:SetAllPoints(a.icon)
    a.cd:SetReverse(true)
    a.cd:SetDrawEdge(false)
    pcall(a.cd.SetHideCountdownNumbers, a.cd, true)
    local top = CreateFrame("Frame", nil, a)
    top:SetAllPoints()
    top:SetFrameLevel(a.cd:GetFrameLevel() + 1)
    a.count = text(top, "RIGHT")
    a.count:SetPoint("BOTTOMRIGHT", 1, -1)
    a.time = text(top, "CENTER")
    a.time:SetPoint("CENTER", a, "TOP", 0, 0)
    return a
end

local function create(base)
    local p = CreateFrame("Frame", nil, base)
    p:SetPoint("CENTER", base, "CENTER", 0, 0)
    p.base = base
    local lv = p:GetFrameLevel()

    p.glow = p:CreateTexture(nil, "BACKGROUND", nil, -8) -- the target
    p.glow:SetTexture(GLOW)
    p.glow:SetBlendMode("ADD")
    p.low = p:CreateTexture(nil, "BACKGROUND", nil, -7)  -- low health
    p.low:SetTexture(GLOW)
    p.low:SetBlendMode("ADD")
    p.low:SetAlpha(0)
    p.wings = p:CreateTexture(nil, "BACKGROUND", nil, -6) -- the elite ornament
    p.wings:Hide()

    p.panel = newPanel(p, lv + 1)
    p.lag = statusBar(p, lv + 2)
    p.lag:SetStatusBarTexture(WHITE)
    p.lagBg = p.lag:CreateTexture(nil, "BACKGROUND")
    p.lagBg:SetAllPoints()
    p.hp = statusBar(p, lv + 3)
    p.heal = p.hp:CreateTexture(nil, "OVERLAY")
    p.heal:SetTexture(WHITE)
    p.heal:SetBlendMode("ADD")
    p.heal:SetAlpha(0)
    p.exec = p.hp:CreateTexture(nil, "OVERLAY", nil, 2)
    p.exec:SetTexture(WHITE)

    p.top = CreateFrame("Frame", nil, p)
    p.top:SetFrameLevel(lv + 6)
    p.top:SetAllPoints()
    p.name = text(p.top, "CENTER")
    p.level = text(p.top, "RIGHT")
    p.hpText = text(p.top, "RIGHT")
    p.raid = p.top:CreateTexture(nil, "OVERLAY")
    p.raid:SetTexture(RAID_ICONS)
    p.raid:Hide()
    p.quest = p.top:CreateTexture(nil, "OVERLAY")
    p.quest:SetTexture(QUEST_ICON)
    p.quest:Hide()

    -- the cast bar, with a panel and an icon of its own
    p.castPanel = newPanel(p, lv + 1)
    p.cast = statusBar(p, lv + 3)
    p.castIcon = p.top:CreateTexture(nil, "ARTWORK")
    p.castIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    p.castIconEdge = p:CreateTexture(nil, "BORDER")
    p.castIconEdge:SetColorTexture(0, 0, 0, 1)
    p.castName = text(p.top, "LEFT")
    p.castTime = text(p.top, "RIGHT")

    p.auras = {}
    p:SetScript("OnUpdate", NP.OnUpdate)
    p:Hide()
    return p
end

-- Sizes and places everything from the settings; nameOnly: just the name (allies).
local function layout(p)
    local C, A = cfg(), ns.db.appearance
    local nameOnly = p.nameOnly
    local W = C.width
    local b = layoutPanel(p.panel)
    local Hp = b * 2 + PAD * 2 + C.healthHeight
    p.W, p.Hp = W, Hp
    p:SetSize(W, Hp)

    p.panel:ClearAllPoints()
    p.panel:SetAllPoints(p)
    p.panel:SetShown(not nameOnly)
    local tex = ns.BarTexture(C.texture)
    for _, bar in ipairs({ p.hp, p.lag }) do
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", p, "TOPLEFT", b + PAD, -(b + PAD))
        bar:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -(b + PAD), b + PAD)
        bar:SetStatusBarTexture(tex)
        bar:SetShown(not nameOnly)
    end
    p.lagBg:SetTexture(tex)
    p.lagBg:SetVertexColor(0, 0, 0, 0.5)

    -- the execute mark: a thin line where the range begins
    local barW = W - 2 * (b + PAD)
    p.exec:ClearAllPoints()
    p.exec:SetPoint("TOP", p.hp, "TOPLEFT", math.floor(barW * C.executeAt + 0.5), 0)
    p.exec:SetPoint("BOTTOM", p.hp, "BOTTOMLEFT", math.floor(barW * C.executeAt + 0.5), 0)
    p.exec:SetWidth(1)
    p.exec:SetVertexColor(1, 1, 1, 0.85)

    -- glows around the panel
    for _, g in ipairs({ p.glow, p.low }) do
        g:ClearAllPoints()
        g:SetPoint("TOPLEFT", p, "TOPLEFT", -TARGET_GLOW, TARGET_GLOW)
        g:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", TARGET_GLOW, -TARGET_GLOW)
    end
    tint(p.glow, C.targetGlowColor, 0.9)
    tint(p.low, LOW, 1)
    p.low:SetAlpha(0)

    -- the ornament at the panel's left end
    local s = math.floor(Hp * 2.6)
    p.wings:ClearAllPoints()
    p.wings:SetSize(s, s)
    p.wings:SetPoint("CENTER", p, "LEFT", 0, 0)

    -- texts: the name above (or in the bar), the level in front of it, health on the right
    local size = C.textSize
    ns.SetFont(p.name, A.nameFont, nameOnly and size + 1 or size, "OUTLINE")
    ns.SetFont(p.level, A.amountFont, math.max(7, size - 1), "OUTLINE")
    ns.SetFont(p.hpText, A.amountFont, math.max(7, size - 1), "OUTLINE")
    ns.SetFont(p.castName, A.nameFont, math.max(7, size - 1), "OUTLINE")
    ns.SetFont(p.castTime, A.amountFont, math.max(7, size - 1), "OUTLINE")
    p.name:ClearAllPoints()
    p.level:ClearAllPoints()
    local inBar = C.nameInBar and not nameOnly
    if inBar then
        p.name:SetJustifyH("LEFT")
        p.level:SetPoint("LEFT", p.hp, "LEFT", 3, 0)
        p.name:SetPoint("LEFT", p.level, "RIGHT", 3, 0)
        p.name:SetWidth(W * 0.62)
    else
        p.name:SetJustifyH("CENTER")
        if nameOnly then
            p.name:SetPoint("CENTER", p, "CENTER", 0, 0)
        else
            p.name:SetPoint("BOTTOM", p, "TOP", 0, 3)
        end
        p.name:SetWidth(W)
        p.level:SetPoint("RIGHT", p.name, "LEFT", -2, 0)
    end
    p.nameInBar = inBar
    p.hpText:ClearAllPoints()
    p.hpText:SetPoint("RIGHT", p.hp, "RIGHT", -3, 0)
    p.hpText:SetShown(not nameOnly and C.healthText ~= "none")

    local icon = math.max(12, Hp + 6)
    p.raid:ClearAllPoints()
    p.raid:SetSize(icon, icon)
    p.raid:SetPoint("LEFT", p, "RIGHT", 4, 0)
    p.quest:ClearAllPoints()
    p.quest:SetSize(icon * 0.9, icon * 0.9)
    if inBar or nameOnly or not C.name then
        p.quest:SetPoint("BOTTOMLEFT", p, "TOPRIGHT", -2, 0)
    else
        p.quest:SetPoint("LEFT", p.name, "CENTER", 0, 0) -- moved to the name's end on update
    end

    -- the cast bar under the panel
    local cb = layoutPanel(p.castPanel)
    local Hc = cb * 2 + PAD * 2 + C.castHeight
    p.castPanel:ClearAllPoints()
    p.castPanel:SetPoint("TOPLEFT", p, "BOTTOMLEFT", 0, -2)
    p.castPanel:SetSize(W, Hc)
    p.cast:ClearAllPoints()
    p.cast:SetPoint("TOPLEFT", p.castPanel, "TOPLEFT", cb + PAD, -(cb + PAD))
    p.cast:SetPoint("BOTTOMRIGHT", p.castPanel, "BOTTOMRIGHT", -(cb + PAD), cb + PAD)
    p.cast:SetStatusBarTexture(tex)
    p.castIconEdge:ClearAllPoints()
    p.castIconEdge:SetSize(Hc, Hc)
    p.castIconEdge:SetPoint("RIGHT", p.castPanel, "LEFT", -2, 0)
    p.castIcon:ClearAllPoints()
    p.castIcon:SetPoint("TOPLEFT", p.castIconEdge, "TOPLEFT", 1, -1)
    p.castIcon:SetPoint("BOTTOMRIGHT", p.castIconEdge, "BOTTOMRIGHT", -1, 1)
    p.castName:ClearAllPoints()
    p.castName:SetPoint("LEFT", p.cast, "LEFT", 3, 0)
    p.castName:SetWidth(W * 0.7)
    p.castTime:ClearAllPoints()
    p.castTime:SetPoint("RIGHT", p.cast, "RIGHT", -3, 0)

    for _, a in ipairs(p.auras) do
        a:SetSize(C.auraSize, math.floor(C.auraSize * 0.8))
        ns.SetFont(a.count, A.amountFont, math.max(7, math.floor(C.auraSize * 0.45)), "OUTLINE")
        ns.SetFont(a.time, A.amountFont, math.max(7, math.floor(C.auraSize * 0.45)), "OUTLINE")
    end
    p.layoutVersion = NP.version
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

function NP:UpdateHealth(p, animate)
    local unit, C = p.unit, cfg()
    local A = C.anim
    if p.nameOnly then return end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    ns.Resources.SetBar(p.hp, cur, max, A.smooth)
    p.lag:SetMinMaxValues(0, max or 1)
    local plain = not isSecret(cur) and not isSecret(max) and cur ~= nil and max ~= nil
    if plain and animate and A.damage and p.lagValue and cur < p.lagValue then
        if not p.lagHold then p.lagHold = LAG_HOLD end
    else
        p.lagValue, p.lagHold = plain and cur or nil, nil
        p.lag:SetValue(cur or 0)
    end
    if plain and animate and A.heal and p.lastHP and cur > p.lastHP and max > 0 then
        p.healFrom, p.healTo, p.healMax, p.healT = p.lastHP, cur, max, 0
    end
    p.lastHP = plain and cur or nil
    p.frac = plain and max > 0 and cur / max or nil

    -- color: dead or tapped, threat, execute, then the chosen kind
    local c
    if dead(unit) then
        c = GREY
    elseif UnitIsTapDenied and call(UnitIsTapDenied, unit) then
        c = TAPPED
    else
        c = p.hostile and threatColor(unit)
        if not c and p.hostile and C.execute and p.frac and p.frac > 0 and p.frac <= C.executeAt then
            c = C.executeColor
        end
        if not c then
            if C.healthColor == "custom" then
                c = C.customColor
            elseif C.healthColor == "class" then
                c = classColor(unit) or reactionColor(unit)
            else
                c = reactionColor(unit)
            end
        end
    end
    p.hp:SetStatusBarColor(c[1], c[2], c[3], 1)
    p.lag:SetStatusBarColor(lerp(c[1], 1, 0.75), lerp(c[2], 0.9, 0.6), lerp(c[3], 0.8, 0.6), 0.9)
    p.exec:SetShown(p.hostile and C.execute and true or false)

    if p.hpText:IsShown() then
        if dead(unit) then
            p.hpText:SetText(UnitIsConnected and call(UnitIsConnected, unit) == false and L["Offline"] or L["Dead"])
        else
            ns.Resources.SetText(p.hpText, C.healthText, cur, max, true, unit)
        end
    end
    p.lowOn = A.lowHealth and p.frac and p.frac > 0 and p.frac <= A.lowAt and not dead(unit) or false
end

function NP:UpdateName(p)
    local unit, C = p.unit, cfg()
    if C.name or p.nameOnly then
        if not pcall(p.name.SetText, p.name, ns.UnitDisplayName(unit)) then p.name:SetText("") end
    else
        p.name:SetText("")
    end
    local c
    if C.nameColor == "class" then
        c = classColor(unit) or reactionColor(unit)
    elseif C.nameColor == "reaction" then
        c = reactionColor(unit)
    else
        c = { 1, 1, 1 }
    end
    p.name:SetTextColor(c[1], c[2], c[3])

    local level = C.level and not p.nameOnly and call(UnitLevel, unit)
    if level and level < 0 then
        p.level:SetText("??")
        p.level:SetTextColor(1, 0.2, 0.1)
    elseif level and level > 0 then
        p.level:SetText(level)
        p.level:SetTextColor(levelColor(level))
    else
        p.level:SetText("")
    end
    -- without a level the name starts where it would
    if p.nameInBar then
        p.name:ClearAllPoints()
        if p.level:GetText() ~= "" then
            p.name:SetPoint("LEFT", p.level, "RIGHT", 3, 0)
        else
            p.name:SetPoint("LEFT", p.hp, "LEFT", 3, 0)
        end
    end
end

function NP:UpdateClass(p)
    local C = cfg()
    local cls = C.ornament and not p.nameOnly and classification(p.unit)
    p.wings:SetShown(cls and true or false)
    if not cls then return end
    local E = ns.db.blizzard.unitFrames.elite
    local style = ORNAMENTS[E[STYLE_KEYS[cls]]] or ORNAMENTS.wings
    p.wings:SetTexture(MEDIA .. style .. "Left")
    tint(p.wings, E[COLOR_KEYS[cls]] or E.eliteColor, 1)
end

function NP:UpdateRaid(p)
    local i = cfg().raidIcon and call(GetRaidTargetIndex, p.unit)
    if i and SetRaidTargetIconTexture then
        SetRaidTargetIconTexture(p.raid, i)
        p.raid:Show()
    else
        p.raid:Hide()
    end
end

function NP:UpdateQuest(p)
    -- creatures only: players and what they control never need killing for a quest
    local unit = p.unit
    local player = call(UnitIsPlayer, unit) or (UnitPlayerControlled and call(UnitPlayerControlled, unit))
    local on = cfg().quest and not player and not dead(unit) and ns.UnitForQuest and ns.UnitForQuest(unit)
    p.quest:SetShown(on and true or false)
    if on and not (p.nameInBar or p.nameOnly or not cfg().name) then
        -- at the end of the name
        local w = p.name:GetStringWidth()
        w = (w and not isSecret(w)) and math.min(w, p.W) or p.W * 0.5
        p.quest:ClearAllPoints()
        p.quest:SetPoint("LEFT", p.name, "CENTER", w / 2 + 2, 0)
    end
end

function NP:UpdateTarget(p)
    local C = cfg()
    local is = call(UnitIsUnit, p.unit, "target") and true or false
    p.isTarget = is
    p.glow:SetShown(is and C.targetGlow and not p.nameOnly)
    p:SetScale(is and C.targetScale or 1)
end

---------------------------------------------------------------------------
-- Auras: yours on the unit (debuffs on enemies, buffs on allies), plus others
-- you list; listed ones can also be left out
--
-- Each plate keeps its unit's auras by instance ID. They're read from the unit
-- where the client lets us (always on Classic, out of combat on Forever and
-- Retail); where it refuses (other units' auras in combat on Forever), they're
-- kept up from what UNIT_AURA hands over: added, updated and removed auras.
-- Whose an aura is and whether it's a debuff, the client can tell us through
-- its filters when the values themselves are secret.
---------------------------------------------------------------------------

local always, never = {}, {} -- spell ID or lower-case name -> true

local function buildList(src)
    local t = {}
    for _, e in ipairs(src or {}) do
        local id = tonumber(e)
        if id then t[id] = true else t[strtrim(tostring(e)):lower()] = true end
    end
    return t
end

local function listed(set, e)
    return (e.spell and set[e.spell]) or (e.name and set[e.name:lower()]) or false
end

-- Whether the aura with this instance ID passes filter ("PLAYER", "HARMFUL"),
-- asked of the client; nil when it can't tell.
local function passes(unit, id, filter)
    local CU = C_UnitAuras
    if not (CU and CU.IsAuraFilteredOutByInstanceID) then return nil end
    local ok, out = pcall(CU.IsAuraFilteredOutByInstanceID, unit, id, filter)
    out = ok and Safe(out)
    if out == nil then return nil end
    return not out
end

-- An entry from an aura table (a query's or UNIT_AURA's); nil when unreadable.
-- harmful, mine: known from the query's filter, else from the aura or the client.
-- (The aura's isFromPlayerOrPlayerPet is any player's, not only yours.)
local function entryOf(unit, d, harmful, mine)
    d = SafeTable(d)
    if not d then return nil end
    local id = Safe(d.auraInstanceID)
    if not id then return nil end
    if harmful == nil then
        harmful = Safe(d.isHarmful)
        if harmful == nil then
            local helpful = Safe(d.isHelpful)
            if helpful ~= nil then harmful = not helpful else harmful = passes(unit, id, "HARMFUL") end
        end
    end
    if mine == nil then
        local src = Safe(d.sourceUnit)
        if src then mine = src == "player" or src == "pet" or src == "vehicle" end
    end
    if mine == nil then mine = passes(unit, id, harmful and "HARMFUL|PLAYER" or "HELPFUL|PLAYER") end
    local count = Safe(d.applications)
    local countText
    if count == nil and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
        -- secret stacks: the client writes them (empty below 2)
        local ok, s = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, id, 2)
        if ok then countText = s end
    end
    return {
        id = id, icon = d.icon, count = count, countText = countText,
        duration = Safe(d.duration), expires = Safe(d.expirationTime),
        spell = Safe(d.spellId), name = Safe(d.name), mine = mine, harmful = harmful,
    }
end

-- Reads the unit's auras afresh; false when the client refuses (the cache stays).
local function scanAuras(p)
    local unit, old, fresh = p.unit, p.auraCache or {}, {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        -- yours first (the client's PLAYER filter tells), then everyone's
        local yours = {}
        for _, kind in ipairs({ "HARMFUL|PLAYER", "HELPFUL|PLAYER", "HARMFUL", "HELPFUL" }) do
            local own = kind:find("PLAYER", 1, true) ~= nil
            for i = 1, 40 do
                local ok, d = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, kind)
                if not ok then
                    p.auraScan = "refused"
                    return false
                end
                if not d then break end
                local t = SafeTable(d)
                local id = t and Safe(t.auraInstanceID)
                if id then
                    if own then
                        yours[id] = true
                    else
                        local e = entryOf(unit, d, kind == "HARMFUL", yours[id] or false)
                        if e then fresh[e.id] = e end
                    end
                end
            end
        end
    elseif UnitAura then
        -- older clients: no instance IDs, the index stands in
        for _, kind in ipairs({ "HARMFUL", "HELPFUL" }) do
            for i = 1, 40 do
                local ok, name, icon, count, _, duration, expires, src, _, _, spell = pcall(UnitAura, unit, i, kind)
                if not ok then
                    p.auraScan = "refused"
                    return false
                end
                if name == nil then break end
                src = Safe(src)
                local key = kind .. i .. ":" .. tostring(Safe(spell) or Safe(name))
                fresh[key] = {
                    id = key, icon = icon, count = Safe(count), duration = Safe(duration), expires = Safe(expires),
                    spell = Safe(spell), name = Safe(name), harmful = kind == "HARMFUL",
                    mine = src == "player" or src == "pet" or src == "vehicle",
                }
            end
        end
    else
        return false
    end
    -- the ones known already keep their place in the row
    for id, e in pairs(fresh) do
        if old[id] then
            e.seq = old[id].seq
        else
            p.auraSeq = (p.auraSeq or 0) + 1
            e.seq = p.auraSeq
        end
    end
    p.auraCache = fresh
    p.auraScan = "ok"
    return true
end

-- What UNIT_AURA hands over, for when the auras can't be read.
local function applyAuraInfo(p, info)
    local unit, cache = p.unit, p.auraCache
    for _, d in ipairs(SafeTable(info.addedAuras) or {}) do
        local e = entryOf(unit, d)
        if e then
            p.auraSeq = (p.auraSeq or 0) + 1
            e.seq = p.auraSeq
            cache[e.id] = e
            p.auraAdded = (p.auraAdded or 0) + 1
        end
    end
    for _, id in ipairs(SafeTable(info.updatedAuraInstanceIDs) or {}) do
        id = Safe(id)
        local old = id and cache[id]
        if old then
            local e
            if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local ok, d = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
                e = ok and entryOf(unit, d, old.harmful)
            end
            if e then
                e.seq = old.seq
                if e.mine == nil then e.mine = old.mine end
                cache[id] = e
            elseif old.duration and old.duration > 0 then
                -- re-applied: its time starts over
                old.expires = GetTime() + old.duration
            end
        end
    end
    for _, id in ipairs(SafeTable(info.removedAuraInstanceIDs) or {}) do
        id = Safe(id)
        if id then cache[id] = nil end
    end
end

local function auraTime(left)
    if left >= 3600 then return math.floor(left / 3600 + 0.5) .. "h" end
    if left >= 60 then return math.floor(left / 60 + 0.5) .. "m" end
    if left >= 10 then return tostring(math.floor(left + 0.5)) end
    return string.format("%.1f", left)
end

-- Shows what the cache holds for this kind of plate.
function NP:ShowAuras(p)
    local C = cfg()
    local list = {}
    if C.auras and not p.nameOnly and not p.gameAuras then
        -- everyone's, where that's set for this side; else yours and the listed ones
        local all = (p.hostile and C.auraAllHostile) or (not p.hostile and C.auraAllFriendly)
        for _, e in pairs(p.auraCache or {}) do
            if e.harmful == p.hostile and not listed(never, e) and (all or e.mine or listed(always, e)) then
                list[#list + 1] = e
            end
        end
        table.sort(list, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
    end
    local n = math.min(#list, C.maxAuras)
    local unit = p.unit
    for i = 1, n do
        local e, b = list[i], p.auras[i]
        if not b then
            b = newAura(p)
            p.auras[i] = b
            b:SetSize(C.auraSize, math.floor(C.auraSize * 0.8))
            local A = ns.db.appearance
            ns.SetFont(b.count, A.amountFont, math.max(7, math.floor(C.auraSize * 0.45)), "OUTLINE")
            ns.SetFont(b.time, A.amountFont, math.max(7, math.floor(C.auraSize * 0.45)), "OUTLINE")
        end
        pcall(b.icon.SetTexture, b.icon, e.icon)
        b.icon:SetTexCoord(0.08, 0.92, 0.18, 0.82)
        if e.count then
            b.count:SetText(e.count > 1 and e.count or "")
        elseif not (e.countText and pcall(b.count.SetText, b.count, e.countText)) then
            b.count:SetText("")
        end
        b.expires = nil
        if e.duration and e.expires and e.duration > 0 and e.expires > 0 then
            b.cd:SetCooldown(e.expires - e.duration, e.duration)
            b.expires = e.expires
        elseif type(e.id) == "number" and C_UnitAuras and C_UnitAuras.GetAuraDuration and b.cd.SetCooldownFromDurationObject then
            -- secret times: the client draws the spiral itself
            local ok, d = pcall(C_UnitAuras.GetAuraDuration, unit, e.id)
            if not (ok and d and pcall(b.cd.SetCooldownFromDurationObject, b.cd, d)) then b.cd:Clear() end
        else
            b.cd:Clear()
        end
        b.time:SetText("")
        b:Show()
    end
    for i = n + 1, #p.auras do p.auras[i]:Hide() end
    -- a row centered above the name (or the panel)
    local gap, w = 2, C.auraSize
    local x0 = -((n * w) + (n - 1) * gap) / 2
    local anchor, y = p, 3
    if C.name and not p.nameInBar then anchor, y = p.name, 2 end
    for i = 1, n do
        local b = p.auras[i]
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", anchor, "TOP", x0 + (i - 1) * (w + gap), y)
    end
    p.auraCount = n
    self:UpdateAuraTimes(p)
end

---------------------------------------------------------------------------
-- The game's aura row: where the client keeps auras from addons (other units'
-- in combat on Forever and Retail), the game's own plate still shows them. Its
-- aura row is borrowed then: moved from the invisible plate onto ours.
---------------------------------------------------------------------------

local AURA_KEYS = { "AurasFrame", "BuffFrame", "AuraFrame", "DebuffFrame" }
local borrowed = {} -- the game's aura row -> { parent, p = our plate showing it }
local placing = false

-- The game's aura row on base's plate, or nil.
local function gameAuraRow(base)
    local uf = base.UnitFrame
    if not uf then return nil end
    for _, k in ipairs(AURA_KEYS) do
        local f = uf[k]
        if type(f) == "table" and f.SetParent and f.GetObjectType then return f end
    end
end

local function placeRow(f)
    local b = borrowed[f]
    local p = b and b.p
    if not p or placing then return end
    placing = true
    local C = cfg()
    local anchor, y = p, 3
    if C.name and not p.nameInBar then anchor, y = p.name, 2 end
    f:ClearAllPoints()
    f:SetPoint("BOTTOM", anchor, "TOP", 0, y)
    placing = false
end

local function borrowRow(p)
    local f = gameAuraRow(p.base)
    if not f then return false end
    local b = borrowed[f]
    if not b then
        -- (where it sat can't be read: the game keeps its plate's regions from
        -- being measured; it places the row again itself when it gets it back)
        b = { parent = p.base.UnitFrame }
        borrowed[f] = b
        -- the game places its row again now and then: it comes back to ours
        hooksecurefunc(f, "SetPoint", function(self) placeRow(self) end)
    end
    b.p = p
    p.gameRow = f
    f:SetParent(p)
    f:SetFrameLevel(p:GetFrameLevel() + 8)
    placeRow(f)
    return true
end

local function returnRow(p)
    local f = p.gameRow
    local b = f and borrowed[f]
    p.gameRow = nil
    if not b or b.p ~= p then return end
    b.p = nil
    placing = true
    f:SetParent(b.parent)
    f:ClearAllPoints()
    pcall(f.SetPoint, f, "BOTTOM", b.parent, "CENTER", 0, 12)
    placing = false
end

-- Whether the game draws this plate's auras: chosen, or (automatic) on clients
-- that keep other units' auras from addons.
local function gameDrawsAuras()
    local src = cfg().auraSource
    if src == "auto" then return issecretvalue ~= nil end
    return src == "game"
end

-- info: UNIT_AURA's payload, nil for a fresh look (a new plate, settings).
function NP:UpdateAuras(p, info)
    local C = cfg()
    local game = false
    if C.auras and not p.nameOnly and gameDrawsAuras() then
        local ok, res = pcall(borrowRow, p)
        game = ok and res or false
        if ok then p.rowError = nil end
        if not ok then
            p.rowError = tostring(res)
            pcall(returnRow, p)
        end
    end
    p.gameAuras = game or nil
    if not game and p.gameRow then returnRow(p) end
    if not C.auras or p.nameOnly or game then
        self:ShowAuras(p)
        return
    end
    if not scanAuras(p) then
        info = SafeTable(info)
        if info and not Safe(info.isFullUpdate) then applyAuraInfo(p, info) end
    end
    self:ShowAuras(p)
end

function NP:UpdateAuraTimes(p)
    local show, now = cfg().auraTimer, GetTime()
    for i = 1, p.auraCount or 0 do
        local b = p.auras[i]
        if show and b.expires then
            local left = b.expires - now
            b.time:SetText(left > 0 and auraTime(left) or "")
        else
            b.time:SetText("")
        end
    end
end

---------------------------------------------------------------------------
-- Cast bar
---------------------------------------------------------------------------

-- Whether v is there: a secret value is (and can't be compared with nil).
local function present(v)
    return isSecret(v) or v ~= nil
end

local function isCasting(unit)
    return present((UnitCastingInfo(unit))) or (UnitChannelInfo and present((UnitChannelInfo(unit)))) or false
end

local function castColor(p, locked)
    local C = cfg()
    local c = locked == true and C.castLockedColor or C.castColor
    p.cast:SetStatusBarColor(c[1], c[2], c[3], 1)
end

local function showCast(p, on)
    p.castPanel:SetShown(on)
    p.cast:SetShown(on)
    local C = cfg()
    p.castIcon:SetShown(on and C.castIcon)
    p.castIconEdge:SetShown(on and C.castIcon)
    p.castName:SetShown(on and C.castName)
    p.castTime:SetShown(on and C.castTime)
end

function NP:StopCast(p)
    p.casting, p.castHold = nil, nil
    showCast(p, false)
end

function NP:StartCast(p)
    local C, unit = cfg(), p.unit
    if not C.castbar or p.nameOnly then self:StopCast(p) return end
    local channel = false
    local name, _, icon, startMS, endMS, _, _, locked = UnitCastingInfo(unit)
    if not present(name) and UnitChannelInfo then
        name, _, icon, startMS, endMS, _, locked = UnitChannelInfo(unit)
        channel = true
    end
    if not present(name) then self:StopCast(p) return end
    local s, e = Safe(startMS), Safe(endMS)
    p.castTimer = nil
    if s and e and e > s then
        p.castStart, p.castEnd = s / 1000, e / 1000
    else
        -- secret times: the client can run the bar itself
        local get = channel and UnitChannelDuration or UnitCastingDuration
        local ok = get and p.cast.SetTimerDuration and pcall(function()
            p.cast:SetTimerDuration(get(unit), nil, channel and 1 or 0)
        end)
        if not ok then self:StopCast(p) return end
        p.castTimer = true
    end
    p.casting, p.channel, p.castHold = true, channel, nil
    castColor(p, Safe(locked))
    pcall(p.castIcon.SetTexture, p.castIcon, icon or 134400)
    if not pcall(p.castName.SetText, p.castName, name) then p.castName:SetText("") end
    p.castTime:SetText("")
    showCast(p, true)
end

function NP:InterruptCast(p)
    if not p.casting then return end
    p.casting, p.castTimer = nil, nil
    p.cast:SetMinMaxValues(0, 1)
    p.cast:SetValue(1)
    p.cast:SetStatusBarColor(INTERRUPTED[1], INTERRUPTED[2], INTERRUPTED[3], 1)
    p.castName:SetText(L["Interrupted"])
    p.castTime:SetText("")
    p.castHold = GetTime() + INTERRUPTED_HOLD
end

---------------------------------------------------------------------------
-- Animations
---------------------------------------------------------------------------

function NP.OnUpdate(p, dt)
    local now = GetTime()
    ns.Resources.GlideBar(p.hp, dt)

    if p.lagHold then
        p.lagHold = p.lagHold - dt
        if p.lagHold <= 0 and p.lagValue and p.lastHP then
            p.lagValue = p.lagValue + (p.lastHP - p.lagValue) * math.min(1, dt * LAG_SPEED * 2)
            if p.lagValue - p.lastHP < 0.5 then p.lagValue, p.lagHold = p.lastHP, nil end
        end
        if p.lagValue then p.lag:SetValue(p.lagValue) end
    end

    if p.healT then
        p.healT = p.healT + dt
        local f = p.healT / HEAL_FLASH
        if f >= 1 or not p.healMax or p.healMax <= 0 then
            p.healT = nil
            p.heal:SetAlpha(0)
        else
            local width = p.hp:GetWidth()
            local x0 = width * math.min(1, p.healFrom / p.healMax)
            local x1 = width * math.min(1, p.healTo / p.healMax)
            p.heal:ClearAllPoints()
            p.heal:SetPoint("TOPLEFT", p.hp, "TOPLEFT", x0, 0)
            p.heal:SetSize(math.max(1, x1 - x0), p.hp:GetHeight())
            p.heal:SetVertexColor(0.5, 1, 0.5, 1)
            p.heal:SetAlpha(0.8 * (1 - f) * (1 - f))
        end
    end

    p.low:SetAlpha(p.lowOn and (0.35 + 0.35 * math.abs(math.sin(now * 3))) or 0)

    if p.casting and not p.castTimer then
        local total = p.castEnd - p.castStart
        local f = total > 0 and math.min(1, math.max(0, (now - p.castStart) / total)) or 1
        if p.channel then f = 1 - f end
        p.cast:SetMinMaxValues(0, 1)
        p.cast:SetValue(f)
        if p.castTime:IsShown() then p.castTime:SetText(string.format("%.1f", math.max(0, p.castEnd - now))) end
        if now > p.castEnd + 0.3 then NP:StopCast(p) end -- a missing stop event
    elseif p.castHold and now >= p.castHold then
        NP:StopCast(p)
    end

    p.auraT = (p.auraT or 0) + dt
    if p.auraT >= AURA_EVERY then
        p.auraT = 0
        NP:UpdateAuraTimes(p)
    end
end

---------------------------------------------------------------------------
-- Plates coming and going
---------------------------------------------------------------------------

-- Runs a part of the update on its own, so one failing doesn't take the rest
-- with it; the first error of each part is told once in chat and kept for /wl debug.
local errors, reported = {}, {}
local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return true end
    errors[label] = tostring(err)
    if not reported[label] then
        reported[label] = true
        ns.Print("nameplates: " .. label .. " failed: " .. tostring(err))
    end
    return false
end
NP.Try = try

function NP:Update(p)
    try("name", self.UpdateName, self, p)
    try("ornament", self.UpdateClass, self, p)
    try("health", self.UpdateHealth, self, p, false)
    try("raid icon", self.UpdateRaid, self, p)
    try("target", self.UpdateTarget, self, p)
    try("auras", self.UpdateAuras, self, p)
    try("quest", self.UpdateQuest, self, p)
    try("cast bar", self.StartCast, self, p)
end

function NP:Added(unit)
    local base = baseOf(unit)
    local side = self.active and base and sideOf(unit)
    if not side then
        if base then showGame(base) end
        self:Removed(unit)
        return
    end
    local p = pool[base]
    if not p then
        p = create(base)
        pool[base] = p
    end
    -- the game hands a plate to another unit without removing it first now and then
    if p.unit and p.unit ~= unit then plates[p.unit] = nil end
    plates[unit] = p
    p.unit, p.hostile = unit, side == "hostile"
    local nameOnly = not p.hostile and cfg().friendlyNameOnly
    if p.nameOnly ~= nameOnly or p.layoutVersion ~= self.version then
        p.nameOnly = nameOnly
        layout(p)
    end
    p.lagValue, p.lastHP, p.lagHold, p.healT = nil, nil, nil, nil
    p.hp.snap = true
    p.auraCache, p.auraSeq, p.auraScan, p.auraAdded = {}, 0, nil, nil
    hideGame(base)
    p:Show()
    self:Update(p)
end

function NP:Removed(unit)
    local p = plates[unit]
    if not p then return end
    plates[unit] = nil
    p.unit = nil
    if p.gameRow then returnRow(p) end
    p.gameAuras = nil
    self:StopCast(p)
    p:Hide()
end

-- The health bar ours shows on base's plate, if ours is up (for the range indicator).
function NP.BarOf(base)
    local p = pool[base]
    return p and p.unit and p:IsShown() and not p.nameOnly and p.hp or nil
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

NP.version = 0
local savedSize -- the game's plate sizes before ours took them over
local pendingCVars = false

-- The game's plate size (click area, room when stacking) and stacking follow ours;
-- both can only change out of combat.
local function setGameOptions()
    if InCombatLockdown() then pendingCVars = true return end
    pendingCVars = false
    local C = cfg()
    local CN = C_NamePlate
    if NP.active then
        if C.motion ~= "game" then pcall(SetCVar, "nameplateMotion", C.motion == "stack" and 1 or 0) end
        if CN and CN.SetNamePlateEnemySize then
            if not savedSize then
                local ok, ew, eh = pcall(CN.GetNamePlateEnemySize)
                local ok2, fw, fh = pcall(CN.GetNamePlateFriendlySize)
                savedSize = { e = ok and Safe(ew) and { ew, eh } or nil, f = ok2 and Safe(fw) and { fw, fh } or nil }
            end
            local h = C.healthHeight + C.textSize + 10 + (C.castbar and C.castHeight + 4 or 0)
            local w = C.width + 10
            if C.hostile then pcall(CN.SetNamePlateEnemySize, w, h) end
            if C.friendly then pcall(CN.SetNamePlateFriendlySize, w, h) end
        end
    elseif savedSize and CN then
        if savedSize.e then pcall(CN.SetNamePlateEnemySize, savedSize.e[1], savedSize.e[2]) end
        if savedSize.f then pcall(CN.SetNamePlateFriendlySize, savedSize.f[1], savedSize.f[2]) end
        savedSize = nil
    end
end

function NP:Apply()
    if not (ns.db and self.ready) then return end
    local C = cfg()
    self.active = C.enabled and (C.hostile or C.friendly) and true or false
    self.version = self.version + 1
    always, never = buildList(C.auraAlways), buildList(C.auraNever)
    setGameOptions()
    -- every plate up now: ours on, refreshed or off
    for _, p in pairs(pool) do
        if p.unit then self:Removed(p.unit) end
        showGame(p.base)
    end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if call(UnitExists, unit) then self:Added(unit) end
    end
end

-- /wl debug: your target's plate and how its auras are read.
function NP:Debug()
    if not self.active then
        ns.Print("nameplates: off")
        return
    end
    local p
    for unit, q in pairs(plates) do
        if call(UnitIsUnit, unit, "target") then p = q end
    end
    if not p then
        -- why not: the game's plate, whether addons may touch it, the side
        local base = C_NamePlate and C_NamePlate.GetNamePlateForUnit and call(C_NamePlate.GetNamePlateForUnit, "target")
        local forbidden = base and select(2, pcall(base.IsForbidden, base))
        if not base and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
            -- asked again with closed plates included: there, but closed to addons
            local ok, b = pcall(C_NamePlate.GetNamePlateForUnit, "target", true)
            if ok and b then base, forbidden = b, true end
        end
        local cvars, names = {}, { "nameplateShowEnemies", "nameplateShowFriends", "nameplateShowFriendlyPlayers",
                                   "nameplateShowEnemyPlayers", "nameplateShowAll" }
        -- every plate setting this client has
        local ok, all = pcall(C_Console and C_Console.GetAllCommands)
        if ok and type(all) == "table" then
            names = {}
            for _, c in ipairs(all) do
                local n = type(c) == "table" and c.command
                if type(n) == "string" and n:lower():find("^nameplateshow") then names[#names + 1] = n end
            end
            table.sort(names)
        end
        for _, name in ipairs(names) do
            local ok, v = pcall(C_CVar.GetCVar, name)
            if ok and v ~= nil then cvars[#cvars + 1] = name:gsub("nameplateShow", "") .. "=" .. tostring(v) end
        end
        ns.Print("nameplates: game settings " .. table.concat(cvars, ", "))
        ns.Print(("nameplates: your target has no plate of ours; the game's plate %s, side %s, attackable %s, enemy %s, player %s"):format(
            not base and "not found" or forbidden and "closed to addons" or "found",
            tostring(sideOf("target")), tostring(call(UnitCanAttack, "player", "target")),
            tostring(UnitIsEnemy and call(UnitIsEnemy, "player", "target")), tostring(call(UnitIsPlayer, "target"))))
        for label, err in pairs(errors) do ns.Print("  error in " .. label .. ": " .. err) end
        return
    end
    local n, mine = 0, 0
    for _, e in pairs(p.auraCache or {}) do
        n = n + 1
        if e.mine then mine = mine + 1 end
    end
    local CU = C_UnitAuras or {}
    local row = gameAuraRow(p.base)
    ns.Print(("nameplates: auras drawn by %s; the game's aura row %s%s"):format(
        p.gameAuras and "the game" or "WombatLog", row and "found" or "not found",
        p.rowError and (" (borrowing it failed: " .. p.rowError .. ")") or ""))
    for label, err in pairs(errors) do ns.Print("  error in " .. label .. ": " .. err) end
    ns.Print(("nameplates: %s, auras read %s, from events %d, known %d (yours %d), shown %d; filter check %s, duration %s"):format(
        p.unit, tostring(p.auraScan or "not yet"), p.auraAdded or 0, n, mine, p.auraCount or 0,
        CU.IsAuraFilteredOutByInstanceID and "yes" or "no", CU.GetAuraDuration and "yes" or "no"))
end

function NP:Init()
    self.ready = true
    self:Apply()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function on(unit, fn)
    unit = Safe(unit)
    local p = unit and plates[unit]
    if p and NP.active then try("event", fn, p) end
end

ns.Listen("NAME_PLATE_UNIT_ADDED", function(unit)
    unit = Safe(unit)
    if unit and NP.ready then try("new plate", NP.Added, NP, unit) end
end)
ns.Listen("NAME_PLATE_UNIT_REMOVED", function(unit)
    unit = Safe(unit)
    if not unit then return end
    local p = plates[unit]
    NP:Removed(unit)
    if p then showGame(p.base) end
end)

for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_HEALTH_FREQUENT", "UNIT_MAXHEALTH" }) do
    ns.Listen(ev, function(unit) on(unit, function(p) NP:UpdateHealth(p, true) end) end)
end
for _, ev in ipairs({ "UNIT_NAME_UPDATE", "UNIT_LEVEL" }) do
    ns.Listen(ev, function(unit) on(unit, function(p) NP:UpdateName(p) end) end)
end
ns.Listen("UNIT_CLASSIFICATION_CHANGED", function(unit) on(unit, function(p) NP:UpdateClass(p) end) end)
for _, ev in ipairs({ "UNIT_FACTION", "UNIT_FLAGS", "UNIT_CONNECTION" }) do
    -- a unit turning hostile or friendly gets the other kind of plate
    ns.Listen(ev, function(unit)
        on(unit, function(p)
            local side = sideOf(p.unit)
            if (side == "hostile") ~= p.hostile or side == nil then
                NP:Added(p.unit)
            else
                NP:UpdateHealth(p, false)
                NP:UpdateName(p)
            end
        end)
    end)
end
-- UNIT_AURA for every unit if the client allows it, else for each plate's unit
local function onAura(unit, info) on(unit, function(p) NP:UpdateAuras(p, info) end) end
if not ns.Listen("UNIT_AURA", onAura) then
    for i = 1, 40, 2 do ns.Listen("UNIT_AURA", onAura, "nameplate" .. i, "nameplate" .. (i + 1)) end
end
for _, ev in ipairs({ "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE" }) do
    ns.Listen(ev, function(unit) on(unit, function(p) NP:UpdateHealth(p, false) end) end)
end
-- your threat on every plate changes with yours
ns.Listen("UNIT_THREAT_SITUATION_UPDATE", function(unit)
    if Safe(unit) ~= "player" or not NP.active then return end
    for _, p in pairs(plates) do NP:UpdateHealth(p, false) end
end)

for _, ev in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_DELAYED",
                      "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_EMPOWER_START" }) do
    ns.Listen(ev, function(unit) on(unit, function(p) NP:StartCast(p) end) end)
end
for _, ev in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_EMPOWER_STOP" }) do
    ns.Listen(ev, function(unit) on(unit, function(p) if not p.castHold then NP:StopCast(p) end end) end)
end
for _, ev in ipairs({ "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
    ns.Listen(ev, function(unit)
        on(unit, function(p)
            -- a failed second attempt during a cast isn't the cast failing
            if ev == "UNIT_SPELLCAST_FAILED" and isCasting(p.unit) then return end
            NP:InterruptCast(p)
        end)
    end)
end
ns.Listen("UNIT_SPELLCAST_INTERRUPTIBLE", function(unit) on(unit, function(p) if p.casting then castColor(p, false) end end) end)
ns.Listen("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", function(unit) on(unit, function(p) if p.casting then castColor(p, true) end end) end)

ns.Listen("PLAYER_TARGET_CHANGED", function()
    if not NP.active then return end
    for _, p in pairs(plates) do NP:UpdateTarget(p) end
end)
ns.Listen("RAID_TARGET_UPDATE", function()
    if not NP.active then return end
    for _, p in pairs(plates) do NP:UpdateRaid(p) end
end)
for _, ev in ipairs({ "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED" }) do
    ns.Listen(ev, function()
        if not NP.active or not cfg().quest then return end
        for _, p in pairs(plates) do NP:UpdateQuest(p) end
    end)
end
ns.Listen("PLAYER_REGEN_ENABLED", function()
    if pendingCVars then setGameOptions() end
end)
-- role and spec changes turn the threat colors around
for _, ev in ipairs({ "PLAYER_ROLES_ASSIGNED", "PLAYER_SPECIALIZATION_CHANGED" }) do
    ns.Listen(ev, function()
        if not NP.active then return end
        for _, p in pairs(plates) do NP:UpdateHealth(p, false) end
    end)
end
