-- Profession Workbench: the flat dark crafting window

local ADDON, ns = ...
local PW = ns.PW

local floor, min, max, format = math.floor, math.min, math.max, string.format
local BT = BackdropTemplateMixin and "BackdropTemplate" or nil
local WHITE = "Interface\\Buttons\\WHITE8X8"

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------

local C = {
    bg       = { 0.07, 0.07, 0.08, 0.97 },
    panel    = { 0.11, 0.11, 0.13, 1 },
    button   = { 0.16, 0.16, 0.19, 1 },
    hover    = { 0.22, 0.22, 0.26, 1 },
    selected = { 0.16, 0.27, 0.45, 1 },
    border   = { 0.24, 0.24, 0.28, 1 },
    text     = { 0.92, 0.92, 0.92 },
    muted    = { 0.58, 0.58, 0.62 },
    header   = { 0.85, 0.75, 0.5 },
    accent   = { 0.35, 0.6, 1 },
    cooldown = { 1, 0.72, 0.3 },
}

local DIFF = {
    optimal = { color = { 1, 0.5, 0.25 },    label = "Orange", desc = "Guaranteed skill-up" },
    medium  = { color = { 1, 0.82, 0 },      label = "Yellow", desc = "Likely skill-up" },
    easy    = { color = { 0.25, 0.75, 0.25 }, label = "Green",  desc = "Unlikely skill-up" },
    trivial = { color = { 0.5, 0.5, 0.5 },   label = "Gray",   desc = "No skill-up" },
}
local DIFF_ORDER = { "optimal", "medium", "easy", "trivial" }
local FALLBACK = { color = { 0.9, 0.9, 0.9 }, label = "", desc = "" }
PW.DIFF = DIFF

local W, H = 780, 520
local PAD = 8
local BODY_TOP = -104
local FOOTER_H = 26
local LIST_W = 340
local ROW_H = 20
local NUM_ROWS = floor(((H + BODY_TOP - FOOTER_H - PAD) - 8) / ROW_H)
local NUM_REAGENTS = 7
local NUM_CD_LINES = 3

PW.offset = 0
PW.display = {}
PW.recipes = {}
PW.byIndex = {}
PW.collapsed = {}
PW.searchText = ""

---------------------------------------------------------------------------
-- Widget helpers
---------------------------------------------------------------------------

local function SetBD(f, bg, border)
    if not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(unpack(bg))
    f:SetBackdropBorderColor(unpack(border or C.border))
end

local function Text(parent, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetTextColor(unpack(color or C.text))
    fs:SetJustifyH("LEFT")
    return fs
end

local function FlatButton(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent, BT)
    b:SetSize(w, h)
    SetBD(b, C.button)
    b.label = Text(b, "GameFontHighlightSmall")
    b.label:SetPoint("CENTER")
    b.label:SetJustifyH("CENTER")
    b.label:SetText(label)
    b:SetScript("OnEnter", function(self)
        if self:IsEnabled() then self:SetBackdropColor(unpack(C.hover)) end
    end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(C.button)) end)
    return b
end

local function SetButtonEnabled(b, on)
    b:SetEnabled(on)
    if on then
        b.label:SetTextColor(unpack(C.text))
    else
        b.label:SetTextColor(0.4, 0.4, 0.42)
        b:SetBackdropColor(unpack(C.button))
    end
end

local function Toggle(parent, label, key, width)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 18)
    b.box = CreateFrame("Frame", nil, b, BT)
    b.box:SetSize(12, 12)
    b.box:SetPoint("LEFT")
    SetBD(b.box, C.panel)
    b.fill = b.box:CreateTexture(nil, "OVERLAY")
    b.fill:SetTexture(WHITE)
    b.fill:SetPoint("TOPLEFT", 3, -3)
    b.fill:SetPoint("BOTTOMRIGHT", -3, 3)
    b.fill:SetVertexColor(unpack(C.accent))
    b.text = Text(b, "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", b.box, "RIGHT", 6, 0)
    b.text:SetText(label)
    b.key = key
    b:SetScript("OnClick", function(self)
        PW.db.filters[self.key] = not PW.db.filters[self.key]
        PW:UpdateFilterWidgets()
        PW.offset = 0
        PW:RebuildList()
        PW:UpdateDetail()
    end)
    return b
end

