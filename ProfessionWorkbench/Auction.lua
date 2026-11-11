-- Profession WorkBench: auction house price scanning.
--
-- How this prices things, and why it does it this way:
--
-- The C_AuctionHouse API offers two ways to look up an item. SendSearchQuery is
-- limited to 100 calls a minute and only answers once the throttled message
-- system says it is ready - an event that fires once and can leave a caller
-- waiting forever. SendBrowseQuery is what Blizzard's own auction house uses on
-- this client, gives back a flat list of items with a minPrice per item, and
-- pages with RequestMoreBrowseResults.
--
-- So a scan here does not ask about items one at a time. It sends ONE browse
-- query, pulls every page of results, and harvests the prices of every item it
-- recognises along the way. That is a single query for the whole profession
-- rather than hundreds, which is both faster and far gentler on the throttle.
--
-- Only one request is ever outstanding. Results that arrive while we aren't
-- waiting (a second event for the same page, or the player's own search in
-- Blizzard's window) are ignored, and a watchdog retries once and then gives up
-- if the auction house never answers, so a scan can't hang.

local ADDON, ns = ...
local PW = assert(ns.PW, "Profession WorkBench: Auction.lua must load after Core.lua")

local floor, max, format = math.floor, math.max, string.format

local AH = C_AuctionHouse
local usable = AH and type(AH.SendBrowseQuery) == "function"
    and type(AH.GetBrowseResults) == "function"

PW.AH_AVAILABLE = usable and true or false

local function Notify(msg)
    if PW.Print then PW.Print(msg) end
end

-- Cheapest first, so the prices we see first are the ones we keep.
local SORTS = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder
    and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }

-- Give up on a runaway listing after this many extra pages.
local MAX_PAGES = 60
-- Seconds to wait for an answer before retrying (once) and then giving up.
local REQUEST_TIMEOUT = 15
-- Pause between pages, to stay well inside the throttle.
local PAGE_DELAY = 0.2

---------------------------------------------------------------------------
-- What we want to price
---------------------------------------------------------------------------

