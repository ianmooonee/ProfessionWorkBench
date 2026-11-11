-- Profession WorkBench: prices on item tooltips.
--
-- Everything the addon knows about an item's value is easier to read where you
-- are already looking, so the price block is added to every item tooltip that
-- has anything to say, followed by which recipes use it and what makes it.

local ADDON, ns = ...
local PW = assert(ns.PW, "Profession WorkBench: Tooltip.lua must load after Core.lua")

local format = string.format

local ITEM_TYPE = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item

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
    if vendor and vendor > 0 then
        AddLine(tt, "Vendor", PW.Money(vendor, true))
        any = true
    end

    -- Only label a price "Auction" when it really came from the auction house;
    -- a vendor-learned price is already shown above and must not appear twice.
    local entry = self:PriceEntry(itemID)
    if entry and entry.unit and entry.source ~= "vendor" then
        local stale = self:IsStale(itemID)
        local text = PW.Money(entry.unit, true)
        if stale then
            text = text .. format(" |cff9a9aa0(%s)|r", PW.Age(self:PriceAge(itemID)))
        end
        local label = entry.source == "manual" and "Price" or "Auction"
        AddLine(tt, label, text, stale and { 0.7, 0.7, 0.7 } or nil)
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

    return any
end

-- Which recipes use the item, and which recipe makes it.
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
    -- Cached because this now runs on every item tooltip. Each scan (which
    -- happens whenever a profession opens) clears the cache, so an answer
    -- taken while the profession was closed doesn't outlive the next open.
    self.usesIndex[itemID] = list
    return list
end

function PW:RecipeMaking(itemID)
    return self:FindRecipeByOutput(itemID)
end

-- Called after each scan, since recipes and profits change.
function PW:InvalidateItemIndexes()
    self.usesIndex = nil
end

---------------------------------------------------------------------------
-- Hook
---------------------------------------------------------------------------

local hooked = false

local function Decorate(tt, itemID)
    if not itemID then return end
    -- Always show whatever is known: prices first, then the recipe detail.
    local prices = PW:AddPriceLines(tt, itemID)
    local detail = PW:AddDetailLines(tt, itemID)
    if prices or detail then
        -- Name the addon once, at the end, so the block isn't mistaken for game text.
        tt:AddLine(" ")
        tt:AddLine("|cff5a9bffProfession Workbench|r", 1, 1, 1, true)
    end
end

function PW:InstallTooltipHook()
    if hooked then return end
    hooked = true

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and ITEM_TYPE then
        TooltipDataProcessor.AddTooltipPostCall(ITEM_TYPE, function(tt, data)
            Decorate(tt, data and (data.id or (data.item and data.item.itemID)))
        end)
        return
    end

    -- Older tooltip system: hook each item tooltip directly.
    local function OnSetItem(tt)
        local _, link = tt:GetItem()
        Decorate(tt, PW.ItemIDFromLink(link))
    end
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tt and tt.HookScript and tt:HasScript("OnTooltipSetItem") then
            tt:HookScript("OnTooltipSetItem", OnSetItem)
        end
    end
end
