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
local MAX_W, MAX_H = 1600, 1200
local MAX_ROWS = 60 -- rows created; how many are used depends on the window height
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

local function TargetExists(loc)
    return loc and C_Item and C_Item.DoesItemExist and C_Item.DoesItemExist(loc)
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function SavePosition(f)
    local p, _, rp, x, y = f:GetPoint()
    PW.db.point = { p, rp, x, y }
end

function PW:RestorePosition()
    local f = self.frame
    if not f then return end
    local size = self.db.size
    f:SetSize(size and size[1] or W, size and size[2] or H)
    f:ClearAllPoints()
    local p = self.db.point
    if p then
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.6, 2.0, 0.1

-- Scale the window, keeping its center on the same spot of the screen.
function PW:SetScale(scale)
    scale = tonumber(scale) or 1
    scale = floor(scale * 20 + 0.5) / 20 -- round to 0.05
    scale = min(max(scale, SCALE_MIN), SCALE_MAX)
    self.db.scale = scale

    local f = self.frame
    if not f then return scale end
    local cx, cy = f:GetCenter()
    local oldEff = f:GetEffectiveScale()
    f:SetScale(scale)
    if cx and f:GetNumPoints() > 0 then
        local ratio = oldEff / f:GetEffectiveScale()
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx * ratio, cy * ratio)
        local p, _, rp, x, y = f:GetPoint()
        self.db.point = { p, rp, x, y }
    end
    if f.scaleText then f.scaleText:SetText(format("%d%%", scale * 100 + 0.5)) end
    return scale
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

    -- Scale controls: [-] 100% [+]
    local function ScaleButton(label, delta, tip)
        local b = FlatButton(f, label, 20, 18)
        b:SetScript("OnClick", function() PW:SetScale((PW.db.scale or 1) + delta) end)
        b:HookScript("OnEnter", function(self)
            ShowTooltip(self, function(tt)
                tt:SetText(tip)
                tt:AddLine("Or type /pwb scale <number>, e.g. /pwb scale 1.3", 0.7, 0.7, 0.7)
            end)
        end)
        b:HookScript("OnLeave", GameTooltip_Hide)
        return b
    end
    local plus = ScaleButton("+", SCALE_STEP, "Larger window")
    plus:SetPoint("RIGHT", close, "LEFT", -8, 0)
    f.scaleText = Text(f, "GameFontHighlightSmall", C.muted)
    f.scaleText:SetPoint("RIGHT", plus, "LEFT", -4, 0)
    f.scaleText:SetWidth(36)
    f.scaleText:SetJustifyH("CENTER")
    local minus = ScaleButton("-", -SCALE_STEP, "Smaller window")
    minus:SetPoint("RIGHT", f.scaleText, "LEFT", -4, 0)

    -- Switch to Blizzard's window (it gets a "Use Workbench" button to come back).
    local blizz = FlatButton(f, "Default UI", 76, 18)
    blizz:SetPoint("RIGHT", minus, "LEFT", -12, 0)
    blizz:SetScript("OnClick", function() PW:SetUseBlizzard(true) end)
    blizz:HookScript("OnEnter", function(self)
        ShowTooltip(self, function(tt)
            tt:SetText("Switch to the default window")
            tt:AddLine("Click \"Use Workbench\" on it to come back.", 0.7, 0.7, 0.7)
        end)
    end)
    blizz:HookScript("OnLeave", GameTooltip_Hide)

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
    best:SetPoint("RIGHT", f, "RIGHT", -PAD - 2, 0)
    best:SetHeight(18)
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
    -- Recompute how many rows fit when the window is resized.
    list:SetScript("OnSizeChanged", function(self, _, height)
        NUM_ROWS = min(MAX_ROWS, max(1, floor(((height or self:GetHeight()) - 8) / ROW_H)))
        if PW.frame and PW.frame.scroll then PW:UpdateList() end
    end)

    for i = 1, MAX_ROWS do
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
    c.craftControls = { minus, qty, plus, create, createAll }

    -- Enchant target: enchants that go on gear are applied straight to the
    -- item picked here (replaces the quantity / create controls).
    local er = CreateFrame("Frame", nil, c)
    er:SetPoint("TOPLEFT", 10, y - 18)
    er:SetPoint("RIGHT", c, "RIGHT", -10, 0)
    er:SetHeight(22)
    er:Hide()

    local enchant = FlatButton(er, "Enchant", 90, 22)
    enchant:SetPoint("RIGHT")
    enchant:SetScript("OnClick", function() PW:DoEnchant() end)
    if enchant.SetMotionScriptsWhileDisabled then enchant:SetMotionScriptsWhileDisabled(true) end
    enchant:HookScript("OnEnter", function(self)
        if self.reason then
            ShowTooltip(self, function(tt) tt:SetText(self.reason, 1, 0.4, 0.4) end)
        end
    end)
    enchant:HookScript("OnLeave", GameTooltip_Hide)
    er.button = enchant

    local slot = CreateFrame("Button", nil, er, BT)
    slot:SetPoint("TOPLEFT")
    slot:SetPoint("BOTTOMRIGHT", enchant, "BOTTOMLEFT", -8, 0)
    SetBD(slot, C.bg)
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetSize(20, 20)
    slot.icon:SetPoint("LEFT", 1, 0)
    slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    slot.plus = Text(slot, "GameFontHighlight", C.muted)
    slot.plus:SetPoint("CENTER", slot.icon, "CENTER")
    slot.plus:SetText("+")
    slot.text = Text(slot, "GameFontHighlightSmall")
    slot.text:SetPoint("LEFT", slot.icon, "RIGHT", 6, 0)
    slot.text:SetPoint("RIGHT", -6, 0)
    slot.text:SetWordWrap(false)
    slot:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            PW:SetEnchantTarget(nil)
        elseif CursorHasItem and CursorHasItem() then
            PW:DropEnchantTarget()
        else
            PW:ToggleEnchantMenu(self)
        end
    end)
    slot:SetScript("OnReceiveDrag", function() PW:DropEnchantTarget() end)
    slot:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(C.hover))
        ShowTooltip(self, function(tt)
            local link = PW:EnchantTargetLink()
            if link then
                tt:SetHyperlink(link)
                tt:AddLine("Right-click to clear", 0.7, 0.7, 0.7)
            else
                tt:SetText("Item to enchant")
                tt:AddLine("Click to pick from your gear and bags,", 0.7, 0.7, 0.7)
                tt:AddLine("or drag an item here.", 0.7, 0.7, 0.7)
            end
        end)
    end)
    slot:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(C.bg))
        GameTooltip:Hide()
    end)
    er.slot = slot
    c.enchantRow = er

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
    help:SetPoint("BOTTOMRIGHT", -26, 11)

    -- Resize grip (bottom-right corner)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        PW.db.size = { floor(f:GetWidth() + 0.5), floor(f:GetHeight() + 0.5) }
        SavePosition(f)
    end)
    grip:SetScript("OnEnter", function(self)
        ShowTooltip(self, function(tt)
            tt:SetText("Drag to resize")
            tt:AddLine("/pwb reset restores the default size", 0.7, 0.7, 0.7)
        end)
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)
    help:SetJustifyH("RIGHT")
    help:SetText("/pwb for options")
