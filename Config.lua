local ADDON, ns = ...
local Config = {}
ns.Config = Config

local WHITE = "Interface\\Buttons\\WHITE8X8"
local PAGE_WIDTH = 600
local COL2_X = 310

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
    { text = "Friz Quadrata", value = "Fonts\\FRIZQT__.TTF" },
    { text = "Arial Narrow", value = "Fonts\\ARIALN.TTF" },
    { text = "Morpheus", value = "Fonts\\MORPHEUS.TTF" },
    { text = "Skurri", value = "Fonts\\SKURRI.TTF" },
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
                list[#list + 1] = { text = name, value = path }
            end
        end
    end
    return list
end

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

local function NewPage(parent)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate")
    if not ok or not scroll.ScrollBar then
        scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    end
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -82)
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
    fs:SetText(text)
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
    fs:SetText(text)
    self:Add(fs, math.max(fs:GetStringHeight(), 12) + 8)
end

function Page:Checkbox(label, bind, col)
    bind = asBind(bind)
    local cb = CreateFrame("CheckButton", nil, self.child, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    if cb.Text then cb.Text:SetText("") end
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(label)
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
    holder:SetSize(270, 44)

    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(label)
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

-- options: list of { text, value } or a function returning one
function Page:Dropdown(label, bind, options, col)
    bind = asBind(bind)
    local function opts()
        return type(options) == "function" and options() or options
    end
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(270, 48)
    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(label)

    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, holder, "WowStyle1DropdownTemplate")
    if ok and dd and dd.SetupMenu then
        dd:SetPoint("TOPLEFT", 0, -18)
        dd:SetWidth(230)
        if dd.SetDefaultText then dd:SetDefaultText("Choose...") end
        dd:SetupMenu(function(_, root)
            for _, o in ipairs(opts()) do
                root:CreateRadio(o.text,
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
        b:SetSize(230, 22)
        b:SetPoint("TOPLEFT", 0, -18)
        local function current()
            for _, o in ipairs(opts()) do
                if o.value == bind.get() then return o.text end
            end
            return "Choose..."
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
    b:SetSize(270, 24)

    local border = b:CreateTexture(nil, "BACKGROUND")
    border:SetSize(20, 20)
    border:SetPoint("LEFT")
    border:SetColorTexture(0.85, 0.85, 0.85, 1)
    local swatch = b:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(18, 18)
    swatch:SetPoint("CENTER", border)
    local text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", border, "RIGHT", 8, 0)
    text:SetText(label)
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
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    self:Add(b, 32, col, dy)
    return b
end

function Page:EditBox(label, col)
    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(270, 48)
    local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText(label)
    local e = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    e:SetSize(220, 22)
    e:SetPoint("TOPLEFT", 6, -18)
    e:SetAutoFocus(false)
    e:SetMaxLetters(32)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    self:Add(holder, 50, col)
    return e
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

local function BuildAppearance(p)
    p:Header("Layout")
    p:Slider("Window width", "appearance.width", 200, 600, 10, px)
    p:Slider("Row height", "appearance.rowHeight", 14, 40, 1, px, 2)
    p:Slider("Row spacing", "appearance.rowGap", 0, 10, 1, px)
    p:Slider("Row background opacity", "appearance.rowBgOpacity", 0, 1, 0.05, pct, 2)
    p:Checkbox("Show spell icons", "appearance.showIcons")
    p:Checkbox("Incoming events on the right", "appearance.mirrorIncoming", 2)
    p:Checkbox("Newest row on top", "appearance.newestOnTop")
    p:Checkbox("Dim older rows", "appearance.ageDim", 2)

    p:Header("Text")
    p:Dropdown("Number font", "appearance.amountFont", fontOptions)
    p:Dropdown("Name font", "appearance.nameFont", fontOptions, 2)
    p:Slider("Number size", "appearance.amountSize", 8, 28, 1)
    p:Slider("Name size", "appearance.nameSize", 8, 24, 1, nil, 2)
    p:Dropdown("Outline", "appearance.outline", {
        { text = "None", value = "" },
        { text = "Outline", value = "OUTLINE" },
        { text = "Thick outline", value = "THICKOUTLINE" },
    })
    p:Dropdown("Number format", "appearance.numberFormat", {
        { text = "Full (12,345)", value = "full" },
        { text = "Short (12.3k)", value = "short" },
    }, 2)

    p:Header("Header")
    p:Checkbox("Show header", "appearance.header.show")
    p:Checkbox("DPS", "appearance.header.dps", 2)
    p:Checkbox("HPS", "appearance.header.hps")
    p:Checkbox("Fight timer", "appearance.header.timer", 2)
    p:Checkbox("Damage / taken totals", "appearance.header.totals")
    p:Checkbox("Biggest hit", "appearance.header.biggest", 2)
end

local function BuildCrits(p)
    p:Header("Crit effects")
    p:Note("Crit rows always get a bigger number and a thicker accent bar. These add the extras on top.")
    p:Checkbox("Pop-in animation", "crit.pop")
    p:Slider("Pop size", "crit.popScale", 1.1, 2.5, 0.1, times, 2)
    p:Checkbox("Shine sweep", "crit.shine")
    p:Checkbox("Flash", "crit.flash", 2)
    p:Checkbox("Row tint", "crit.glow")
    p:Checkbox("Icon border", "crit.iconBorder", 2)
    p:Checkbox("CRIT tag", "crit.tag")
    p:Slider("Crit number size", "appearance.critSize", 10, 40, 1)
    p:Button("Replay crit animation", function() ns.Display:ReplayCrits() end, 2, -12)
    p:Note("The crit highlight color is on the Colors tab.")
end

local function BuildColors(p)
    p:Header("Row types")
    local kinds = {}
    for _, k in ipairs(KINDS) do
        if k[1] ~= "damage" then kinds[#kinds + 1] = k end
    end
    for i, k in ipairs(kinds) do
        p:Color(k[2], "colors." .. k[1], (i % 2 == 0) and 2 or nil)
    end

    p:Header("Crits")
    p:Color("Crit highlight", "colors.crit")

    p:Header("Damage schools")
    p:Note("Your damage rows use the color of the spell's school.")
    local i = 0
    for _, mask in ipairs({ 1, 2, 4, 8, 16, 32, 64 }) do
        i = i + 1
        p:Color(ns.SCHOOL_NAMES[mask], "colors.schools." .. mask, (i % 2 == 0) and 2 or nil)
    end

    p.y = p.y - 8
    p:Button("Reset all colors", function()
        Confirm("Reset all colors to their defaults?", function()
            ns.db.colors = ns.CopyTable(ns.defaults.colors)
            ns.ApplyAll(true)
        end)
    end)
end

local function BuildPosition(p)
    local P = function() return ns.db.position end
    local sw, sh = math.ceil(GetScreenWidth()), math.ceil(GetScreenHeight())

    p:Header("Window")
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

local function BuildBehaviour(p)
    p:Header("Visibility")
    p:Dropdown("Show the window", "behaviour.visibility", {
        { text = "Only in combat", value = "combat" },
        { text = "Always", value = "always" },
    })
    p:Slider("Stay after combat", "behaviour.linger", 0, 30, 1, wholeSecs, 2)
    p:Slider("Fade-in time", "behaviour.fadeIn", 0, 2, 0.05, secs)
    p:Slider("Fade-out time", "behaviour.fadeOut", 0, 3, 0.05, secs, 2)
    p:Slider("Max rows", "behaviour.lines", 3, 30, 1)
    p:Checkbox("Clear the log when a new fight starts", "behaviour.clearOnNewFight", 2)

    p:Header("Events to show")
    for i, k in ipairs(KINDS) do
        p:Checkbox(k[2], "behaviour.show." .. k[1], (i % 2 == 0) and 2 or nil)
    end

    p:Header("Filters")
    p:Slider("Min amount: your hits & heals", "behaviour.minAmountOut", 0, 5000, 10)
    p:Slider("Min amount: incoming", "behaviour.minAmountIn", 0, 5000, 10, nil, 2)
    p:Checkbox("Only crits: your hits & heals", "behaviour.hideNormalOut")
    p:Checkbox("Only crits: incoming", "behaviour.hideNormalIn", 2)
    p:Note("Incoming covers damage taken and heals on you. Hidden rows still count toward DPS, HPS and totals.")
    p:Checkbox("Strict group filter", "behaviour.strict")
    p:Note("In a group, hits on your target that can't be matched to your own swing or cast are dropped. Turn this off to show them dimmed instead. They never count toward your DPS.")
end

local function BuildProfiles(p)
    local Profiles = ns.Profiles
    local function profileOptions(exclude)
        local list = {}
        for _, name in ipairs(Profiles.List()) do
            if name ~= exclude then list[#list + 1] = { text = name, value = name } end
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
            ns.Print("now using profile '" .. name .. "'.")
        else
            ns.Print("enter a profile name that isn't taken yet.")
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
        Confirm("Delete profile '" .. target .. "'?", function()
            Profiles.Delete(target)
            deleteTarget = nil
            Config:RefreshAll()
        end)
    end, 2, -18, 120)
    p:Button("Reset current profile", function()
        Confirm("Reset profile '" .. Profiles.Current() .. "' to defaults?", Profiles.Reset)
    end)
end

local TABS = {
    { "Appearance", BuildAppearance },
    { "Crits", BuildCrits },
    { "Colors", BuildColors },
    { "Position", BuildPosition },
    { "Behaviour", BuildBehaviour },
    { "Profiles", BuildProfiles },
}

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function Config:SelectTab(index)
    for i, tab in ipairs(self.tabs) do
        local on = i == index
        tab.page.scroll:SetShown(on)
        tab.underline:SetShown(on)
        tab.text:SetTextColor(on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
    end
end

function Config:RefreshAll()
    if not self.panel then return end
    refreshing = true
    for _, w in ipairs(widgets) do w.Refresh() end
    refreshing = false
    self.profileText:SetText("Profile: |cffffffff" .. (ns.Profiles.Current() or "") .. "|r")
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
        local tab = CreateFrame("Button", nil, panel)
        tab:SetSize(96, 24)
        tab:SetPoint("TOPLEFT", panel, "TOPLEFT", 16 + (i - 1) * 100, -50)
        local bg = tab:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.05)
        local hl = tab:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        tab.underline = tab:CreateTexture(nil, "ARTWORK")
        tab.underline:SetColorTexture(1, 0.82, 0, 0.9)
        tab.underline:SetHeight(2)
        tab.underline:SetPoint("BOTTOMLEFT")
        tab.underline:SetPoint("BOTTOMRIGHT")
        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tab.text:SetPoint("CENTER")
        tab.text:SetText(def[1])

        tab.page = NewPage(panel)
        def[2](tab.page)
        tab:SetScript("OnClick", function() Config:SelectTab(i) end)
        self.tabs[i] = tab
    end
    self:SelectTab(1)

    panel:SetScript("OnShow", function()
        Config:RefreshAll()
        ns.Display:SetPreview(true)
    end)
    panel:SetScript("OnHide", function()
        ns.Display:SetPreview(false)
        if not ns.locked then ns.Display:SetLocked(true) end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        self.category = Settings.RegisterCanvasLayoutCategory(panel, "WombatLog")
        Settings.RegisterAddOnCategory(self.category)
    else
        -- no Settings API: run as a standalone window
        panel:SetParent(UIParent)
        panel:SetSize(680, 580)
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
