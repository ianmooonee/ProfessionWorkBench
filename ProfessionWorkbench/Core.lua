-- Profession Workbench: core logic (saved data, events, profession data, cooldowns, bank cache)

local ADDON, ns = ...
local PW = {}
ns.PW = PW
_G.ProfessionWorkbench = PW -- handy for /dump while debugging

PW.version = "0.6.2"

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
    sortProfit = false,
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
    prices = {}, -- account-wide: [itemID] = { unit, source, at }
    queues = {}, -- [profession] = { { name = recipeName, count = n }, ... }
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
    self.charName = UnitName("player")
    -- Kept so a name containing "-" isn't mangled when listing other characters.
    self.charDB.name = self.charName
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

-- The character's bank bags. Modern clients name them in Enum.BagIndex; the
-- classic globals (BANK_CONTAINER, NUM_BAG_SLOTS, NUM_BANKBAGSLOTS) are gone
-- from newer ones, so fall back to them only when the enum is missing.
local function BankBags()
    local bags = {}
    local e = Enum and Enum.BagIndex
    if e then
        for name, id in pairs(e) do
            -- Character tabs only: the account bank is a separate storage.
            if name:find("CharacterBankTab") then bags[#bags + 1] = id end
        end
    end
    if #bags == 0 then
        bags[1] = BANK_CONTAINER or -1
        local first = (NUM_BAG_SLOTS or 4) + 1
        for b = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do
            bags[#bags + 1] = b
        end
    end
    return bags
end

function PW:ScanBank()
    if not self.charDB or not NumSlots then return end
    local counts = {}
    for _, bag in ipairs(BankBags()) do
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
    for _, r in ipairs(recipes) do
        byIndex[r.index] = r
        -- Prefer the client's own craftable count, then whatever the scan
        -- reported, then the reagent arithmetic. Working it out from reagents
        -- costs several calls per recipe, so it stays the last resort.
        local n = API.CraftableCount(r.index)
        if n == nil then n = r.numAvailable end
        if n == nil then n = self:CraftableFromBags(r.index) end
        r.numAvailable = n or 0
        r.profit = select(1, self:Profit(r.index))
    end
    -- Rebuild the reagent -> recipe map so the queue can find intermediates.
    self:BuildOutputIndex()
    return recipes, byIndex
end

-- How many of the item one craft makes, for valuing the output.
function PW:AmountMade(index)
    local lo = API.NumMade(index)
    return max(lo or 1, 1)
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
            local cd = store[r.name]
            -- Only restart the timer when the recipe is on cooldown now, so a
            -- refresh while a craft is running doesn't push the expiry back.
            if not cd or (cd.expires or 0) <= now then
                store[r.name] = {
                    expires = now + r.cooldown,
                    profession = profession,
                    char = self.charName,
                }
            end
        end
        -- A recipe that is off cooldown needs no change: the entry keeps its
        -- past expiry, which shows as Ready and is pruned in ReadyCooldowns.
    end
end

-- Cooldowns that have finished and not been announced yet, soonest first.
-- Entries are dropped a day after they expire so the saved table can't grow.
function PW:ReadyCooldowns()
    local store, ready = self.charDB and self.charDB.cooldowns, {}
    if not store then return ready end
    local now = time()
    for name, cd in pairs(store) do
        local expires = cd.expires or 0
        if expires > 0 and expires <= now then
            if not cd.reported then
                cd.reported = true
                ready[#ready + 1] = { recipe = name }
            elseif expires < now - 86400 then
                store[name] = nil -- announced a day ago, nothing left to keep
            end
        end
    end
    table.sort(ready, function(a, b) return a.recipe < b.recipe end)
    return ready
end

-- Tracked cooldowns for every character, earliest expiry first.
function PW:AllCooldowns()
    local entries, now = {}, time()
    for key, data in pairs(self.db.chars or {}) do
        -- Saved before hyphenated names were split, so prefer the stored name.
        local char = data.name or key
        for recipe, cd in pairs(data.cooldowns or {}) do
            entries[#entries + 1] = {
                char = char,
                recipe = recipe,
                profession = cd.profession,
                left = math.max((cd.expires or 0) - now, 0),
                ready = (cd.expires or 0) <= now,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.left == b.left then
            if a.char == b.char then return a.recipe < b.recipe end
            return a.char < b.char
        end
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
    -- Only while our window replaces it: Blizzard's window can also be opened
    -- without a profession (e.g. the K key), and must then stay open.
    if not (PW.frame and PW.frame:IsShown()) then return end
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
            f:HookScript("OnShow", function()
                -- Next frame: TRADE_SKILL_SHOW may not have been handled yet.
                C_Timer.After(0, function()
                    PW:UpdateSwitchButtons()
                    PW.SuppressBlizzard()
                end)
            end)
        end
    end
    self:UpdateSwitchButtons()
end

-- "Use Workbench" only makes sense while a profession is actually open.
function PW:UpdateSwitchButtons()
    local show = self.tradeSkillOpen and API ~= nil and API.CanReplace()
    for name in pairs(ns.BLIZZARD_FRAMES) do
        local f = _G[name]
        if f and f.pwbSwitch then f.pwbSwitch:SetShown(show and true or false) end
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
    "MERCHANT_SHOW", "MERCHANT_UPDATE",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
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
        local ready = PW:ReadyCooldowns()
        if #ready > 0 then
            local names = {}
            for i, e in ipairs(ready) do names[i] = e.recipe end
            Print("Cooldowns ready: |cffffffff" .. table.concat(names, ", ") .. "|r")
        end
    end)
end

function PW:TRADE_SKILL_SHOW()
    self.tradeSkillOpen = true
    self:UpdateSwitchButtons()
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
    API.Prepare()

    self:BuildUI()
    self.frame:Show()
    self:Refresh()

    self.SuppressBlizzard()
    C_Timer.After(0, PW.SuppressBlizzard)
end

function PW:TRADE_SKILL_UPDATE()
    self:RequestRefresh()
end
PW.TRADE_SKILL_LIST_UPDATE = PW.TRADE_SKILL_UPDATE
PW.TRADE_SKILL_DATA_SOURCE_CHANGED = PW.TRADE_SKILL_UPDATE
PW.NEW_RECIPE_LEARNED = PW.TRADE_SKILL_UPDATE

function PW:TRADE_SKILL_CLOSE()
    self.tradeSkillOpen = false
    self:UpdateSwitchButtons()
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

-- Merchant prices are fixed, so every visit fills in more of the catalogue.
function PW:MERCHANT_SHOW()
    local learned = self:ScanMerchant()
    if learned and learned > 0 then self:RequestRefresh() end
end

function PW:MERCHANT_UPDATE()
    self:ScanMerchant()
end

function PW:PrintDisposition(itemID)
    local f = self:ItemFacts(itemID)
    if not f then
        Print("Item " .. tostring(itemID) .. " isn't cached yet. Hover it once and try again.")
        return
    end
    Print(format("%s (item level %d)", f.name, f.itemLevel or 0))
    local d = self:Disposition(itemID)
    if not d then return end
    if d.vendor then print("  vendor pays:     " .. PW.Money(d.vendor)) end
    if d.auction then print("  auction (after cut): " .. PW.Money(d.auction)) end
    if d.disenchant then
        local lootText = self:LootText(itemID)
        print(format("  disenchant:      %s%s", PW.Money(d.disenchant), lootText and ("  (" .. lootText .. ")") or ""))
    else
        print("  disenchant:      not possible, or its materials have no price")
    end
    local label = ({ vendor = "sell to a vendor", auction = "auction house",
                     disenchant = "disenchant" })[d.best]
    if label then print("  best: " .. label) end
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

SLASH_PROFWORKBENCH1 = "/pwb"
SlashCmdList.PROFWORKBENCH = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    -- This is a plain function: there is no self, so use PW explicitly.
    local self = PW

    if msg == "blizz" or msg == "blizzard" then
        PW:SetUseBlizzard(not PW.db.useBlizzard)
        Print(PW.db.useBlizzard
            and "Using the default Blizzard window. Click \"Use Workbench\" on it, or type /pwb blizz, to switch back."
            or "Using the Profession Workbench window.")

    elseif msg:match("^scale%f[%A]") or msg == "scale" then
        local arg = msg:match("^scale%s+(%S+)")
        if not arg then
            Print(format("Window scale is %.2f. Use /pwb scale <0.6-2>, e.g. /pwb scale 1.3", PW.db.scale or 1))
        elseif not tonumber(arg) then
            Print("Usage: /pwb scale <0.6-2>, e.g. /pwb scale 1.3")
        else
            Print(format("Window scale set to %.2f.", PW:SetScale(arg)))
        end

    elseif msg:match("^price%f[%A]") or msg == "price" then
        local rest = msg:match("^price%s+(.+)$")
        if not rest then
            Print("Usage: /pwb price <itemID> <gold>  - set a price by hand, e.g. /pwb price 2592 1.5")
            Print("       /pwb price clear <itemID>  - forget a manual price")
            Print("       /pwb prices  - list what is known")
        elseif rest:match("^clear%s+%d+$") then
            local clearID = tonumber(rest:match("^clear%s+(%d+)$"))
            if PW:Prices()[clearID] then
                PW:Prices()[clearID] = nil
                Print("Forgot the price for item " .. clearID .. ".")
                if PW.frame and PW.frame:IsShown() then PW:Refresh() end
            else
                Print("No price stored for item " .. clearID .. ".")
            end
        else
            local id, amount = rest:match("^(%d+)%s+(.+)$")
            if id and amount then
                id = tonumber(id)
                local gold = tonumber(amount:match("^([%d%.]+)"))
                if not gold then
                    Print("That price doesn't look like a number. Try /pwb price 2592 1.5")
                else
                    local copper = floor(gold * 10000 + 0.5)
                    PW:SetPrice(id, copper, "manual", true)
                    local name = C_Item and C_Item.GetItemInfo and select(1, C_Item.GetItemInfo(id))
                    Print(format("Price set: %s = %s each.", name or ("item " .. id), PW.Money(copper)))
                    if PW.frame and PW.frame:IsShown() then PW:Refresh() end
                end
            else
                Print("Usage: /pwb price <itemID> <gold>, e.g. /pwb price 2592 1.5")
            end
        end

    elseif msg == "prices" then
        local prices, list = PW:Prices(), {}
        for id in pairs(prices) do list[#list + 1] = id end
        table.sort(list)
        if #list == 0 then
            Print("No prices stored yet.")
            print("  Visit a merchant to learn vendor prices, or set one with /pwb price <itemID> <gold>.")
        else
            Print(format("%d prices stored:", #list))
            for _, id in ipairs(list) do
                local p = prices[id]
                local name = C_Item and C_Item.GetItemInfo and select(1, C_Item.GetItemInfo(id))
                print(format("  %s - %s each (%s, %s)%s",
                    name or ("item " .. id), PW.Money(p.unit), p.source or "?",
                    PW.Age(p.at and (time() - p.at)), PW:IsStale(id) and " |cffff5959stale|r" or ""))
            end
        end

    elseif msg:match("^queue%f[%A]") or msg == "queue" then
        local arg = msg:match("^queue%s+(.+)$")
        local r = self.selected and self.byIndex[self.selected]
        if arg then
            local count, name = arg:match("^(%d+)%s+(.+)$")
            name = name or arg
            count = tonumber(count) or 1
            local found = PW:FindRecipeByName(name)
            if found then
                PW:AddToQueue(found.index, count)
                Print(format("Queued %dx %s.", count, found.name))
                if PW.frame and PW.frame:IsShown() then PW:RefreshQueue() end
            else
                Print("No recipe called \"" .. name .. "\" here. Open the right profession first.")
            end
        elseif r then
            PW:AddToQueue(r.index, 1)
            Print(format("Queued 1x %s. Type /pwb queue <count> <recipe> to add more.", r.name))
            if PW.frame and PW.frame:IsShown() then PW:RefreshQueue() end
        else
            Print("Usage: /pwb queue [<count>] [<recipe name>]")
            Print("       With no arguments, queues the selected recipe once.")
        end

    elseif msg == "queueclear" then
        PW:ClearQueue()
        Print("Craft queue cleared.")
        if PW.frame and PW.frame:IsShown() then PW:RefreshQueue() end

    elseif msg == "list" or msg == "shopping" then
        local queue = PW:Queue()
        if #queue == 0 then
            Print("The craft queue is empty. Add something with /pwb queue.")
        elseif not self.recipes then
            -- The shopping list needs the profession open to resolve recipes.
            Print(format("The queue has %d crafts. Open the profession to see what is missing.", PW:QueueCount()))
            for _, q in ipairs(queue) do print(format("  %dx %s", q.count, q.name)) end
        else
            Print(format("Shopping list for %d queued crafts:", PW:QueueCount()))
            local list = PW:ShoppingList(queue, self.db.filters.useBank)
            if #list == 0 then
                print("  Everything needed is already in your bags.")
            end
            for _, entry in ipairs(list) do
                local col = entry.missing > 0 and "|cffff5959" or "|cff66ff66"
                print(format("  %s x%d|r  (have %d, need %d)%s",
                    col, entry.missing, entry.have, entry.need, entry.name and ("  " .. entry.name) or ""))
            end
        end

    elseif msg:match("^scanitem%f[%A]") or msg == "scanitem" then
        local amount = msg:match("^scanitem%s+(%S+)$")
        local gold = amount and tonumber(amount:match("^([%d%.]+)"))
        local ok, text = PW:PriceHovered(gold)
        Print(text)
        if ok and PW.frame and PW.frame:IsShown() then PW:Refresh() end

    elseif msg:match("^de%f[%A]") or msg == "de" then
        local arg = msg:match("^de%s+(.+)$")
        if not arg then
            -- No argument: use the hovered item, else the selected recipe's output.
            local hovered = PW:HoveredItem()
            local itemID = hovered
            if not itemID and self.selected and self.byIndex[self.selected] then
                itemID = self.API.OutputItemID and self.API.OutputItemID(self.selected)
            end
            if not itemID then
                Print("Usage: /pwb de <itemID or item name>  - or hover an item and type /pwb de")
            else
                PW:PrintDisposition(itemID)
            end
        elseif tonumber(arg) then
            PW:PrintDisposition(tonumber(arg))
        else
            -- Look the name up among the recipes we can see.
            local found
            local needle = arg:lower()
            for _, r in ipairs(self.recipes or {}) do
                if r.name:lower() == needle then
                    found = self.API.OutputItemID and self.API.OutputItemID(r.index)
                    break
                end
            end
            if found then
                PW:PrintDisposition(found)
            else
                Print("No item called \"" .. arg .. "\" in this profession's recipes.")
            end
        end

    elseif msg:match("^ahscan%f[%A]") or msg == "ahscan" then
        PW:StartScan()

    elseif msg:match("^ahstop") then
        if PW:IsScanning() then PW:StopScan(false) else Print("No scan is running.") end

    elseif msg:match("^ahstatus") then
        local done, total, failed = PW:ScanProgress()
        if not done then
            Print("No scan is running.")
        else
            Print(format("Scanning: %d of %d items (%d skipped). /pwb ahstop to cancel.", done, total, failed or 0))
        end

    elseif msg:match("^ahitem") then
        PW:ScanHovered()

    elseif msg == "ahhelp" then
        Print("Auction house:")
        print("  /pwb ahscan - price your recipes' reagents, products and disenchant materials")
        print("  /pwb ahitem - price just the item you are hovering")
        print("  /pwb ahstatus, /pwb ahstop")

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
        Print("Prices known: " .. tostring(PW:PriceCount()))
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
        print("  /pwb price <itemID> <gold> - set an item's price by hand")
        print("  /pwb scanitem <gold> - record the hovered item's price by hand")
        print("  /pwb de [item] - compare vendor, auction and disenchant value")
        print("  /pwb ahscan - at the auction house, price your reagents and products")
        print("  /pwb ahstop - stop a running auction house scan")
        print("  /pwb ahitem - price just the item you are hovering")
        print("  /pwb prices - list known prices")
        print("  /pwb queue [<count>] [<recipe>] - add to the craft queue")
        print("  /pwb list - shopping list for the queue")
        print("  /pwb queueclear - empty the craft queue")
        print("  /pwb reset - reset the window position and size")
        print("  /pwb debug - show client and API info")
    end
end
