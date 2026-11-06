local ADDON, ns = ...
local MB = {}
ns.MacroBuilder = MB
local L = ns.L

-- A window that builds macros from blocks: each line is a command with its parts
-- ("[mod:shift,@focus] Polymorph; Polymorph"), each part a set of condition chips and
-- a spell slot that takes spells and items dragged from the spellbook or the bags.
-- It reads existing macros back into blocks, counts the characters, checks spells
-- and conditions, shows live which part of each line would run right now and saves
-- straight into the game's macros.

local W, H = 880, 600
local LIST_W = 200
local RX = 14 + LIST_W + 16        -- the builder's left edge
local RW = W - RX - 14             -- and its width
local CW = RW - 30                 -- a line card's width (room for the scroll bar)
local ARG_W = 190
local MAX_BODY = 255
local MAX_NAME = 16
local QUESTION = 134400            -- INV_Misc_QuestionMark: with #showtooltip, the spell's icon
local GREEN_DOT = "|TInterface\\COMMON\\Indicator-Green:12|t "
local GREY_DOT = "|TInterface\\COMMON\\Indicator-Gray:12|t "

-- arg: what goes after the conditions. "spell" (spells and items), "item",
-- "sequence" (reset= and a comma list), "list" (a comma list), "unit"; optional: may stay empty.
local CMD = {
    ["/cast"] = { arg = "spell" }, ["/use"] = { arg = "spell" },
    ["/castsequence"] = { arg = "sequence" }, ["/castrandom"] = { arg = "list" },
    ["/target"] = { arg = "unit", optional = true }, ["/focus"] = { arg = "unit", optional = true },
    ["/assist"] = { arg = "unit", optional = true }, ["/targetenemy"] = {},
    ["/cleartarget"] = {}, ["/clearfocus"] = {},
    ["/startattack"] = { arg = "unit", optional = true }, ["/stopattack"] = {}, ["/stopcasting"] = {},
    ["/cancelaura"] = { arg = "spell" }, ["/cancelform"] = {}, ["/dismount"] = {},
    ["/equip"] = { arg = "item" },
    ["/petattack"] = { arg = "unit", optional = true }, ["/petfollow"] = {},
    ["/petpassive"] = {}, ["/petdefensive"] = {},
    ["/stopmacro"] = {},
}

-- The "+ line" menu: headers and commands with a short description, translated on display.
local COMMAND_MENU = {
    { "Spells & items" },
    { "/cast", "Cast a spell" }, { "/use", "Use an item or a spell" },
    { "/castsequence", "Cast spells in turn" }, { "/castrandom", "Cast a random one" },
    { "Targeting" },
    { "/target", "Target a unit" }, { "/focus", "Set your focus" },
    { "/assist", "Target what a unit targets" }, { "/targetenemy", "Next enemy" },
    { "/cleartarget", "Clear your target" }, { "/clearfocus", "Clear your focus" },
    { "Combat" },
    { "/startattack", "Start auto-attack" }, { "/stopattack", "Stop auto-attack" },
    { "/stopcasting", "Stop the current cast" }, { "/cancelaura", "Remove a buff" },
    { "/cancelform", "Leave your form" }, { "/dismount", "Get off your mount" },
    { "/equip", "Equip an item" },
    { "Pet" },
    { "/petattack", "Your pet attacks" }, { "/petfollow", "Your pet follows you" },
    { "/petpassive", "Your pet goes passive" }, { "/petdefensive", "Your pet goes defensive" },
    { "Other" },
    { "#showtooltip", "The icon and tooltip" }, { "/stopmacro", "Stop the macro here" },
    { "raw", "Free text" },
}

-- Conditions: the token, its label and the label of its "no" form.
local CONDITIONS = {
    { "Modifier keys" },
    { "mod:shift", "Shift", "No Shift" }, { "mod:ctrl", "Ctrl", "No Ctrl" },
    { "mod:alt", "Alt", "No Alt" }, { "mod", "Any modifier", "No modifier" },
    { "The unit" },
    { "exists", "Exists", "Doesn't exist" }, { "harm", "Enemy", "Not an enemy" },
    { "help", "Friendly", "Not friendly" }, { "dead", "Dead", "Alive" },
    { "You" },
    { "combat", "In combat", "Out of combat" }, { "stealth", "Stealthed", "Not stealthed" },
    { "mounted", "Mounted", "Not mounted" }, { "flying", "Flying", "Not flying" },
    { "swimming", "Swimming", "Not swimming" }, { "indoors", "Indoors", "Not indoors" },
    { "outdoors", "Outdoors", "Not outdoors" }, { "group", "In a group", "Not in a group" },
    { "group:raid", "In a raid", "Not in a raid" }, { "channeling", "Channeling", "Not channeling" },
    { "pet", "Pet out", "No pet" },
    { "Mouse" },
    { "button:2", "Right-click", "Not right-click" },
}

-- Who a part acts on (@unit).
local TARGETS = {
    { "target", "Target" }, { "focus", "Focus" }, { "mouseover", "Mouseover" },
    { "player", "Yourself" }, { "pet", "Pet" }, { "targettarget", "Target's target" },
    { "cursor", "Cursor (ground spells)" }, { "party1", "Party member 1" }, { "party2", "Party member 2" },
}

-- Every condition the game knows, for the check (without "no" and the ":value").
local KNOWN = {}
for _, k in ipairs({ "act", "actionbar", "advflyable", "bar", "bonusbar", "btn", "button",
    "canexitvehicle", "channel", "channeling", "combat", "cursor", "dead", "equipped", "exists",
    "extrabar", "flyable", "flying", "form", "group", "harm", "help", "indoors", "known", "mod",
    "modifier", "mounted", "outdoors", "overridebar", "party", "pet", "petbattle", "possessbar",
    "pvptalent", "raid", "resting", "shapeshift", "spec", "stance", "stealth", "swimming", "talent",
    "unithasvehicleui", "vehicleui", "worn" }) do
    KNOWN[k] = true
end

local COND_BY_TOKEN = {}
for _, e in ipairs(CONDITIONS) do
    if e[2] then COND_BY_TOKEN[e[1]] = e end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safe(fn, ...)
    if not fn then return end
    local ok, v = pcall(fn, ...)
    if ok then return v end
end

-- "|" starts an escape code in a font string
local function plain(s)
    return (tostring(s or ""):gsub("|", "||"))
end

local function spellTexture(x)
    if C_Spell and C_Spell.GetSpellTexture then
        local t = safe(C_Spell.GetSpellTexture, x)
        if t then return t end
    end
    return safe(GetSpellTexture, x)
end

local function itemInfoInstant(x)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not fn then return end
    local ok, id, _, _, _, icon = pcall(fn, x)
    if ok then return id, icon end
end

local function iconOf(name)
    name = trim(name):gsub("^!", "")
    if name == "" then return end
    return spellTexture(name) or select(2, itemInfoInstant(name))
end

local function knownSpell(name)
    if C_Spell and C_Spell.GetSpellInfo and safe(C_Spell.GetSpellInfo, name) then return true end
    return safe(GetSpellInfo, name) ~= nil
end

