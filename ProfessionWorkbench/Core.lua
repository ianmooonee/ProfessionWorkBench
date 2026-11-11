-- Profession Workbench: core logic (saved data, events, profession data, cooldowns, bank cache)

local ADDON, ns = ...
local PW = {}
ns.PW = PW
_G.ProfessionWorkbench = PW -- handy for /dump while debugging

PW.version = "0.3.0"

local floor, max, format = math.floor, math.max, string.format

local function Print(msg)
    print("|cff5a9bffProfession Workbench|r: " .. msg)
end
PW.Print = Print

local function Try(fn, ...)
    if type(fn) == "function" then
        return pcall(fn, ...)
    end
end

-- Profession API backend (classic or C_TradeSkillUI), chosen in Compat.lua.
local API = ns.API
PW.API = API

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local defaults = {
    useBlizzard = false,
    scale = 1,
    filters = {
        optimal = true,
        medium = true,
        easy = true,
        trivial = true,
        haveMats = false,
        useBank = true,
    },
    collapsed = {}, -- [profession] = { [category] = true }
    chars = {},
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function PW:InitDB()
    ProfessionWorkbenchDB = ProfessionWorkbenchDB or {}
    CopyDefaults(defaults, ProfessionWorkbenchDB)
    self.db = ProfessionWorkbenchDB

    local key = (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "")
    self.db.chars[key] = self.db.chars[key] or {}
    self.charDB = self.db.chars[key]
    self.charDB.cooldowns = self.charDB.cooldowns or {}
    self.charDB.bank = self.charDB.bank or {}
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function PW.FormatTime(seconds)
    if not seconds or seconds <= 0 then return "Ready" end
    local d = floor(seconds / 86400)
    local h = floor((seconds % 86400) / 3600)
    local m = floor((seconds % 3600) / 60)
    if d > 0 then return format("%dd %dh", d, h) end
    if h > 0 then return format("%dh %dm", h, m) end
    return format("%dm", max(m, 1))
end

function PW.ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- Bank cache: bank contents are only readable while the bank is open,
-- so we remember them per character.
---------------------------------------------------------------------------

local NumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots

local function SlotInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount end
    elseif GetContainerItemInfo then
        local _, count, _, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
        return id or PW.ItemIDFromLink(link), count
    end
end

function PW:ScanBank()
    if not self.charDB or not NumSlots then return end
    local counts = {}
    local bags = { BANK_CONTAINER or -1 }
    local first = (NUM_BAG_SLOTS or 4) + 1
    for b = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do
        bags[#bags + 1] = b
    end
    for _, bag in ipairs(bags) do
        for slot = 1, (NumSlots(bag) or 0) do
            local id, count = SlotInfo(bag, slot)
            if id then counts[id] = (counts[id] or 0) + (count or 1) end
        end
    end
    self.charDB.bank = counts
    self.charDB.bankScanned = time()
end

function PW:BankCount(itemID)
    return (itemID and self.charDB and self.charDB.bank[itemID]) or 0
end

---------------------------------------------------------------------------
-- Profession data
---------------------------------------------------------------------------

-- Returns a flat list of recipes (headers are stored on each recipe)
-- and a lookup by recipe key.
function PW:Scan()
    local recipes = API.Scan()
    local byIndex = {}
    for _, r in ipairs(recipes) do byIndex[r.index] = r end
    return recipes, byIndex
end

function PW:GetReagents(index)
    local list = API.GetReagents(index)
    for _, rg in ipairs(list) do
        rg.bank = self:BankCount(rg.itemID or PW.ItemIDFromLink(rg.link))
    end
    return list
end

-- How many crafts the reagents in bags allow (the API's numAvailable can be
-- 0 for some recipes, e.g. enchants, even with every reagent in the bags).
function PW:CraftableFromBags(index)
    local n
    for _, rg in ipairs(self:GetReagents(index)) do
        local can = floor(rg.bags / max(rg.need, 1))
        n = n and math.min(n, can) or can
    end
    return n or 0
end

function PW:CraftableWithBank(index)
    local n
    for _, rg in ipairs(self:GetReagents(index)) do
        local can = floor((rg.bags + rg.bank) / max(rg.need, 1))
        n = n and math.min(n, can) or can
    end
    return n or 0
end

function PW:RecordCooldowns(profession, recipes)
    local store = self.charDB.cooldowns
    local now = time()
    for _, r in ipairs(recipes) do
        if r.cooldown then
            store[r.name] = { expires = now + r.cooldown, profession = profession }
        elseif store[r.name] then
            -- Known cooldown recipe that is off cooldown now.
            store[r.name].expires = 0
        end
    end
end

-- Every tracked cooldown for every character, soonest first.
function PW:AllCooldowns()
    local entries, now = {}, time()
    for charKey, data in pairs(self.db.chars) do
        for recipe, cd in pairs(data.cooldowns or {}) do
            entries[#entries + 1] = {
                char = charKey:match("^([^-]+)") or charKey,
                recipe = recipe,
                left = (cd.expires or 0) - now,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.left == b.left then return a.recipe < b.recipe end
        return a.left < b.left
    end)
    return entries
end

---------------------------------------------------------------------------
-- Replacing the Blizzard window
---------------------------------------------------------------------------

function PW:ShouldReplace()
    return self.db and not self.db.useBlizzard and API ~= nil and API.CanReplace()
end

-- Hide Blizzard's profession window without ending the trade skill session
-- (its OnHide handler would close the trade skill).
function PW.SuppressBlizzard()
    if not PW:ShouldReplace() then return end
    for name in pairs(ns.BLIZZARD_FRAMES) do
        local f = _G[name]
        if f and f:IsShown() then
            local onHide = f:GetScript("OnHide")
            f:SetScript("OnHide", nil)
            HideUIPanel(f)
            if f:IsShown() then f:Hide() end
            f:SetScript("OnHide", onHide)
        end
    end
end

-- "Use Workbench" button shown on top of Blizzard's profession window.
local function AddSwitchButton(f, name)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(130, 22)
    b:SetText("Use Workbench")
    if name == "TradeSkillFrame" then
        -- The classic frame's art is inset from its edges.
        b:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -34, -10)
    else
        b:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -4, 2)
    end
    b:SetScript("OnClick", function() PW:SetUseBlizzard(false) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Switch to the Profession Workbench window")
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    f.pwbSwitch = b
end

function PW:HookBlizzard()
    self.hooked = self.hooked or {}
    for name in pairs(ns.BLIZZARD_FRAMES) do
        local f = _G[name]
        if f and not self.hooked[name] then
            self.hooked[name] = true
            AddSwitchButton(f, name)
            f:HookScript("OnShow", function(frame)
                frame.pwbSwitch:SetShown(API ~= nil and API.CanReplace())
                if PW:ShouldReplace() then C_Timer.After(0, PW.SuppressBlizzard) end
            end)
        end
    end
end

local LoadAddOnF = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn

local function BlizzardShown()
    for name in pairs(ns.BLIZZARD_FRAMES) do
        local f = _G[name]
        if f and f:IsShown() then return true end
    end
    return false
end

local function ShowBlizzard()
    for name, addon in pairs(ns.BLIZZARD_FRAMES) do
        if not _G[name] and LoadAddOnF then pcall(LoadAddOnF, addon) end
    end
    PW:HookBlizzard()
    for name in pairs(ns.BLIZZARD_FRAMES) do
        local f = _G[name]
        if f then
            ShowUIPanel(f)
            if f:IsShown() then return true end
        end
    end
    return false
end

-- Switch between our window and Blizzard's, keeping the profession open.
function PW:SetUseBlizzard(on)
    self.db.useBlizzard = on and true or false
    if on then
        if self.frame and self.frame:IsShown() then
            self.switching = true
            self.frame:Hide()
            self.switching = false
            if not ShowBlizzard() then
                Print("Couldn't open the default window. Close and reopen the profession.")
            end
        end
    elseif API and BlizzardShown() then
        self:OpenWindow()
    end
end

-- Called from the UI when our window is hidden (close button, Esc, ...).
function PW:OnWindowHidden()
    GameTooltip:Hide()
    if not self.closingFromGame and not self.switching and API then
        API.Close()
    end
end

do
    local pending = false
    function PW:RequestRefresh()
        if pending then return end
        pending = true
        C_Timer.After(0.1, function()
            pending = false
            if PW.frame and PW.frame:IsShown() then PW:Refresh() end
        end)
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
    local handler = PW[event]
    if handler then handler(PW, ...) end
end)

