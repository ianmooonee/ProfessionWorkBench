-- Profession WorkBench: prices on item tooltips.
--
-- Everything the addon knows about an item's value is easier to read where you
-- are already looking. Items your professions care about get the price block
-- automatically; anything else only when a modifier is held, so ordinary
-- world drops stay clean.

local ADDON, ns = ...
local PW = assert(ns.PW, "Profession WorkBench: Tooltip.lua must load after Core.lua")

local format = string.format

local ITEM_TYPE = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item

-- Items the professions use: reagents of known recipes, their outputs, and the
-- disenchant materials. Shared with the scan so "what I price" is one set.
local interesting

function PW:RefreshInterestingItems()
    local _, set = self:ScanTargets()
    interesting = set
end

function PW:IsInterestingItem(itemID)
    if not itemID then return false end
    if not interesting then self:RefreshInterestingItems() end
    return interesting and interesting[itemID] or false
end

---------------------------------------------------------------------------
-- The block itself
---------------------------------------------------------------------------

local function AddLine(tt, label, value, color)
    if not value then return end
    if color then
        tt:AddDoubleLine(label, value, 0.6, 0.6, 0.62, color[1], color[2], color[3])
    else
        tt:AddDoubleLine(label, value, 0.6, 0.6, 0.62, 0.9, 0.9, 0.9)
    end
end

-- Returns true if anything was added.
function PW:AddPriceLines(tt, itemID)
    local any = false

    -- What a vendor pays is exact and needs no scan, so it is always worth it.
    local vendor = self:VendorValue(itemID)
    if vendor then
        AddLine(tt, "Vendor", PW.Money(vendor, true))
        any = true
    end

    local unit = self:UnitPrice(itemID)
    if unit then
        local stale = self:IsStale(itemID)
        local text = PW.Money(unit, true)
        if stale then
            text = text .. format(" |cff9a9aa0(%s)|r", PW.Age(self:PriceAge(itemID)))
        end
        AddLine(tt, "Auction", text, stale and { 0.7, 0.7, 0.7 } or nil)
        any = true
    end

    -- What it turns into, which matters most for the tailoring/enchanting loop.
    local deValue, deComplete, loot = self:DisenchantValue(itemID, false)
    if deValue then
        AddLine(tt, "Disenchant", PW.Money(deValue, true) .. (deComplete and "" or "+"),
            { 0.4, 0.9, 0.45 })
        any = true
        local lootText = self:LootText(itemID)
        if lootText then
            tt:AddLine("  |cff9a9aa0" .. lootText .. "|r", 1, 1, 1, true)
        end
    end

    if any then
        -- Name the addon so the block is not mistaken for game text.
        tt:AddLine(" ")
        tt:AddLine("|cff5a9bffProfession Workbench|r", 1, 1, 1, true)
    end
    return any
end

-- The disenchant/craft detail shown when a modifier is held.
function PW:AddDetailLines(tt, itemID)
    local any = false
    local craftable = self:RecipesUsing(itemID)
    if craftable and #craftable > 0 then
        tt:AddLine(format("Used by %d recipe%s", #craftable, #craftable == 1 and "" or "s"),
            0.7, 0.7, 0.7)
        -- The most profitable few, so the list stays short.
        local shown = 0
        for _, r in ipairs(craftable) do
            if r.profit and shown < 3 then
                shown = shown + 1
                local col = r.profit >= 0 and "|cff66e673" or "|cffff6666"
                tt:AddLine(format("  %s  %s%s|r", r.name, col, PW.Money(r.profit, true)),
                    1, 1, 1, true)
            end
        end
        any = true
    end

    local madeBy = self:RecipeMaking(itemID)
    if madeBy then
        local cost = self:CraftCost(madeBy.index)
        if cost then
            tt:AddLine(format("Made by %s, cost %s", madeBy.name, PW.Money(cost, true)),
                0.7, 0.7, 0.7)
            any = true
        end
    end
    return any
end

---------------------------------------------------------------------------
-- Recipe lookups, by item
---------------------------------------------------------------------------

function PW:RecipesUsing(itemID)
    if not itemID then return end
    self.usesIndex = self.usesIndex or {}
    local cached = self.usesIndex[itemID]
    if cached then return cached end
    local list = {}
    for _, r in ipairs(self.recipes or {}) do
        for _, rg in ipairs(self:GetReagents(r.index)) do
            local id = rg.itemID or PW.ItemIDFromLink(rg.link)
            if id == itemID then
                list[#list + 1] = r
                break
            end
        end
    end
    table.sort(list, function(a, b)
        local pa, pb = a.profit or -math.huge, b.profit or -math.huge
        if pa ~= pb then return pa > pb end
        return a.name < b.name
    end)
    self.usesIndex[itemID] = list
    return list
end

function PW:RecipeMaking(itemID)
    return self:FindRecipeByOutput(itemID)
end

-- Called after each scan, since recipes and profits change.
function PW:InvalidateItemIndexes()
    self.usesIndex = nil
    interesting = nil
end

---------------------------------------------------------------------------
-- Hook
---------------------------------------------------------------------------

local hooked = false

function PW:InstallTooltipHook()
    if hooked or not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and ITEM_TYPE) then
        return
    end
    hooked = true
    TooltipDataProcessor.AddTooltipPostCall(ITEM_TYPE, function(tt, data)
        local itemID = data and (data.id or (data.item and data.item.itemID))
        if not itemID then return end
        -- Only price things once there is something to say.
        local known = PW:IsInterestingItem(itemID) or PW:UnitPrice(itemID) or PW:VendorValue(itemID)
        if not known then return end

        local modifier = IsModifiedClick and IsModifiedClick("ALT")
        local interestingItem = PW:IsInterestingItem(itemID)
        if not interestingItem and not modifier then return end

        PW:AddPriceLines(tt, itemID)
        if modifier then PW:AddDetailLines(tt, itemID) end
    end)
end
