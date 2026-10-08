local ADDON, ns = ...
local Config = {}
ns.Config = Config
local L = ns.L

local WHITE = "Interface\\Buttons\\WHITE8X8"
local PAGE_WIDTH = 500
local COL2_X = 260
local WIDGET_W = 230
local SIDEBAR_W = 124
local PAGE_TOP = -50     -- pages of features without sub-tabs
local SUBTAB_TOP = -50   -- the sub-tab bar
local SUBPAGE_TOP = -84  -- pages under a sub-tab bar

local widgets = {}
local refreshing = false

---------------------------------------------------------------------------
-- Value bindings: "appearance.width" -> ns.db.appearance.width
---------------------------------------------------------------------------

local function resolve(path)
    local keys = {}
    for k in path:gmatch("[^%.]+") do keys[#keys + 1] = tonumber(k) or k end
    local t = ns.db
    for i = 1, #keys - 1 do t = t[keys[i]] end
    return t, keys[#keys]
end

local function Bind(path)
    return {
        get = function()
            local t, k = resolve(path)
            return t[k]
        end,
        set = function(v)
            local t, k = resolve(path)
            t[k] = v
            ns.ApplyAll()
        end,
    }
end

local function asBind(b)
    if type(b) == "string" then return Bind(b) end
    return b
end

---------------------------------------------------------------------------
-- Formatters and option lists
---------------------------------------------------------------------------

local function pct(v) return math.floor(v * 100 + 0.5) .. "%" end
local function px(v) return v .. " px" end
local function secs(v) return string.format("%.2fs", v) end
local function wholeSecs(v) return v .. "s" end
local function times(v) return string.format("%.2fx", v) end

local BUILTIN_FONTS = {
    { text = "Friz Quadrata", value = "Fonts\\FRIZQT__.TTF", raw = true },
    { text = "Arial Narrow", value = "Fonts\\ARIALN.TTF", raw = true },
    { text = "Morpheus", value = "Fonts\\MORPHEUS.TTF", raw = true },
    { text = "Skurri", value = "Fonts\\SKURRI.TTF", raw = true },
}

-- Built-in fonts plus any registered with LibSharedMedia by other addons.
local function fontOptions()
    local list, seen = {}, {}
    for _, f in ipairs(BUILTIN_FONTS) do
        list[#list + 1] = f
        seen[f.value] = true
    end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            local path = LSM:Fetch("font", name)
            if path and not seen[path] then
                seen[path] = true
                list[#list + 1] = { text = name, value = path, raw = true }
            end
        end
    end
    return list
end

-- For the pop-up alerts: their own font or the log window's.
local function alertFontOptions()
    local list = { { text = "Same as log window", value = "" } }
    for _, f in ipairs(fontOptions()) do list[#list + 1] = f end
    return list
end

local OUTLINE_OPTIONS = {
    { text = "None", value = "" },
    { text = "Outline", value = "OUTLINE" },
    { text = "Thick outline", value = "THICKOUTLINE" },
    { text = "Monochrome", value = "OUTLINE, MONOCHROME" },
}

local function autoPx(v) return v == 0 and L["Auto"] or v .. " px" end

local KINDS = {
    { "damage", "Your damage" }, { "heal", "Your heals" }, { "avoid", "Misses & avoids" },
    { "taken", "Damage taken" }, { "healIn", "Heals received" }, { "cast", "Casts" },
    { "buff", "Buffs gained" }, { "debuffIn", "Debuffs on you" }, { "debuffOut", "Debuffs you apply" },
    { "fade", "Aura fades" }, { "kill", "Kills" },
}

StaticPopupDialogs.WOMBATLOG_CONFIRM = {
    text = "%s",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(_, fn) fn() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Confirm(text, fn)
    StaticPopup_Show("WOMBATLOG_CONFIRM", text, nil, fn)
end

---------------------------------------------------------------------------
-- Pages: a scrolling column of widgets, two columns per row
---------------------------------------------------------------------------

local Page = {}
Page.__index = Page

local function NewPage(parent, top)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate")
    if not ok or not scroll.ScrollBar then
        scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    end
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", SIDEBAR_W + 26, top or PAGE_TOP)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -28, 8)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(PAGE_WIDTH, 1)
    scroll:SetScrollChild(child)
    scroll:Hide()
    return setmetatable({ scroll = scroll, child = child, y = -4, rowY = -4 }, Page)
end

-- col 2 places w beside the previous widget; dy nudges it down within that row.
function Page:Add(w, h, col, dy)
    if col == 2 then
        w:SetPoint("TOPLEFT", self.child, "TOPLEFT", COL2_X, self.rowY + (dy or 0))
        self.y = math.min(self.y, self.rowY - h)
    else
        self.rowY = self.y
        w:SetPoint("TOPLEFT", self.child, "TOPLEFT", 16, self.y)
        self.y = self.y - h
    end
    self.child:SetHeight(-self.y + 20)
end

local function register(w)
    widgets[#widgets + 1] = w
    return w
end

function Page:Header(text)
    self.y = self.y - 10
    local fs = self.child:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetText(L[text])
    local line = self.child:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", self.child, "RIGHT", -16, 0)
    self:Add(fs, 28)
end

function Page:Note(text)
    local fs = self.child:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetWidth(PAGE_WIDTH - 40)
    fs:SetJustifyH("LEFT")
    fs:SetText(L[text])
    self:Add(fs, math.max(fs:GetStringHeight(), 12) + 8)
end

function Page:Checkbox(label, bind, col)
    bind = asBind(bind)
    local cb = CreateFrame("CheckButton", nil, self.child, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    if cb.Text then cb.Text:SetText("") end
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(L[label])
    cb:SetHitRectInsets(0, -(text:GetStringWidth() + 6), 0, 0) -- label is clickable too
    cb:SetScript("OnClick", function(self)
        if not refreshing then bind.set(self:GetChecked() and true or false) end
    end)
    cb.Refresh = function() cb:SetChecked(bind.get() and true or false) end
    register(cb)
    self:Add(cb, 28, col)
    return cb
end

function Page:Slider(label, bind, minV, maxV, step, fmt, col)
    bind = asBind(bind)
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(WIDGET_W, 44)

    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(L[label])
    local valueText = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valueText:SetPoint("TOPRIGHT")

    local s = CreateFrame("Slider", nil, holder)
    s:SetPoint("TOPLEFT", 0, -18)
    s:SetPoint("TOPRIGHT", 0, -18)
    s:SetHeight(18)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetHitRectInsets(0, 0, -4, -4)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0, 0, 0, 0.6)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(6)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = s:GetThumbTexture()
    thumb:SetSize(32, 32)
    local fill = s:CreateTexture(nil, "BORDER")
    fill:SetColorTexture(1, 0.82, 0, 0.55)
    fill:SetPoint("LEFT", track, "LEFT")
    fill:SetPoint("RIGHT", thumb, "CENTER")
    fill:SetHeight(6)

    local function snap(v)
        v = minV + math.floor((v - minV) / step + 0.5) * step
        return tonumber(string.format("%.2f", v))
    end
    local function show(v)
        valueText:SetText(fmt and fmt(v) or tostring(v))
    end

    s:SetScript("OnValueChanged", function(_, v)
        v = snap(v)
        show(v)
        if refreshing then return end
        if v ~= bind.get() then bind.set(v) end
    end)

    holder.Refresh = function()
        local v = bind.get() or minV
        s:SetValue(v)
        show(v)
    end
    register(holder)
    self:Add(holder, 50, col)
    return holder
end

local function optionText(o)
    return o.raw and o.text or L[o.text]
end

-- options: list of { text, value } or a function returning one; text is translated
-- unless the option has raw = true (font, profile and spell names)
function Page:Dropdown(label, bind, options, col)
    bind = asBind(bind)
    local function opts()
        return type(options) == "function" and options() or options
    end
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(WIDGET_W, 48)
    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(L[label])

    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, holder, "WowStyle1DropdownTemplate")
    if ok and dd and dd.SetupMenu then
        dd:SetPoint("TOPLEFT", 0, -18)
        dd:SetWidth(WIDGET_W - 20)
        if dd.SetDefaultText then dd:SetDefaultText(L["Choose..."]) end
        dd:SetupMenu(function(_, root)
            for _, o in ipairs(opts()) do
                root:CreateRadio(optionText(o),
                    function() return bind.get() == o.value end,
                    function()
                        bind.set(o.value)
                        C_Timer.After(0, function() dd:GenerateMenu() end)
                    end)
            end
        end)
        holder.Refresh = function() dd:GenerateMenu() end
    else
        -- fallback for clients without the modern dropdown: click cycles the options
        local b = CreateFrame("Button", nil, holder, "UIPanelButtonTemplate")
        b:SetSize(WIDGET_W - 20, 22)
        b:SetPoint("TOPLEFT", 0, -18)
        local function current()
            for _, o in ipairs(opts()) do
                if o.value == bind.get() then return optionText(o) end
            end
            return L["Choose..."]
        end
        b:SetScript("OnClick", function()
            local list, index = opts(), 0
            for i, o in ipairs(list) do
                if o.value == bind.get() then index = i end
            end
            local nextOpt = list[index % #list + 1]
            if nextOpt then bind.set(nextOpt.value) end
            b:SetText(current())
        end)
        holder.Refresh = function() b:SetText(current()) end
    end
    register(holder)
    self:Add(holder, 52, col)
    return holder
end

function Page:Color(label, path, col)
    local bind = Bind(path)
    local b = CreateFrame("Button", nil, self.child)
    b:SetSize(WIDGET_W, 24)

    local border = b:CreateTexture(nil, "BACKGROUND")
    border:SetSize(20, 20)
    border:SetPoint("LEFT")
    border:SetColorTexture(0.85, 0.85, 0.85, 1)
    local swatch = b:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(18, 18)
    swatch:SetPoint("CENTER", border)
    local text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", border, "RIGHT", 8, 0)
    text:SetText(L[label])
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)

    b.Refresh = function()
        local c = bind.get()
        swatch:SetColorTexture(c[1], c[2], c[3], 1)
    end
    local function apply(r, g, bl)
        local c = bind.get()
        c[1], c[2], c[3] = r, g, bl
        b.Refresh()
        ns.ApplyAll()
    end

    b:SetScript("OnClick", function()
        local c = bind.get()
        local r, g, bl = c[1], c[2], c[3]
        local info = {
            r = r, g = g, b = bl, hasOpacity = false,
            swatchFunc = function() apply(ColorPickerFrame:GetColorRGB()) end,
            cancelFunc = function() apply(r, g, bl) end,
        }
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else
            ColorPickerFrame.func = info.swatchFunc
            ColorPickerFrame.cancelFunc = info.cancelFunc
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.previousValues = { r, g, bl }
            ColorPickerFrame:SetColorRGB(r, g, bl)
            ShowUIPanel(ColorPickerFrame)
        end
    end)
    register(b)
    self:Add(b, 28, col)
    return b
end

function Page:Button(text, onClick, col, dy, width)
    local b = CreateFrame("Button", nil, self.child, "UIPanelButtonTemplate")
    b:SetSize(width or 170, 24)
    b:SetText(L[text])
    b:SetScript("OnClick", onClick)
    self:Add(b, 32, col, dy)
    return b
end

function Page:EditBox(label, col)
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(WIDGET_W, 48)
    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(L[label])
    local e = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    e:SetSize(WIDGET_W - 30, 22)
    e:SetPoint("TOPLEFT", 6, -18)
    e:SetAutoFocus(false)
    e:SetMaxLetters(32)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    self:Add(holder, 50, col)
    return e
end

-- Two lists side by side: the proc list (with Remove) and recently gained buffs (with Add).
local LIST_ROWS = 12

function Page:ProcLists()
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(PAGE_WIDTH - 32, 24 + LIST_ROWS * 22)
    local left = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    left:SetPoint("TOPLEFT")
    left:SetText(L["Your proc list"])
    local right = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    right:SetPoint("TOPLEFT", COL2_X - 16, 0)
    right:SetText(L["Recently gained buffs"])

    local function makeRow(x, i)
        local r = CreateFrame("Frame", nil, holder)
        r:SetSize(WIDGET_W, 20)
        r:SetPoint("TOPLEFT", x, -20 - (i - 1) * 22)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT")
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetPoint("LEFT", 20, 0)
        r.text:SetWidth(WIDGET_W - 86)
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.btn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.btn:SetSize(60, 18)
        r.btn:SetPoint("RIGHT")
        return r
    end
    local mine, recent = {}, {}
    for i = 1, LIST_ROWS do
        mine[i] = makeRow(0, i)
        recent[i] = makeRow(COL2_X - 16, i)
    end
    local emptyMine = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyMine:SetPoint("TOPLEFT", 0, -22)
    emptyMine:SetWidth(WIDGET_W)
    emptyMine:SetJustifyH("LEFT")
    emptyMine:SetText(L["Empty. Add a buff by name or spell ID above, or pick one on the right."])
    local emptyRecent = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyRecent:SetPoint("TOPLEFT", COL2_X - 16, -22)
    emptyRecent:SetWidth(WIDGET_W)
    emptyRecent:SetJustifyH("LEFT")
    emptyRecent:SetText(L["Buffs you gain while proc alerts are on show up here."])

    holder.Refresh = function()
        local list = ns.db.procs.list
        for i, r in ipairs(mine) do
            local entry = list[i]
            if entry then
                r.icon:SetTexture(nil)
                r.text:SetText(entry)
                r.btn:SetText(L["Remove"])
                r.btn:SetScript("OnClick", function()
                    ns.Alerts:RemoveProc(i)
                    holder.Refresh()
                end)
                r:Show()
            else
                r:Hide()
            end
        end
        emptyMine:SetShown(#list == 0)
        local auras = ns.Alerts.recentAuras or {}
        for i, r in ipairs(recent) do
            local a = auras[i]
            if a then
                r.icon:SetTexture(a.icon or 134400)
                r.text:SetText(a.name)
                r.btn:SetText(L["Add"])
                r.btn:SetEnabled(not ns.Alerts:HasProc(a.name))
                r.btn:SetScript("OnClick", function()
                    ns.Alerts:AddProc(a.name)
                    holder.Refresh()
                end)
                r:Show()
            else
                r:Hide()
            end
        end
        emptyRecent:SetShown(#auras == 0)
    end
    register(holder)
    self:Add(holder, 30 + LIST_ROWS * 22)
    return holder
end

-- A fixed set of entries the user can move up and down. getList returns the keys
-- in order, setList saves a new order, labels maps keys to names.
function Page:OrderList(label, getList, setList, labels)
    local count = #getList()
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(WIDGET_W + 60, 20 + count * 22)
    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(L[label])

    local function move(i, delta)
        local list = getList()
        local j = i + delta
        if not list[j] then return end
        list[i], list[j] = list[j], list[i]
        setList(list)
        ns.ApplyAll()
        holder.Refresh()
    end

    local rows = {}
    for i = 1, count do
        local r = CreateFrame("Frame", nil, holder)
        r:SetSize(WIDGET_W + 60, 20)
        r:SetPoint("TOPLEFT", 0, -20 - (i - 1) * 22)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetPoint("LEFT", 4, 0)
        r.up = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.up:SetSize(56, 18)
        r.up:SetPoint("RIGHT", -60, 0)
        r.up:SetText(L["Up"])
        r.up:SetScript("OnClick", function() move(i, -1) end)
        r.down = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.down:SetSize(56, 18)
        r.down:SetPoint("RIGHT")
        r.down:SetText(L["Down"])
        r.down:SetScript("OnClick", function() move(i, 1) end)
        local stripe = r:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.06)
        rows[i] = r
    end

    holder.Refresh = function()
        local list = getList()
        for i, r in ipairs(rows) do
            r.text:SetText(i .. ".  " .. (labels[list[i]] and L[labels[list[i]]] or list[i] or ""))
            r.up:SetEnabled(i > 1)
            r.down:SetEnabled(i < #list)
        end
    end
    register(holder)
    self:Add(holder, 26 + count * 22)
    return holder
end

-- Two lists side by side: your reminders (type toggle, remove) and class suggestions (add).
local MODE_TEXT = { usable = "Usable", buff = "Buff", debuff = "Debuff", interrupt = "Interrupt" }

function Page:ReminderLists()
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(PAGE_WIDTH - 32, 24 + LIST_ROWS * 22)
    local left = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    left:SetPoint("TOPLEFT")
    left:SetText(L["Your reminders"])
    local right = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    right:SetPoint("TOPLEFT", COL2_X - 16, 0)
    right:SetText(L["Suggestions for your class"])

    local function makeRow(x, i, twoButtons)
        local r = CreateFrame("Frame", nil, holder)
        r:SetSize(WIDGET_W, 20)
        r:SetPoint("TOPLEFT", x, -20 - (i - 1) * 22)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT")
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetPoint("LEFT", 20, 0)
        r.text:SetWidth(WIDGET_W - (twoButtons and 150 or 86))
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.btn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.btn:SetPoint("RIGHT")
        if twoButtons then
            r.btn:SetSize(24, 18)
            r.btn:SetText("X")
            r.mode = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            r.mode:SetSize(58, 18)
            r.mode:SetPoint("RIGHT", r.btn, "LEFT", -2, 0)
            -- the key shown on the icon; saved on Enter or when the box loses focus
            r.keyBox = CreateFrame("EditBox", nil, r, "InputBoxTemplate")
            r.keyBox:SetSize(36, 18)
            r.keyBox:SetPoint("RIGHT", r.mode, "LEFT", -4, 0)
            r.keyBox:SetAutoFocus(false)
            r.keyBox:SetMaxLetters(8)
            r.keyBox:SetScript("OnEscapePressed", r.keyBox.ClearFocus)
            r.keyBox:SetScript("OnEnterPressed", r.keyBox.ClearFocus)
            r.keyBox:SetScript("OnEditFocusLost", function(box)
                if r.index then ns.Reminders:SetKey(r.index, box:GetText()) end
            end)
        else
            r.btn:SetSize(60, 18)
            r.btn:SetText(L["Add"])
        end
        return r
    end
    local mine, suggested = {}, {}
    for i = 1, LIST_ROWS do
        mine[i] = makeRow(0, i, true)
        suggested[i] = makeRow(COL2_X - 16, i, false)
    end
    local emptyMine = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyMine:SetPoint("TOPLEFT", 0, -22)
    emptyMine:SetWidth(WIDGET_W)
    emptyMine:SetJustifyH("LEFT")
    emptyMine:SetText(L["Empty. Add a spell by name or spell ID above, or pick a suggestion on the right."])
    local emptySuggested = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptySuggested:SetPoint("TOPLEFT", COL2_X - 16, -22)
    emptySuggested:SetWidth(WIDGET_W)
    emptySuggested:SetJustifyH("LEFT")
    emptySuggested:SetText(L["No more suggestions for your class and level."])

    holder.Refresh = function()
        -- only this class's reminders; i is the index into the whole list
        local list, visible = ns.db.reminders.list, ns.Reminders:Visible()
        for row, r in ipairs(mine) do
            local i = visible[row]
            local entry = i and list[i]
            if entry then
                local name, icon = ns.Reminders.Describe(entry.spell)
                r.icon:SetTexture(icon)
                r.text:SetText(name)
                r.mode:SetText(MODE_TEXT[entry.mode] and L[MODE_TEXT[entry.mode]] or entry.mode)
                r.index = i
                if not r.keyBox:HasFocus() then r.keyBox:SetText(entry.key or "") end
                r.mode:SetScript("OnClick", function()
                    ns.Reminders:ToggleMode(i)
                    holder.Refresh()
                end)
                r.btn:SetScript("OnClick", function()
                    ns.Reminders:Remove(i)
                    holder.Refresh()
                end)
                r:Show()
            else
                r.index = nil
                r:Hide()
            end
        end
        emptyMine:SetShown(#visible == 0)
        local sugg = ns.Reminders:Suggestions()
        for i, r in ipairs(suggested) do
            local sg = sugg[i]
            if sg then
                r.icon:SetTexture(sg.icon or 134400)
                r.text:SetText(sg.name .. " |cff999999(" .. L[MODE_TEXT[sg.mode]] .. ")|r")
                r.btn:SetScript("OnClick", function()
                    ns.Reminders:Add(sg.text, sg.mode)
                    holder.Refresh()
                end)
                r:Show()
            else
                r:Hide()
            end
        end
        emptySuggested:SetShown(#sugg == 0)
    end
    register(holder)
    self:Add(holder, 30 + LIST_ROWS * 22)
    return holder
end

---------------------------------------------------------------------------
-- Combat log
---------------------------------------------------------------------------

local function BuildLogLayout(p)
    p:Header("Layout")
    p:Slider("Window width", "appearance.width", 200, 600, 10, px)
    p:Slider("Max rows", "behaviour.lines", 3, 30, 1, nil, 2)
    p:Slider("Row height", "appearance.rowHeight", 14, 40, 1, px)
    p:Slider("Row spacing", "appearance.rowGap", 0, 10, 1, px, 2)
    p:Slider("Row background opacity", "appearance.rowBgOpacity", 0, 1, 0.05, pct)
    p:Checkbox("Show spell icons", "appearance.showIcons")
    p:Checkbox("Incoming events on the right", "appearance.mirrorIncoming", 2)
    p:Checkbox("Newest row on top", "appearance.newestOnTop")
    p:Checkbox("Dim older rows", "appearance.ageDim", 2)

    p:Header("Text")
    p:Dropdown("Number font", "appearance.amountFont", fontOptions)
    p:Dropdown("Name font", "appearance.nameFont", fontOptions, 2)
    p:Slider("Number size", "appearance.amountSize", 8, 28, 1)
    p:Slider("Name size", "appearance.nameSize", 8, 24, 1, nil, 2)
    p:Dropdown("Outline", "appearance.outline", OUTLINE_OPTIONS)
    p:Dropdown("Number format", "appearance.numberFormat", {
        { text = "Full (12,345)", value = "full" },
        { text = "Short (12.3k)", value = "short" },
    }, 2)
end

local function BuildLogHeader(p)
    p:Header("Header")
    p:Note("The line above the rows with live numbers for the current fight.")
    p:Checkbox("Show header", "appearance.header.show")
    p:Checkbox("DPS", "appearance.header.dps")
    p:Checkbox("HPS", "appearance.header.hps", 2)
    p:Checkbox("Fight timer", "appearance.header.timer")
    p:Checkbox("Damage / taken totals", "appearance.header.totals", 2)
    p:Checkbox("Biggest hit", "appearance.header.biggest")
end

local function BuildLogCrits(p)
    p:Header("Crit rows")
    p:Note("Crit rows always get a bigger number and a thicker accent bar. These add the extras on top.")
    p:Checkbox("Pop-in animation", "crit.pop")
    p:Slider("Pop size", "crit.popScale", 1.1, 2.5, 0.1, times, 2)
    p:Checkbox("Shine sweep", "crit.shine")
    p:Checkbox("Flash", "crit.flash", 2)
    p:Checkbox("Row tint", "crit.glow")
    p:Checkbox("Icon border", "crit.iconBorder", 2)
    p:Checkbox("CRIT tag", "crit.tag")
    p:Slider("Crit number size", "appearance.critSize", 10, 40, 1)
    p:Color("Crit highlight color", "colors.crit", 2)
    p:Button("Replay crit animation", function() ns.Display:ReplayCrits() end)
end

local function BuildLogColors(p)
    p:Header("Row types")
    local kinds = {}
    for _, k in ipairs(KINDS) do
        if k[1] ~= "damage" then kinds[#kinds + 1] = k end
    end
    for i, k in ipairs(kinds) do
        p:Color(k[2], "colors." .. k[1], (i % 2 == 0) and 2 or nil)
    end

    p:Header("Damage schools")
    p:Note("Your damage rows use the color of the spell's school. The crit color is on the Crits tab.")
    local i = 0
    for _, mask in ipairs({ 1, 2, 4, 8, 16, 32, 64 }) do
        i = i + 1
        p:Color(ns.SCHOOL_NAMES[mask], "colors.schools." .. mask, (i % 2 == 0) and 2 or nil)
    end

    p.y = p.y - 8
    p:Button("Reset all colors", function()
        Confirm(L["Reset all colors to their defaults?"], function()
            ns.db.colors = ns.CopyTable(ns.defaults.colors)
            ns.ApplyAll(true)
        end)
    end)
end

local function BuildLogEvents(p)
    p:Header("Events to show")
    for i, k in ipairs(KINDS) do
        p:Checkbox(k[2], "behaviour.show." .. k[1], (i % 2 == 0) and 2 or nil)
    end

    p:Header("Damage over time")
    p:Checkbox("Pin running DoTs", "behaviour.pinDots")
    p:Note("One row per DoT on your target that counts up its damage, ticks and crit ticks, with the time left. When the DoT runs out, the row scrolls away like any other.")

    p:Header("Filters")
    p:Slider("Min amount: your hits & heals", "behaviour.minAmountOut", 0, 5000, 10)
    p:Slider("Min amount: incoming", "behaviour.minAmountIn", 0, 5000, 10, nil, 2)
    p:Checkbox("Only crits: your hits & heals", "behaviour.hideNormalOut")
    p:Checkbox("Only crits: incoming", "behaviour.hideNormalIn", 2)
    p:Note("Incoming covers damage taken and heals on you. Hidden rows still count toward DPS, HPS and totals.")
    p:Checkbox("Strict group filter", "behaviour.strict")
    p:Note("In a group, hits on your target that can't be matched to your own swing or cast are dropped. Turn this off to show them dimmed instead. They never count toward your DPS. (Not needed on Classic clients: there every hit comes with its source.)")
end

local function BuildLogWindow(p)
    local P = function() return ns.db.position end
    local sw, sh = math.ceil(GetScreenWidth()), math.ceil(GetScreenHeight())

    p:Header("Visibility")
    p:Dropdown("Show the window", "behaviour.visibility", {
        { text = "Only in combat", value = "combat" },
        { text = "Always", value = "always" },
    })
    p:Slider("Stay after combat", "behaviour.linger", 0, 30, 1, wholeSecs, 2)
    p:Slider("Fade-in time", "behaviour.fadeIn", 0, 2, 0.05, secs)
    p:Slider("Fade-out time", "behaviour.fadeOut", 0, 3, 0.05, secs, 2)
    p:Checkbox("Clear the log when a new fight starts", "behaviour.clearOnNewFight")

    p:Header("Position")
    p:Checkbox("Unlock (drag the window to move it)", {
        get = function() return not ns.locked end,
        set = function(v) ns.Display:SetLocked(not v) end,
    })
    p:Slider("Horizontal position", "position.x", -sw, sw, 1)
    p:Slider("Vertical position", "position.y", -sh, sh, 1, nil, 2)
    p:Slider("Scale", {
        get = function() return P().scale end,
        set = function(v)
            -- keep the window's center where it is on screen
            local pos = P()
            local ratio = pos.scale / v
            pos.x = math.floor(pos.x * ratio + 0.5)
            pos.y = math.floor(pos.y * ratio + 0.5)
            pos.scale = v
            ns.ApplyAll(true)
        end,
    }, 0.5, 3, 0.05, times)
    p:Slider("Window opacity", "position.alpha", 0.1, 1, 0.05, pct, 2)
    p:Dropdown("Frame layer", "position.strata", {
        { text = "Background", value = "BACKGROUND" },
        { text = "Low", value = "LOW" },
        { text = "Medium", value = "MEDIUM" },
        { text = "High", value = "HIGH" },
        { text = "Dialog", value = "DIALOG" },
    })
    p:Note("The layer only matters when other windows overlap. While this panel is open, the window is drawn on top so you can see it.")
    p:Button("Center on screen", function()
        P().x, P().y = 0, 0
        ns.ApplyAll(true)
    end)
    p:Button("Reset position", function()
        local D = ns.defaults.position
        P().x, P().y, P().scale = D.x, D.y, D.scale
        ns.ApplyAll(true)
    end, 2)
end

---------------------------------------------------------------------------
-- Crit alerts
---------------------------------------------------------------------------

local SOUND_CHANNELS = {
    { text = "Master", value = "Master" },
    { text = "Sound effects", value = "SFX" },
    { text = "Dialog", value = "Dialog" },
    { text = "Ambience", value = "Ambience" },
}

local function BuildAlertVisual(p)
    p:Header("Visual crit alert")
    p:Note("A separate pop-up over your character whenever you land a crit. It works independently of the log window and its filters.")
    p:Checkbox("Show visual alert", "alerts.visual.enabled")
    p:Checkbox("Include heal crits", "alerts.visual.heals", 2)
    p:Slider("Min amount", "alerts.visual.minAmount", 0, 5000, 10)
    p:Slider("Display time", "alerts.visual.duration", 0.5, 3, 0.1, secs, 2)

    p:Header("Look")
    p:Slider("Number size", "alerts.visual.size", 20, 80, 1)
    p:Slider("Scale", "alerts.visual.scale", 0.5, 2, 0.05, times, 2)
    p:Checkbox("Spell icon", "alerts.visual.showIcon")
    p:Checkbox("Spell name", "alerts.visual.showName", 2)
    p:Checkbox("Glow burst", "alerts.visual.glow")
    p:Checkbox("Use crit highlight color", "alerts.visual.useCritColor", 2)
    p:Color("Custom alert color", "alerts.visual.color")

    p:Header("Text")
    p:Dropdown("Number font", "alerts.visual.font", alertFontOptions)
    p:Dropdown("Name font", "alerts.visual.nameFont", alertFontOptions, 2)
    p:Dropdown("Outline", "alerts.visual.outline", OUTLINE_OPTIONS)

    p:Header("Position")
    p:Checkbox("Unlock (drag the alert to move it)", {
        get = function() return ns.Alerts.crit.unlocked end,
        set = function(v) ns.Alerts.crit:SetLocked(not v) end,
    })
    p:Button("Test", function() ns.Alerts:Test() end)
    p:Button("Reset position", function()
        local V, D = ns.db.alerts.visual, ns.defaults.alerts.visual
        V.x, V.y = D.x, D.y
        ns.ApplyAll(true)
    end, 2)
end

local function BuildAlertSound(p)
    p:Header("Sound crit alert")
    p:Checkbox("Play sound", "alerts.sound.enabled")
    p:Checkbox("Include heal crits", "alerts.sound.heals", 2)
    p:Dropdown("Sound", {
        get = function() return ns.db.alerts.sound.sound end,
        set = function(v)
            ns.db.alerts.sound.sound = v
            ns.Alerts:PlayConfigured() -- preview on pick
        end,
    }, ns.Alerts.SoundOptions)
    p:Dropdown("Sound channel", "alerts.sound.channel", SOUND_CHANNELS, 2)
    p:Slider("Min amount", "alerts.sound.minAmount", 0, 5000, 10)
    p:Slider("Min time between sounds", "alerts.sound.throttle", 0, 1, 0.05, secs, 2)
    p:Button("Play sound", function() ns.Alerts:PlayConfigured() end)
end

local function BuildAlertStreaks(p)
    p:Header("Crit streaks")
    p:Note("Crits in a row add a growing \"x3 CRIT STREAK\" banner to the crit alert. Any normal hit or miss ends the streak.")
    p:Checkbox("Show crit streaks", "alerts.streak.enabled")
    p:Checkbox("Rising sound with the streak", "alerts.streak.escalatingSound", 2)
    p:Note("The rising sound is your crit sound (Sound tab), raised a little more with every crit. Only the WombatLog sounds can be raised; others play unchanged.")
    p:Slider("Show from streak", "alerts.streak.min", 2, 5, 1, function(v) return "x" .. v end)
    p:Button("Test x3", function() ns.Alerts:TestStreak(3) end, 2, -12, 100)

    p:Header("Record alert")
    p:Note("When a hit beats one of your personal records, the crit alert shows \"NEW RECORD!\". Which records are tracked is set under Fight summary.")
    p:Checkbox("Record banner", "alerts.record.banner")
    p:Checkbox("Record fanfare sound", "alerts.record.sound", 2)
    p:Button("Test record", function() ns.Alerts:TestRecord() end)
end

---------------------------------------------------------------------------
-- Proc alerts
---------------------------------------------------------------------------

local function BuildProcGeneral(p)
    p:Header("Proc & buff alerts")
    p:Note("Shows a separate alert, with an optional sound, whenever you gain a buff from your list (Buffs tab). Useful for procs like Clearcasting or Overpower windows.")
    p:Checkbox("Enable proc alerts", "procs.enabled")
    p:Checkbox("Play sound", "procs.sound", 2)
    p:Dropdown("Sound", {
        get = function() return ns.db.procs.soundChoice end,
        set = function(v)
            ns.db.procs.soundChoice = v
            ns.Alerts:PlayProcSound()
        end,
    }, ns.Alerts.SoundOptions)
    p:Dropdown("Sound channel", "procs.channel", SOUND_CHANNELS, 2)
    p:Button("Test", function() ns.Alerts:TestProc() end)
end

local function BuildProcBuffs(p)
    p:Header("Buffs to watch")
    local box = p:EditBox("Buff name or spell ID")
    local lists
    p:Button("Add", function()
        if ns.Alerts:AddProc(box:GetText()) then
            box:SetText("")
            box:ClearFocus()
            lists.Refresh()
        end
    end, 2, -18, 100)
    lists = p:ProcLists()
end

local function BuildProcLook(p)
    p:Header("Look")
    p:Slider("Display time", "procs.duration", 0.5, 4, 0.1, secs)
    p:Slider("Text size", "procs.size", 16, 60, 1, nil, 2)
    p:Slider("Scale", "procs.scale", 0.5, 2, 0.05, times)
    p:Color("Proc color", "procs.color", 2)
    p:Checkbox("Buff icon", "procs.showIcon")
    p:Checkbox("Buff name", "procs.showName", 2)
    p:Checkbox("Glow burst", "procs.glow")

    p:Header("Position")
    p:Checkbox("Unlock (drag the alert to move it)", {
        get = function() return ns.Alerts.proc.unlocked end,
        set = function(v) ns.Alerts.proc:SetLocked(not v) end,
    })
    p:Button("Test", function() ns.Alerts:TestProc() end)
    p:Button("Reset position", function()
        local P, D = ns.db.procs, ns.defaults.procs
        P.x, P.y = D.x, D.y
        ns.ApplyAll(true)
    end, 2)
end

---------------------------------------------------------------------------
-- Swing timer
---------------------------------------------------------------------------

local function BuildSwing(p)
    p:Header("Swing timer")
    p:Note("A thin lane in the log window, right under the header, that restarts with every auto-attack. When main hand, off hand or ranged run at the same time, they share the lane. It moves, scales and fades with the log window.")
    p:Checkbox("Show swing timer", "swing.enabled")
    p:Checkbox("Time left", "swing.showTime", 2)
    p:Checkbox("Off-hand bar", "swing.offhand")
    p:Checkbox("Ranged bar (Auto Shot, wands)", "swing.ranged", 2)

    p:Header("Look")
    p:Slider("Lane height", "swing.height", 3, 20, 1, px)
    p:Button("Test", function() ns.Swing:Test() end, 2, -12, 100)
    p:Color("Main hand", "swing.color")
    p:Color("Off hand", "swing.offColor", 2)
    p:Color("Ranged", "swing.rangedColor")
    p:Note("Time left is only drawn when a bar is at least 7 px high.")
end

---------------------------------------------------------------------------
-- Resource display
---------------------------------------------------------------------------

local TEXT_MODES = {
    { text = "None", value = "none" },
    { text = "Value (12.3k)", value = "value" },
    { text = "Value / max", value = "valuemax" },
    { text = "Percent", value = "percent" },
    { text = "Missing (-1.2k)", value = "deficit" },
}

local function BuildResGeneral(p)
    p:Header("Personal resource display")
    p:Note("Health, power, druid mana, combo points and a cast bar under your character. On Forever and Retail the game keeps your health and power secret from addons in combat: the bars still fill correctly, but numbers in the text may disappear while you fight.")
    p:Checkbox("Show resource display", "resources.enabled")
    p:Button("Test", function() ns.Resources:Test() end, 2, -2, 100)

    p:Header("Visibility")
    p:Dropdown("Show when", "resources.visibility", {
        { text = "In combat or not full", value = "combatOrNotFull" },
        { text = "Only in combat", value = "combat" },
        { text = "Always", value = "always" },
    })
    p:Slider("Opacity", "resources.alpha", 0.1, 1, 0.05, pct, 2)
    p:Slider("Fade-in time", "resources.fadeIn", 0, 2, 0.05, secs)
    p:Slider("Fade-out time", "resources.fadeOut", 0, 3, 0.05, secs, 2)
    p:Checkbox("Power counts for \"not full\"", "resources.power.countForVisibility")
    p:Note("Rage counts while it is above 0; mana, energy and focus count while they are below full.")
end

local function BuildResLook(p)
    p:Header("Position")
    p:Checkbox("Unlock (drag the display to move it)", {
        get = function() return ns.Resources.unlocked end,
        set = function(v) ns.Resources:SetLocked(not v) end,
    })
    p:Button("Reset position", function()
        local R, D = ns.db.resources, ns.defaults.resources
        R.x, R.y = D.x, D.y
        ns.ApplyAll(true)
    end, 2)
    local sw, sh = math.ceil(GetScreenWidth()), math.ceil(GetScreenHeight())
    p:Slider("Horizontal position", "resources.x", -sw, sw, 1)
    p:Slider("Vertical position", "resources.y", -sh, sh, 1, nil, 2)

    p:Header("Look")
    p:Slider("Width", "resources.width", 80, 500, 5, px)
    p:Slider("Scale", "resources.scale", 0.5, 2.5, 0.05, times, 2)
    p:Slider("Spacing", "resources.spacing", 0, 10, 1, px)
    p:Slider("Background opacity", "resources.bgOpacity", 0, 1, 0.05, pct, 2)
    p:Dropdown("Bar texture", "resources.texture", ns.Resources.TextureOptions)
    p:Dropdown("Background", "resources.bgStyle", {
        { text = "Fade (like the log rows)", value = "fade" },
        { text = "Solid", value = "solid" },
    }, 2)
    p:Checkbox("Gloss", "resources.gloss")
    p:Checkbox("Thin border", "resources.border", 2)
    p:Checkbox("Smooth bar movement", "resources.smooth")

    p:Header("Bar order")
    p:Note("Top to bottom. The cast bar comes and goes: at the top it appears over the display, at the bottom under it, and in between it keeps its place free so nothing jumps.")
    p:OrderList("Bars", ns.Resources.Order, function(list) ns.db.resources.order = list end, {
        health = "Health", power = "Power", druidMana = "Druid mana",
        combo = "Combo points", castbar = "Cast bar",
    })
    p:Button("Reset order", function()
        ns.db.resources.order = ns.CopyTable(ns.defaults.resources.order)
        ns.ApplyAll(true)
    end)
end

local function BuildResHealth(p)
    p:Header("Health")
    p:Checkbox("Health bar", "resources.health.enabled")
    p:Checkbox("Class color", "resources.health.classColor", 2)
    p:Slider("Height", "resources.health.height", 4, 40, 1, px)
    p:Color("Custom color", "resources.health.color", 2)
    p:Dropdown("Left text", "resources.health.textLeft", TEXT_MODES)
    p:Dropdown("Right text", "resources.health.textRight", TEXT_MODES, 2)
    p:Slider("Text size", "resources.health.textSize", 7, 20, 1)
end

local function BuildResPower(p)
    p:Header("Power")
    p:Checkbox("Power bar (mana, rage, energy)", "resources.power.enabled")
    p:Checkbox("Power type color", "resources.power.typeColor", 2)
    p:Slider("Height", "resources.power.height", 2, 30, 1, px)
    p:Color("Custom color", "resources.power.color", 2)
    p:Dropdown("Left text", "resources.power.textLeft", TEXT_MODES)
    p:Dropdown("Right text", "resources.power.textRight", TEXT_MODES, 2)
    p:Slider("Text size", "resources.power.textSize", 7, 20, 1)

    p:Header("Druid mana")
    p:Checkbox("Mana bar in bear and cat form", "resources.druidMana.enabled")
    p:Color("Color", "resources.druidMana.color", 2)
    p:Slider("Height", "resources.druidMana.height", 2, 20, 1, px)
end

local function BuildResCombo(p)
    p:Header("Combo points")
    p:Checkbox("Combo point bar", "resources.combo.enabled")
    p:Checkbox("Only when you have combo points", "resources.combo.onlyWhenActive", 2)
    p:Dropdown("Style", "resources.combo.style", {
        { text = "Bar", value = "bar" },
        { text = "Squares", value = "squares" },
        { text = "Circles", value = "circles" },
        { text = "Diamonds", value = "diamonds" },
    })
    p:Slider("Height / size", "resources.combo.height", 2, 32, 1, px, 2)
    p:Slider("Gap", "resources.combo.gap", 0, 12, 1, px)
    p:Checkbox("Segment lines", "resources.combo.ticks", 2)
    p:Note("Squares share the display's width. Circles and diamonds are as wide as they are high and sit centered. Gap and segment lines: gap for squares, circles and diamonds, segment lines for the bar.")

    p:Header("Color")
    p:Color("Color", "resources.combo.color")
    p:Checkbox("Color gradient", "resources.combo.gradient", 2)
    p:Color("Last point color", "resources.combo.color2")
    p:Note("With a gradient, the first point gets the first color, the last point the second and the points between blend from one to the other.")
end

local function BuildResCast(p)
    p:Header("Cast bar")
    p:Checkbox("Cast bar", "resources.castbar.enabled")
    p:Checkbox("Spell icon", "resources.castbar.icon", 2)
    p:Checkbox("Spell name", "resources.castbar.name")
    p:Checkbox("Time left", "resources.castbar.time", 2)
    p:Slider("Height", "resources.castbar.height", 6, 30, 1, px)
    p:Slider("Text size", "resources.castbar.textSize", 7, 20, 1, nil, 2)
    p:Color("Color", "resources.castbar.color")
    p:Color("Uninterruptible", "resources.castbar.uninterruptibleColor", 2)
end

---------------------------------------------------------------------------
-- Spell reminders
---------------------------------------------------------------------------

local function BuildRemGeneral(p)
    p:Header("Spell reminders")
    p:Note("Icons that light up while a spell from your list (Spells tab) wants attention. \"Usable\": the spell is usable right now and off cooldown, such as Riposte after a parry or Overpower after a dodge. \"Buff\": your buff of that name is missing or about to run out, such as Battle Shout or Arcane Intellect. \"Debuff\": your debuff of that name on your hostile target is missing or about to run out, such as a DoT, Sunder Armor or Hunter's Mark. \"Interrupt\": the spell is usable while your hostile target casts something you can interrupt, such as Kick or Counterspell.")
    p:Checkbox("Enable spell reminders", "reminders.enabled")
    p:Checkbox("Only in combat (default for each reminder)", "reminders.combatOnly", 2)
    p:Slider("Refresh buffs with less than", "reminders.refreshAt", 0, 60, 1, function(v)
        return v == 0 and L["only when missing"] or L["%ss left"]:format(v)
    end)
    p:Button("Test", function() ns.Reminders:Test() end, 2, -12, 100)
    p:Slider("Refresh debuffs with less than", "reminders.debuffRefreshAt", 0, 15, 0.5, function(v)
        return v == 0 and L["only when missing"] or L["%ss left"]:format(v)
    end)
    p:Note("Buff and debuff reminders are dimmed while you can't cast the spell (no mana, on cooldown, target out of range).")
    p:Note("On Forever and Retail the game hides auras from addons during combat. Reminders then go on from what they last saw and from your own casts: a debuff you cast counts as on the target for its normal duration, even if it was resisted or dispelled. Classic clients always see the real auras.")
    p:Note("Cooldowns can be hidden there in combat, too: a \"Usable\" reminder then disappears when you cast the spell and comes back when its normal cooldown (from the game data, without talents) is over. Whether you have enough mana, rage or energy can only be checked while the game shows it. /wl debug lists what is readable right now.")

    p:Header("Default sound")
    p:Checkbox("Play a sound when a reminder comes up", "reminders.sound")
    p:Dropdown("Sound", {
        get = function() return ns.db.reminders.soundChoice end,
        set = function(v)
            local R = ns.db.reminders
            R.soundChoice = v
            ns.Alerts.PlaySound(v, R.channel)
        end,
    }, ns.Alerts.SoundOptions)
    p:Dropdown("Sound channel", "reminders.channel", SOUND_CHANNELS, 2)
end

local function BuildRemSpells(p)
    p:Header("Spells to watch")
    local box = p:EditBox("Spell name or spell ID")
    local addMode = "usable"
    p:Dropdown("Remind when", {
        get = function() return addMode end,
        set = function(v) addMode = v end,
    }, {
        { text = "Usable (Riposte, Overpower)", value = "usable" },
        { text = "Buff missing (Battle Shout)", value = "buff" },
        { text = "Debuff missing on target (Sunder, DoTs)", value = "debuff" },
        { text = "Interrupt (target is casting)", value = "interrupt" },
    }, 2)
    local keyBox = p:EditBox("Key to show (optional, e.g. Q or S-2)")
    keyBox:SetMaxLetters(8)
    local lists
    p:Button("Add", function()
        if ns.Reminders:Add(box:GetText(), addMode, keyBox:GetText()) then
            box:SetText("")
            keyBox:SetText("")
            box:ClearFocus()
            keyBox:ClearFocus()
            lists.Refresh()
        end
    end, 2, -18, 100)
    p:Note("The key appears in the icon's corner, like on an action button. Edit it in the list (Enter saves). Click a reminder's type to switch between Usable, Buff, Debuff and Interrupt. Spells you don't know (yet) stay in the list but never show.")
    lists = p:ReminderLists()

    p:Header("Reminder details")
    p:Note("Pick a reminder to give it its own sound and to choose when it shows. \"Default\" follows the General tab; a sound of \"None\" keeps the reminder silent.")
    local selected -- the spell text of the reminder being edited
    local function entryIndex()
        if selected then return ns.Reminders:Find(selected) end
    end
    local function soundChoices()
        local list = { { text = "Default", value = "default" }, { text = "None", value = "none" } }
        for _, o in ipairs(ns.Alerts.SoundOptions()) do list[#list + 1] = o end
        return list
    end
    local soundDropdown, whenDropdown
    p:Dropdown("Reminder", {
        get = function()
            if not entryIndex() then selected = nil end
            return selected
        end,
        set = function(v)
            selected = v
            soundDropdown.Refresh()
            whenDropdown.Refresh()
        end,
    }, function()
        local list = {}
        for _, i in ipairs(ns.Reminders:Visible()) do
            local entry = ns.db.reminders.list[i]
            list[#list + 1] = { text = (ns.Reminders.Describe(entry.spell)), value = entry.spell, raw = true }
        end
        return list
    end)
    soundDropdown = p:Dropdown("Sound", {
        get = function()
            local i = entryIndex()
            if not i then return nil end
            return ns.db.reminders.list[i].sound or "default"
        end,
        set = function(v)
            local i = entryIndex()
            if not i then return end
            ns.Reminders:SetSound(i, v ~= "default" and v or nil)
            local play = ns.Reminders.SoundFor(ns.db.reminders.list[i].sound)
            if play then ns.Alerts.PlaySound(play, ns.db.reminders.channel) end -- preview on pick
        end,
    }, soundChoices, 2)
    whenDropdown = p:Dropdown("Show", {
        get = function()
            local i = entryIndex()
            if not i then return nil end
            return ns.db.reminders.list[i].when or "default"
        end,
        set = function(v)
            local i = entryIndex()
            if i then ns.Reminders:SetWhen(i, v ~= "default" and v or nil) end
        end,
    }, {
        { text = "Default (General tab)", value = "default" },
        { text = "Only in combat", value = "combat" },
        { text = "Always", value = "always" },
    })
end

local function BuildRemLook(p)
    p:Header("Look")
    p:Slider("Icon size", "reminders.size", 20, 80, 1, px)
    p:Slider("Scale", "reminders.scale", 0.5, 2, 0.05, times, 2)
    p:Slider("Spacing", "reminders.spacing", 0, 20, 1, px)
    p:Color("Highlight color", "reminders.color", 2)
    p:Checkbox("Spell name", "reminders.showName")
    p:Checkbox("Pulsing glow", "reminders.glow", 2)
    p:Checkbox("Animations (pop in with a flash, shrink away)", "reminders.animate")
    p:Button("Test", function() ns.Reminders:Test() end, 2, -2, 100)

    p:Header("Position")
    p:Checkbox("Unlock (drag the icons to move them)", {
        get = function() return ns.Reminders.unlocked end,
        set = function(v) ns.Reminders:SetLocked(not v) end,
    })
    p:Button("Reset position", function()
        local R, D = ns.db.reminders, ns.defaults.reminders
        R.x, R.y = D.x, D.y
        ns.ApplyAll(true)
    end, 2)
end

---------------------------------------------------------------------------
-- Kill alerts
---------------------------------------------------------------------------

local function BuildKillGeneral(p)
    p:Header("Kill alert")
    p:Note("A pop-up when a mob you fought dies: the XP you got counting up, the mob's name and, for kills in quick succession, a multi-kill counter. Your XP bar can fill under it, too (the XP tracker shows it all the time).")
    p:Checkbox("Show kill alerts", "killAlert.enabled")
    p:Button("Test", function() ns.KillAlert:Test() end, 2, -2, 100)
    p:Checkbox("Also kills without XP (grey mobs, max level)", "killAlert.noXpKills")
    p:Slider("Display time", "killAlert.duration", 1, 6, 0.5, secs, 2)
    p:Checkbox("XP gained", "killAlert.showXP")
    p:Checkbox("XP bar", "killAlert.showBar", 2)
    p:Checkbox("Mob name", "killAlert.showName")
    p:Checkbox("Multi-kill counter", "killAlert.multiKill", 2)
    p:Note("Kills come from the XP message on every client. On Classic clients the combat log also reports kills without XP. On Forever and Retail there is no such event: a kill without XP is noticed when your target dies after you hit it, so it has to be targeted.")
end

local function BuildKillSound(p)
    p:Header("Sound")
    p:Checkbox("Play a sound", "killAlert.sound")
    p:Checkbox("Rising pitch for multi-kills", "killAlert.risingPitch", 2)
    p:Dropdown("Sound", {
        get = function() return ns.db.killAlert.soundChoice end,
        set = function(v)
            local K = ns.db.killAlert
            K.soundChoice = v
            ns.Alerts.PlaySound(v, K.channel)
        end,
    }, ns.Alerts.SoundOptions)
    p:Dropdown("Sound channel", "killAlert.channel", SOUND_CHANNELS, 2)
    p:Note("Rising pitch works with the WombatLog sounds; sounds from WoW or SharedMedia play unchanged.")
end

local function BuildKillLook(p)
    p:Header("Look")
    p:Slider("Text size", "killAlert.size", 16, 60, 1)
    p:Slider("Scale", "killAlert.scale", 0.5, 2, 0.05, times, 2)
    p:Color("XP color", "killAlert.color")

    p:Header("Text")
    p:Dropdown("Number font", "killAlert.font", alertFontOptions)
    p:Dropdown("Name font", "killAlert.nameFont", alertFontOptions, 2)
    p:Dropdown("Outline", "killAlert.outline", OUTLINE_OPTIONS)

    p:Header("Position")
    p:Checkbox("Unlock (drag the alert to move it)", {
        get = function() return ns.KillAlert.unlocked end,
        set = function(v) ns.KillAlert:SetLocked(not v) end,
    })
    p:Button("Reset position", function()
        local K, D = ns.db.killAlert, ns.defaults.killAlert
        K.x, K.y = D.x, D.y
        ns.ApplyAll(true)
    end, 2)
end

-- The XP bar's look and effects, shared by the kill alert and the XP tracker.
local function BuildXPBarLook(p, path)
    p:Dropdown("Bar texture", path .. ".texture", ns.Resources.TextureOptions)
    p:Slider("Background opacity", path .. ".bgOpacity", 0, 1, 0.05, pct, 2)
    p:Slider("Segments", path .. ".segments", 0, 20, 1, function(v) return v < 2 and L["None"] or tostring(v) end)
    p:Checkbox("Thin border", path .. ".border", 2)
    p:Slider("Fill speed", path .. ".speed", 1, 20, 1)
end

local function BuildXPBarEffects(p, path, test)
    p:Header("Effects")
    p:Checkbox("Spark at the fill's edge", path .. ".spark")
    p:Checkbox("Gloss", path .. ".gloss", 2)
    p:Checkbox("Light up the XP just gained", path .. ".gainFlash")
    p:Checkbox("Glow behind the bar", path .. ".glow", 2)
    p:Checkbox("Show rested XP", path .. ".rested")
    p:Checkbox("Percent text", path .. ".percent", 2)
    p:Button("Test", test)
end

local function BuildKillBar(p)
    p:Header("XP bar")
    p:Note("Your XP bar under the kill alert. Turn it on or off under General. Unlock the alert under Look to see changes live.")
    p:Slider("Length", "killAlert.bar.width", 0, 500, 10, autoPx)
    p:Slider("Thickness", "killAlert.bar.height", 0, 30, 1, autoPx, 2)
    BuildXPBarLook(p, "killAlert.bar")
    p:Checkbox("Same color as the XP text", "killAlert.bar.useTextColor")
    p:Color("Custom bar color", "killAlert.bar.color", 2)
    BuildXPBarEffects(p, "killAlert.bar", function() ns.KillAlert:Test() end)
end

local function BuildKillQuest(p)
    p:Header("Quest alert")
    p:Note("The same pop-up when you turn in a quest: the XP counting up and the quest's name. Size, fonts, position and display time are the kill alert's.")
    p:Checkbox("Show quest alerts", "questAlert.enabled")
    p:Button("Test", function() ns.KillAlert:TestQuest() end, 2, -2, 100)
    p:Checkbox("Quest name", "questAlert.showName")
    p:Color("XP color", "questAlert.color", 2)

    p:Header("Sound")
    p:Checkbox("Play a sound", "questAlert.sound")
    p:Dropdown("Sound", {
        get = function() return ns.db.questAlert.soundChoice end,
        set = function(v)
            local Q = ns.db.questAlert
            Q.soundChoice = v
            ns.Alerts.PlaySound(v, Q.channel)
        end,
    }, ns.Alerts.SoundOptions)
    p:Dropdown("Sound channel", "questAlert.channel", SOUND_CHANNELS, 2)
end

---------------------------------------------------------------------------
-- XP tracker
---------------------------------------------------------------------------

local function BuildTrackerGeneral(p)
    p:Header("XP tracker")
    p:Note("A small XP bar that is always on screen. When you get XP it springs up bigger, fills with a glow and shows the XP you got, then settles back.")
    p:Checkbox("Show the XP tracker", "xpTracker.enabled")
    p:Button("Test", function() ns.XPTracker:Test() end, 2, -2, 100)
    p:Checkbox("Hide at max level", "xpTracker.hideAtMax")
    p:Checkbox("Level", "xpTracker.showLevel", 2)
    p:Checkbox("XP gained under the bar", "xpTracker.popText")

    p:Header("Growing")
    p:Slider("Size when XP comes in", "xpTracker.popScale", 1, 2.5, 0.05, times)
    p:Slider("Stays big for", "xpTracker.popHold", 0.5, 5, 0.5, secs, 2)
end

local function BuildTrackerLook(p)
    p:Header("Look")
    p:Slider("Length", "xpTracker.width", 80, 500, 10, px)
    p:Slider("Thickness", "xpTracker.height", 4, 30, 1, px, 2)
    p:Slider("Scale", "xpTracker.scale", 0.5, 2, 0.05, times)
    p:Color("Bar color", "xpTracker.color", 2)

    p:Header("Text")
    p:Slider("Text size", "xpTracker.textSize", 8, 30, 1)
    p:Dropdown("Font", "xpTracker.font", alertFontOptions, 2)
    p:Dropdown("Outline", "xpTracker.outline", OUTLINE_OPTIONS)

    p:Header("Position")
    p:Checkbox("Unlock (drag the tracker to move it)", {
        get = function() return ns.XPTracker.unlocked end,
        set = function(v) ns.XPTracker:SetLocked(not v) end,
    })
    p:Button("Reset position", function()
        local T, D = ns.db.xpTracker, ns.defaults.xpTracker
        T.x, T.y = D.x, D.y
        ns.ApplyAll(true)
    end, 2)
end

local function BuildTrackerBar(p)
    p:Header("XP bar")
    BuildXPBarLook(p, "xpTracker.bar")
    BuildXPBarEffects(p, "xpTracker.bar", function() ns.XPTracker:Test() end)
end

---------------------------------------------------------------------------
-- Fight summary, session, minimap
---------------------------------------------------------------------------

local function BuildStatsSummary(p)
    p:Header("Fight summary")
    p:Note("A card after each fight: DPS, HPS, crit rate, biggest hit, longest streak, top spells and new records. Click it to open the journal, right-click to close, drag to move.")
    p:Checkbox("Show summary after combat", "stats.summary.enabled")
    p:Slider("Display time", "stats.summary.duration", 0, 30, 1, function(v)
        return v == 0 and L["until clicked"] or (v .. "s")
    end, 2)
    p:Slider("Scale", "stats.summary.scale", 0.5, 2, 0.05, times)
    p:Button("Show last fight", function() ns.Report:TestSummary() end, 2, -12)
    p:Button("Reset position", function()
        local S, D = ns.db.stats.summary, ns.defaults.stats.summary
        S.x, S.y = D.x, D.y
        ns.ApplyAll(true)
    end)
end

local function BuildStatsHistory(p)
    p:Header("Fight history")
    p:Checkbox("Record fight history", "stats.history.enabled")
    p:Slider("Fights to keep", "stats.history.keep", 5, 100, 5)
    p:Slider("Ignore fights shorter than", "stats.history.minDuration", 0, 30, 1, wholeSecs, 2)

    p:Header("Personal records")
    p:Note("Your best normal hit and best crit per spell, best DPS and longest crit streak, per character. A spell's first hit is saved silently; only beating a record counts as new.")
    p:Checkbox("Track records", "stats.records.enabled")
    p:Slider("Best DPS: min fight length", "stats.records.minDpsDuration", 0, 60, 1, wholeSecs)
    p:Note("The record banner and sound are under Crit alerts, Streaks & records.")
    p:Button("Open journal", function() ns.Report:OpenJournal("fights") end)
    p:Button("Records", function() ns.Report:OpenJournal("records") end, 2)
end

local function BuildSession(p)
    p:Header("Session tracker")
    p:Note("Tracks this play session: kills, XP per hour, time and kills to the next level, rested XP, deaths and money. A /reload continues the session; logging in again starts a new one.")
    p:Checkbox("Track session", "session.enabled")
    p:Checkbox("Session line above the log window", "session.headerLine", 2)
    p:Button("Open session", function() ns.Report:OpenJournal("session") end)
    p:Button("Reset session", function()
        ns.Stats:ResetSession()
        ns.Print(L["session reset."])
    end, 2)
end

local function BuildMinimap(p)
    p:Header("Minimap button")
    p:Checkbox("Show minimap button", "minimap.enabled")
    p:Note("Click: journal. Right-click: settings. Shift-click: test fight. Drag it along the minimap edge. WombatLog is also listed in the addon compartment.")
end

---------------------------------------------------------------------------
-- Language
---------------------------------------------------------------------------

local function BuildLanguage(p)
    p:Header("Language")
    p:Dropdown("Language", {
        get = function() return WombatLogDB.locale or "auto" end,
        set = function(v)
            if v == (WombatLogDB.locale or "auto") then return end
            WombatLogDB.locale = v
            Confirm(L["The new language is used after reloading the interface. Reload now?"], ReloadUI)
        end,
    }, ns.LocaleOptions)
    p:Note("Applies to all characters. \"Automatic\" follows the language of your game client and falls back to English.")
    p:Note("Missing your language? Copy Locales/deDE.lua in the addon folder, translate it and add it to WombatLog.toc. It then shows up here by itself. Translations are welcome on GitHub.")
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------

local function BuildProfiles(p)
    local Profiles = ns.Profiles
    local function profileOptions(exclude)
        local list = {}
        for _, name in ipairs(Profiles.List()) do
            if name ~= exclude then list[#list + 1] = { text = name, value = name, raw = true } end
        end
        return list
    end

    p:Header("Active profile")
    p:Note("Profiles are shared by all your characters. Each character remembers which one it uses.")
    p:Dropdown("Profile for this character", {
        get = Profiles.Current,
        set = Profiles.Set,
    }, function() return profileOptions() end)

    p:Header("New profile")
    local nameBox = p:EditBox("Name")
    local function create(copy)
        local name = strtrim(nameBox:GetText() or "")
        if Profiles.New(name, copy and Profiles.Current() or nil) then
            nameBox:SetText("")
            nameBox:ClearFocus()
            ns.Print(L["now using profile '%s'."]:format(name))
        else
            ns.Print(L["enter a profile name that isn't taken yet."])
        end
    end
    p:Button("Create with defaults", function() create(false) end)
    p:Button("Copy current profile", function() create(true) end, 2)

    p:Header("Manage")
    local deleteTarget
    p:Dropdown("Profile to delete", {
        get = function() return deleteTarget end,
        set = function(v) deleteTarget = v end,
    }, function() return profileOptions(Profiles.Current()) end)
    p:Button("Delete", function()
        local target = deleteTarget
        if not target then return end
        Confirm(L["Delete profile '%s'?"]:format(target), function()
            Profiles.Delete(target)
            deleteTarget = nil
            Config:RefreshAll()
        end)
    end, 2, -18, 120)
    p:Button("Reset current profile", function()
        Confirm(L["Reset profile '%s' to defaults?"]:format(Profiles.Current()), Profiles.Reset)
    end)
end

-- One sidebar tab per feature; bigger features split into sub-tabs along the top.
-- An entry is { "Name", builder } or { "Name", { { "Sub-tab", builder }, ... } }.
local TABS = {
    { "Combat log", {
        { "Layout", BuildLogLayout },
        { "Header", BuildLogHeader },
        { "Crits", BuildLogCrits },
        { "Colors", BuildLogColors },
        { "Events", BuildLogEvents },
        { "Window", BuildLogWindow },
    } },
    { "Crit alerts", {
        { "Visual", BuildAlertVisual },
        { "Sound", BuildAlertSound },
        { "Streaks & records", BuildAlertStreaks },
    } },
    { "Proc alerts", {
        { "General", BuildProcGeneral },
        { "Buffs", BuildProcBuffs },
        { "Look", BuildProcLook },
    } },
    { "Spell reminders", {
        { "General", BuildRemGeneral },
        { "Spells", BuildRemSpells },
        { "Look", BuildRemLook },
    } },
    { "Kill alerts", {
        { "General", BuildKillGeneral },
        { "Sound", BuildKillSound },
        { "Look", BuildKillLook },
        { "XP bar", BuildKillBar },
        { "Quest alert", BuildKillQuest },
    } },
    { "XP tracker", {
        { "General", BuildTrackerGeneral },
        { "Look", BuildTrackerLook },
        { "XP bar", BuildTrackerBar },
    } },
    { "Swing timer", BuildSwing },
    { "Resource display", {
        { "General", BuildResGeneral },
        { "Look", BuildResLook },
        { "Health", BuildResHealth },
        { "Power", BuildResPower },
        { "Combo points", BuildResCombo },
        { "Cast bar", BuildResCast },
    } },
    { "Fight summary", {
        { "Summary", BuildStatsSummary },
        { "History & records", BuildStatsHistory },
    } },
    { "Session", BuildSession },
    { "Minimap button", BuildMinimap },
    { "Language", BuildLanguage },
    { "Profiles", BuildProfiles },
}

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

-- Sidebar tabs mark the active one on the left edge, sub-tabs along the bottom.
local function TabButton(parent, label, mark)
    local b = CreateFrame("Button", nil, parent)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.05)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.underline = b:CreateTexture(nil, "ARTWORK")
    b.underline:SetColorTexture(1, 0.82, 0, 0.9)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetText(L[label])
    if mark == "bottom" then
        b.underline:SetHeight(2)
        b.underline:SetPoint("BOTTOMLEFT")
        b.underline:SetPoint("BOTTOMRIGHT")
        b.text:SetPoint("CENTER", 0, 1)
    else
        b.underline:SetWidth(3)
        b.underline:SetPoint("TOPLEFT")
        b.underline:SetPoint("BOTTOMLEFT")
        b.text:SetPoint("LEFT", 10, 0)
    end
    return b
end

local function Highlight(b, on)
    b.underline:SetShown(on)
    b.text:SetTextColor(on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
end

-- sub: which sub-tab to show; each feature remembers its last one.
function Config:SelectTab(index, sub)
    for i, tab in ipairs(self.tabs) do
        local on = i == index
        Highlight(tab, on)
        if tab.page then tab.page.scroll:SetShown(on) end
        if tab.subs then
            if on and sub then tab.sub = sub end
            tab.bar:SetShown(on)
            for j, s in ipairs(tab.subs) do
                Highlight(s, j == tab.sub)
                s.page.scroll:SetShown(on and j == tab.sub)
            end
        end
    end
end

function Config:RefreshAll()
    if not self.panel then return end
    refreshing = true
    for _, w in ipairs(widgets) do w.Refresh() end
    refreshing = false
    self.profileText:SetText(L["Profile:"] .. " |cffffffff" .. (ns.Profiles.Current() or "") .. "|r")
end

function Config:Init()
    local panel = CreateFrame("Frame", "WombatLogConfig")
    panel:Hide()
    self.panel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("WombatLog")
    self.profileText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    self.profileText:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 14, 2)

    self.tabs = {}
    for i, def in ipairs(TABS) do
        local tab = TabButton(panel, def[1])
        tab:SetSize(SIDEBAR_W, 24)
        tab:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -50 - (i - 1) * 27)
        if type(def[2]) == "function" then
            tab.page = NewPage(panel)
            def[2](tab.page)
        else
            tab.sub = 1
            tab.subs = {}
            tab.bar = CreateFrame("Frame", nil, panel)
            tab.bar:SetPoint("TOPLEFT", panel, "TOPLEFT", SIDEBAR_W + 26, SUBTAB_TOP)
            tab.bar:SetSize(PAGE_WIDTH, 24)
            local x = 0
            for j, sub in ipairs(def[2]) do
                local s = TabButton(tab.bar, sub[1], "bottom")
                local w = math.ceil(s.text:GetStringWidth()) + 22
                s:SetSize(w, 24)
                s:SetPoint("TOPLEFT", x, 0)
                x = x + w + 3
                s.page = NewPage(panel, SUBPAGE_TOP)
                sub[2](s.page)
                s:SetScript("OnClick", function() Config:SelectTab(i, j) end)
                tab.subs[j] = s
            end
        end
        tab:SetScript("OnClick", function() Config:SelectTab(i) end)
        self.tabs[i] = tab
    end
    self:SelectTab(1)

    panel:SetScript("OnShow", function()
        Config:RefreshAll()
        ns.Display:SetPreview(true)
        ns.Resources:SetPreview(true)
    end)
    panel:SetScript("OnHide", function()
        ns.Display:SetPreview(false)
        ns.Resources:SetPreview(false)
        if ns.Resources.unlocked then ns.Resources:SetLocked(true) end
        if not ns.locked then ns.Display:SetLocked(true) end
        if ns.Alerts.crit.unlocked then ns.Alerts.crit:SetLocked(true) end
        if ns.Alerts.proc.unlocked then ns.Alerts.proc:SetLocked(true) end
        if ns.Reminders.unlocked then ns.Reminders:SetLocked(true) end
        if ns.KillAlert.unlocked then ns.KillAlert:SetLocked(true) end
        if ns.XPTracker.unlocked then ns.XPTracker:SetLocked(true) end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        self.category = Settings.RegisterCanvasLayoutCategory(panel, "WombatLog")
        Settings.RegisterAddOnCategory(self.category)
    else
        -- no Settings API: run as a standalone window
        panel:SetParent(UIParent)
        panel:SetSize(720, 600)
        panel:SetPoint("CENTER")
        panel:SetFrameStrata("DIALOG")
        panel:SetMovable(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        local bg = panel:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
        local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
        tinsert(UISpecialFrames, "WombatLogConfig")
    end
end

function Config:Open()
    if not self.panel then return end
    if self.category then
        Settings.OpenToCategory(self.category:GetID())
    else
        self.panel:SetShown(not self.panel:IsShown())
    end
end