end

function PW:BuildUI()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "ProfessionWorkbenchFrame", UIParent, BT)
    f:SetSize(W, H)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(W, H, MAX_W, MAX_H)
    else
        if f.SetMinResize then f:SetMinResize(W, H) end
        if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end
    end
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        SavePosition(frame)
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
    f:SetScale(self.db.scale or 1)
    self:RestorePosition()

    BuildTitle(f)
    BuildToolbar(f)
    BuildList(f)
    BuildDetail(f)
    BuildFooter(f)
    f.scaleText:SetText(format("%d%%", (self.db.scale or 1) * 100 + 0.5))
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
        local item = i <= NUM_ROWS and self.display[self.offset + i] or nil
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
    if index ~= self.selected then
        if self.enchantMenu then self.enchantMenu:Hide() end
        -- Keep the picked item only if it can take the new enchant too.
        if self.enchantTarget and not (TargetExists(self.enchantTarget)
            and self.API.IsValidEnchantTarget(index, self.enchantTarget)) then
            self.enchantTarget = nil
        end
    end
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

    -- Enchants that go on gear get the item slot instead of quantity controls.
    local enchantMode = self.API.SupportsEnchantTarget(r)
    for _, w in ipairs(c.craftControls) do w:SetShown(not enchantMode) end
    c.enchantRow:SetShown(enchantMode)
    if not enchantMode and self.enchantMenu then self.enchantMenu:Hide() end
    self:UpdateEnchantRow()
end

---------------------------------------------------------------------------
-- Enchant target
---------------------------------------------------------------------------

local MENU_ROWS = 12
local MENU_ROW_H = 20

function PW:EnchantTargetLink()
    local loc = self.enchantTarget
    if TargetExists(loc) then return C_Item.GetItemLink(loc) end
end

function PW:SetEnchantTarget(loc)
    self.enchantTarget = loc
    if self.enchantMenu then self.enchantMenu:Hide() end
    self:UpdateEnchantRow()
end

-- An item dropped on the slot (or clicked onto it from the cursor).
function PW:DropEnchantTarget()
    local loc = C_Cursor and C_Cursor.GetCursorItem and C_Cursor.GetCursorItem()
    ClearCursor()
    if not loc or not self.selected then return end
    if self.API.IsValidEnchantTarget(self.selected, loc) then
        self:SetEnchantTarget(loc)
    else
        PW.Print("That item can't receive this enchant.")
    end