local function haveItem(name)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    local n = safe(count, name)
    if type(n) == "number" and n > 0 then return true end
    local equipped = (C_Item and C_Item.IsEquippedItem) or IsEquippedItem
    return safe(equipped, name) == true
end

-- The spell or item on the cursor (dragged from the spellbook, the bags or a bar):
-- its name and icon.
local function cursorThing()
    local ok, kind, a, b, c = pcall(GetCursorInfo)
    if not ok or not kind then return end
    local name, icon
    if kind == "spell" then
        if type(c) == "number" then
            name = (C_Spell and safe(C_Spell.GetSpellName, c)) or safe(GetSpellInfo, c)
            icon = spellTexture(c)
        end
        if not name and type(a) == "number" then
            name = safe(GetSpellBookItemName, a, b)
            if not name and C_SpellBook and C_SpellBook.GetSpellBookItemName then
                name = safe(C_SpellBook.GetSpellBookItemName, a, b == "pet" and 1 or 0)
            end
        end
        if name and not icon then icon = spellTexture(name) end
    elseif kind == "item" then
        name = (C_Item and safe(C_Item.GetItemNameByID, a)) or safe(GetItemInfo, a)
        if not name and type(b) == "string" then name = b:match("%[(.-)%]") end
        icon = select(2, itemInfoInstant(a))
    end
    if name and name ~= "" then return name, icon end
end

