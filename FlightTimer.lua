local ADDON, ns = ...
local FlightTimer = {}
ns.FlightTimer = FlightTimer
local Safe = ns.Safe
local L = ns.L

-- A timer that shows up by itself when you take a flight path: two map pins joined by
-- an arc of dots, your faction's flying mount travelling along it, the time left and
-- when you arrive.
--
-- Where the times come from, best first:
--   learned   every flight is measured; the route's own average (with its stops)
--   data      the hops' times worked out from the game's routes (FlightData_<Flavor>.lua),
--             scaled by how fast flights turned out to be on this client so far
--   map       a hop missing from the data: its distance on the flight map, at the pace
--             of the other hops on that map
-- Without any of them the timer counts up and learns the route for next time.

local MEDIA = "Interface\\AddOns\\WombatLog\\Media\\"
local PIN = MEDIA .. "FlightPin"
local DOT = MEDIA .. "Round50"
local GLOW = MEDIA .. "Glow"
local MOUNTS = { gryphon = MEDIA .. "FlightGryphon", wyvern = MEDIA .. "FlightWyvern", bird = MEDIA .. "FlightBird" }

local W, H = 300, 118          -- the frame, before scaling
local X0, X1 = 34, W - 34      -- where the arc meets the pins' heads
local BASE, PEAK = 46, 100     -- the arc's ends and its highest point, from the bottom
local T0, T1 = 0.07, 0.93      -- the dots leave the pins' heads free
local DOTS = 30
local PIN_SIZE = 28
local MOUNT_SIZE = 38
local TAKEOFF_WAIT = 10        -- seconds after picking a destination the flight may take to start
local FADE_IN, LAND_HOLD, LAND_FADE = 0.3, 1.4, 0.8
local ROUTE_MEMORY = 5         -- a route's time follows its last few flights
local PACE_MEMORY = 20         -- the pace of flights on this client follows the last 20

local SAMPLE = { from = "Crossroads, The Barrens", to = "Ratchet, The Barrens", est = 14 }

local function cfg() return ns.db.flightTimer end

local function store()
    local S = WombatLogDB.flightTimes
    S.routes = S.routes or {}
    return S
end

local function short(name)
    return name and (name:match("^%s*([^,]+)") or name) or "?"
end

local function clock(s)
    s = math.max(0, math.floor(s + 0.5))
    if s >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
    end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

---------------------------------------------------------------------------
-- The flight map: its nodes and the route to a destination
---------------------------------------------------------------------------

local nodesCache -- slot -> { id, name, x, y, kind } while the flight map is open

local function readNodes()
    local n = Safe(NumTaxiNodes and NumTaxiNodes()) or 0
    if n == 0 then return nodesCache end
    local nodes = {}
    for i = 1, n do
        local x, y = TaxiNodePosition(i)
        nodes[i] = { name = Safe(TaxiNodeName(i)), kind = Safe(TaxiNodeGetType(i)), x = Safe(x), y = Safe(y) }
    end
    -- the node IDs the flight data is keyed by
    if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID then
        local ok, list = pcall(function() return C_TaxiMap.GetAllTaxiNodes(GetTaxiMapID()) end)
        if ok and type(list) == "table" then
            for _, d in ipairs(list) do
                local slot = d.slotIndex
                if slot and nodes[slot] and d.nodeID then nodes[slot].id = d.nodeID end
            end
        end
    end
    nodesCache = nodes
    return nodes
end

local function nearestSlot(nodes, x, y)
    if not (x and y) then return nil end
    local best, bestD
    for i, nd in pairs(nodes) do
        if nd.x and nd.y then
            local d = (nd.x - x) ^ 2 + (nd.y - y) ^ 2
            if not bestD or d < bestD then best, bestD = i, d end
        end
    end
    return best
end

