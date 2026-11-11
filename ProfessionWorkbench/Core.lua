-- Profession Workbench: core logic (saved data, events, profession data, cooldowns, bank cache)

local ADDON, ns = ...
local PW = {}
ns.PW = PW
_G.ProfessionWorkbench = PW -- handy for /dump while debugging

PW.version = "0.2.0"

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

-- The addon is written against the classic-style trade skill API
-- (GetNumTradeSkills / GetTradeSkillInfo / DoTradeSkill ...).
PW.hasLegacyAPI = type(GetNumTradeSkills) == "function"
    and type(GetTradeSkillInfo) == "function"
    and type(GetTradeSkillReagentInfo) == "function"

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local defaults = {
    useBlizzard = false,
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

-- Returns a flat list of recipes (headers are stored on each recipe).
function PW:Scan()
    local recipes, byIndex = {}, {}
    local header
    local now = GetTime()
    local collapsedFound = false

    for i = 1, (GetNumTradeSkills() or 0) do
        local name, skillType, numAvailable, isExpanded = GetTradeSkillInfo(i)
        if name then
            if skillType == "header" or skillType == "subheader" then
                header = name
                if isExpanded == false then collapsedFound = true end
            else
                local r = {
                    index = i,
                    name = name,
                    difficulty = skillType,
                    numAvailable = numAvailable or 0,
                    header = header,
                    icon = GetTradeSkillIcon and GetTradeSkillIcon(i),
                }
                local cd = GetTradeSkillCooldown and GetTradeSkillCooldown(i)
                if cd and cd > 0 then
                    r.cooldownEnds = now + cd
                    r.cooldown = cd
                end
                recipes[#recipes + 1] = r
                byIndex[i] = r
            end
        end
    end

    -- Make sure every category is expanded so we see every recipe.
    if collapsedFound and (self.expandTries or 0) < 3 then
        self.expandTries = (self.expandTries or 0) + 1
        Try(ExpandTradeSkillSubClass, 0)
    end

    return recipes, byIndex
end

function PW:GetReagents(index)
    local list = {}
    for j = 1, (GetTradeSkillNumReagents(index) or 0) do
        local name, texture, need, bags = GetTradeSkillReagentInfo(index, j)
        local link = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(index, j)
        list[j] = {
            name = name,
            icon = texture,
            need = need or 1,
            bags = bags or 0,
            bank = self:BankCount(PW.ItemIDFromLink(link)),
            link = link,
        }
    end
    return list
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
    return self.db and not self.db.useBlizzard and self.hasLegacyAPI
end

-- Hide Blizzard's TradeSkillFrame without ending the trade skill session
-- (its OnHide handler would call CloseTradeSkill()).
function PW.SuppressBlizzard()
    local f = TradeSkillFrame
    if not f or not f:IsShown() or not PW:ShouldReplace() then return end
    local onHide = f:GetScript("OnHide")
    f:SetScript("OnHide", nil)
    HideUIPanel(f)
    if f:IsShown() then f:Hide() end
    f:SetScript("OnHide", onHide)
end

function PW:HookBlizzard()
    if self.hooked or not TradeSkillFrame then return end
    self.hooked = true
    TradeSkillFrame:HookScript("OnShow", function()
        if PW:ShouldReplace() then C_Timer.After(0, PW.SuppressBlizzard) end
    end)
end

local function ResetBlizzardFilters()
    Try(TradeSkillOnlyShowMakeable, false)
    Try(SetTradeSkillSubClassFilter, 0, 1, 1)
    Try(SetTradeSkillInvSlotFilter, 0, 1, 1)
    Try(SetTradeSkillItemNameFilter, "")
    Try(ExpandTradeSkillSubClass, 0)
end

-- Called from the UI when our window is hidden (close button, Esc, ...).
function PW:OnWindowHidden()
    GameTooltip:Hide()
    if not self.closingFromGame then
        Try(CloseTradeSkill)
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
    "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED", "GET_ITEM_INFO_RECEIVED",
}) do
    pcall(events.RegisterEvent, events, e) -- tolerate events this client lacks
end

function PW:ADDON_LOADED(name)
    if name == ADDON then
        self:InitDB()
        if TradeSkillFrame then self:HookBlizzard() end
    elseif name == "Blizzard_TradeSkillUI" then
        self:HookBlizzard()
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
    if not self.hasLegacyAPI then
        if not self.warnedAPI then
            self.warnedAPI = true
            Print("This client uses a profession API the addon doesn't support yet. Type /pwb debug and share the output.")
        end
        return
    end
    if not self:ShouldReplace() then return end

    self:HookBlizzard()
    self.SuppressBlizzard()
    C_Timer.After(0, PW.SuppressBlizzard)

    self.expandTries = 0
    ResetBlizzardFilters()

    self:BuildUI()
    self.frame:Show()
    self:Refresh()
end

function PW:TRADE_SKILL_UPDATE()
    self:RequestRefresh()
end

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
        PW.db.useBlizzard = not PW.db.useBlizzard
        Print(PW.db.useBlizzard
            and "Using the default Blizzard window. Type /pwb blizz again to switch back."
            or "Using the Profession Workbench window.")
        if PW.frame and PW.frame:IsShown() then PW.frame:Hide() end

    elseif msg == "reset" then
        PW.db.point = nil
        if PW.RestorePosition then PW:RestorePosition() end
        Print("Window position reset.")

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
        Print("Classic trade skill API: " .. tostring(PW.hasLegacyAPI))
        Print("C_TradeSkillUI present: " .. tostring(C_TradeSkillUI ~= nil))
        Print("Craft API (old Enchanting window): " .. tostring(type(GetNumCrafts) == "function"))
        Print("C_Container present: " .. tostring(C_Container ~= nil))

    else
        Print("commands:")
        print("  /pwb blizz - switch between this window and the default one")
        print("  /pwb cd - list tracked cooldowns for all characters")
        print("  /pwb reset - reset the window position")
        print("  /pwb debug - show client and API info")
    end
end