---------------------------------------------------------------------------
-- Macro text <-> blocks
---------------------------------------------------------------------------
-- A macro: { name, icon, perChar, index, lines }. A line is one of
--   { kind = "show", tag = "#showtooltip", arg = "Fireball" }
--   { kind = "cmd", cmd = "/cast", clauses = { clause, ... } }
--   { kind = "raw", text = "/say Hello" }   (anything the blocks don't cover)
-- A clause is one ";" part: { groups = { group, ... }, arg = "Polymorph", reset = "target" },
-- each group one [...] (several groups: either one), { target = "focus", conds = { "harm" } }.

local function newClause() return { groups = {}, arg = "" } end

local function newLine(cmd)
    if cmd == "#showtooltip" or cmd == "#show" then return { kind = "show", tag = cmd, arg = "" } end
    if cmd == "raw" then return { kind = "raw", text = "" } end
    return { kind = "cmd", cmd = cmd, clauses = { newClause() } }
end

-- Splits at sep outside of [...].
local function splitTop(s, sep)
    local parts, depth, start = {}, 0, 1
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "[" then depth = depth + 1
        elseif ch == "]" then depth = math.max(depth - 1, 0)
        elseif ch == sep and depth == 0 then
            parts[#parts + 1] = s:sub(start, i - 1)
            start = i + 1
        end
    end
    parts[#parts + 1] = s:sub(start)
    return parts
end

local function parseGroup(inner)
    local g = { conds = {} }
    for token in inner:gmatch("[^,]+") do
        local t = trim(token)
        local unit = t:match("^@(.+)$") or t:match("^[Tt][Aa][Rr][Gg][Ee][Tt]%s*=%s*(.+)$")
        if unit then
            g.target = trim(unit)
        elseif t ~= "" then
            g.conds[#g.conds + 1] = t
        end
    end
    return g
end

local function parseClause(text, spec)
    local c = newClause()
    local rest = trim(text)
    while true do
        local inner, after = rest:match("^%[([^%]]*)%](.*)$")
        if not inner then break end
        c.groups[#c.groups + 1] = parseGroup(inner)
        rest = trim(after)
    end
    if spec.arg == "sequence" then
        local r, after = rest:match("^[Rr][Ee][Ss][Ee][Tt]=(%S+)%s*(.*)$")
        if r then c.reset, rest = r, after end
    end
    c.arg = trim(rest)
    return c
end

local function parseLine(text)
    text = trim(text)
    if text == "" then return end
    local tag, arg = text:match("^(#%a+)%s*(.*)$")
    if tag and (tag:lower() == "#showtooltip" or tag:lower() == "#show") then
        return { kind = "show", tag = tag:lower(), arg = trim(arg) }
    end
    local cmd, rest = text:match("^(/%S+)%s*(.*)$")
    local spec = cmd and CMD[cmd:lower()]
    if spec then
        local line = { kind = "cmd", cmd = cmd:lower(), clauses = {} }
        for _, part in ipairs(splitTop(rest, ";")) do
            local c = parseClause(part, spec)
            -- an empty part (a trailing ";") adds nothing
            if #c.groups > 0 or c.arg ~= "" or (c.reset or "") ~= "" or #line.clauses == 0 then
                line.clauses[#line.clauses + 1] = c
            end
        end
        return line
    end
    return { kind = "raw", text = text }
end

local function parseBody(body)
    local lines = {}
    for text in (tostring(body or "") .. "\n"):gmatch("(.-)\r?\n") do
        local line = parseLine(text)
        if line then lines[#lines + 1] = line end
    end
    return lines
end

local function groupText(g)
    local parts = {}
    if g.target and g.target ~= "" then parts[1] = "@" .. g.target end
    for _, c in ipairs(g.conds) do parts[#parts + 1] = c end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function clauseText(line, c)
    local spec = CMD[line.cmd]
    local s = ""
    for _, g in ipairs(c.groups) do s = s .. groupText(g) end
    local arg = spec.arg and trim(c.arg) or ""
    if spec.arg == "sequence" and trim(c.reset) ~= "" then
        arg = trim("reset=" .. trim(c.reset) .. " " .. arg)
    end
    if arg ~= "" then s = s == "" and arg or (s .. " " .. arg) end
    return s
end

-- The part after the command: what SecureCmdOptionParse reads.
local function optionsText(line)
    local parts = {}
    for _, c in ipairs(line.clauses) do
        local t = clauseText(line, c)
        if t ~= "" then parts[#parts + 1] = t end
    end
    return table.concat(parts, "; ")
end

local function lineText(line)
    if line.kind == "show" then
        return line.arg ~= "" and (line.tag .. " " .. trim(line.arg)) or line.tag
    elseif line.kind == "raw" then
        return trim(line.text)
    end
    local o = optionsText(line)
    return o ~= "" and (line.cmd .. " " .. o) or line.cmd
end

local function buildBody(m)
    local out = {}
    for _, line in ipairs(m.lines) do
        local t = lineText(line)
        if t ~= "" then out[#out + 1] = t end
    end
    return table.concat(out, "\n")
end

-- Turns a line into another command, keeping what fits.
local function convert(line, cmd)
    local new
    if cmd == "raw" then
        new = { kind = "raw", text = lineText(line) }
    elseif cmd:sub(1, 1) == "#" then
        local arg = line.kind == "show" and line.arg or ""
        if line.kind == "cmd" and CMD[line.cmd].arg then arg = line.clauses[#line.clauses].arg end
        new = { kind = "show", tag = cmd, arg = arg or "" }
    elseif line.kind == "cmd" then
        line.cmd = cmd
        return
    else
        if line.kind == "raw" then
            local rest = line.text:match("^/%S+%s*(.*)$") or line.text
            new = parseLine(cmd .. " " .. rest)
        end
        if not new or new.kind ~= "cmd" then
            new = newLine(cmd)
            if line.kind == "show" then new.clauses[1].arg = line.arg end
        end
    end
    wipe(line)
    for k, v in pairs(new) do line[k] = v end
end

-- The spells and items a macro names, in order.
local function namesIn(m)
    local list = {}
    local function add(text)
        for name in tostring(text or ""):gmatch("[^,]+") do
            name = trim(name):gsub("^!", "")
            if name ~= "" then list[#list + 1] = name end
        end
    end
    for _, line in ipairs(m.lines) do
        if line.kind == "show" then
            add(line.arg)
        elseif line.kind == "cmd" then
            local a = CMD[line.cmd].arg
            if a == "spell" or a == "item" or a == "sequence" or a == "list" then
                for _, c in ipairs(line.clauses) do add(c.arg) end
            end
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Conditions: labels, "no" forms, the check
---------------------------------------------------------------------------

local function baseName(token)
    return (token:lower():match("^[^:]+") or "")
end

-- "nocombat" -> "combat", true
local function splitNeg(token)
    local t = trim(token):lower()
    if t:sub(1, 2) == "no" and KNOWN[baseName(t:sub(3))] then return t:sub(3), true end
    return t, false
end

local function flip(token)
    local base, neg = splitNeg(token)
    return neg and base or ("no" .. base)
end

local function condLabel(token)
    local base, neg = splitNeg(token)
    local e = COND_BY_TOKEN[base]
    if e then return L[neg and e[3] or e[2]] end
    local name, val = base:match("^(%a+):(.+)$")
    if name == "form" or name == "stance" then return (neg and L["Not form %s"] or L["Form %s"]):format(val) end
    if name == "spec" then return (neg and L["Not spec %s"] or L["Spec %s"]):format(val) end
    return token
end

local function targetLabel(unit)
    for _, t in ipairs(TARGETS) do
        if t[1] == unit:lower() then return L[t[2]] end
    end
    return unit
end

---------------------------------------------------------------------------
-- Checks and the live preview
---------------------------------------------------------------------------

local function validate(m, body)
    local errors, warnings = {}, {}
    if #body > MAX_BODY then
        errors[#errors + 1] = L["Too long: %d of %d characters."]:format(#body, MAX_BODY)
    end
    if trim(m.name) == "" then errors[#errors + 1] = L["Give the macro a name."] end
    local n = 0
    for _, line in ipairs(m.lines) do
        if lineText(line) ~= "" then
            n = n + 1
            if line.kind == "show" and n > 1 then
                warnings[#warnings + 1] = L["Line %d: #showtooltip only works on the first line."]:format(n)
            elseif line.kind == "cmd" then
                local spec = CMD[line.cmd]
                local missing = false
                for _, c in ipairs(line.clauses) do
                    for _, g in ipairs(c.groups) do
                        for _, token in ipairs(g.conds) do
                            local base = splitNeg(token)
                            if not KNOWN[baseName(base)] then
                                warnings[#warnings + 1] = L["Line %d: unknown condition \"%s\"."]:format(n, plain(token))
                            end
                        end
                    end
                    if spec.arg and not spec.optional and trim(c.arg) == "" then missing = true end
                    if spec.arg == "spell" or spec.arg == "item" or spec.arg == "sequence" or spec.arg == "list" then
                        for name in c.arg:gmatch("[^,]+") do
                            name = trim(name):gsub("^!", "")
                            -- slot numbers (13, 14) and item:12345 always work
                            if name ~= "" and not tonumber(name) and not name:lower():find("^item:%d+")
                                and not knownSpell(name) and not haveItem(name) then
                                warnings[#warnings + 1] = L["Line %d: \"%s\" is not in your spellbook or bags."]:format(n, plain(name))
                            end
                        end
                    end
                end
                if missing then warnings[#warnings + 1] = L["Line %d: no spell or item chosen yet."]:format(n) end
            end
        end
    end
    return errors, warnings
end

-- What a line does right now: "fires", action, target; "skips"; or nil (can't tell).
local function evaluate(line)
    if line.kind ~= "cmd" or not SecureCmdOptionParse then return end
    local o = optionsText(line)
    if o == "" then return "fires", "" end
    local ok, action, target = pcall(SecureCmdOptionParse, o)
    if not ok then return end
    if action == nil then return "skips" end
    return "fires", action, target
end

---------------------------------------------------------------------------
-- Widgets: pools, a pop-up menu, a text prompt
---------------------------------------------------------------------------

local Pool = {}
Pool.__index = Pool

local function NewPool(create)
    return setmetatable({ create = create, all = {}, n = 0 }, Pool)
end

function Pool:Get()
    self.n = self.n + 1
    local o = self.all[self.n]
    if not o then
        o = self.create()
        self.all[self.n] = o
    end
    o:ClearAllPoints()
    o:Show()
    return o
end

function Pool:Reset()
    for _, o in ipairs(self.all) do
        if o.ClearFocus then
            o.onChange, o.onDrop = nil, nil
            o:ClearFocus()
        end
        o:Hide()
    end
    self.n = 0
end

local function border(frame, r, g, b, a)
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
                            { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, a)
        t:SetPoint(side[1])
        t:SetPoint(side[2])
        if side[3] then t:SetWidth(side[3]) else t:SetHeight(side[4]) end
    end
end

local function showTip(self)
    if not self.tipTitle then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.tipTitle)
    if self.tipText then GameTooltip:AddLine(self.tipText, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
end

local function hideTip() GameTooltip:Hide() end

local function tip(w, title, text)
    w.tipTitle, w.tipText = title, text
    w:SetScript("OnEnter", showTip)
    w:SetScript("OnLeave", hideTip)
end

local menu

local function HideMenu()
    if menu then menu.blocker:Hide() end
end

-- entries: { text, func } or { text, header = true }; long lists run in columns.
local function ShowMenu(anchor, entries)
    if not menu then
        local blocker = CreateFrame("Button", nil, UIParent)
        blocker:SetAllPoints(UIParent)
        blocker:SetFrameStrata("FULLSCREEN_DIALOG")
        blocker:RegisterForClicks("AnyUp")
        blocker:SetScript("OnClick", HideMenu)
        blocker:Hide()
        menu = CreateFrame("Frame", nil, blocker)
        menu:SetFrameLevel(blocker:GetFrameLevel() + 5)
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        local bg = menu:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.06, 0.08, 0.97)
        border(menu, 1, 1, 1, 0.15)
        menu.blocker, menu.items = blocker, {}
    end
    local ROWS, ROW_H = 16, 18
    local colW = 120
    for i, e in ipairs(entries) do
        local item = menu.items[i]
        if not item then
            item = CreateFrame("Button", nil, menu)
            item:SetHeight(ROW_H)
            item.hl = item:CreateTexture(nil, "HIGHLIGHT")
            item.hl:SetAllPoints()
            item.hl:SetColorTexture(1, 1, 1, 0.1)
            item.text = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            item.text:SetPoint("LEFT", 8, 0)
            item:SetScript("OnClick", function(self)
                HideMenu()
                if self.func then self.func() end
            end)
            menu.items[i] = item
        end
        item.text:SetText(e[1])
        item.func = e[2]
        if e.header then
            item.text:SetFontObject("GameFontNormalSmall")
            item:EnableMouse(false)
        else
            item.text:SetFontObject("GameFontHighlightSmall")
            item:EnableMouse(true)
        end
        colW = math.max(colW, item.text:GetStringWidth() + 20)
        item:Show()
    end
    for i = #entries + 1, #menu.items do menu.items[i]:Hide() end
    local col, row, rows = 0, 0, 0
    for i, e in ipairs(entries) do
        -- a new column when this one is full, or when a header would be left at its bottom
        if row >= ROWS or (e.header and row > ROWS - 3 and row > 0) then
            col, row = col + 1, 0
        end
        local item = menu.items[i]
        item:ClearAllPoints()
        item:SetWidth(colW)
        item:SetPoint("TOPLEFT", 4 + col * colW, -4 - row * ROW_H)
        row = row + 1
        rows = math.max(rows, row)
    end
    menu:SetSize((col + 1) * colW + 8, rows * ROW_H + 8)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    menu.blocker:Show()
end

StaticPopupDialogs.WOMBATLOG_MACRO_INPUT = {
    text = "%s",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    editBoxWidth = 240,
    OnShow = function(self)
        local e = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
        if e then
            e:SetText("")
            e:SetFocus()
        end
    end,
    OnAccept = function(self, fn)
        local e = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
        if e and fn then fn(e:GetText()) end
    end,
    EditBoxOnEnterPressed = function(self)
        local popup = self:GetParent()
        if popup.data then popup.data(self:GetText()) end
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Prompt(text, fn)
    StaticPopup_Show("WOMBATLOG_MACRO_INPUT", text, nil, function(v)
        v = trim(v)
        if v ~= "" then fn(v) end
    end)
end

local function Confirm(text, fn)
    StaticPopup_Show("WOMBATLOG_CONFIRM", text, nil, fn)
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local f          -- the window
local cur        -- the macro in the builder
local dirty = false
local pools = {}

local function changed(structural)
    dirty = true
    if structural then MB:Render() else MB:UpdatePreview() end
end

-- Drops the spell or item on the cursor into an edit box: replaces its text, or adds
-- to the list for /castsequence and /castrandom.
local function acceptDrop(e)
    local name = cursorThing()
    if not name or not e.onDrop then return end
    ClearCursor()
    e.onDrop(name)
end

local function NewEditBox(parent)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetAutoFocus(false)
    e:SetHeight(20)
    e.ph = e:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    e.ph:SetPoint("LEFT", 1, 0)
    e.ph:SetPoint("RIGHT", -2, 0)
    e.ph:SetJustifyH("LEFT")
    e.ph:SetWordWrap(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e:SetScript("OnTextChanged", function(self, user)
        self.ph:SetShown(self:GetText() == "" and not self:HasFocus())
        if user and self.onChange then self.onChange(self:GetText()) end
    end)
    e:SetScript("OnEditFocusGained", function(self) self.ph:Hide() end)
    e:SetScript("OnEditFocusLost", function(self)
        self:HighlightText(0, 0)
        self.ph:SetShown(self:GetText() == "")
    end)
    e:SetScript("OnReceiveDrag", acceptDrop)
    e:SetScript("OnMouseUp", function(self) if GetCursorInfo() then acceptDrop(self) end end)
    return e
end

local function SetupEditBox(e, x, y, w, text, placeholder, onChange, onDrop)
    e:SetPoint("TOPLEFT", f.child, "TOPLEFT", x + 6, y)
    e:SetWidth(w - 6)
    e:SetText(text or "")
    e:SetCursorPosition(0)
    e.ph:SetText(placeholder or "")
    e.ph:SetShown((text or "") == "")
    e.onChange, e.onDrop = onChange, onDrop
    e.tipTitle, e.tipText = nil, nil
    e:SetScript("OnEnter", nil)
    e:SetScript("OnLeave", nil)
end

local function NewChip(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(18)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if self.onRight then self.onRight(self) end
        elseif self.onLeft then
            self.onLeft(self)
        end
    end)
    return b
end

local CHIP_COLORS = {
    target = { 0.20, 0.45, 0.85, 0.45 },
    cond = { 0.85, 0.65, 0.10, 0.35 },
    neg = { 0.85, 0.25, 0.20, 0.40 },
    add = { 1, 1, 1, 0.08 },
}

local function NewIconButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(16, 16)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    return b
end

local function NewCard(parent)
    local c = CreateFrame("Frame", nil, parent)
    local bg = c:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.04)
    c.accent = c:CreateTexture(nil, "ARTWORK")
    c.accent:SetPoint("TOPLEFT")
    c.accent:SetPoint("BOTTOMLEFT")
    c.accent:SetWidth(2)
    return c
end

local function at(w, x, y)
    w:SetPoint("TOPLEFT", f.child, "TOPLEFT", x, y)
end

local LABEL_COLORS = {
    GameFontDisableSmall = { 0.6, 0.6, 0.6 },
    GameFontNormal = { 1, 0.82, 0 },
    GameFontHighlightSmall = { 1, 1, 1 },
}

local function Label(x, y, text, font)
    local fs = pools.text:Get()
    font = font or "GameFontDisableSmall"
    fs:SetFontObject(font)
    local c = LABEL_COLORS[font]
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetWidth(0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(text)
    at(fs, x, y)
    return fs
end

local function Chip(text, kind)
    local b = pools.chip:Get()
    b.text:SetText(text)
    b:SetWidth(math.ceil(b.text:GetStringWidth()) + 14)
    local c = CHIP_COLORS[kind]
    b.bg:SetColorTexture(c[1], c[2], c[3], c[4])
    b.onLeft, b.onRight = nil, nil
    tip(b, nil, nil)
    return b
end

local function IconButton(x, y, texture, title, onClick)
    local b = pools.icon:Get()
    b.icon:SetTexture(texture)
    at(b, x, y)
    b:SetScript("OnClick", onClick)
    tip(b, title)
    return b
end

local function TextButton(x, y, w, text, onClick)
    local b = pools.button:Get()
    b:SetSize(w, 20)
    b:SetText(text)
    at(b, x, y)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnReceiveDrag", nil)
    tip(b, nil)
    return b
end

-- The command menu, for a new line or to change one.
local function commandEntries(onPick)
    local list = {}
    for _, e in ipairs(COMMAND_MENU) do
        if e[2] then
            local label = e[1] == "raw" and L["Text"] or e[1]
            list[#list + 1] = { label .. "  |cff999999" .. L[e[2]] .. "|r", function() onPick(e[1]) end }
        else
            list[#list + 1] = { L[e[1]], header = true }
        end
    end
    return list
end

local function targetEntries(onPick)
    local list = { { L["Who it acts on"], header = true } }
    list[#list + 1] = { L["Current target (default)"], function() onPick(nil) end }
    for _, t in ipairs(TARGETS) do
        list[#list + 1] = { L[t[2]] .. "  |cff999999@" .. t[1] .. "|r", function() onPick(t[1]) end }
    end
    list[#list + 1] = { L["Other unit or name..."], function()
        Prompt(L["A unit (party3, arena1, focustarget) or a player's name:"], function(v)
            onPick((v:gsub("^@", "")))
        end)
    end }
    return list
end

-- Removes groups left without target and conditions: an empty [] would always match.
local function tidy(clause)
    for i = #clause.groups, 1, -1 do
        local g = clause.groups[i]
        if not g.target and #g.conds == 0 then table.remove(clause.groups, i) end
    end
end

-- The "+" menu on a part: who it acts on, conditions, and an "or" group.
-- newGroup: what is picked goes into a new [...] group.
local function conditionEntries(clause, anchor, newGroup)
    local function group()
        local g = clause.groups[#clause.groups]
        if newGroup or not g then
            g = { conds = {} }
            clause.groups[#clause.groups + 1] = g
        end
        return g
    end
    local function addCond(token)
        local g = group()
        local base = splitNeg(token)
        for i, t in ipairs(g.conds) do
            if splitNeg(t) == base then
                g.conds[i] = token
                changed(true)
                return
            end
        end
        g.conds[#g.conds + 1] = token
        changed(true)
    end
    local list = targetEntries(function(unit)
        local g = clause.groups[#clause.groups]
        if unit or newGroup or g then
            group().target = unit
            tidy(clause)
            changed(true)
        end
    end)
    for _, e in ipairs(CONDITIONS) do
        if e[2] then
            list[#list + 1] = { L[e[2]], function() addCond(e[1]) end }
        else
            list[#list + 1] = { L[e[1]], header = true }
        end
    end
    list[#list + 1] = { L["Form or stance..."], function()
        Prompt(L["Form or stance number (0 = none):"], function(v)
            if tonumber(v) then addCond("form:" .. v) end
        end)
    end }
    list[#list + 1] = { L["Other condition..."], function()
        Prompt(L["A condition as in a macro, for example equipped:Shields or spec:2:"], function(v)
            v = v:gsub("[%[%]%s]", "")
            if v ~= "" then addCond(v) end
        end)
    end }
    if #clause.groups > 0 and not newGroup then
        list[#list + 1] = { L["Or"], header = true }
        list[#list + 1] = { L["Add an \"or\" group..."], function()
            ShowMenu(anchor, conditionEntries(clause, anchor, true))
        end }
    end
    return list
end

local function renderClauses(line, top)
    local spec = CMD[line.cmd]
    local chipMax = spec.arg and (CW - ARG_W - 40) or (CW - 40)
    local argX = CW - ARG_W - 28
    local y = top
    for ci, clause in ipairs(line.clauses) do
        local x, rowY = 10, y
        -- chips run left to right and wrap under the first one
        local function place(w, h)
            local width = w.GetStringWidth and w:GetStringWidth() or w:GetWidth()
            if x + width > chipMax and x > 10 then
                x, rowY = 30, rowY - 20
            end
            w:ClearAllPoints()
            at(w, x, rowY - (h or 0))
            x = x + width + 4
        end
        if ci > 1 then
            place(Label(0, 0, L["otherwise"]), 3)
        end
        for gi, g in ipairs(clause.groups) do
            if gi > 1 then
                place(Label(0, 0, L["or"]), 3)
            end
            if g.target then
                local b = Chip("@ " .. targetLabel(g.target), "target")
                b.onLeft = function(self)
                    ShowMenu(self, targetEntries(function(unit)
                        g.target = unit
                        tidy(clause)
                        changed(true)
                    end))
                end
                b.onRight = function()
                    g.target = nil
                    tidy(clause)
                    changed(true)
                end
                tip(b, targetLabel(g.target), "@" .. plain(g.target) .. "\n" .. L["Click: change   Right-click: remove"])
                place(b)
            end
            for ti, token in ipairs(g.conds) do
                local _, neg = splitNeg(token)
                local b = Chip(condLabel(token), neg and "neg" or "cond")
                b.onLeft = function()
                    g.conds[ti] = flip(token)
                    changed(true)
                end
                b.onRight = function()
                    table.remove(g.conds, ti)
                    tidy(clause)
                    changed(true)
                end
                tip(b, condLabel(token), plain(token) .. "\n" .. L["Click: flip   Right-click: remove"])
                place(b)
            end
        end
        local add = Chip(#clause.groups == 0 and L["+ condition"] or "+", "add")
        add.onLeft = function(self) ShowMenu(self, conditionEntries(clause, self)) end
        tip(add, L["Add a condition"], L["Without conditions this part always runs. With several, all of them must hold; an \"or\" group is an alternative set."])
        place(add)

        if spec.arg == "sequence" then
            local r = pools.edit:Get()
            SetupEditBox(r, argX, y, 64, clause.reset, L["reset"], function(v)
                clause.reset = v
                changed()
            end)
            tip(r, L["Reset"], L["When the sequence starts over: seconds (5), target, combat, shift, ctrl or alt, joined with / (target/5)."])
            local e = pools.edit:Get()
            SetupEditBox(e, argX + 66, y, ARG_W - 66, clause.arg, L["Spell, Spell, ..."], function(v)
                clause.arg = v
                changed()
            end, function(name)
                clause.arg = trim(clause.arg) == "" and name or (trim(clause.arg) .. ", " .. name)
                changed(true)
            end)
        elseif spec.arg then
            local e = pools.edit:Get()
            local ph = spec.arg == "unit" and L["unit or name (optional)"]
                or spec.arg == "item" and L["drag an item here"]
                or spec.arg == "list" and L["Spell, Spell, ..."]
                or L["drag a spell here"]
            local isList = spec.arg == "list"
            SetupEditBox(e, argX, y, ARG_W, clause.arg, ph, function(v)
                clause.arg = v
                changed()
            end, spec.arg ~= "unit" and function(name)
                clause.arg = (isList and trim(clause.arg) ~= "") and (trim(clause.arg) .. ", " .. name) or name
                changed(true)
            end or nil)
            if spec.arg ~= "unit" then
                tip(e, L["Spell or item"], L["Drag a spell from your spellbook or an item from your bags here, or type its name."])
            end
        end
        if #line.clauses > 1 then
            IconButton(CW - 20, y - 2, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", L["Remove this part"], function()
                table.remove(line.clauses, ci)
                changed(true)
            end)
        end
        y = math.min(rowY, y) - 24
    end
    local alt = TextButton(10, y, 150, L["+ alternative"], function()
        line.clauses[#line.clauses + 1] = newClause()
        changed(true)
    end)
    alt:SetHeight(18)
    tip(alt, L["Add an alternative"], L["The macro uses the first part whose conditions hold, from left to right. Add a part without conditions last as the fallback."])
    return top - y + 22
end

local function renderLine(i, line, y)
    local card = pools.card:Get()
    at(card, 0, y)
    card:SetWidth(CW)
    local accent = line.kind == "cmd" and { 1, 0.82, 0 } or line.kind == "show" and { 0.4, 0.7, 1 } or { 0.6, 0.6, 0.6 }
    card.accent:SetColorTexture(accent[1], accent[2], accent[3], 0.8)

    Label(8, y - 7, i .. ".", "GameFontNormal")
    local cmdText = line.kind == "cmd" and line.cmd or line.kind == "show" and line.tag or L["Text"]
    local cmdBtn = TextButton(28, y - 4, 118, cmdText, nil)
    cmdBtn:SetScript("OnClick", function(self)
        ShowMenu(self, commandEntries(function(cmd)
            convert(line, cmd)
            changed(true)
        end))
    end)
    tip(cmdBtn, L["Command"], L["Click to choose another command."])

    if i > 1 then
        IconButton(CW - 60, y - 6, "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up", L["Move up"], function()
            cur.lines[i], cur.lines[i - 1] = cur.lines[i - 1], cur.lines[i]
            changed(true)
        end)
    end
    if i < #cur.lines then
        IconButton(CW - 42, y - 6, "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", L["Move down"], function()
            cur.lines[i], cur.lines[i + 1] = cur.lines[i + 1], cur.lines[i]
            changed(true)
        end)
    end
    IconButton(CW - 20, y - 6, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", L["Remove this line"], function()
        table.remove(cur.lines, i)
        changed(true)
    end)

    local h
    if line.kind == "cmd" then
        local live = Label(154, y - 8, "", "GameFontHighlightSmall")
        live:SetWidth(CW - 154 - 70)
        live:SetJustifyH("LEFT")
        live:SetWordWrap(false)
        f.live[#f.live + 1] = { fs = live, line = line }
        h = 28 + renderClauses(line, y - 28)
    elseif line.kind == "show" then
        local e = pools.edit:Get()
        SetupEditBox(e, 154, y - 4, ARG_W, line.arg, L["the first spell of the macro"], function(v)
            line.arg = v
            changed()
        end, function(name)
            line.arg = name
            changed(true)
        end)
        tip(e, line.tag, L["Shows the icon, cooldown and tooltip of this spell or item. Empty: the one the macro would use right now."])
        h = 28
    else
        local e = pools.edit:Get()
        SetupEditBox(e, 154, y - 4, CW - 154 - 70, line.text, L["/say Hello  or any other line"], function(v)
            line.text = v
            changed()
        end)
        h = 28
    end
    card:SetHeight(h)
    return y - h
end

function MB:Render()
    if not f then return end
    HideMenu()
    for _, p in pairs(pools) do p:Reset() end
    f.live = {}
    local y = -2
    for i, line in ipairs(cur.lines) do
        y = renderLine(i, line, y) - 6
    end
    local add = TextButton(0, y - 2, 150, L["+ add line"], nil)
    add:SetHeight(22)
    local function dropLine()
        local name = cursorThing()
        if not name then return end
        ClearCursor()
        local line = newLine("/cast")
        line.clauses[1].arg = name
        cur.lines[#cur.lines + 1] = line
        changed(true)
    end
    add:SetScript("OnReceiveDrag", dropLine)
    add:SetScript("OnClick", function(self)
        if GetCursorInfo() then dropLine() return end
        ShowMenu(self, commandEntries(function(cmd)
            cur.lines[#cur.lines + 1] = newLine(cmd)
            changed(true)
        end))
    end)
    Label(158, y - 7, L["or drag a spell or item onto it"])
    f.child:SetHeight(-y + 30)
    self:UpdateHeader()
    self:UpdatePreview()
    self:UpdateLive()
end

function MB:UpdateHeader()
    f.name:SetText(cur.name or "")
    f.name:SetCursorPosition(0)
    local icon = cur.icon
    if not icon or icon == QUESTION then icon = iconOf(namesIn(cur)[1] or "") or QUESTION end
    f.icon.tex:SetTexture(icon)
    for _, b in ipairs(f.scope) do
        local on = (b.perChar == (cur.perChar == true))
        b.underline:SetShown(on)
        b.text:SetTextColor(on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
        b:SetEnabled(not cur.index)
    end
end

function MB:UpdatePreview()
    if not f then return end
    local body = buildBody(cur)
    f.body:SetText(body ~= "" and plain(body) or ("|cff808080" .. L["(empty)"] .. "|r"))
    local n = #body
    local over = n > MAX_BODY
    f.count:SetText((over and "|cffff5555" or (n > MAX_BODY - 20 and "|cffffd100" or "|cffaaaaaa"))
        .. L["%d / %d characters"]:format(n, MAX_BODY) .. "|r")
    local errors, warnings = validate(cur, body)
    local out = {}
    for _, e in ipairs(errors) do out[#out + 1] = "|cffff5555" .. e .. "|r" end
    for _, w in ipairs(warnings) do out[#out + 1] = "|cffffd100" .. w .. "|r" end
    if #out == 0 then out[1] = "|cff55ff77" .. L["Looks good."] .. "|r" end
    f.checks:SetText(table.concat(out, "\n"))
    f.save:SetEnabled(#errors == 0)
    f.pickup:SetEnabled(cur.index ~= nil and not dirty)
    if dirty then
        f.state:SetText("|cffffd100" .. L["Unsaved changes"] .. "|r")
    elseif cur.index then
        f.state:SetText("|cff55ff77" .. L["Saved"] .. "|r")
    else
        f.state:SetText("")
    end
end

function MB:UpdateLive()
    if not f or not f.live then return end
    for _, l in ipairs(f.live) do
        local status, action, target = evaluate(l.line)
        if status == "fires" then
            local what = action ~= "" and plain(action) or L["runs"]
            if target and target ~= "" then what = what .. "  |cff80b0ff@" .. plain(target) .. "|r" end
            l.fs:SetText(GREEN_DOT .. what)
        elseif status == "skips" then
            l.fs:SetText(GREY_DOT .. "|cff808080" .. L["does nothing right now"] .. "|r")
        else
            l.fs:SetText("")
        end
    end
end

---------------------------------------------------------------------------
-- The macro list
---------------------------------------------------------------------------

local function accountSlots()
    return MAX_ACCOUNT_MACROS or 120
end

-- Asks first when the builder holds unsaved changes.
local function whenDiscarded(fn)
    if dirty then
        Confirm(L["Discard your changes to this macro?"], fn)
    else
        fn()
    end
end

function MB:RenderList()
    if not f then return end
    for _, r in ipairs(f.listRows) do r:Hide() end
    for _, h in ipairs(f.listHeaders) do h:Hide() end
    local base = accountSlots()
    local general, char = {}, {}
    for i = 1, base + 60 do
        local name, icon = GetMacroInfo(i)
        if name then
            local list = i <= base and general or char
            list[#list + 1] = { index = i, name = name, icon = icon }
        end
    end
    local y, row, header = -2, 0, 0
    local child = f.listChild
    local function addHeader(text)
        header = header + 1
        local h = f.listHeaders[header]
        if not h then
            h = child:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            f.listHeaders[header] = h
        end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", 4, y - 4)
        h:SetText(text)
        h:Show()
        y = y - 20
    end
    local function addRow(m)
        row = row + 1
        local r = f.listRows[row]
        if not r then
            r = CreateFrame("Button", nil, child)
            r:SetSize(LIST_W - 24, 20)
            r.sel = r:CreateTexture(nil, "BACKGROUND")
            r.sel:SetAllPoints()
            r.sel:SetColorTexture(1, 0.82, 0, 0.15)
            local hl = r:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.08)
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(16, 16)
            r.icon:SetPoint("LEFT", 4, 0)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            r.text:SetPoint("RIGHT", -4, 0)
            r.text:SetJustifyH("LEFT")
            r.text:SetWordWrap(false)
            r:RegisterForDrag("LeftButton")
            r:SetScript("OnClick", function(self)
                whenDiscarded(function() MB:Load(self.index) end)
            end)
            r:SetScript("OnDragStart", function(self)
                if not InCombatLockdown() then PickupMacro(self.index) end
            end)
            tip(r, nil)
            f.listRows[row] = r
        end
        r.index = m.index
        r.icon:SetTexture(m.icon or QUESTION)
        r.text:SetText(plain(m.name))
        r.sel:SetShown(cur and cur.index == m.index)
        r.tipTitle, r.tipText = plain(m.name), L["Click: open in the builder   Drag: onto an action bar"]
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, y)
        r:Show()
        y = y - 21
    end
    local maxChar = MAX_CHARACTER_MACROS
    addHeader(L["General macros"] .. "  |cff999999" .. #general .. "/" .. base .. "|r")
    for _, m in ipairs(general) do addRow(m) end
    y = y - 6
    addHeader(L["Character macros"] .. "  |cff999999" .. #char .. (maxChar and ("/" .. maxChar) or "") .. "|r")
    for _, m in ipairs(char) do addRow(m) end
    child:SetHeight(-y + 10)
end

---------------------------------------------------------------------------
-- New, open, save
---------------------------------------------------------------------------

function MB:New()
    cur = { name = "", perChar = false, lines = { newLine("#showtooltip"), newLine("/cast") } }
    dirty = false
    self:Render()
    self:RenderList()
end

function MB:Load(index)
    local name, icon, body = GetMacroInfo(index)
    if not name then return end
    cur = { name = name, icon = icon, index = index, loadedName = name,
            perChar = index > accountSlots(), lines = parseBody(body) }
    if #cur.lines == 0 then cur.lines[1] = newLine("/cast") end
    dirty = false
    self:Render()
    self:RenderList()
end

-- The index of the macro being edited, also when others moved it since it was opened.
local function currentIndex()
    if not cur.index then return end
    if GetMacroInfo(cur.index) == cur.loadedName then return cur.index end
    local i = GetMacroIndexByName(cur.loadedName)
    if i and i > 0 then return i end
end

function MB:Save()
    if InCombatLockdown() then
        ns.Print(L["Macros can't be saved in combat."])
        return
    end
    local body = buildBody(cur)
    local errors = validate(cur, body)
    if #errors > 0 then
        ns.Print(errors[1])
        return
    end
    -- Blizzard's macro window writes its own text back when it closes: close it first
    if MacroFrame and MacroFrame:IsShown() then HideUIPanel(MacroFrame) end
    local name = trim(cur.name)
    local index = currentIndex()
    local ok, result
    if index then
        -- nil keeps the macro's icon (with #showtooltip, GetMacroInfo reports the spell's)
        ok, result = pcall(EditMacro, index, name, cur.iconChanged and cur.icon or nil, body)
    else
        local general, char = GetNumMacros()
        local limit = cur.perChar and MAX_CHARACTER_MACROS or MAX_ACCOUNT_MACROS
        if limit and (cur.perChar and char or general) >= limit then
            ns.Print(L["No free macro slot: delete a macro first."])
            return
        end
        ok, result = pcall(CreateMacro, name, cur.icon or QUESTION, body, cur.perChar and true or nil)
    end
    -- some clients hand back nothing: look the macro up by its name
    if ok and type(result) ~= "number" then result = GetMacroIndexByName(name) end
    if result == 0 then result = nil end
    if not ok or not result then
        ns.Print(L["Couldn't save the macro: %s"]:format(tostring(result or "?")))
        return
    end
    cur.index, cur.loadedName, cur.name, cur.iconChanged = result, name, name, nil
    dirty = false
    ns.Print(L["Macro \"%s\" saved."]:format(plain(name)))
    self:UpdateHeader()
    self:UpdatePreview()
    self:RenderList()
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------

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

local function ScopeButton(parent, label, perChar)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(96, 22)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.05)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.underline = b:CreateTexture(nil, "ARTWORK")
    b.underline:SetColorTexture(1, 0.82, 0, 0.9)
    b.underline:SetHeight(2)
    b.underline:SetPoint("BOTTOMLEFT")
    b.underline:SetPoint("BOTTOMRIGHT")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(label)
    b.perChar = perChar
    b:SetScript("OnClick", function()
        if cur.index then return end
        cur.perChar = perChar
        dirty = true
        MB:UpdateHeader()
        MB:UpdatePreview()
    end)
    b:SetMotionScriptsWhileDisabled(true)
    tip(b, label, L["New macros only: a saved macro keeps its place, so it stays on your bars."])
    return b
end

local function Build()
    f = CreateFrame("Frame", "WombatLogMacroBuilder", UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    -- under DIALOG, so the game's pop-ups (confirm, text prompt) stay on top
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "WombatLogMacroBuilder")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.06, 0.96)
    border(f, 1, 1, 1, 0.12)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText(L["Macro builder"])
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- left: the game's macros
    local new = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    new:SetSize(LIST_W, 22)
    new:SetPoint("TOPLEFT", 14, -42)
    new:SetText(L["New macro"])
    new:SetScript("OnClick", function() whenDiscarded(function() MB:New() end) end)
    local listScroll, listChild = NewScroll(f)
    listScroll:SetPoint("TOPLEFT", 14, -70)
    listScroll:SetPoint("BOTTOMLEFT", 14, 14)
    listScroll:SetWidth(LIST_W - 4)
    listChild:SetWidth(LIST_W - 24)
    f.listChild, f.listRows, f.listHeaders = listChild, {}, {}
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.08)
    sep:SetWidth(1)
    sep:SetPoint("TOPLEFT", RX - 9, -42)
    sep:SetPoint("BOTTOMLEFT", RX - 9, 14)

    -- top: icon, name, general or character, save
    local icon = CreateFrame("Button", nil, f)
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", RX, -36)
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetAllPoints()
    icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    border(icon, 1, 1, 1, 0.25)
    local ihl = icon:CreateTexture(nil, "HIGHLIGHT")
    ihl:SetAllPoints()
    ihl:SetColorTexture(1, 1, 1, 0.15)
    icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function dropIcon()
        local _, tex = cursorThing()
        if not tex then return end
        ClearCursor()
        cur.icon, cur.iconChanged = tex, true
        changed(true)
    end
    icon:SetScript("OnReceiveDrag", dropIcon)
    icon:SetScript("OnClick", function(_, button)
        if GetCursorInfo() then dropIcon() return end
        if button == "RightButton" then
            cur.icon, cur.iconChanged = QUESTION, true
            changed(true)
            return
        end
        -- left-click steps through the icons of the macro's spells
        local icons = {}
        for _, name in ipairs(namesIn(cur)) do
            local t = iconOf(name)
            if t then icons[#icons + 1] = t end
        end
        if #icons == 0 then return end
        local nextIcon = icons[1]
        for i, t in ipairs(icons) do
            if t == cur.icon then nextIcon = icons[i % #icons + 1] end
        end
        cur.icon, cur.iconChanged = nextIcon, true
        changed(true)
    end)
    tip(icon, L["Icon"], L["The question mark takes the icon of the spell from #showtooltip (or the one the macro would use). Click: the icon of a spell in the macro. Drag a spell or item here: its icon. Right-click: question mark."])
    f.icon = icon

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", RX + 48, -36)
    nameLabel:SetText(L["Name"])
    local name = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    name:SetAutoFocus(false)
    name:SetSize(150, 20)
    name:SetPoint("TOPLEFT", RX + 54, -50)
    name:SetMaxLetters(MAX_NAME)
    name:SetScript("OnEscapePressed", name.ClearFocus)
    name:SetScript("OnEnterPressed", name.ClearFocus)
    name:SetScript("OnTextChanged", function(self, user)
        if user then
            cur.name = self:GetText()
            changed()
        end
    end)
    f.name = name

    local saveAs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    saveAs:SetPoint("TOPLEFT", RX + 222, -36)
    saveAs:SetText(L["Saved as"])
    f.scope = {
        ScopeButton(f, L["General"], false),
        ScopeButton(f, L["Character"], true),
    }
    f.scope[1]:SetPoint("TOPLEFT", RX + 222, -50)
    f.scope[2]:SetPoint("LEFT", f.scope[1], "RIGHT", 3, 0)

    f.save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.save:SetSize(100, 24)
    f.save:SetPoint("TOPRIGHT", -14, -48)
    f.save:SetText(L["Save"])
    f.save:SetScript("OnClick", function() MB:Save() end)
    f.pickup = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.pickup:SetSize(120, 24)
    f.pickup:SetPoint("RIGHT", f.save, "LEFT", -6, 0)
    f.pickup:SetText(L["Onto a bar"])
    f.pickup:SetScript("OnClick", function()
        local i = currentIndex()
        if i and not InCombatLockdown() then PickupMacro(i) end
    end)
    f.pickup:SetMotionScriptsWhileDisabled(true)
    tip(f.pickup, L["Onto a bar"], L["Puts the saved macro on your cursor: click an action button to place it."])
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.state:SetPoint("BOTTOMRIGHT", f.save, "TOPRIGHT", 0, 4)

    -- middle: the lines
    local scroll, child = NewScroll(f)
    scroll:SetPoint("TOPLEFT", RX, -88)
    scroll:SetPoint("BOTTOMRIGHT", -34, 178)
    child:SetWidth(CW)
    f.child = child
    pools.card = NewPool(function()
        local c = NewCard(child)
        c:SetFrameLevel(child:GetFrameLevel() + 1)
        return c
    end)
    local function above(o)
        o:SetFrameLevel(child:GetFrameLevel() + 3)
        return o
    end
    -- labels on a layer of their own, above the cards' backgrounds
    local textLayer = CreateFrame("Frame", nil, child)
    textLayer:SetAllPoints(child)
    textLayer:SetFrameLevel(child:GetFrameLevel() + 4)
    pools.text = NewPool(function() return textLayer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall") end)
    pools.chip = NewPool(function() return above(NewChip(child)) end)
    pools.edit = NewPool(function() return above(NewEditBox(child)) end)
    pools.icon = NewPool(function() return above(NewIconButton(child)) end)
    pools.button = NewPool(function() return above(CreateFrame("Button", nil, child, "UIPanelButtonTemplate")) end)

    -- bottom: the text, its length, the checks
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(1, 1, 1, 0.08)
    div:SetHeight(1)
    div:SetPoint("BOTTOMLEFT", RX, 170)
    div:SetPoint("BOTTOMRIGHT", -14, 170)
    local bodyTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bodyTitle:SetPoint("TOPLEFT", f, "BOTTOMLEFT", RX, 162)
    bodyTitle:SetText(L["Macro text"])
    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPRIGHT", f, "BOTTOMLEFT", RX + 340, 160)
    local bodyBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    bodyBg:SetColorTexture(0, 0, 0, 0.35)
    bodyBg:SetPoint("TOPLEFT", f, "BOTTOMLEFT", RX, 144)
    bodyBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", RX + 340, 34)
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.body:SetPoint("TOPLEFT", bodyBg, "TOPLEFT", 6, -6)
    f.body:SetPoint("BOTTOMRIGHT", bodyBg, "BOTTOMRIGHT", -6, 6)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(2)

    local checkTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    checkTitle:SetPoint("TOPLEFT", f, "BOTTOMLEFT", RX + 360, 162)
    checkTitle:SetText(L["Checks"])
    f.checks = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.checks:SetPoint("TOPLEFT", f, "BOTTOMLEFT", RX + 360, 142)
    f.checks:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 34)
    f.checks:SetJustifyH("LEFT")
    f.checks:SetJustifyV("TOP")
    f.checks:SetSpacing(2)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", RX, 14)
    hint:SetPoint("BOTTOMRIGHT", -14, 14)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["Live: hold Shift, Ctrl or Alt or change your target, and each line shows what it would do right now."])

    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.15 then return end
        elapsed = 0
        MB:UpdateLive()
    end)
    f:SetScript("OnHide", HideMenu)
end

---------------------------------------------------------------------------
-- Blizzard's macro window: a button that opens its selected macro here
---------------------------------------------------------------------------

local function blizzardSelected()
    local mf = MacroFrame
    local i = safe(function()
        if mf.GetSelectedIndex and mf.GetMacroDataIndex then
            local s = mf:GetSelectedIndex()
            if s then return mf:GetMacroDataIndex(s) end
        end
        return mf.selectedMacro
    end)
    if type(i) == "number" and GetMacroInfo(i) then return i end
end

local function hookMacroFrame()
    if MB.macroButton or not MacroFrame then return end
    local b = CreateFrame("Button", nil, MacroFrame, "UIPanelButtonTemplate")
    b:SetSize(90, 22)
    b:SetText(L["Builder"])
    if MacroFrameTab2 then
        b:SetPoint("LEFT", MacroFrameTab2, "RIGHT", 10, 0)
    else
        b:SetPoint("TOPRIGHT", MacroFrame, "TOPRIGHT", -30, -28)
    end
    b:SetFrameLevel(MacroFrame:GetFrameLevel() + 10)
    b:SetScript("OnClick", function()
        local i = blizzardSelected()
        HideUIPanel(MacroFrame)
        MB:Open(i)
    end)
    tip(b, L["Macro builder"], L["Opens the selected macro in WombatLog's macro builder."])
    MB.macroButton = b
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function MB:Open(index)
    if not f then Build() end
    if MacroFrame and MacroFrame:IsShown() then HideUIPanel(MacroFrame) end
    f:Show()
    if index and GetMacroInfo(index) and not (cur and cur.index == index) then
        whenDiscarded(function() MB:Load(index) end)
    elseif not cur then
        self:New()
    else
        self:Render()
    end
    self:RenderList()
end

function MB:Toggle()
    if f and f:IsShown() then f:Hide() else self:Open() end
end

function MB:Init()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if isLoaded and safe(isLoaded, "Blizzard_MacroUI") then hookMacroFrame() end
    ns.Listen("ADDON_LOADED", function(name)
        if name == "Blizzard_MacroUI" then hookMacroFrame() end
    end)
    ns.Listen("UPDATE_MACROS", function()
        if f and f:IsShown() then MB:RenderList() end
    end)
end

-- for tools/test_macrobuilder.lua
MB._test = { parseBody = parseBody, buildBody = buildBody, parseLine = parseLine, lineText = lineText,
             convert = convert, flip = flip, splitNeg = splitNeg, condLabel = condLabel,
             validate = validate, namesIn = namesIn }