-- Every item a list of recipes makes or uses. Reads the API directly (no bank
-- counts needed), since this can cover hundreds of unlearned recipes.
local function ItemsOf(self, recipes)
    local ids, seen = {}, {}
    for _, r in ipairs(recipes or {}) do
        local out = self.API.OutputItemID and self.API.OutputItemID(r.index)
        if out and not seen[out] then seen[out] = true; ids[#ids + 1] = out end
        for _, rg in ipairs(self.API.GetReagents(r.index)) do
            local id = rg.itemID or PW.ItemIDFromLink(rg.link)
            if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    return ids
end

-- Remember what a profession makes and uses, per character, so a scan at the
-- auction house covers every profession this character has opened rather than
-- only the last one. Refreshed at most every 30 seconds per profession, since
-- the window refreshes on every bag change.
local REMEMBER_EVERY = 30
function PW:RememberProfessionItems(profession, recipes)
    if not profession or not self.charDB or not recipes or #recipes == 0 then return end
    self.charDB.scanItems = self.charDB.scanItems or {}
    local entry = self.charDB.scanItems[profession]
    if entry and entry.at and (time() - entry.at) < REMEMBER_EVERY then return end

    -- Learned recipes, plus the ones not learned yet when the API can list
    -- them, so prices are ready before you train a recipe.
    local all = {}
    for i, r in ipairs(recipes) do all[i] = r end
    local unlearned = self.API.UnlearnedRecipeIDs and self.API.UnlearnedRecipeIDs() or {}
    for _, id in ipairs(unlearned) do all[#all + 1] = { index = id } end

    local items = ItemsOf(self, all)
    if #items == 0 then return end
    self.charDB.scanItems[profession] = {
        items = items, recipes = #recipes, unlearned = #unlearned, at = time(),
    }
end

-- Professions this character has items remembered for, sorted by name.
function PW:RememberedProfessions()
    local list = {}
    for prof, entry in pairs(self.charDB and self.charDB.scanItems or {}) do
        list[#list + 1] = {
            name = prof, items = #(entry.items or {}),
            recipes = entry.recipes, unlearned = entry.unlearned, at = entry.at,
        }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function PW:ForgetProfession(name)
    local store = self.charDB and self.charDB.scanItems
    if not store or not name then return end
    local wanted = name:lower()
    for prof in pairs(store) do
        if prof:lower() == wanted then
            store[prof] = nil
            return prof
        end
    end
end

-- Returns the item list, a set of the same items, and the profession names.
function PW:ScanTargets()
    local seen, list = {}, {}
    local function Add(itemID)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            list[#list + 1] = itemID
        end
    end
    local profs = {}
    for _, p in ipairs(self:RememberedProfessions()) do
        profs[#profs + 1] = p.name
        for _, id in ipairs(self.charDB.scanItems[p.name].items or {}) do Add(id) end
    end
    -- The open profession too, in case it hasn't been remembered yet.
    for _, id in ipairs(ItemsOf(self, self.recipes)) do Add(id) end
    for _, itemID in ipairs(PW.DE_MATERIALS or {}) do Add(itemID) end
    return list, seen, profs
end

---------------------------------------------------------------------------
-- Scan state
---------------------------------------------------------------------------

-- scan = {
--   wanted = { [itemID] = true }, wantedCount = n,
--   best = { [itemID] = cheapest unit price seen this scan },
--   priced = n, seen = n,      -- items priced / browse rows looked at
--   harvested = n,             -- rows of GetBrowseResults() already read
--   pages = n,                 -- extra pages requested
--   waiting = bool, token = n, -- one outstanding request + its watchdog
--   search = "...", single = itemID,
-- }
local scan

function PW:IsScanning() return scan ~= nil end

function PW:ScanProgress()
    if not scan then return end
    return scan.priced, scan.wantedCount, scan.seen
end

function PW:AuctionHouseOpen()
    -- The window is a load-on-demand addon: nil until opened at least once.
    return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) and true or false
end

local function NewScan(wantedSet, wantedCount)
    return {
        wanted = wantedSet, wantedCount = wantedCount,
        best = {}, priced = 0, seen = 0, harvested = 0, pages = 0,
        waiting = false, token = 0, retried = false,
    }
end

function PW:StartScan()
    if not usable then
        Notify("This client has no auction house browse API. Record prices with /pwb scanitem instead.")
        return
    end
    if not self:AuctionHouseOpen() then
        Notify("Open the auction house first, then scan.")
        return
    end
    if scan then
        Notify("A scan is already running. Click the button again, or /pwb ahstop, to cancel it.")
        return
    end
    local wanted, wantedSet, profs = self:ScanTargets()
    if #profs == 0 and #(self.recipes or {}) == 0 then
        Notify("Open each of your professions once first, so the addon knows what to price.")
        return
    end
    scan = NewScan(wantedSet, #wanted)
    Notify(format("Scanning the auction house for %d items (%s, plus disenchanting materials).",
        #wanted, #profs > 0 and table.concat(profs, ", ") or (self.profession or "open profession")))
    self:UpdateAHButton()
    self:SendBrowse()
end

-- status: "done" (read everything), "capped" (hit MAX_PAGES), "error",
-- or anything false-y for a cancel. Kept compatible with StopScan(false).
function PW:StopScan(status)
    if not scan then return end
    local s = scan
    scan = nil

    if s.single then
        local name = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(s.single)) or ("item " .. s.single)
        if s.best[s.single] then
            Notify(format("%s: lowest buyout %s each.", name, PW.Money(s.best[s.single])))
        elseif status == "done" then
            Notify(format("%s isn't listed on the auction house right now.", name))
        elseif status then
            Notify(format("Couldn't price %s.", name))
        end
    elseif status == "done" then
        local missing = s.wantedCount - s.priced
        Notify(format("Scan finished: priced %d of the %d items you care about (looked at %d listings).%s",
            s.priced, s.wantedCount, s.seen,
            missing > 0 and format(" %d aren't listed right now.", missing) or ""))
    elseif status == "capped" then
        Notify(format("Scan stopped after %d pages: priced %d of %d. The auction house was too big to read in one go.",
            s.pages, s.priced, s.wantedCount))
    elseif status == "error" then
        Notify(format("Scan stopped: the auction house stopped answering. Priced %d of %d.", s.priced, s.wantedCount))
    else
        Notify(format("Scan stopped: priced %d of %d so far.", s.priced, s.wantedCount))
    end

    self:UpdateAHButton()
    if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- Mark a request as outstanding and start its watchdog.
local function Arm()
    scan.waiting = true
    scan.token = scan.token + 1
    local s, token = scan, scan.token
    C_Timer.After(REQUEST_TIMEOUT, function()
        if scan == s and s.waiting and s.token == token then
            PW:OnRequestLost()
        end
    end)
end

-- One query for the whole house (or one item name); pages arrive through the
-- browse events.
function PW:SendBrowse()
    if not scan then return end
    scan.harvested = 0 -- a new query replaces the result list
    Arm()
    local ok, err = pcall(AH.SendBrowseQuery, {
        searchString = scan.search or "",
        sorts = SORTS,
        filters = {},
        itemClassFilters = {},
    })
    if not ok then
        Notify("The auction house refused the query: " .. tostring(err))
        self:StopScan("error")
    end
end

function PW:RequestMore()
    if not scan then return end
    scan.pages = scan.pages + 1
    Arm()
    if not pcall(AH.RequestMoreBrowseResults) then
        self:StopScan("done")
    end
end

-- The request was dropped or never answered: retry once, then give up.
function PW:OnRequestLost()
    if not scan then return end
    scan.waiting = false
    if scan.retried then
        self:StopScan("error")
        return
    end
    scan.retried = true
    if scan.pages == 0 and scan.harvested == 0 then
        self:SendBrowse()
    else
        scan.pages = scan.pages - 1 -- the lost page doesn't count
        self:RequestMore()
    end
end

---------------------------------------------------------------------------
-- Harvesting prices from browse results
---------------------------------------------------------------------------

-- Read the rows that arrived since last time and record the cheapest price
-- per wanted item. GetBrowseResults() returns the whole accumulated list, so
-- only the new tail is read; each row is counted once.
function PW:HarvestBrowse()
    if not scan then return end
    local results = AH.GetBrowseResults()
    if type(results) ~= "table" then return end
    if #results < scan.harvested then scan.harvested = 0 end -- list was replaced

    for i = scan.harvested + 1, #results do
        local r = results[i]
        local key = r and r.itemKey
        local itemID = key and (key.itemID or (key.GetItemID and key:GetItemID()))
        if itemID then
            scan.seen = scan.seen + 1
            -- minPrice is the cheapest listing of that item key, per unit.
            local price = r.minPrice
            if price and price > 0 and scan.wanted[itemID] then
                price = floor(price + 0.5)
                -- Several item keys can share an itemID; keep the cheapest.
                if not scan.best[itemID] then
                    scan.priced = scan.priced + 1
                end
                if not scan.best[itemID] or price < scan.best[itemID] then
                    scan.best[itemID] = price
                    PW:SetPrice(itemID, price, "ah")
                end
            end
        end
    end
    scan.harvested = #results
    self:UpdateAHButton()
end

-- Results arrived: harvest, then ask for another page if there is more.
function PW:OnBrowseResults()
    -- Only act on an answer to our own request. This drops the second event
    -- some clients send for the same page, and the player's own searches.
    if not scan or not scan.waiting then return end
    scan.waiting = false
    scan.retried = false
    self:HarvestBrowse()

    local full = not AH.HasFullBrowseResults or AH.HasFullBrowseResults()
    if full or scan.priced >= scan.wantedCount then
        self:StopScan("done")
        return
    end
    if scan.pages >= MAX_PAGES then
        self:StopScan("capped")
        return
    end
    local s = scan
    C_Timer.After(PAGE_DELAY, function()
        if scan == s and not s.waiting then PW:RequestMore() end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function PW:AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    self:OnBrowseResults()
end

function PW:AUCTION_HOUSE_BROWSE_RESULTS_ADDED()
    self:OnBrowseResults()
end

-- The throttle discarded a queued request: don't wait for the watchdog.
function PW:AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
    if scan and scan.waiting then self:OnRequestLost() end
end

---------------------------------------------------------------------------
-- A button in the auction house window itself
---------------------------------------------------------------------------

local ahButton

local function BuildAHButton(parent)
    if ahButton then return ahButton end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    -- Beside the search box at the top, clear of the tab strip.
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -34)
    b:SetText("Scan prices")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Price just the listing under the cursor.
            PW:ScanHovered()
            return
        end
        if PW:IsScanning() then
            PW:StopScan(false)
        else
            PW:StartScan()
        end
        PW:UpdateAHButton()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Profession Workbench: scan prices")
        GameTooltip:AddLine("Records what your known recipes' reagents and products are worth, plus the disenchant materials.", 1, 1, 1, true)
        GameTooltip:AddLine("One browse query with every page, so it is quick.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Right-click: price just the listing under your cursor.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    ahButton = b
    return b
end

function PW:UpdateAHButton()
    local b = ahButton
    if not b then return end
    local priced, wanted = self:ScanProgress()
    if priced then
        b:SetText(format("Stop %d/%d", priced, wanted))
    else
        b:SetText("Scan prices")
    end
end

function PW:HookAuctionHouse()
    if not usable or not AuctionHouseFrame then return end
    BuildAHButton(AuctionHouseFrame):SetShown(true)
    self:UpdateAHButton()
end

function PW:AUCTION_HOUSE_SHOW()
    self:HookAuctionHouse()
    C_Timer.After(0, function() PW:HookAuctionHouse() end)
    C_Timer.After(0.5, function() PW:HookAuctionHouse() end)
    if not PW.ahHinted and usable then
        PW.ahHinted = true
        Notify("There is a \"Scan prices\" button on the auction house window.")
    end
end

function PW:AUCTION_HOUSE_CLOSED()
    if scan then self:StopScan(false) end
end

---------------------------------------------------------------------------
-- Price a single item from where the cursor is
---------------------------------------------------------------------------

function PW:ScanHovered()
    if not usable then
        Notify("No auction house API here. Use /pwb scanitem <gold> instead.")
        return
    end
    if not self:AuctionHouseOpen() then
        Notify("Open the auction house first.")
        return
    end
    local itemID = self:HoveredItem()
    if not itemID then
        Notify("Hover an auction listing first.")
        return
    end
    if scan then Notify("A scan is already running; it will cover this item.") return end
    local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(itemID)
    if not name then
        Notify("That item isn't cached yet; hover it again.")
        return
    end
    -- Search by name so this reads a handful of rows, not the whole house.
    scan = NewScan({ [itemID] = true }, 1)
    scan.single = itemID
    scan.search = name
    self:UpdateAHButton()
    self:SendBrowse()
end
