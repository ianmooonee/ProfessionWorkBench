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

-- Give up on a runaway listing after this many pages.
local MAX_PAGES = 40

---------------------------------------------------------------------------
-- What we want to price
---------------------------------------------------------------------------

function PW:ScanTargets()
    local seen, list = {}, {}
    local function Add(itemID)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            list[#list + 1] = itemID
        end
    end
    for _, r in ipairs(self.recipes or {}) do
        Add(self.API.OutputItemID and self.API.OutputItemID(r.index))
        for _, rg in ipairs(self:GetReagents(r.index)) do
            Add(rg.itemID or PW.ItemIDFromLink(rg.link))
        end
    end
    for _, itemID in ipairs(PW.DE_MATERIALS or {}) do Add(itemID) end
    return list, seen
end

---------------------------------------------------------------------------
-- Scan state
---------------------------------------------------------------------------

-- scan = { wanted = { [itemID] = true }, seen = n, pages = n, priced = n }
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

function PW:StartScan()
    if not usable then
        Notify("This client has no auction house browse API. Record prices with /pwb scanitem instead.")
        return
    end
    if scan then
        Notify("A scan is already running. Click the button again, or /pwb ahstop, to cancel it.")
        return
    end
    local wanted, wantedSet = self:ScanTargets()
    if #wanted == 0 then
        Notify("Nothing to price: open a profession first so the addon knows your recipes.")
        return
    end
    scan = { wanted = wantedSet, wantedCount = #wanted, seen = 0, pages = 0, priced = 0 }
    Notify(format("Scanning the auction house for %d items of interest.", #wanted))
    self:SendBrowse()
end

function PW:StopScan(finished)
    if not scan then return end
    local priced, wanted, seen = scan.priced, scan.wantedCount, scan.seen
    scan = nil
    if finished then
        Notify(format("Scan finished: priced %d of the %d items you care about (looked at %d listings).", priced, wanted, seen))
    else
        Notify(format("Scan stopped: priced %d of %d so far.", priced, wanted))
    end
    self:UpdateAHButton()
    if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- One query for the whole house; pages arrive through the browse events.
function PW:SendBrowse()
    if not scan then return end
    scan.pages = 0
    local ok, err = pcall(AH.SendBrowseQuery, {
        searchString = "",
        sorts = SORTS,
        filters = {},
        itemClassFilters = {},
    })
    if not ok then
        Notify("The auction house refused the query: " .. tostring(err))
        self:StopScan(false)
    end
end

---------------------------------------------------------------------------
-- Harvesting prices from browse results
---------------------------------------------------------------------------

-- Walk every browse result available and record the cheapest price per item.
-- Returns how many new items were priced.
function PW:HarvestBrowse()
    if not scan then return 0 end
    local results = AH.GetBrowseResults()
    if type(results) ~= "table" then return 0 end

    local newPrices = 0
    for _, r in ipairs(results) do
        local key = r.itemKey
        local itemID = key and (key.itemID or (key.GetItemID and key:GetItemID()))
        if itemID then
            scan.seen = scan.seen + 1
            -- minPrice is the cheapest listing of that item, per unit already.
            local price = r.minPrice
            if price and price > 0 and scan.wanted[itemID] then
                local before = PW:UnitPrice(itemID)
                PW:SetPrice(itemID, floor(price + 0.5), "ah")
                if PW:UnitPrice(itemID) ~= before then newPrices = newPrices + 1 end
            end
        end
    end
    scan.priced = 0
    for itemID in pairs(scan.wanted) do
        if PW:UnitPrice(itemID) then scan.priced = scan.priced + 1 end
    end
    if newPrices > 0 then self:UpdateAHButton() end
    return newPrices
end

-- Results arrived: harvest, then ask for another page if there is more.
function PW:OnBrowseResults()
    if not scan then return end
    self:HarvestBrowse()

    if AH.HasFullBrowseResults() then
        self:StopScan(true)
        return
    end
    scan.pages = scan.pages + 1
    if scan.pages > MAX_PAGES then
        self:StopScan(true)
        return
    end
    local ok = pcall(AH.RequestMoreBrowseResults)
    if not ok then
        self:StopScan(true)
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function PW:AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    -- Some clients fire this once per page batch and again with the additions,
    -- so ignore it unless a scan is actually waiting on data.
    if scan then self:OnBrowseResults() end
end

function PW:AUCTION_HOUSE_BROWSE_RESULTS_ADDED()
    if scan then self:OnBrowseResults() end
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
    b:SetScript("OnClick", function()
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
        GameTooltip:AddLine("Reads the auction house listing and records what your known recipes' reagents and products are worth, plus the disenchant materials.", 1, 1, 1, true)
        GameTooltip:AddLine("One browse query with every page, so it is quick and stays well inside the auction house limits.", 0.7, 0.7, 0.7, true)
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
    local itemID = self:HoveredItem()
    if not itemID then
        Notify("Hover an auction listing first.")
        return
    end
    if scan then Notify("A scan is already running; it will cover this item.") return end
    if not (C_Item and C_Item.GetItemInfo and select(1, C_Item.GetItemInfo(itemID))) then
        Notify("That item isn't cached yet; hover it again.")
        return
    end
    -- A scan restricted to the one item.
    scan = { wanted = { [itemID] = true }, wantedCount = 1, seen = 0, pages = 0, priced = 0 }
    self:SendBrowse()
end
