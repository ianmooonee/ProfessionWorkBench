-- Profession WorkBench: auction house price scanning.
--
-- The client has only the modern C_AuctionHouse API. There is no synchronous
-- "what does X cost": a search is sent, results arrive later, and searches are
-- limited to 100 per minute. So a scan is a queue that sends one query at a
-- time, waits for the throttle, and can be stopped and resumed.
--
-- Two shapes of result matter and they are easy to confuse:
--   * commodities (stackable goods: cloth, dust, ore) report a UNIT price
--   * items (gear) report the buyout of the whole listing, so the unit price
--     is buyoutAmount / quantity
-- Getting that wrong is off by a stack factor, so the two paths are kept apart.

local ADDON, ns = ...
local PW = assert(ns.PW, "Profession WorkBench: Auction.lua must load after Core.lua")

local floor, max, format = math.floor, math.max, string.format

local AH = C_AuctionHouse
local usable = AH and type(AH.SendSearchQuery) == "function"
    and type(AH.MakeItemKey) == "function"

PW.AH_AVAILABLE = usable and true or false

local SORTS = {} -- default sort; we only need the cheapest listing

---------------------------------------------------------------------------
-- Scan state
---------------------------------------------------------------------------

-- A scan is: { queue = {itemID, ...}, index = n, found = {}, done = n, failed = n }
local scan

local function Notify(msg)
    if PW.Print then PW.Print(msg) end
end

function PW:IsScanning()
    return scan ~= nil
end

-- Whether the auction house is open. The UI is a load-on-demand addon, so the
-- frame may not exist until the player opens it; prefer probing the API state
-- and fall back to the frame only when that is unavailable.
function PW:AuctionHouseOpen()
    -- The window is a load-on-demand addon: nil until the player opens it once.
    return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) and true or false
end

function PW:ScanProgress()
    if not scan then return end
    return scan.done, #scan.queue, scan.failed
end

-- The items worth pricing: every reagent of every known recipe, every recipe
-- output, and the disenchant materials (so disenchant values work too).
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
    return list
end