end

function PW:DoEnchant()
    local r = self.selected and self.byIndex[self.selected]
    if r and TargetExists(self.enchantTarget) then
        local ok, err = pcall(self.API.CraftEnchant, r.index, self.enchantTarget)
        if not ok then
            PW.Print("Enchanting failed: " .. tostring(err) .. " - type /pwb debug and share both messages.")
        end
    end
end

function PW:UpdateEnchantRow()
    local f = self.frame
    if not f then return end
    local er = f.detail.content.enchantRow
    if not er:IsShown() then return end
    local r = self.selected and self.byIndex[self.selected]
    if not TargetExists(self.enchantTarget) then self.enchantTarget = nil end

    local slot = er.slot
    local link = self:EnchantTargetLink()
    if link then
        slot.icon:SetTexture(C_Item.GetItemIcon(self.enchantTarget))
        slot.icon:Show()
        slot.plus:Hide()
        slot.text:SetText(link)
    else
        slot.icon:Hide()
        slot.plus:Show()
        slot.text:SetText("|cff9a9aa0Choose an item to enchant|r")
    end

    local onCooldown = r and r.cooldownEnds and r.cooldownEnds > GetTime()
    local reason
    if not r then
        reason = "Select an enchant."
    elseif not link then
        reason = "Choose an item to enchant first."
    elseif onCooldown then
        reason = "This enchant is on cooldown."
    elseif r.numAvailable <= 0 and self:CraftableFromBags(r.index) <= 0 then
        reason = "Missing reagents in your bags."
    end
    er.button.reason = reason
    SetButtonEnabled(er.button, reason == nil)
end

local function BuildEnchantMenu(f)
    local m = CreateFrame("Frame", nil, f, BT)
    m:SetFrameStrata("DIALOG")
    m:SetWidth(280)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    m:EnableMouseWheel(true)
    SetBD(m, C.panel)
    m:Hide()
    m.offset = 0
    m:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta
        PW:UpdateEnchantMenu()
    end)

    m.empty = Text(m, "GameFontHighlightSmall", C.muted)
    m.empty:SetPoint("LEFT", 8, 0)
    m.empty:SetText("Nothing in your gear or bags can take this enchant.")

    m.rows = {}
    for i = 1, MENU_ROWS do
        local b = CreateFrame("Button", nil, m)
        b:SetHeight(MENU_ROW_H)
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * MENU_ROW_H)
        b:SetPoint("RIGHT", m, "RIGHT", -4, 0)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetTexture(WHITE)
        b.bg:SetVertexColor(0, 0, 0, 0)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(16, 16)
        b.icon:SetPoint("LEFT", 4, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.text = Text(b, "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.text:SetPoint("RIGHT", -4, 0)
        b.text:SetWordWrap(false)
        b:SetScript("OnEnter", function(self)
            self.bg:SetVertexColor(unpack(C.hover))
            if self.entry and self.entry.link then
                ShowTooltip(self, function(tt) tt:SetHyperlink(self.entry.link) end)
            end
        end)
        b:SetScript("OnLeave", function(self)
            self.bg:SetVertexColor(0, 0, 0, 0)
            GameTooltip:Hide()
        end)
        b:SetScript("OnClick", function(self)
            if self.entry then PW:SetEnchantTarget(self.entry.location) end
        end)
        m.rows[i] = b
    end
    return m
end

function PW:UpdateEnchantMenu()
    local m = self.enchantMenu
    local items = self.enchantItems or {}
    local maxOffset = max(0, #items - MENU_ROWS)
    m.offset = min(max(m.offset, 0), maxOffset)
    for i, b in ipairs(m.rows) do
        local e = items[m.offset + i]
        b.entry = e
        if e then
            b.icon:SetTexture(e.icon)
            b.text:SetText((e.equipped and "" or "|cff9a9aa0(bag)|r ") .. (e.link or "?"))
            b:Show()
        else
            b:Hide()
        end
    end
    m.empty:SetShown(#items == 0)
    m:SetHeight(max(1, min(#items, MENU_ROWS)) * MENU_ROW_H + 8)
end

function PW:ToggleEnchantMenu(anchor)
    local m = self.enchantMenu
    if m and m:IsVisible() then m:Hide() return end
    if not m then
        m = BuildEnchantMenu(self.frame)
        self.enchantMenu = m
    end
    self.enchantItems = self.API.EnchantTargets(self.selected)
    m.offset = 0
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    self:UpdateEnchantMenu()
    m:Show()
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
            if counts.optimal + counts.medium > 0 then
                f.best.text:SetText("You don't have the reagents in your bags for any orange or yellow recipe.")
            else
                f.best.text:SetText("No orange or yellow recipes left. Learn new ones to keep leveling.")
            end
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