for _, e in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN",
    "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
    "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED",
    "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED", "GET_ITEM_INFO_RECEIVED",
}) do
    pcall(events.RegisterEvent, events, e) -- tolerate events this client lacks
end

function PW:ADDON_LOADED(name)
    if name == ADDON then
        self:InitDB()
        self:HookBlizzard()
    else
        for _, addon in pairs(ns.BLIZZARD_FRAMES) do
            if name == addon then self:HookBlizzard() end
        end
    end
end

function PW:PLAYER_LOGIN()
    C_Timer.After(5, function()
        local ready = {}
        for recipe, cd in pairs(PW.charDB.cooldowns) do
            if (cd.expires or 0) <= time() then ready[#ready + 1] = recipe end
        end
        if #ready > 0 then
            table.sort(ready)
            Print("Cooldowns ready: |cffffffff" .. table.concat(ready, ", ") .. "|r")
        end
    end)
end

function PW:TRADE_SKILL_SHOW()
    if not API then
        if not self.warnedAPI then
            self.warnedAPI = true
            Print("This client uses a profession API the addon doesn't support yet. Type /pwb debug and share the output.")
        end
        return
    end
    if not self:ShouldReplace() then return end
    self:OpenWindow()
end

function PW:OpenWindow()
    self:HookBlizzard()
    self.SuppressBlizzard()
    C_Timer.After(0, PW.SuppressBlizzard)

    API.Prepare()

    self:BuildUI()
    self.frame:Show()
    self:Refresh()
end

function PW:TRADE_SKILL_UPDATE()
    self:RequestRefresh()
end
PW.TRADE_SKILL_LIST_UPDATE = PW.TRADE_SKILL_UPDATE
PW.TRADE_SKILL_DATA_SOURCE_CHANGED = PW.TRADE_SKILL_UPDATE
PW.NEW_RECIPE_LEARNED = PW.TRADE_SKILL_UPDATE

function PW:TRADE_SKILL_CLOSE()
    if self.frame and self.frame:IsShown() then
        self.closingFromGame = true
        self.frame:Hide()
        self.closingFromGame = false
    end
end

function PW:BAG_UPDATE_DELAYED()
    if self.bankOpen then self:ScanBank() end
    self:RequestRefresh()
end

function PW:BANKFRAME_OPENED()
    self.bankOpen = true
    self:ScanBank()
    self:RequestRefresh()
end

function PW:BANKFRAME_CLOSED()
    self.bankOpen = false
end

function PW:PLAYERBANKSLOTS_CHANGED()
    if self.bankOpen then self:ScanBank() end
    self:RequestRefresh()
end

function PW:GET_ITEM_INFO_RECEIVED()
    self:RequestRefresh()
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

SLASH_PROFWORKBENCH1 = "/pwb"
SlashCmdList.PROFWORKBENCH = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "blizz" or msg == "blizzard" then
        PW:SetUseBlizzard(not PW.db.useBlizzard)
        Print(PW.db.useBlizzard
            and "Using the default Blizzard window. Click \"Use Workbench\" on it, or type /pwb blizz, to switch back."
            or "Using the Profession Workbench window.")

    elseif msg:match("^scale") then
        local arg = msg:match("^scale%s+(%S+)")
        if not arg then
            Print(format("Window scale is %.2f. Use /pwb scale <0.6-2>, e.g. /pwb scale 1.3", PW.db.scale or 1))
        elseif not tonumber(arg) then
            Print("Usage: /pwb scale <0.6-2>, e.g. /pwb scale 1.3")
        else
            Print(format("Window scale set to %.2f.", PW:SetScale(arg)))
        end

    elseif msg == "reset" then
        PW.db.point = nil
        PW.db.size = nil
        if PW.RestorePosition then PW:RestorePosition() end
        Print("Window position and size reset.")

    elseif msg == "cd" or msg == "cooldowns" then
        local list = PW:AllCooldowns()
        if #list == 0 then
            Print("No cooldowns tracked yet. Open a profession that has a cooldown recipe to start tracking it.")
        end
        for _, e in ipairs(list) do
            Print(format("%s - %s: %s", e.char, e.recipe, PW.FormatTime(e.left)))
        end

    elseif msg == "debug" then
        local version, build, _, toc = GetBuildInfo()
        Print(format("v%s, client %s (%s), interface %s", PW.version, tostring(version), tostring(build), tostring(toc)))
        Print("Backend: " .. (API and API.kind or "none"))
        Print("Classic trade skill API: " .. tostring(type(GetNumTradeSkills) == "function"))
        Print("C_TradeSkillUI present: " .. tostring(C_TradeSkillUI ~= nil))
        if C_TradeSkillUI then
            local have, missing = {}, {}
            for _, fn in ipairs(ns.MODERN_FUNCS) do
                local t = type(C_TradeSkillUI[fn]) == "function" and have or missing
                t[#t + 1] = fn
            end
            Print("  has: " .. (#have > 0 and table.concat(have, ", ") or "-"))
            Print("  missing: " .. (#missing > 0 and table.concat(missing, ", ") or "-"))
        end
        local frames = {}
        for name in pairs(ns.BLIZZARD_FRAMES) do
            if _G[name] then frames[#frames + 1] = name end
        end
        Print("Blizzard frames loaded: " .. (#frames > 0 and table.concat(frames, ", ") or "none"))
        Print("Craft API (old Enchanting window): " .. tostring(type(GetNumCrafts) == "function"))
        Print("C_Container present: " .. tostring(C_Container ~= nil))

    else
        Print("commands:")
        print("  /pwb blizz - switch between this window and the default one")
        print("  /pwb cd - list tracked cooldowns for all characters")
        print("  /pwb scale <0.6-2> - change the window size, e.g. /pwb scale 1.3")
        print("  /pwb reset - reset the window position and size")
        print("  /pwb debug - show client and API info")
    end
end