function PW:StartScan()
    if not usable then
        Notify("This client has no auction house API the addon can use. Record prices with /pwb scanitem instead.")
        return
    end
    -- The frame check is only a courtesy: if the name ever differs, the scan
    -- still runs and reports through the events.
    if not self:AuctionHouseOpen() then
        Notify("Open the auction house first, then start the scan.")
    end
    if scan then
        Notify("A scan is already running. /pwb ahstop to cancel it.")
        return
    end
    local targets = self:ScanTargets()
    if #targets == 0 then
        Notify("Nothing to scan: open a profession first so the addon knows your recipes.")
        return
    end
    scan = { queue = targets, index = 1, done = 0, failed = 0 }
    Notify(format("Scanning %d items. This paces itself to the auction house limit, so it takes a couple of minutes.", #targets))
    self:PumpScan()
end

function PW:StopScan(finished)
    if not scan then return end
    local done, total = scan.done, #scan.queue
    scan = nil
    if finished then
        Notify(format("Scan finished: %d of %d items priced.", done, total))
    else
        Notify(format("Scan stopped after %d of %d items.", done, total))
    end
    self:UpdateAHButton()
    if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- Send the next query, or wait for the throttle to clear.
function PW:PumpScan()
    if not scan then return end
    -- Do not hard-stop on a missing frame; the throttle and result events are
    -- the real signal that the auction house is alive.
    if not AH.IsThrottledMessageSystemReady() then
        -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY will call us again.
        scan.waiting = true
        return
    end
    scan.waiting = false

    if scan.index > #scan.queue then
        self:StopScan(true)
        return
    end

    local itemID = scan.queue[scan.index]
    local key = AH.MakeItemKey(itemID)
    local info = key and AH.GetItemKeyInfo(key)
    -- Both kinds go through SendSearchQuery; only the result readers differ.
    local ok = pcall(AH.SendSearchQuery, key, SORTS, false, 0, 0)
    if not ok then
        scan.failed = scan.failed + 1
        scan.index = scan.index + 1
        C_Timer.After(0.2, function() PW:PumpScan() end)
        return
    end
    scan.awaiting = itemID
    scan.awaitingKey = key
    scan.awaitingCommodity = (info and info.isCommodity) or false
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

-- Cheap check for whether a result set belongs to the item we are waiting on.
local function ResultIsFor(itemKey, itemID)
    if not itemKey then return true end
    local ok, info = pcall(AH.GetItemKeyInfo, itemKey)
    return ok and info and info.itemID == itemID
end

-- Record the cheapest unit price from the results now available for an item.
function PW:CollectResults(itemID, itemKey, isCommodity, fromEventKey, fromEventID)
    -- Results are keyed differently for the two kinds, and the payload of the
    -- update event tells us which arrived. Only handle the item we sent.
    if fromEventID and fromEventID ~= itemID then return false end

    local cheapest, complete = nil, true
    if isCommodity then
        local n = AH.GetNumCommoditySearchResults(itemID) or 0
        for i = 1, n do
            local r = AH.GetCommoditySearchResultInfo(itemID, i)
            if r and r.unitPrice and r.unitPrice > 0 then
                if not cheapest or r.unitPrice < cheapest then cheapest = r.unitPrice end
            end
        end
        complete = AH.HasFullCommoditySearchResults(itemID)
    else
        if not itemKey then return false end
        local n = AH.GetNumItemSearchResults(itemKey) or 0
        for i = 1, n do
            local r = AH.GetItemSearchResultInfo(itemKey, i)
            -- buyoutAmount covers the whole stack, so divide by quantity.
            if r and r.buyoutAmount and r.buyoutAmount > 0 and (r.quantity or 0) > 0 then
                local unit = r.buyoutAmount / r.quantity
                if not cheapest or unit < cheapest then cheapest = unit end
            end
        end
        complete = AH.HasFullItemSearchResults(itemKey)
    end

    if cheapest then
        -- Guard: stopping from another event must not write into a dead scan.
        PW:SetPrice(itemID, floor(cheapest + 0.5), "ah")
    end
    return complete, cheapest ~= nil
end

-- Finish the current item and move on, requesting more pages if needed.
function PW:AdvanceScan()
    if not scan or not scan.awaiting then return end
    local itemID, itemKey, isCommodity = scan.awaiting, scan.awaitingKey, scan.awaitingCommodity
    -- The scan may be stopped from inside CollectResults, so re-check.
    local complete = self:CollectResults(itemID, itemKey, isCommodity)
    if not scan then return end

    if not complete then
        -- Ask for another page, then wait for the update event again.
        local ok
        if isCommodity then
            ok = pcall(AH.RequestMoreCommoditySearchResults, itemID)
        else
            ok = pcall(AH.RequestMoreItemSearchResults, itemKey)
        end
        scan.pages = (scan.pages or 0) + 1
        if ok and scan.pages <= 3 then return end
    end

    scan.pages = 0
    scan.awaiting, scan.awaitingKey, scan.awaitingCommodity = nil, nil, nil
    scan.index = scan.index + 1
    scan.done = scan.done + 1
    C_Timer.After(0.05, function() PW:PumpScan() end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- A button in the auction house window itself
--
-- Typing a command at the auction house is awkward, so the scan gets a button
-- on Blizzard's window. The frame is a load-on-demand addon, so this is
-- re-tried on AUCTION_HOUSE_SHOW and on the frame becoming available.
---------------------------------------------------------------------------

local ahButton

local function BuildAHButton(parent)
    if ahButton then return ahButton end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    -- Top of the window, clear of the search bar and the tab strip.
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
        GameTooltip:AddLine("Prices every reagent and product of your known recipes, plus the disenchant materials.", 1, 1, 1, true)
        GameTooltip:AddLine("Paced to the auction house limit, so a scan takes a couple of minutes.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    ahButton = b
    return b
end

function PW:UpdateAHButton()
    local b = ahButton
    if not b then return end
    local done, total = self:ScanProgress()
    if done then
        b:SetText(format("Stop %d/%d", done, total))
    else
        b:SetText("Scan prices")
    end
end

-- Called on AUCTION_HOUSE_SHOW, and again once the frame exists.
function PW:HookAuctionHouse()
    if not usable then return end
    if not AuctionHouseFrame then return end
    local b = BuildAHButton(AuctionHouseFrame)
    b:SetShown(true)
    self:UpdateAHButton()
end

function PW:AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    if scan and scan.waiting then self:PumpScan() end
end

function PW:AUCTION_HOUSE_SHOW()
    -- The window may be created after this event fires, so try now and once
    -- more on the next frame.
    self:HookAuctionHouse()
    C_Timer.After(0, function() PW:HookAuctionHouse() end)
    C_Timer.After(0.5, function() PW:HookAuctionHouse() end)
    if not PW.ahHinted and usable then
        PW.ahHinted = true
        Notify("There is a \"Scan prices\" button on the auction house window.")
    end
end

function PW:COMMODITY_SEARCH_RESULTS_UPDATED(receivedItemID)
    if scan and scan.awaiting and scan.awaitingCommodity then
        if not receivedItemID or receivedItemID == scan.awaiting then
            self:AdvanceScan()
        end
    end
end

function PW:ITEM_SEARCH_RESULTS_UPDATED(itemKey)
    if scan and scan.awaiting and not scan.awaitingCommodity then
        if ResultIsFor(itemKey, scan.awaiting) then self:AdvanceScan() end
    end
end

-- The "added" events fire as more pages arrive.
PW.COMMODITY_SEARCH_RESULTS_ADDED = PW.COMMODITY_SEARCH_RESULTS_UPDATED
PW.ITEM_SEARCH_RESULTS_ADDED = PW.ITEM_SEARCH_RESULTS_UPDATED

---------------------------------------------------------------------------
-- Price a single item now, without a full scan
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
    if not self:AuctionHouseOpen() then
        Notify("Open the auction house first.")
        return
    end
    -- Reuse the scan machinery for one item.
    if scan then Notify("A scan is already running; that will cover this item.") return end
    scan = { queue = { itemID }, index = 1, done = 0, failed = 0 }
    self:PumpScan()
end