local function ShowTooltip(owner, fn)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    fn(GameTooltip)
    GameTooltip:Show()
end

local function InsertLink(link)
    if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function PW:RestorePosition()
    local f = self.frame
    if not f then return end
    f:ClearAllPoints()
    local p = self.db.point
    if p then
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

local function BuildTitle(f)
    f.title = Text(f, "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 12, -9)

    f.rank = Text(f, "GameFontHighlight", C.muted)
    f.rank:SetPoint("LEFT", f.title, "RIGHT", 10, 0)

    local close = CreateFrame("Button", nil, f)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -6, -6)
    close.label = Text(close, "GameFontHighlight", C.muted)
    close.label:SetPoint("CENTER")
    close.label:SetText("X")
    close:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 0.4, 0.4) end)
    close:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(C.muted)) end)
    close:SetScript("OnClick", function() f:Hide() end)

    local bar = CreateFrame("StatusBar", nil, f, BT)
    bar:SetPoint("TOPLEFT", 12, -34)
    bar:SetPoint("TOPRIGHT", -12, -34)
    bar:SetHeight(8)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(unpack(C.accent))
    SetBD(bar, C.panel)
    f.skillBar = bar
end

local function BuildToolbar(f)
    -- Search
    local search = CreateFrame("EditBox", nil, f, BT)
    search:SetPoint("TOPLEFT", PAD, -52)
    search:SetSize(LIST_W - 92, 22)
    SetBD(search, C.panel)
    search:SetFontObject(ChatFontNormal)
    search:SetAutoFocus(false)
    search:SetTextInsets(8, 8, 0, 0)
    search.hint = Text(search, "GameFontDisableSmall", C.muted)
    search.hint:SetPoint("LEFT", 8, 0)
    search.hint:SetText("Search recipes or reagents")
    search:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        self.hint:SetShown(text == "")
        PW.searchText = text:lower()
        PW.offset = 0
        PW:RebuildList()
    end)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    f.search = search

    -- Collapse / expand every category at once
    local ca = FlatButton(f, "Collapse all", 86, 22)
    ca:SetPoint("LEFT", search, "RIGHT", 6, 0)
    ca:SetScript("OnClick", function() PW:ToggleCollapseAll() end)
    f.collapseAll = ca

    -- Difficulty chips
    f.chips = {}
    local x = PAD
    for _, key in ipairs(DIFF_ORDER) do
        local d = DIFF[key]
        local chip = CreateFrame("Button", nil, f, BT)
        chip:SetSize(22, 16)
        chip:SetPoint("TOPLEFT", x, -82)
        SetBD(chip, { d.color[1], d.color[2], d.color[3], 1 }, { 0, 0, 0, 1 })
        chip.key = key
        chip:SetScript("OnClick", function(self)
            PW.db.filters[self.key] = not PW.db.filters[self.key]
            PW:UpdateFilterWidgets()
            PW.offset = 0
            PW:RebuildList()
        end)
        chip:SetScript("OnEnter", function(self)
            ShowTooltip(self, function(tt)
                tt:AddLine(d.label, unpack(d.color))
                tt:AddLine(d.desc, 1, 1, 1)
                tt:AddLine("Click to show or hide these recipes.", unpack(C.muted))
            end)
        end)
        chip:SetScript("OnLeave", GameTooltip_Hide)
        f.chips[#f.chips + 1] = chip
        x = x + 26
    end

    f.haveMats = Toggle(f, "Have materials", "haveMats", 110)
    f.haveMats:SetPoint("TOPLEFT", x + 10, -81)
    f.useBank = Toggle(f, "Count bank", "useBank", 100)
    f.useBank:SetPoint("LEFT", f.haveMats, "RIGHT", 8, 0)
    f.useBank:SetScript("OnEnter", function(self)
        ShowTooltip(self, function(tt)
            tt:AddLine("Count bank")
            tt:AddLine("Include bank items in craftable counts and in the Have materials filter. Bank contents are remembered from your last bank visit.", 1, 1, 1, true)
        end)
    end)
    f.useBank:SetScript("OnLeave", GameTooltip_Hide)

    -- Skill-up guide (right of the toolbar)
    f.summary = Text(f, "GameFontHighlightSmall")
    f.summary:SetPoint("TOPLEFT", PAD + LIST_W + PAD + 2, -56)

    local best = CreateFrame("Button", nil, f)
    best:SetPoint("TOPLEFT", PAD + LIST_W + PAD + 2, -78)
    best:SetSize(W - LIST_W - 3 * PAD - 4, 18)
    best.text = Text(best, "GameFontHighlightSmall", C.muted)
    best.text:SetPoint("LEFT")
    best.text:SetPoint("RIGHT")
    best.text:SetWordWrap(false)
    best:SetScript("OnClick", function(self)
        if self.index then PW:Select(self.index, true) end
    end)
    best:SetScript("OnEnter", function(self)
        if self.index then
            ShowTooltip(self, function(tt)
                tt:AddLine("Click to select this recipe.", 1, 1, 1)
            end)
        end
    end)
    best:SetScript("OnLeave", GameTooltip_Hide)
    f.best = best
end

local function BuildList(f)
    local list = CreateFrame("Frame", nil, f, BT)
    list:SetPoint("TOPLEFT", PAD, BODY_TOP)
    list:SetPoint("BOTTOMLEFT", PAD, FOOTER_H + PAD)
    list:SetWidth(LIST_W)
    SetBD(list, C.panel)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        PW.offset = PW.offset - delta * 3
        PW:UpdateList()
    end)
    f.list = list

    list.empty = Text(list, "GameFontDisable", C.muted)
    list.empty:SetPoint("CENTER")
    list.empty:SetText("No recipes match your filters.")

    f.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", -14, 0)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture(WHITE)
        row.bg:SetVertexColor(0, 0, 0, 0)

        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetTexture(WHITE)
        row.bar:SetPoint("TOPLEFT")
        row.bar:SetPoint("BOTTOMLEFT")
        row.bar:SetWidth(3)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 8, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.name = Text(row, "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -62, 0)
        row.name:SetWordWrap(false)

        row.right = Text(row, "GameFontHighlightSmall")
        row.right:SetPoint("RIGHT", -4, 0)
        row.right:SetJustifyH("RIGHT")

        row:SetScript("OnClick", function(self) PW:OnRowClick(self) end)
        row:SetScript("OnEnter", function(self)
            local item = self.item
            if not item then return end
            if not self.isSelected then self.bg:SetVertexColor(unpack(C.hover)) end
            if item.kind == "recipe" then
                ShowTooltip(self, function(tt) PW.API.SetResultTooltip(tt, item.r.index) end)
            end
        end)
        row:SetScript("OnLeave", function(self)
            if not self.isSelected then self.bg:SetVertexColor(0, 0, 0, 0) end
            GameTooltip:Hide()
        end)
        f.rows[i] = row
    end

    local sb = CreateFrame("Slider", nil, list)
    sb:SetPoint("TOPRIGHT", -4, -4)
    sb:SetPoint("BOTTOMRIGHT", -4, 4)
    sb:SetWidth(6)
    sb:SetOrientation("VERTICAL")
    sb:SetThumbTexture(WHITE)
    local thumb = sb:GetThumbTexture()
    thumb:SetVertexColor(0.38, 0.38, 0.44, 1)
    thumb:SetSize(6, 32)
    sb:SetMinMaxValues(0, 0)
    sb:SetValueStep(1)
    if sb.SetObeyStepOnDrag then sb:SetObeyStepOnDrag(true) end
    sb:SetValue(0)
    sb:SetScript("OnValueChanged", function(_, value)
        if PW.updatingScroll then return end
        PW.offset = floor(value + 0.5)
        PW:UpdateList()
    end)
    f.scroll = sb
end

local function BuildDetail(f)
    local d = CreateFrame("Frame", nil, f, BT)
    d:SetPoint("TOPLEFT", f.list, "TOPRIGHT", PAD, 0)
    d:SetPoint("BOTTOMRIGHT", -PAD, FOOTER_H + PAD)
    SetBD(d, C.panel)
    f.detail = d

    d.none = Text(d, "GameFontDisable", C.muted)
    d.none:SetPoint("TOP", 0, -60)
    d.none:SetJustifyH("CENTER")
    d.none:SetText("Select a recipe.")

    local c = CreateFrame("Frame", nil, d)
    c:SetPoint("TOPLEFT")
    c:SetPoint("TOPRIGHT")
    c:SetHeight(300)
    d.content = c

    -- Icon
    local icon = CreateFrame("Button", nil, c, BT)
    icon:SetSize(40, 40)
    icon:SetPoint("TOPLEFT", 10, -10)
    SetBD(icon, C.panel, { 0, 0, 0, 1 })
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetPoint("TOPLEFT", 1, -1)
    icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetScript("OnEnter", function(self)
        if PW.selected then
            ShowTooltip(self, function(tt) PW.API.SetResultTooltip(tt, PW.selected) end)
        end
    end)
    icon:SetScript("OnLeave", GameTooltip_Hide)
    icon:SetScript("OnClick", function()
        if PW.selected and IsModifiedClick("CHATLINK") then
            InsertLink(PW.API.ItemLink(PW.selected))
        end
    end)
    c.icon = icon

    c.name = Text(c, "GameFontNormalLarge")
    c.name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -1)
    c.name:SetPoint("RIGHT", c, "RIGHT", -10, 0)
    c.name:SetWordWrap(false)

    c.diff = Text(c, "GameFontHighlightSmall")
    c.diff:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)

    c.meta = Text(c, "GameFontHighlightSmall", C.muted)
    c.meta:SetPoint("TOPLEFT", c.diff, "BOTTOMLEFT", 0, -3)

    c.cd = Text(c, "GameFontHighlightSmall", C.cooldown)
    c.cd:SetPoint("TOPRIGHT", c, "TOPRIGHT", -10, -12)
    c.cd:SetJustifyH("RIGHT")

    local line = c:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetVertexColor(unpack(C.border))
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 10, -64)
    line:SetPoint("TOPRIGHT", -10, -64)

    local rh = Text(c, "GameFontNormalSmall", C.muted)
    rh:SetPoint("TOPLEFT", 10, -72)
    rh:SetText("Reagents")

    local hint = Text(c, "GameFontHighlightSmall", C.muted)
    hint:SetPoint("TOPRIGHT", -10, -72)
    hint:SetJustifyH("RIGHT")
    hint:SetText("bags / needed")

    c.reagents = {}
    for j = 1, NUM_REAGENTS do
        local r = CreateFrame("Button", nil, c)
        r:SetHeight(22)
        r:SetPoint("TOPLEFT", 10, -88 - (j - 1) * 22)
        r:SetPoint("RIGHT", c, "RIGHT", -10, 0)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.icon:SetPoint("LEFT")
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.name = Text(r, "GameFontHighlightSmall")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetPoint("RIGHT", r, "RIGHT", -130, 0)
        r.name:SetWordWrap(false)
        r.bank = Text(r, "GameFontHighlightSmall", C.muted)
        r.bank:SetPoint("RIGHT", r, "RIGHT", -56, 0)
        r.bank:SetJustifyH("RIGHT")
        r.count = Text(r, "GameFontHighlightSmall")
        r.count:SetPoint("RIGHT")
        r.count:SetJustifyH("RIGHT")
        r:SetScript("OnEnter", function(self)
            if self.recipeIndex then
                ShowTooltip(self, function(tt) PW.API.SetReagentTooltip(tt, self.recipeIndex, self.reagentIndex, self.reagent) end)
            end
        end)
        r:SetScript("OnLeave", GameTooltip_Hide)
        r:SetScript("OnClick", function(self)
            if IsModifiedClick("CHATLINK") then InsertLink(self.link) end
        end)
        c.reagents[j] = r
    end

    c.more = Text(c, "GameFontHighlightSmall", C.muted)
    c.more:SetPoint("TOPLEFT", 10, -88 - NUM_REAGENTS * 22)

    -- Craft controls
    local y = -258
    c.craftable = Text(c, "GameFontHighlightSmall", C.muted)
    c.craftable:SetPoint("TOPLEFT", 10, y)

    local minus = FlatButton(c, "-", 22, 22)
    minus:SetPoint("TOPLEFT", 10, y - 18)
    local qty = CreateFrame("EditBox", nil, c, BT)
    qty:SetSize(40, 22)
    qty:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    SetBD(qty, C.bg)
    qty:SetFontObject(ChatFontNormal)
    qty:SetJustifyH("CENTER")
    qty:SetAutoFocus(false)
    qty:SetNumeric(true)
    qty:SetMaxLetters(3)
    qty:SetText("1")
    qty:SetScript("OnEscapePressed", qty.ClearFocus)
    qty:SetScript("OnEnterPressed", qty.ClearFocus)
    local plus = FlatButton(c, "+", 22, 22)
    plus:SetPoint("LEFT", qty, "RIGHT", 4, 0)

    local function Bump(delta)
        local n = (tonumber(qty:GetText()) or 1) + delta
        qty:SetText(tostring(min(max(n, 1), 999)))
    end
    minus:SetScript("OnClick", function() Bump(-1) end)
    plus:SetScript("OnClick", function() Bump(1) end)

    local create = FlatButton(c, "Create", 90, 22)
    create:SetPoint("LEFT", plus, "RIGHT", 12, 0)
    create:SetScript("OnClick", function()
        qty:ClearFocus()
        if PW.selected then PW.API.Craft(PW.selected, tonumber(qty:GetText()) or 1) end
    end)

    local createAll = FlatButton(c, "Create all", 90, 22)
    createAll:SetPoint("LEFT", create, "RIGHT", 6, 0)
    createAll:SetScript("OnClick", function()
        local r = PW.selected and PW.byIndex[PW.selected]
        if r and r.numAvailable > 0 then PW.API.Craft(r.index, r.numAvailable) end
    end)

    c.qty, c.create, c.createAll = qty, create, createAll

    -- Cooldowns (all characters) - always visible at the bottom of the pane
    local cdLine = d:CreateTexture(nil, "ARTWORK")
    cdLine:SetTexture(WHITE)
    cdLine:SetVertexColor(unpack(C.border))
    cdLine:SetHeight(1)
    cdLine:SetPoint("BOTTOMLEFT", 10, 18 + NUM_CD_LINES * 16 + 14)
    cdLine:SetPoint("BOTTOMRIGHT", -10, 18 + NUM_CD_LINES * 16 + 14)

    local cdTitle = Text(d, "GameFontNormalSmall", C.muted)
    cdTitle:SetPoint("BOTTOMLEFT", 10, 18 + NUM_CD_LINES * 16 - 2)
    cdTitle:SetText("Cooldowns (all characters)")

    f.cdLines = {}
    for i = 1, NUM_CD_LINES do
        local yy = 10 + (NUM_CD_LINES - i) * 16
        local left = Text(d, "GameFontHighlightSmall", C.muted)
        left:SetPoint("BOTTOMLEFT", 10, yy)
        left:SetPoint("RIGHT", d, "RIGHT", -90, 0)
        left:SetWordWrap(false)
        local right = Text(d, "GameFontHighlightSmall", C.cooldown)
        right:SetPoint("BOTTOMRIGHT", -10, yy)
        right:SetJustifyH("RIGHT")
        f.cdLines[i] = { left = left, right = right }
    end
    f.cdEmpty = Text(d, "GameFontHighlightSmall", C.muted)
    f.cdEmpty:SetPoint("BOTTOMLEFT", 10, 10 + (NUM_CD_LINES - 1) * 16)
    f.cdEmpty:SetText("None tracked yet. Opening a profession records its cooldowns.")