-- The slots a flight to `slot` passes, from where you are to there.
local function chainTo(nodes, slot)
    local chain
    local hops = Safe(GetNumRoutes and GetNumRoutes(slot)) or 0
    for h = 1, hops do
        local a, b
        if TaxiGetNodeSlot then
            a, b = Safe(TaxiGetNodeSlot(slot, h, true)), Safe(TaxiGetNodeSlot(slot, h, false))
        elseif TaxiGetSrcX then
            a = nearestSlot(nodes, TaxiGetSrcX(slot, h), TaxiGetSrcY(slot, h))
            b = nearestSlot(nodes, TaxiGetDestX(slot, h), TaxiGetDestY(slot, h))
        end
        if not (a and b and nodes[a] and nodes[b]) then chain = nil; break end
        chain = chain or { a }
        chain[#chain + 1] = b
    end
    if not chain then
        for i, nd in pairs(nodes) do
            if nd.kind == "CURRENT" then chain = { i, slot } end
        end
    end
    return chain
end

local function hopData(a, b)
    local D = ns.FLIGHT_DATA
    if not (D and a and b) then return nil end
    return D[a] and D[a][b] or D[b] and D[b][a]
end

-- Seconds per unit of map distance, from the hops on this map the data knows.
local function mapPace(nodes)
    local ratios = {}
    for _, a in pairs(nodes) do
        for _, b in pairs(nodes) do
            local s = a ~= b and a.id and b.id and ns.FLIGHT_DATA and ns.FLIGHT_DATA[a.id] and ns.FLIGHT_DATA[a.id][b.id]
            if s and a.x and b.x then
                local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
                if d > 0.01 then ratios[#ratios + 1] = s / d end
            end
        end
    end
    if #ratios == 0 then return nil end
    table.sort(ratios)
    return ratios[math.floor(#ratios / 2) + 1]
end

-- Everything about a flight to `slot`: its names, route key, estimate and where
-- that came from ("learned", "estimate" or nil), and the data's own sum (for the pace).
function FlightTimer:Plan(slot)
    local nodes = readNodes()
    if not (nodes and nodes[slot]) then return nil end
    local chain = chainTo(nodes, slot)
    if not chain then return nil end
    local ids, names, allIDs = {}, {}, true
    for i, s in ipairs(chain) do
        ids[i] = tostring(nodes[s].id)
        names[i] = nodes[s].name or "?"
        if not nodes[s].id then allIDs = false end
    end
    local plan = { from = names[1], to = names[#names], stops = #chain - 2 }
    plan.key = allIDs and table.concat(ids, ">") or ("n:" .. table.concat(names, ">"))

    -- the data's time for every hop, a hop it lacks from the map
    local sum, complete, pace = 0, true, nil
    for i = 1, #chain - 1 do
        local a, b = nodes[chain[i]], nodes[chain[i + 1]]
        local s = hopData(a.id, b.id)
        if not s then
            complete = false
            pace = pace or mapPace(nodes) or false
            if pace and a.x and b.x then
                s = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) * pace * 1.1
            end
        end
        if not s then sum = nil; break end
        sum = sum + s
    end
    if complete then plan.dataSum = sum end

    local learned = store().routes[plan.key]
    if learned and learned.t then
        plan.est, plan.kind, plan.flights = learned.t, "learned", learned.n
    elseif sum then
        plan.est, plan.kind = sum * (store().pace or 1), "estimate"
    end
    return plan
end

---------------------------------------------------------------------------
-- Learning
---------------------------------------------------------------------------

local function learn(fl, seconds)
    local S = store()
    local r = S.routes[fl.key]
    -- far shorter than before: the flight was cut short, not faster
    if r and r.t and r.n and r.n >= 2 and seconds < r.t * 0.6 then return end
    r = r or {}
    r.n = (r.n or 0) + 1
    r.t = r.t and (r.t + (seconds - r.t) / math.min(r.n, ROUTE_MEMORY)) or seconds
    S.routes[fl.key] = r
    -- how fast flights are on this client against the data's times
    if fl.dataSum and fl.dataSum > 0 then
        local ratio = math.max(0.4, math.min(2.5, seconds / fl.dataSum))
        S.paceN = math.min((S.paceN or 0) + 1, PACE_MEMORY)
        S.pace = (S.pace or 1) + (ratio - (S.pace or 1)) / S.paceN
    end
end

function FlightTimer:Forget()
    local S = store()
    wipe(S.routes)
    S.pace, S.paceN = nil, nil
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function arcPoint(t)
    local px, py = W / 2, BASE + 2 * (PEAK - BASE)
    local u = 1 - t
    local x = u * u * X0 + 2 * u * t * px + t * t * X1
    local y = u * u * BASE + 2 * u * t * py + t * t * BASE
    local dx = 2 * u * (px - X0) + 2 * t * (X1 - px)
    local dy = 2 * u * (py - BASE) + 2 * t * (BASE - py)
    return x, y, math.atan2(dy, dx)
end

local function newPin(f)
    local p = f:CreateTexture(nil, "ARTWORK")
    p:SetTexture(PIN)
    p:SetSize(PIN_SIZE, PIN_SIZE)
    p.glow = f:CreateTexture(nil, "BACKGROUND")
    p.glow:SetTexture(GLOW)
    p.glow:SetBlendMode("ADD")
    p.glow:SetAlpha(0)
    -- the pin's head (65 % up the texture) sits on the arc's end
    return p
end

local function placePin(f, p, x)
    p:ClearAllPoints()
    p:SetPoint("BOTTOM", f, "BOTTOMLEFT", x, BASE - PIN_SIZE * 0.65)
    p.glow:ClearAllPoints()
    p.glow:SetPoint("CENTER", f, "BOTTOMLEFT", x, BASE)
    p.glow:SetSize(PIN_SIZE * 2.6, PIN_SIZE * 2.6)
end

local function CreateFrames()
    local f = CreateFrame("Frame", "WombatLogFlightTimer", UIParent)
    f:SetSize(W, H)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local C = cfg()
        local s = UIParent:GetEffectiveScale() / f:GetEffectiveScale()
        local cx, cy = f:GetCenter()
        C.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        C.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", C.x, C.y)
    end)
    f:Hide()

    f.dots = {}
    for i = 1, DOTS do
        local d = f:CreateTexture(nil, "BORDER")
        d:SetTexture(DOT)
        local t = T0 + (T1 - T0) * (i - 1) / (DOTS - 1)
        local x, y = arcPoint(t)
        d:SetPoint("CENTER", f, "BOTTOMLEFT", x, y)
        d.t = t
        f.dots[i] = d
    end

    f.fromPin, f.toPin = newPin(f), newPin(f)
    placePin(f, f.fromPin, X0)
    placePin(f, f.toPin, X1)

    f.mountGlow = f:CreateTexture(nil, "BORDER", nil, 1)
    f.mountGlow:SetTexture(GLOW)
    f.mountGlow:SetBlendMode("ADD")
    f.mount = f:CreateTexture(nil, "OVERLAY")
    f.mount:SetSize(MOUNT_SIZE, MOUNT_SIZE)

    f.fromName = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.toName = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    for _, fs in ipairs({ f.fromName, f.toName }) do
        fs:SetWidth(120)
        fs:SetWordWrap(true)
        fs:SetJustifyV("TOP")
    end
    f.fromName:SetPoint("TOP", f, "BOTTOMLEFT", X0, BASE - PIN_SIZE * 0.65 - 3)
    f.toName:SetPoint("TOP", f, "BOTTOMLEFT", X1, BASE - PIN_SIZE * 0.65 - 3)

    f.time = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.time:SetPoint("BOTTOM", f, "BOTTOMLEFT", W / 2, BASE + 2)
    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.sub:SetPoint("TOP", f.time, "BOTTOM", 0, -2)

    f.overlay = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.overlay:SetAllPoints()
    f.overlay:SetColorTexture(0.2, 0.6, 1, 0.15)
    f.overlayText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.overlayText:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.overlayText:SetText(L["WombatLog flight timer - drag to move"])
    f.overlay:Hide()
    f.overlayText:Hide()
    return f
end

local function mountKind()
    local m = cfg().mount
    if MOUNTS[m] then return m end
    local faction = Safe(UnitFactionGroup("player"))
    if faction == "Alliance" then return "gryphon" end
    if faction == "Horde" then return "wyvern" end
    return "bird"
end

function FlightTimer:Init()
    WombatLogDB.flightTimes = WombatLogDB.flightTimes or {}
    self.frame = CreateFrames()
    self.driver = CreateFrame("Frame")
    self.driver:SetScript("OnUpdate", function(_, dt) self:Step(dt) end)
    self:Apply()
    self:HookTaxi()
end

function FlightTimer:Apply()
    local f = self.frame
    if not f then return end
    local C = cfg()
    f:SetScale(C.scale)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", C.x, C.y)

    local font, nameFont, outline, nameOutline = ns.AlertFonts(C)
    local size = C.textSize
    ns.SetFont(f.time, font, math.floor(size * 1.7), outline)
    ns.SetFont(f.sub, nameFont, math.max(8, math.floor(size * 0.85)), nameOutline)
    ns.SetFont(f.fromName, nameFont, size, nameOutline)
    ns.SetFont(f.toName, nameFont, size, nameOutline)
    f.sub:SetTextColor(0.8, 0.8, 0.8)
    f.fromName:SetTextColor(0.85, 0.85, 0.85)
    f.toName:SetTextColor(1, 1, 1)

    local c = C.color
    f.fromPin:SetVertexColor(0.85, 0.85, 0.85, 0.9)
    f.toPin:SetVertexColor(c[1], c[2], c[3], 1)
    f.toPin.glow:SetVertexColor(c[1], c[2], c[3], 1)
    f.fromPin.glow:SetVertexColor(1, 1, 1, 1)
    f.mount:SetTexture(MOUNTS[mountKind()])
    f.mount:SetVertexColor(c[1], c[2], c[3], 1)
    f.mountGlow:SetVertexColor(c[1], c[2], c[3], 1)
    f.mountGlow:SetSize(MOUNT_SIZE * 1.8, MOUNT_SIZE * 1.8)
    local dot = math.max(3, math.floor(size * 0.32))
    for _, d in ipairs(f.dots) do d:SetSize(dot, dot) end

    if not C.enabled and self.flight and not self.unlocked then self:Stop() end
    if self.unlocked and not self:Flying() then self:ShowSample() end
    if self.flight then self:Render(GetTime()) end
end

---------------------------------------------------------------------------
-- A flight
---------------------------------------------------------------------------

function FlightTimer:Begin(fl, startAt)
    fl.start = startAt or GetTime()
    self.flight = fl
    local f = self.frame
    f.fromName:SetText(short(fl.from))
    f.toName:SetText(short(fl.to))
    f.mount:SetTexture(MOUNTS[mountKind()])
    f:SetAlpha(fl.sample and 1 or 0)
    f:Show()
    self:Render(GetTime())
    -- kept across a /reload in the air (not across logging out: you arrive meanwhile)
    if not (fl.test or fl.sample) then
        store().current = {
            from = fl.from, to = fl.to, key = fl.key, est = fl.est, kind = fl.kind,
            dataSum = fl.dataSum, started = time() - (GetTime() - fl.start),
        }
    end
end

function FlightTimer:Land()
    local fl = self.flight
    if not fl or fl.landedAt then return end
    local seconds = GetTime() - fl.start
    fl.landedAt = GetTime()
    if not (fl.test or fl.sample) then
        store().current = nil
        if not fl.aborted and not fl.restored and seconds >= 5 then learn(fl, seconds) end
    end
end

function FlightTimer:Stop()
    self.flight = nil
    self.frame:Hide()
end

-- The flight's progress (0-1), or nil while its time is unknown.
local function progress(fl, now)
    if fl.landedAt then return 1 end
    if fl.sample then return 0.45 end
    if not fl.est or fl.est <= 0 then return nil end
    -- the last bit waits for the landing itself
    return math.min(0.985, (now - fl.start) / fl.est)
end

function FlightTimer:Render(now)
    local fl, f = self.flight, self.frame
    if not fl then return end
    local c = cfg().color
    local p = progress(fl, now)
    local elapsed = now - fl.start

    local tp
    if p then
        tp = T0 + (T1 - T0) * p
    else
        tp = 0.5 + 0.06 * math.sin(now * 0.8) -- unknown time: it hovers mid-way
    end
    for _, d in ipairs(f.dots) do
        if p and d.t <= tp then
            d:SetVertexColor(c[1], c[2], c[3], 1)
        else
            d:SetVertexColor(1, 1, 1, 0.3)
        end
    end
    local x, y, angle = arcPoint(tp)
    y = y + math.sin(now * 3) * 1.5 -- a little lift and fall of the wing beats
    f.mount:ClearAllPoints()
    f.mount:SetPoint("CENTER", f, "BOTTOMLEFT", x, y)
    f.mount:SetRotation(angle * 0.6)
    f.mountGlow:ClearAllPoints()
    f.mountGlow:SetPoint("CENTER", f.mount)
    f.mountGlow:SetAlpha(0.35 + 0.1 * math.sin(now * 2))

    -- the time left, or the time so far while the route is still being learned
    if fl.landedAt then
        f.time:SetText(L["Arrived"])
        f.sub:SetText("")
    elseif p then
        local left = fl.est - elapsed
        f.time:SetText(left > 0 and ((fl.kind == "estimate" and "~" or "") .. clock(left)) or L["Landing"])
        if cfg().showArrival and left > 0 then
            f.sub:SetText(string.format(L["Arrival %s"], date("%H:%M", time() + left)))
        else
            f.sub:SetText("")
        end
    else
        f.time:SetText(clock(elapsed))
        f.sub:SetText(L["Learning this route"])
    end
    f.time:SetTextColor(1, 1, 1)
end

function FlightTimer:Step()
    local now = GetTime()
    -- a destination picked: the flight starts once you are on the taxi
    local pending = self.pending
    if pending then
        if Safe(UnitOnTaxi("player")) then
            self.pending = nil
            if cfg().enabled then
                if self.unlocked then self:SetLocked(true) end
                self:Begin(pending)
            end
        elseif now - pending.at > TAKEOFF_WAIT then
            self.pending = nil
        end
    end

    local fl = self.flight
    if not fl then return end
    local f = self.frame
    if fl.landedAt then
        local t = now - fl.landedAt
        f.toPin.glow:SetAlpha(0.8 * math.max(0, 1 - t / LAND_HOLD))
        f:SetAlpha(1 - math.min(1, math.max(0, (t - LAND_HOLD) / LAND_FADE)))
        if t >= LAND_HOLD + LAND_FADE then
            f.toPin.glow:SetAlpha(0)
            self:Stop()
            return
        end
    else
        if not fl.sample then f:SetAlpha(math.min(1, (now - fl.start) / FADE_IN)) end
        if fl.test then
            if now - fl.start >= fl.est then self:Land() end
        elseif not fl.sample and not Safe(UnitOnTaxi("player")) then
            self:Land()
        end
    end
    self:Render(now)
end

---------------------------------------------------------------------------
-- The game's flight map
---------------------------------------------------------------------------

local function tooltipLine(slot, owner)
    if not (ns.db and cfg().enabled and cfg().tooltip) then return end
    if owner and not GameTooltip:IsOwned(owner) then return end
    if Safe(TaxiNodeGetType(slot)) ~= "REACHABLE" then return end
    local plan = FlightTimer:Plan(slot)
    if not (plan and plan.est) then return end
    local text
    if plan.kind == "learned" then
        text = string.format(L["Flight time: %s"], clock(plan.est))
    else
        text = string.format(L["Flight time: %s"], "~" .. clock(plan.est))
    end
    GameTooltip:AddLine(text, 1, 0.82, 0.3)
    GameTooltip:Show()
end

function FlightTimer:HookTaxi()
    hooksecurefunc("TakeTaxiNode", function(slot)
        if not (ns.db and cfg().enabled) then return end
        local plan = self:Plan(slot) or { from = "?", to = Safe(TaxiNodeName(slot)) or "?" }
        plan.at = GetTime()
        if not plan.key then plan.key = "n:" .. tostring(plan.from) .. ">" .. tostring(plan.to) end
        self.pending = plan
    end)
    if TaxiRequestEarlyLanding then
        hooksecurefunc("TaxiRequestEarlyLanding", function()
            if self.flight then self.flight.aborted = true end
        end)
    end

    -- the classic flight map: one button per node
    local function hookButtons()
        if self.buttonsHooked or not TaxiNodeOnButtonEnter then return end
        self.buttonsHooked = true
        hooksecurefunc("TaxiNodeOnButtonEnter", function(button)
            tooltipLine(button:GetID(), button)
        end)
    end
    hookButtons()

    -- the modern flight map: map pins, made as the map needs them
    local function hookPins()
        if not (FlightMapFrame and FlightMapFrame.EnumeratePinsByTemplate) then return end
        for pin in FlightMapFrame:EnumeratePinsByTemplate("FlightMap_FlightPointPinTemplate") do
            if not pin.wombatHooked then
                pin.wombatHooked = true
                pin:HookScript("OnEnter", function(p)
                    local slot = p.taxiNodeData and p.taxiNodeData.slotIndex
                    if slot then tooltipLine(slot, p) end
                end)
            end
        end
    end

    ns.Listen("TAXIMAP_OPENED", function()
        readNodes()
        hookButtons()
        C_Timer.After(0, hookPins)
        C_Timer.After(0.5, hookPins)
    end)
    ns.Listen("TAXIMAP_CLOSED", function()
        -- the hook on TakeTaxiNode reads the map before it closes; keep it a moment
        C_Timer.After(1, function() nodesCache = nil end)
    end)
end

-- After a /reload in the air: pick the flight up again (shown, not learned from).
ns.Listen("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(1, function()
        local S = WombatLogDB and WombatLogDB.flightTimes
        local cur = S and S.current
        if not cur then return end
        local since = time() - (cur.started or 0)
        if not Safe(UnitOnTaxi("player")) or since > (cur.est or 1800) + 120 then
            S.current = nil
            return
        end
        if FlightTimer.flight or not (ns.db and cfg().enabled) then return end
        FlightTimer:Begin({
            from = cur.from, to = cur.to, key = cur.key, est = cur.est, kind = cur.kind,
            dataSum = cur.dataSum, restored = true,
        }, GetTime() - since)
    end)
end)

---------------------------------------------------------------------------
-- Test and positioning
---------------------------------------------------------------------------

-- A real flight (not the sample or the test) is on screen.
function FlightTimer:Flying()
    local fl = self.flight
    return fl ~= nil and not fl.sample and not fl.test
end

function FlightTimer:ShowSample()
    self:Begin({ from = SAMPLE.from, to = SAMPLE.to, est = SAMPLE.est * 2, kind = "estimate", sample = true },
        GetTime() - SAMPLE.est * 0.9)
end

-- Settings button: a short flight from start to landing.
function FlightTimer:Test()
    if self:Flying() then return end
    if self.unlocked then self:SetLocked(true) end
    self:Begin({ from = SAMPLE.from, to = SAMPLE.to, est = SAMPLE.est, kind = "estimate", test = true })
end

function FlightTimer:SetLocked(locked)
    self.unlocked = not locked
    local f = self.frame
    f:EnableMouse(not locked)
    f.overlay:SetShown(not locked)
    f.overlayText:SetShown(not locked)
    if locked then
        if self.flight and self.flight.sample then self:Stop() end
    elseif not self:Flying() then
        self:ShowSample()
    end
    if ns.Config then ns.Config:RefreshAll() end
end
