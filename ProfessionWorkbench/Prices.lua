-- Profession Workbench: item prices and craft profitability.
--
-- Prices come from three places, in this order of trust:
--   "manual" - typed in with /pwb price, always wins
--   "vendor" - what a merchant charges, learned whenever a merchant is open
--   "ah"     - the lowest buyout seen at the auction house
--
-- Everything here is stored per account, not per character, because prices are
-- a property of the realm's economy rather than of one alt.

local ADDON, ns = ...
-- Loaded right after Core.lua, which creates ns.PW.
local PW = assert(ns.PW, "Profession Workbench: Prices.lua must load after Core.lua")

local floor, min, max, format = math.floor, math.min, math.max, string.format

-- The auction house takes 5% of the sale price.
PW.AH_CUT = 0.05

-- Prices older than this are still shown, but flagged as stale.
local STALE_AFTER = 48 * 3600

-- Source ranks, used when two sources have a price for the same item.
local TRUST = { manual = 3, vendor = 2, ah = 1 }

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

-- db.prices[itemID] = { unit = <copper per unit>, source = "ah"|"vendor"|"manual", at = <time> }
function PW:Prices()
    self.db.prices = self.db.prices or {}
    return self.db.prices
end

-- Copper per unit for one item, or nil when nothing is known.
function PW:UnitPrice(itemID, ignoreSource)
    if not itemID then return end
    local p = self:Prices()[itemID]
    if not p or not p.unit then return end
    if ignoreSource and p.source == ignoreSource then return end
    return p.unit
end

function PW:PriceEntry(itemID)
    return itemID and self:Prices()[itemID] or nil
end