end

local function BuildFooter(f)
    local x = PAD + 2
    for _, key in ipairs(DIFF_ORDER) do
        local d = DIFF[key]
        local sw = f:CreateTexture(nil, "ARTWORK")
        sw:SetTexture(WHITE)
        sw:SetVertexColor(unpack(d.color))
        sw:SetSize(10, 10)
        sw:SetPoint("BOTTOMLEFT", x, 12)
        local t = Text(f, "GameFontHighlightSmall", C.muted)
        t:SetPoint("LEFT", sw, "RIGHT", 5, 0)
        t:SetText(d.desc)
        x = x + 140
    end
    local help = Text(f, "GameFontHighlightSmall", C.muted)
    help:SetPoint("BOTTOMRIGHT", -12, 11)
    help:SetJustifyH("RIGHT")
    help:SetText("/pwb for options")
end

function PW:BuildUI()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "ProfessionWorkbenchFrame", UIParent, BT)
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local p, _, rp, x, y = frame:GetPoint()
        PW.db.point = { p, rp, x, y }
    end)
    SetBD(f, C.bg)
    f:Hide()
    tinsert(UISpecialFrames, "ProfessionWorkbenchFrame") -- close with Esc
    f:SetScript("OnHide", function() PW:OnWindowHidden() end)

    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            PW:UpdateCooldownPanel()
            PW:UpdateList()
            PW:UpdateDetailCooldown()
        end
    end)

    self.frame = f
    self:RestorePosition()

    BuildTitle(f)
    BuildToolbar(f)
    BuildList(f)
    BuildDetail(f)
    BuildFooter(f)
    self:UpdateFilterWidgets()
    return f
