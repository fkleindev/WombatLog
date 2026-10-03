local ADDON, ns = ...
local Report = {}
ns.Report = Report

local WHITE = "Interface\\Buttons\\WHITE8X8"
local GRADIENT = "Interface\\AddOns\\WombatLog\\Media\\Gradient"
local GREY = { 0.65, 0.65, 0.65 }

local CARD_W = 300
local CARD_SPELLS = 5
local J_W, J_H = 700, 450
local LIST_W = 230
local LIST_ROW_H = 36
local TABLE_ROWS = 10

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function text(parent, size, useNumberFont, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local A = ns.db.appearance
    ns.SetFont(fs, useNumberFont and A.amountFont or A.nameFont, size, "OUTLINE")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    return fs
end

local function pct(part, whole)
    if not whole or whole <= 0 then return "-" end
    return math.floor(part / whole * 100 + 0.5) .. "%"
end

local function when(t, withDate)
    if not t then return "" end
    return date(withDate and "%d.%m. %H:%M" or "%H:%M", t)
end

local function fightTitle(snap)
    if snap.test then return "Test fight" end
    local title = snap.zone ~= "" and snap.zone or "Unknown zone"
    if snap.target then title = title .. "  -  " .. snap.target end
    return title
end

local function NewScroll(parent)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate")
    if not ok or not scroll.ScrollBar then
        scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    end
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(10, 10)
    scroll:SetScrollChild(child)
    return scroll, child
end

local function Confirm(msg, fn)
    StaticPopup_Show("WOMBATLOG_CONFIRM", msg, nil, fn)
end

---------------------------------------------------------------------------
-- Summary card
---------------------------------------------------------------------------

local function CreateSummary()
    local f = CreateFrame("Button", "WombatLogSummary", UIParent)
    f:SetWidth(CARD_W)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:RegisterForDrag("LeftButton")
    f:Hide()

    -- no background: like the log window, only the rows get a soft fade
    f.title = text(f, 13, true)
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetText("Fight summary")
    f.duration = text(f, 13, true)
    f.duration:SetPoint("TOPRIGHT", -10, -8)
    f.sub = text(f, 10, false, GREY)
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -2)
    f.sub:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.sub:SetJustifyH("LEFT")
    f.sub:SetWordWrap(false)

    -- same fading divider as under the log header
    f.divider = f:CreateTexture(nil, "ARTWORK")
    f.divider:SetHeight(1)
    f.divider:SetPoint("TOPLEFT", 0, -72)
    f.divider:SetPoint("TOPRIGHT", 0, -72)
    f.divider:SetTexture(GRADIENT)
    f.divider:SetVertexColor(1, 1, 1, 0.5)

    f.blocks = {}
    local labels = { "DPS", "HPS", "CRIT", "BIGGEST", "STREAK" }
    local bw = (CARD_W - 20) / #labels
    for i, label in ipairs(labels) do
        local b = {}
        b.value = text(f, 15, true)
        b.value:SetPoint("TOPLEFT", 10 + (i - 1) * bw, -42)
        b.label = text(f, 8, false, GREY)
        b.label:SetPoint("TOPLEFT", b.value, "BOTTOMLEFT", 0, -1)
        b.label:SetText(label)
        f.blocks[i] = b
    end

    f.rows = {}
    for i = 1, CARD_SPELLS do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(CARD_W - 20, 16)
        r:SetPoint("TOPLEFT", 10, -78 - (i - 1) * 18)
        -- row styling from the log: dark side fade, colored accent bar
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.bg:SetTexture(GRADIENT)
        r.accent = r:CreateTexture(nil, "ARTWORK")
        r.accent:SetPoint("TOPLEFT", 0, -1)
        r.accent:SetPoint("BOTTOMLEFT", 0, 1)
        r.accent:SetWidth(2)
        r.bar = r:CreateTexture(nil, "BACKGROUND", nil, 1)
        r.bar:SetTexture(GRADIENT)
        r.bar:SetPoint("TOPLEFT")
        r.bar:SetPoint("BOTTOMLEFT")
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(14, 14)
        r.icon:SetPoint("LEFT", 5, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.value = text(r, 10, false)
        r.value:SetPoint("RIGHT", -2, 0)
        r.name = text(r, 11, false)
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
        r.name:SetPoint("RIGHT", r.value, "LEFT", -6, 0)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        f.rows[i] = r
    end

    f.records = {}
    for i = 1, 3 do
        local line = text(f, 11, false)
        line:SetJustifyH("LEFT")
        f.records[i] = line
    end

    f:SetScript("OnDragStart", function(self)
        self.dragged = true
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local cfg = ns.db.stats.summary
        local s = UIParent:GetEffectiveScale() / self:GetEffectiveScale()
        local cx, cy = self:GetCenter()
        cfg.x = math.floor(cx - UIParent:GetWidth() * s / 2 + 0.5)
        cfg.y = math.floor(cy - UIParent:GetHeight() * s / 2 + 0.5)
        Report:Apply()
    end)
    f:SetScript("OnClick", function(self, button)
        if self.dragged then
            self.dragged = false
            return
        end
        if button == "RightButton" then
            Report:HideSummary()
        else
            Report:OpenJournal("fights", self.snap)
        end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Fight summary")
        GameTooltip:AddLine("Click: open in journal  -  Right-click: close  -  Drag: move", 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- fades in and out like the log window, with the same times and opacity
    f.fadeTarget = 0
    f:SetAlpha(0)
    f:SetScript("OnUpdate", function(self, dt)
        local a, target = self:GetAlpha(), self.fadeTarget
        if a == target then return end
        local B = ns.db.behaviour
        if target > a then
            a = math.min(target, a + dt / math.max(B.fadeIn, 0.01))
        else
            a = math.max(target, a - dt / math.max(B.fadeOut, 0.01))
        end
        self:SetAlpha(a)
        if a <= 0 then self:Hide() end
    end)
    return f
end

local function FillSummary(f, snap)
    local C = ns.db.colors
    local bgAlpha = ns.db.appearance.rowBgOpacity
    f.snap = snap
    f.duration:SetText(ns.Stats.FormatDuration(snap.duration))
    f.sub:SetText(fightTitle(snap))

    local values = {
        ns.Short(snap.dps), ns.Short(snap.hps), pct(snap.crits, snap.hits),
        snap.top and ns.Short(snap.top.amount) or "-",
        snap.longestStreak > 0 and ("x" .. snap.longestStreak) or "-",
    }
    for i, b in ipairs(f.blocks) do b.value:SetText(values[i]) end
    f.blocks[2].value:SetTextColor(C.heal[1], C.heal[2], C.heal[3])
    f.blocks[3].value:SetTextColor(C.crit[1], C.crit[2], C.crit[3])

    local shown = 0
    local topTotal = snap.spells[1] and snap.spells[1].total or 1
    for i, r in ipairs(f.rows) do
        local s = snap.spells[i]
        if s then
            shown = i
            local kindTotal = s.kind == "heal" and snap.healing or snap.damage
            local c = s.kind == "heal" and C.heal or C.crit
            r.bg:SetVertexColor(0, 0, 0, bgAlpha)
            r.accent:SetColorTexture(c[1], c[2], c[3], 0.9)
            r.bar:SetVertexColor(c[1], c[2], c[3], 0.3)
            r.bar:SetWidth(math.max(1, (CARD_W - 20) * s.total / topTotal))
            r.icon:SetTexture(s.icon or 134400)
            r.name:SetText(s.name)
            r.value:SetText(ns.Short(s.total) .. "  " .. pct(s.total, kindTotal) .. "  |cffaaaaaa" .. pct(s.crits, s.hits) .. " crit|r")
            r:Show()
        else
            r:Hide()
        end
    end

    local y = -78 - shown * 18 - 4
    local lines = {}
    for _, rec in ipairs(snap.records or {}) do
        lines[#lines + 1] = "NEW RECORD  " .. rec.name .. "  " .. ns.Full(rec.amount) .. (rec.crit and " (crit)" or "")
    end
    if snap.newBestDps then lines[#lines + 1] = "NEW BEST DPS  " .. ns.Short(snap.dps) end
    for i, line in ipairs(f.records) do
        if lines[i] then
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", 10, y)
            line:SetText(lines[i])
            line:SetTextColor(C.crit[1], C.crit[2], C.crit[3])
            line:Show()
            y = y - 15
        else
            line:Hide()
        end
    end
    f:SetHeight(-y + 8)
end

function Report:ShowSummary(snap)
    local cfg = ns.db.stats.summary
    if not cfg.enabled or not self.summary then return end
    local f = self.summary
    FillSummary(f, snap)
    if not f:IsShown() then f:SetAlpha(0) end
    f:Show()
    f.fadeTarget = ns.db.position.alpha
    if self.summaryTimer then self.summaryTimer:Cancel() end
    self.summaryTimer = nil
    if cfg.duration > 0 then
        self.summaryTimer = C_Timer.NewTimer(cfg.duration, function()
            self.summaryTimer = nil
            self:HideSummary()
        end)
    end
end

-- Fades out; the card hides itself once fully transparent.
function Report:HideSummary()
    if self.summaryTimer then self.summaryTimer:Cancel(); self.summaryTimer = nil end
    if self.summary then self.summary.fadeTarget = 0 end
end

-- Settings button: last fight, or a sample if there is none yet.
function Report:TestSummary()
    local snap = ns.Stats.last or ns.Stats.char.history[1]
    if not snap then
        snap = {
            test = true, zone = "", duration = 42, damage = 10250, healing = 1310, taken = 2400,
            dps = 244, hps = 31, hits = 40, crits = 9, misses = 2, longestStreak = 3,
            top = { name = "Fireball", amount = 1248, crit = true },
            records = { { name = "Fireball", amount = 1248, crit = true } },
            spells = {
                { name = "Fireball", icon = "Interface\\Icons\\Spell_Fire_Fireball02", kind = "damage", total = 5400, hits = 9, crits = 4, max = 1248 },
                { name = "Frostbolt", icon = "Interface\\Icons\\Spell_Frost_FrostBolt02", kind = "damage", total = 3100, hits = 10, crits = 2, max = 760 },
                { name = "Melee", icon = "Interface\\Icons\\INV_Sword_04", kind = "damage", total = 1750, hits = 14, crits = 2, max = 290 },
                { name = "Flash Heal", icon = "Interface\\Icons\\Spell_Holy_FlashHeal", kind = "heal", total = 1310, hits = 1, crits = 1, max = 1310 },
            },
        }
    end
    local wasEnabled = ns.db.stats.summary.enabled
    ns.db.stats.summary.enabled = true
    self:ShowSummary(snap)
    ns.db.stats.summary.enabled = wasEnabled
end

---------------------------------------------------------------------------
-- Journal window
---------------------------------------------------------------------------

local function border(f, r, g, b, a)
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
                            { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, a)
        t:SetPoint(side[1])
        t:SetPoint(side[2])
        if side[3] then t:SetWidth(side[3]) else t:SetHeight(side[4]) end
    end
end

-- Spell table columns: label, x offset, width, justify
local COLUMNS = {
    { "Spell", 22, 128, "LEFT" }, { "Total", 152, 56, "RIGHT" }, { "%", 210, 38, "RIGHT" },
    { "Hits", 250, 34, "RIGHT" }, { "Crit %", 286, 44, "RIGHT" }, { "Avg", 332, 38, "RIGHT" },
    { "Max", 372, 38, "RIGHT" },
}

local function BuildFightsPage(j, page)
    -- list
    local scroll, child = NewScroll(page)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMLEFT", 0, 34)
    scroll:SetWidth(LIST_W)
    child:SetWidth(LIST_W)
    j.listChild, j.listRows = child, {}

    j.empty = text(page, 12, false, GREY)
    j.empty:SetPoint("TOPLEFT", 4, -6)
    j.empty:SetWidth(LIST_W)
    j.empty:SetJustifyH("LEFT")

    local clear = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    clear:SetSize(140, 22)
    clear:SetPoint("BOTTOMLEFT", 0, 4)
    clear:SetText("Clear history")
    clear:SetScript("OnClick", function()
        Confirm("Delete all recorded fights?", function()
            ns.Stats:ClearHistory()
            Report.selected = nil
            Report:RefreshJournal()
        end)
    end)

    -- detail
    local d = CreateFrame("Frame", nil, page)
    d:SetPoint("TOPLEFT", LIST_W + 30, 0)
    d:SetPoint("BOTTOMRIGHT")
    j.detail = d
    d.title = text(d, 14, true)
    d.title:SetPoint("TOPLEFT")
    d.title:SetPoint("RIGHT")
    d.title:SetJustifyH("LEFT")
    d.title:SetWordWrap(false)
    d.when = text(d, 10, false, GREY)
    d.when:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -3)
    d.line1 = text(d, 11, false)
    d.line1:SetPoint("TOPLEFT", d.when, "BOTTOMLEFT", 0, -10)
    d.line1:SetPoint("RIGHT")
    d.line1:SetJustifyH("LEFT")
    d.line2 = text(d, 11, false)
    d.line2:SetPoint("TOPLEFT", d.line1, "BOTTOMLEFT", 0, -4)
    d.line2:SetPoint("RIGHT")
    d.line2:SetJustifyH("LEFT")

    local top = -86
    for _, col in ipairs(COLUMNS) do
        local h = text(d, 10, false, GREY)
        h:SetPoint("TOPLEFT", col[2], top)
        h:SetWidth(col[3])
        h:SetJustifyH(col[4])
        h:SetText(col[1])
    end
    d.rows = {}
    for i = 1, TABLE_ROWS do
        local row = CreateFrame("Frame", nil, d)
        row:SetPoint("TOPLEFT", 0, top - 16 - (i - 1) * 20)
        row:SetSize(J_W - LIST_W - 60, 18)
        row.bar = row:CreateTexture(nil, "BACKGROUND")
        row.bar:SetTexture(GRADIENT)
        row.bar:SetPoint("TOPLEFT", 20, 0)
        row.bar:SetPoint("BOTTOMLEFT", 20, 0)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT")
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.cells = {}
        for c, col in ipairs(COLUMNS) do
            local cell = text(row, 11, false)
            cell:SetPoint("LEFT", col[2], 0)
            cell:SetWidth(col[3])
            cell:SetJustifyH(col[4])
            cell:SetWordWrap(false)
            row.cells[c] = cell
        end
        d.rows[i] = row
    end
end

local function ListRow(j, i)
    local r = j.listRows[i]
    if r then return r end
    r = CreateFrame("Button", nil, j.listChild)
    r:SetSize(LIST_W - 4, LIST_ROW_H - 2)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * LIST_ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    r.top = text(r, 11, false)
    r.top:SetPoint("TOPLEFT", 6, -4)
    r.top:SetPoint("RIGHT", -6, 0)
    r.top:SetJustifyH("LEFT")
    r.top:SetWordWrap(false)
    r.bottom = text(r, 10, false, GREY)
    r.bottom:SetPoint("TOPLEFT", r.top, "BOTTOMLEFT", 0, -3)
    r:SetScript("OnClick", function(self)
        Report.selected = self.snap
        Report:RefreshJournal()
    end)
    j.listRows[i] = r
    return r
end

local function RenderDetail(d, snap)
    if not snap then
        d:Hide()
        return
    end
    d:Show()
    local C = ns.db.colors
    d.title:SetText(fightTitle(snap))
    d.when:SetText(when(snap.time, true) .. "   -   " .. ns.Stats.FormatDuration(snap.duration))
    d.line1:SetText(string.format("Damage |cffffffff%s|r (%s DPS)    Healing |cffffffff%s|r (%s HPS)    Taken |cffffffff%s|r",
        ns.Short(snap.damage), ns.Short(snap.dps), ns.Short(snap.healing), ns.Short(snap.hps), ns.Short(snap.taken)))
    local biggest = snap.top and (snap.top.name .. " " .. ns.Full(snap.top.amount) .. (snap.top.crit and " crit" or "")) or "-"
    d.line2:SetText(string.format("Crit rate |cffffffff%s|r (%d/%d)    Misses %d    Longest streak |cffffffff%s|r    Biggest %s",
        pct(snap.crits, snap.hits), snap.crits, snap.hits, snap.misses or 0,
        snap.longestStreak > 0 and ("x" .. snap.longestStreak) or "-", biggest))

    local topTotal = snap.spells[1] and snap.spells[1].total or 1
    for i, row in ipairs(d.rows) do
        local s = snap.spells[i]
        if s then
            local kindTotal = s.kind == "heal" and snap.healing or snap.damage
            local c = s.kind == "heal" and C.heal or C.crit
            row.bar:SetVertexColor(c[1], c[2], c[3], 0.3)
            row.bar:SetWidth(math.max(1, 390 * s.total / topTotal))
            row.icon:SetTexture(s.icon or 134400)
            local values = {
                s.name, ns.Short(s.total), pct(s.total, kindTotal), s.hits,
                pct(s.crits, s.hits), ns.Short(s.hits > 0 and s.total / s.hits or 0), ns.Short(s.max),
            }
            for c2, cell in ipairs(row.cells) do cell:SetText(values[c2]) end
            row.cells[1]:SetTextColor(s.kind == "heal" and C.heal[1] or 1, s.kind == "heal" and C.heal[2] or 1,
                s.kind == "heal" and C.heal[3] or 1)
            row:Show()
        else
            row:Hide()
        end
    end
end

local function RefreshFights(j)
    local history = ns.Stats.char.history
    -- a selected fight that isn't stored (test fight) is shown on its own
    local list = history
    if Report.selected and not tContains(history, Report.selected) then
        list = { Report.selected }
        for _, s in ipairs(history) do list[#list + 1] = s end
    end
    if not Report.selected then Report.selected = list[1] end

    for i, snap in ipairs(list) do
        local r = ListRow(j, i)
        r.snap = snap
        r.top:SetText(when(snap.time) .. "  " .. fightTitle(snap))
        r.bottom:SetText(ns.Stats.FormatDuration(snap.duration) .. "   " .. ns.Short(snap.dps) .. " DPS   "
            .. pct(snap.crits, snap.hits) .. " crit")
        if snap == Report.selected then
            r.bg:SetColorTexture(1, 0.82, 0, 0.14)
        else
            r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
        end
        r:Show()
    end
    for i = #list + 1, #j.listRows do j.listRows[i]:Hide() end
    j.listChild:SetHeight(math.max(10, #list * LIST_ROW_H))

    if #list == 0 then
        j.empty:SetText(ns.db.stats.history.enabled and "No fights recorded yet."
            or "Fight history is turned off in the settings.")
        j.empty:Show()
    else
        j.empty:Hide()
    end
    RenderDetail(j.detail, Report.selected)
end

local function BuildRecordsPage(j, page)
    j.recTop = text(page, 12, false)
    j.recTop:SetPoint("TOPLEFT", 0, 0)
    j.recTop:SetPoint("RIGHT")
    j.recTop:SetJustifyH("LEFT")

    local headers = { { "Spell", 22 }, { "Best hit", 260 }, { "Best crit", 420 } }
    for _, h in ipairs(headers) do
        local fs = text(page, 10, false, GREY)
        fs:SetPoint("TOPLEFT", h[2], -40)
        fs:SetText(h[1])
    end

    local scroll, child = NewScroll(page)
    scroll:SetPoint("TOPLEFT", 0, -56)
    scroll:SetPoint("BOTTOMRIGHT", -24, 34)
    child:SetWidth(J_W - 60)
    j.recChild, j.recRows = child, {}

    local reset = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("BOTTOMLEFT", 0, 4)
    reset:SetText("Reset records")
    reset:SetScript("OnClick", function()
        Confirm("Reset all personal records for this character?", function()
            ns.Stats:ResetRecords()
            Report:RefreshJournal()
        end)
    end)
end

local function RecordRow(j, i)
    local r = j.recRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, j.recChild)
    r:SetSize(J_W - 60, 20)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT")
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = text(r, 11, false)
    r.name:SetPoint("LEFT", 22, 0)
    r.name:SetWidth(230)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.hit = text(r, 11, false)
    r.hit:SetPoint("LEFT", 260, 0)
    r.crit = text(r, 11, false)
    r.crit:SetPoint("LEFT", 420, 0)
    j.recRows[i] = r
    return r
end

local function RefreshRecords(j)
    local rec = ns.Stats.char.records
    local C = ns.db.colors
    local parts = {}
    if rec.bestDps then
        parts[#parts + 1] = string.format("Best DPS |cffffffff%s|r (%s, %s)", ns.Short(rec.bestDps.dps),
            ns.Stats.FormatDuration(rec.bestDps.duration), when(rec.bestDps.date, true))
    end
    if rec.longestStreak and rec.longestStreak > 0 then
        parts[#parts + 1] = "Longest crit streak |cffffffffx" .. rec.longestStreak .. "|r"
    end
    if not ns.db.stats.records.enabled then parts[#parts + 1] = "|cffaaaaaa(records are turned off in the settings)|r" end
    j.recTop:SetText(#parts > 0 and table.concat(parts, "     ") or "No records yet.")

    local list = {}
    for _, r in pairs(rec.spells) do list[#list + 1] = r end
    local function best(r) return math.max(r.crit and r.crit.amount or 0, r.hit and r.hit.amount or 0) end
    table.sort(list, function(a, b) return best(a) > best(b) end)

    for i, r in ipairs(list) do
        local row = RecordRow(j, i)
        row.icon:SetTexture(r.icon or 134400)
        row.name:SetText(r.name or "?")
        if r.kind == "heal" then
            row.name:SetTextColor(C.heal[1], C.heal[2], C.heal[3])
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.hit:SetText(r.hit and (ns.Full(r.hit.amount) .. "  |cffaaaaaa" .. when(r.hit.date, true) .. "|r") or "-")
        row.crit:SetText(r.crit and (ns.Full(r.crit.amount) .. "  |cffaaaaaa" .. when(r.crit.date, true) .. "|r") or "-")
        row.crit:SetTextColor(C.crit[1], C.crit[2], C.crit[3])
        row:Show()
    end
    for i = #list + 1, #j.recRows do j.recRows[i]:Hide() end
    j.recChild:SetHeight(math.max(10, #list * 20))
end

local SESSION_LINES = 12

local function BuildSessionPage(j, page)
    j.sessLabels, j.sessValues = {}, {}
    for i = 1, SESSION_LINES do
        local l = text(page, 12, false, GREY)
        l:SetPoint("TOPLEFT", 0, -(i - 1) * 22)
        local v = text(page, 12, false)
        v:SetPoint("TOPLEFT", 200, -(i - 1) * 22)
        j.sessLabels[i], j.sessValues[i] = l, v
    end
    local reset = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("BOTTOMLEFT", 0, 4)
    reset:SetText("Reset session")
    reset:SetScript("OnClick", function()
        ns.Stats:ResetSession()
        Report:RefreshJournal()
    end)
    page:SetScript("OnUpdate", function(self, dt)
        self.clock = (self.clock or 0) + dt
        if self.clock >= 1 then
            self.clock = 0
            Report:RefreshJournal()
        end
    end)
end

local function money(copper)
    if GetCoinTextureString then return GetCoinTextureString(copper or 0) end
    return string.format("%.2fg", (copper or 0) / 10000)
end

local function RefreshSession(j)
    local lines = {}
    local i = ns.db.session.enabled and ns.Stats:SessionInfo()
    if not ns.db.session.enabled then
        lines[1] = { "Session tracking is turned off in the settings.", "" }
    elseif not i then
        lines[1] = { "No session data yet.", "" }
    else
        local F = ns.Stats.FormatDuration
        lines[#lines + 1] = { "Session time", F(i.elapsed) }
        lines[#lines + 1] = { "Time in combat", F(i.combatTime) .. "  (" .. pct(i.combatTime, i.elapsed) .. ")" }
        lines[#lines + 1] = { "Fights / kills / deaths", i.fights .. " / " .. i.kills .. " / " .. i.deaths }
        if not i.atMax then
            lines[#lines + 1] = { "XP gained", ns.Full(i.xp) .. (i.levels > 0 and ("  (" .. i.levels .. " level-ups)") or "") }
            lines[#lines + 1] = { "XP per hour", i.xpPerHour and ns.Full(i.xpPerHour) or "-" }
            lines[#lines + 1] = { "Time to level", i.timeToLevel and F(i.timeToLevel) or "-" }
            lines[#lines + 1] = { "XP per kill", i.avgKillXp and ns.Full(i.avgKillXp) or "-" }
            lines[#lines + 1] = { "Kills to level", i.killsToLevel and tostring(i.killsToLevel) or "-" }
            lines[#lines + 1] = { "Rested XP", i.rested and ns.Full(i.rested) or "none" }
        end
        lines[#lines + 1] = { "Money looted / spent", money(i.moneyIn) .. "  /  " .. money(i.moneyOut) }
    end
    for n = 1, SESSION_LINES do
        local line = lines[n]
        j.sessLabels[n]:SetText(line and line[1] or "")
        j.sessValues[n]:SetText(line and line[2] or "")
    end
end

local TABS = {
    { "fights", "Fights", BuildFightsPage, RefreshFights },
    { "records", "Records", BuildRecordsPage, RefreshRecords },
    { "session", "Session", BuildSessionPage, RefreshSession },
}

local function CreateJournal()
    local j = CreateFrame("Frame", "WombatLogJournal", UIParent)
    j:SetSize(J_W, J_H)
    j:SetPoint("CENTER")
    j:SetFrameStrata("DIALOG")
    j:SetClampedToScreen(true)
    j:SetMovable(true)
    j:EnableMouse(true)
    j:RegisterForDrag("LeftButton")
    j:SetScript("OnDragStart", j.StartMoving)
    j:SetScript("OnDragStop", j.StopMovingOrSizing)
    j:Hide()
    tinsert(UISpecialFrames, "WombatLogJournal")

    local bg = j:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.06, 0.94)
    border(j, 1, 1, 1, 0.12)

    local title = text(j, 15, true)
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("WombatLog Journal")
    local close = CreateFrame("Button", nil, j, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    j.tabs, j.pages = {}, {}
    for i, def in ipairs(TABS) do
        local tab = CreateFrame("Button", nil, j)
        tab:SetSize(92, 22)
        tab:SetPoint("TOPLEFT", 14 + (i - 1) * 96, -38)
        local tbg = tab:CreateTexture(nil, "BACKGROUND")
        tbg:SetAllPoints()
        tbg:SetColorTexture(1, 1, 1, 0.05)
        local hl = tab:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        tab.underline = tab:CreateTexture(nil, "ARTWORK")
        tab.underline:SetColorTexture(1, 0.82, 0, 0.9)
        tab.underline:SetHeight(2)
        tab.underline:SetPoint("BOTTOMLEFT")
        tab.underline:SetPoint("BOTTOMRIGHT")
        tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tab.label:SetPoint("CENTER")
        tab.label:SetText(def[2])
        tab:SetScript("OnClick", function() Report:SelectTab(def[1]) end)
        j.tabs[def[1]] = tab

        local page = CreateFrame("Frame", nil, j)
        page:SetPoint("TOPLEFT", 14, -72)
        page:SetPoint("BOTTOMRIGHT", -14, 10)
        page:Hide()
        def[3](j, page)
        j.pages[def[1]] = page
    end
    return j
end

function Report:SelectTab(key)
    local j = self.journal
    self.tab = key
    for k, page in pairs(j.pages) do
        local on = k == key
        page:SetShown(on)
        j.tabs[k].underline:SetShown(on)
        j.tabs[k].label:SetTextColor(on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
    end
    self:RefreshJournal()
end

function Report:RefreshJournal()
    local j = self.journal
    if not j or not j:IsShown() then return end
    for _, def in ipairs(TABS) do
        if def[1] == self.tab then def[4](j) end
    end
end

function Report:OpenJournal(tab, snap)
    if snap then self.selected = snap end
    self.journal:Show()
    self:SelectTab(tab or self.tab or "fights")
end

function Report:ToggleJournal(tab)
    if self.journal:IsShown() and (not tab or tab == self.tab) then
        self.journal:Hide()
    else
        self:OpenJournal(tab)
    end
end

---------------------------------------------------------------------------
-- Init and settings
---------------------------------------------------------------------------

function Report:Init()
    self.summary = CreateSummary()
    self.journal = CreateJournal()
    self.tab = "fights"
    self:Apply()
end

function Report:Apply()
    local f = self.summary
    if not f then return end
    local cfg = ns.db.stats.summary
    f:SetScale(cfg.scale)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", cfg.x, cfg.y)
    if not cfg.enabled then self:HideSummary() end
    self:RefreshJournal()
end