-- Record a price, keeping the more trusted source unless `force` is set.
function PW:SetPrice(itemID, unit, source, force)
    if not itemID or not unit or unit < 0 then return end
    local prices = self:Prices()
    local old = prices[itemID]
    if old and not force then
        local oldRank, newRank = TRUST[old.source] or 0, TRUST[source] or 0
        -- A manual price is never overwritten by a scan or a vendor visit.
        if oldRank > newRank then return old end
        -- Same source: the newer observation wins, so prices can rise as well
        -- as fall and the timestamp stays current. (Picking the cheapest
        -- listing within one scan is the scanner's job, see Auction.lua.)
    end
    local entry = { unit = unit, source = source, at = time() }
    prices[itemID] = entry
    return entry
end

function PW:PriceAge(itemID)
    local p = self:PriceEntry(itemID)
    return p and p.at and (time() - p.at) or nil
end

function PW:IsStale(itemID)
    local age = self:PriceAge(itemID)
    return age ~= nil and age > STALE_AFTER
end

function PW:PriceCount()
    local n = 0
    for _ in pairs(self:Prices()) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Reading a price off the item under the cursor
--
-- A full auction house scan needs a throttled query queue. Hovering a listing
-- and recording it is a far smaller thing that works today, and it gives real
-- market prices without touching the auction house API at all.
---------------------------------------------------------------------------

-- The item and money amount shown in whatever tooltip is up, if it is an item.
function PW:HoveredItem()
    if not (GameTooltip and TooltipUtil and TooltipUtil.GetDisplayedItem) then return end
    local ok, item = pcall(TooltipUtil.GetDisplayedItem, GameTooltip)
    if not ok or not item then return end
    local itemID = item.itemID or (item.GetItemID and item:GetItemID())
    if not itemID then return end
    -- The tooltip's own text carries the price line; reading it is fragile, so
    -- report the item and let the caller supply the amount.
    return itemID, item
end

-- Record a price for the hovered item. `gold` is per unit.
function PW:PriceHovered(gold)
    local itemID = self:HoveredItem()
    if not itemID then return false, "Hover an item first (an auction listing or a bag item)." end
    if not gold or gold <= 0 then return false, "Give a price, e.g. /pwb scanitem 1.5" end
    local copper = floor(gold * 10000 + 0.5)
    self:SetPrice(itemID, copper, "manual", true)
    local name = C_Item and C_Item.GetItemInfo and select(1, C_Item.GetItemInfo(itemID))
    return true, format("Recorded %s at %s each.", name or ("item " .. itemID), PW.Money(copper))
end

---------------------------------------------------------------------------
-- Vendor prices
--
-- There is no API for "what does a vendor charge for item X": merchants are
-- only readable while their window is open. So learn what is on offer each
-- time one is open, and treat that as the item's fixed vendor cost.
---------------------------------------------------------------------------

-- price is the cost of stackCount units, so a whole page gives per-unit costs.
function PW:ScanMerchant()
    if not (C_MerchantFrame and C_MerchantFrame.GetItemInfo and GetMerchantNumItems) then return end
    local learned = 0
    for index = 1, (GetMerchantNumItems() or 0) do
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
        if ok and info and info.itemID and info.price and info.price > 0 then
            local count = info.stackCount and info.stackCount > 0 and info.stackCount or 1
            local unit = info.price / count
            -- Extended cost means it's bought with currency, not gold.
            if not info.hasExtendedCost and unit >= 1 then
                local before = self:UnitPrice(info.itemID)
                self:SetPrice(info.itemID, floor(unit + 0.5), "vendor")
                if self:UnitPrice(info.itemID) ~= before then learned = learned + 1 end
            end
        end
    end
    return learned
end

---------------------------------------------------------------------------
-- Money formatting
---------------------------------------------------------------------------

local COPPER_ICON = "|cffffd700g|r"
local SILVER_ICON = "|cffc7c7cfs|r"
local COPPER_ONLY = "|cffeda55fc|r"

-- 1234567 -> "123g 45s 67c", trimmed to the two most useful parts.
function PW.Money(copper, short)
    copper = floor((copper or 0) + 0.5)
    local negative = copper < 0
    if negative then copper = -copper end
    local g = floor(copper / 10000)
    local s = floor((copper % 10000) / 100)
    local c = copper % 100
    local out
    if g > 0 then
        out = format("%d%s %02d%s", g, COPPER_ICON, s, SILVER_ICON)
        if not short and c > 0 then out = out .. format(" %02d%s", c, COPPER_ONLY) end
    elseif s > 0 then
        out = format("%d%s", s, SILVER_ICON)
        if not short and c > 0 then out = out .. format(" %02d%s", c, COPPER_ONLY) end
    else
        out = format("%d%s", c, COPPER_ONLY)
    end
    return negative and ("-" .. out) or out
end

function PW.Age(seconds)
    if not seconds then return "never" end
    if seconds < 90 then return "just now" end
    if seconds < 3600 then return format("%dm ago", floor(seconds / 60)) end
    if seconds < 86400 then return format("%dh ago", floor(seconds / 3600)) end
    return format("%dd ago", floor(seconds / 86400))
end

---------------------------------------------------------------------------
-- Craft economics
---------------------------------------------------------------------------

-- Cost of one reagent line, or nil if any part of it is unpriced.
function PW:ReagentCost(reagent, count)
    local unit = self:UnitPrice(reagent.itemID)
    if not unit then return end
    return unit * (reagent.need or 1) * (count or 1)
end

-- What one craft costs in reagents. Returns cost, complete.
-- `complete` is false when some reagent has no price, so callers can show a
-- partial figure rather than pretending the craft is free.
function PW:CraftCost(index)
    local total, complete = 0, true
    local reagents = self:GetReagents(index)
    if #reagents == 0 then return nil, false end
    for _, rg in ipairs(reagents) do
        local c = self:ReagentCost(rg, 1)
        if c then
            total = total + c
        else
            complete = false
        end
    end
    return total, complete, reagents
end

-- What the craft's output sells for on the AH, after the cut.
-- Returns value, complete.
function PW:OutputValue(index)
    local itemID = self.API and self.API.OutputItemID and self.API.OutputItemID(index)
    if not itemID then return nil, false end
    local unit = self:UnitPrice(itemID)
    if not unit then return nil, false end
    local made = self:AmountMade(index)
    return floor(unit * made * (1 - PW.AH_CUT) + 0.5), true
end

-- Profit per craft: output value minus reagent cost.
-- Returns profit, complete.
function PW:Profit(index)
    local cost, costComplete = self:CraftCost(index)
    local value, valueComplete = self:OutputValue(index)
    if not cost or not value then return nil, false end
    return value - cost, (costComplete and valueComplete)
end