end

---------------------------------------------------------------------------
-- Updating
---------------------------------------------------------------------------

function PW:UpdateFilterWidgets()
    local f, fl = self.frame, self.db.filters
    if not f then return end
    for _, chip in ipairs(f.chips) do
        chip:SetAlpha(fl[chip.key] and 1 or 0.2)
    end
    f.haveMats.fill:SetShown(fl.haveMats)
    f.useBank.fill:SetShown(fl.useBank)
end

local function Craftable(r)
    if PW.db.filters.useBank then
        if r.withBank == nil then r.withBank = PW:CraftableWithBank(r.index) end
        return max(r.withBank, r.numAvailable)
    end
    return r.numAvailable
end

function PW:Matches(r)
    local fl = self.db.filters
    local key = DIFF[r.difficulty] and r.difficulty or "trivial"
    if not fl[key] then return false end
    if fl.haveMats and Craftable(r) <= 0 then return false end

    local q = self.searchText
    if q ~= "" and not r.name:lower():find(q, 1, true) then
        if not r.reagentText then
            local parts = {}
            for _, rg in ipairs(self:GetReagents(r.index)) do
                parts[#parts + 1] = (rg.name or ""):lower()
            end
            r.reagentText = table.concat(parts, "\n")
        end
        if not r.reagentText:find(q, 1, true) then return false end
    end
    return true
end

-- Categories are shown expanded while searching, so matches are never hidden.
function PW:IsCollapsed(header)
    return header and self.collapsed[header] and self.searchText == ""
end

function PW:Headers()
    local list, seen = {}, {}
    for _, r in ipairs(self.recipes) do
        if r.header and not seen[r.header] then
            seen[r.header] = true
            list[#list + 1] = r.header
        end
    end
    return list
end

function PW:AnyExpanded()
    for _, h in ipairs(self:Headers()) do
        if not self.collapsed[h] then return true end
    end
    return false
end

function PW:ToggleCollapseAll()
    local collapse = self:AnyExpanded()
    for _, h in ipairs(self:Headers()) do
        self.collapsed[h] = collapse or nil
    end
    self.offset = 0
    self:RebuildList()
end

function PW:RebuildList()
    if not self.frame then return end
    local display = {}
    local lastHeader
    for _, r in ipairs(self.recipes) do
        if self:Matches(r) then
            if r.header and r.header ~= lastHeader then
                display[#display + 1] = { kind = "header", name = r.header }
            end
            lastHeader = r.header
            if not self:IsCollapsed(r.header) then
                display[#display + 1] = { kind = "recipe", r = r }
            end
        end
    end
    self.display = display
    self.frame.collapseAll.label:SetText(self:AnyExpanded() and "Collapse all" or "Expand all")
    self:UpdateList()
end

function PW:UpdateList()
    local f = self.frame
    if not f then return end
    local total = #self.display
    local maxOffset = max(0, total - NUM_ROWS)
    self.offset = min(max(self.offset or 0, 0), maxOffset)

    self.updatingScroll = true
    f.scroll:SetMinMaxValues(0, maxOffset)
    f.scroll:SetValue(self.offset)
    self.updatingScroll = false
    f.scroll:SetShown(maxOffset > 0)
    f.list.empty:SetShown(total == 0 and #self.recipes > 0)

    local now = GetTime()
    for i, row in ipairs(f.rows) do
        local item = self.display[self.offset + i]
        row.item = item
        row.isSelected = false
        if not item then
            row:Hide()
        else
            row:Show()
            if item.kind == "header" then
                row.icon:Hide()
                row.bar:Hide()
                row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.name:SetText((self:IsCollapsed(item.name) and "+  " or "-  ") .. item.name)
                row.name:SetTextColor(unpack(C.header))
                row.right:SetText("")
                row.bg:SetVertexColor(0, 0, 0, 0)
            else
                local r = item.r
                local d = DIFF[r.difficulty] or FALLBACK
                row.icon:Show()
                row.icon:SetTexture(r.icon)
                row.bar:Show()
                row.bar:SetVertexColor(unpack(d.color))
                row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.name:SetText(r.name)
                row.name:SetTextColor(unpack(d.color))

                local right = ""
                if r.cooldownEnds and r.cooldownEnds > now then
                    right = "|cffffb84d" .. PW.FormatTime(r.cooldownEnds - now) .. "|r"
                else
                    local n = r.numAvailable
                    local nb = self.db.filters.useBank and Craftable(r) or n
                    if nb > n then
                        right = format("|cffffffff%d|r|cff8fb8ff+%d|r", n, nb - n)
                    elseif n > 0 then
                        right = format("|cffffffff%d|r", n)
                    end
                end
                row.right:SetText(right)

                row.isSelected = (r.index == self.selected)
                if row.isSelected then
                    row.bg:SetVertexColor(unpack(C.selected))
                elseif row:IsMouseOver() then
                    row.bg:SetVertexColor(unpack(C.hover))
                else
                    row.bg:SetVertexColor(0, 0, 0, 0)
                end
            end
        end
    end
end

function PW:OnRowClick(row)
    local item = row.item
    if not item then return end
    if item.kind == "header" then
        if self.searchText ~= "" then return end -- everything is expanded while searching
        self.collapsed[item.name] = (not self.collapsed[item.name]) or nil
        self:RebuildList()
        return
    end
    if IsModifiedClick("CHATLINK") then
        local idx = item.r.index
        InsertLink(PW.API.RecipeLink(idx))
        return
    end
    self:Select(item.r.index)
end

function PW:Select(index, scrollTo)
    self.selected = index
    PW.API.Select(index)
    if scrollTo then
        for i, item in ipairs(self.display) do
            if item.kind == "recipe" and item.r.index == index then
                if i <= self.offset or i > self.offset + NUM_ROWS then
                    self.offset = i - floor(NUM_ROWS / 2)
                end
                break
            end
        end
    end
    self:UpdateList()
    self:UpdateDetail()
end

function PW:UpdateDetailCooldown()
    local f = self.frame
    local r = f and self.selected and self.byIndex[self.selected]
    if not r then return end
    local left = r.cooldownEnds and (r.cooldownEnds - GetTime()) or 0
    f.detail.content.cd:SetText(left > 0 and ("Cooldown: " .. PW.FormatTime(left)) or "")
end

function PW:UpdateDetail()
    local f = self.frame
    if not f then return end
    local d = f.detail
    local c = d.content
    local r = self.selected and self.byIndex[self.selected]
    if not r then
        c:Hide()
        d.none:Show()
        return
    end
    c:Show()
    d.none:Hide()

    local dd = DIFF[r.difficulty] or FALLBACK
    c.icon.tex:SetTexture(r.icon)
    c.name:SetText(r.name)
    c.name:SetTextColor(unpack(dd.color))
    c.diff:SetText(dd.label ~= "" and (dd.label .. " - " .. dd.desc) or "")
    c.diff:SetTextColor(unpack(dd.color))

    local meta = r.header or ""
    local lo, hi = PW.API.NumMade(r.index)
    local made
    if lo and hi and hi > lo then
        made = format("Makes %d-%d", lo, hi)
    elseif lo and lo > 1 then
        made = "Makes " .. lo
    end
    if made then meta = (meta ~= "" and (meta .. ", ") or "") .. made end
    c.meta:SetText(meta)
    self:UpdateDetailCooldown()

    local reagents = self:GetReagents(r.index)
    local useBank = self.db.filters.useBank
    for j, row in ipairs(c.reagents) do
        local rg = reagents[j]
        if rg then
            row:Show()
            row.recipeIndex, row.reagentIndex, row.link, row.reagent = r.index, j, rg.link, rg
            row.icon:SetTexture(rg.icon)
            row.name:SetText(rg.name or "Loading...")
            local color
            if rg.bags >= rg.need then
                color = "|cff66ff66"
            elseif rg.bags + rg.bank >= rg.need then
                color = "|cffffd24d"
            else
                color = "|cffff5959"
            end
            row.count:SetText(format("%s%d|r / %d", color, rg.bags, rg.need))
            row.bank:SetText((useBank and rg.bank > 0) and format("+%d in bank", rg.bank) or "")
        else
            row:Hide()
            row.recipeIndex, row.link, row.reagent = nil, nil, nil
        end
    end
    local extra = #reagents - NUM_REAGENTS
    c.more:SetText(extra > 0 and format("+%d more (see tooltip)", extra) or "")

    local text = format("Craftable from bags: |cffffffff%d|r", r.numAvailable)
    if useBank then
        local withBank = self:CraftableWithBank(r.index)
        if withBank > r.numAvailable then
            text = text .. format("   with bank: |cff8fb8ff%d|r", withBank)
        end
    end
    c.craftable:SetText(text)

    local onCooldown = r.cooldownEnds and r.cooldownEnds > GetTime()
    local can = r.numAvailable > 0 and not onCooldown
    SetButtonEnabled(c.create, can)
    SetButtonEnabled(c.createAll, can and r.numAvailable > 1)
end

function PW:UpdateSummary()
    local f = self.frame
    if not f then return end
    local counts = { optimal = 0, medium = 0, easy = 0 }
    local bestOrange, bestYellow
    for _, r in ipairs(self.recipes) do
        if counts[r.difficulty] then counts[r.difficulty] = counts[r.difficulty] + 1 end
        local ready = r.numAvailable > 0 and not r.cooldownEnds
        if ready and r.difficulty == "optimal" and not bestOrange then bestOrange = r end
        if ready and r.difficulty == "medium" and not bestYellow then bestYellow = r end
    end
    f.summary:SetText(format(
        "Skill-up recipes:   |cffff8040%d orange|r    |cffffd100%d yellow|r    |cff40bf40%d green|r",
        counts.optimal, counts.medium, counts.easy))

    local best = bestOrange or bestYellow
    if best then
        local hex = best.difficulty == "optimal" and "ff8040" or "ffd100"
        f.best.text:SetText(format("Best skill-up you can craft now:  |cff%s%s|r (%d)", hex, best.name, best.numAvailable))
        f.best.index = best.index
    else
        local _, rank, maxRank = PW.API.GetLine()
        if rank and maxRank and maxRank > 0 and rank >= maxRank then
            f.best.text:SetText("Skill is at the cap for your current rank. Train the next rank to keep leveling.")
        else
            f.best.text:SetText("No orange or yellow recipe is craftable from your bags right now.")
        end
        f.best.index = nil
    end
end

function PW:UpdateCooldownPanel()
    local f = self.frame
    if not f or not self.db then return end
    local entries = self:AllCooldowns()
    for i, line in ipairs(f.cdLines) do
        local e = entries[i]
        if e then
            local label = e.char .. ":  |cffffffff" .. e.recipe .. "|r"
            if i == #f.cdLines and #entries > #f.cdLines then
                label = label .. format("   (+%d more, /pwb cd)", #entries - #f.cdLines)
            end
            line.left:SetText(label)
            line.right:SetText(e.left <= 0 and "|cff66ff66Ready|r" or PW.FormatTime(e.left))
        else
            line.left:SetText("")
            line.right:SetText("")
        end
    end
    f.cdEmpty:SetShown(#entries == 0)
end

function PW:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end

    local name, rank, maxRank = PW.API.GetLine()
    if name ~= self.profession then
        -- Switched profession: start fresh.
        self.profession = name
        self.selected = nil
        self.offset = 0
        -- Collapsed categories are remembered per profession.
        local key = name or "?"
        self.db.collapsed[key] = self.db.collapsed[key] or {}
        self.collapsed = self.db.collapsed[key]
        f.search:SetText("")
    end

    f.title:SetText(name or "Profession")
    f.rank:SetText(format("%d / %d", rank or 0, maxRank or 0))
    f.skillBar:SetMinMaxValues(0, max(maxRank or 1, 1))
    f.skillBar:SetValue(rank or 0)

    self.recipes, self.byIndex = self:Scan()
    self:RecordCooldowns(name, self.recipes)

    if not (self.selected and self.byIndex[self.selected]) then
        self.selected = nil
    end

    self:UpdateSummary()
    self:RebuildList()

    if not self.selected then
        local first = f.best.index
        if not first then
            for _, item in ipairs(self.display) do
                if item.kind == "recipe" then first = item.r.index break end
            end
        end
        if first then self:Select(first, true) end
    end

    self:UpdateDetail()
    self:UpdateCooldownPanel()
end
