-- Profession Workbench: disenchant value, and which of vendor / auction /
-- disenchant pays best for an item.
--
-- The client has no disenchant API at all: the server rolls the loot, and
-- nothing in the addon API exposes the table. So this is seeded from the WoW
-- Forever disenchanting guide, resolved by item level. Every number here is an
-- average, and a single disenchant can come out better or worse.
--
-- Item IDs and the level bands are Forever's; a wrong ID here would quietly
-- produce wrong gold figures, so they are all named below.

local ADDON, ns = ...
local PW = assert(ns.PW, "Profession WorkBench: Disenchant.lua must load after Core.lua")

local floor, max, format = math.floor, math.max, string.format

---------------------------------------------------------------------------
-- Materials
---------------------------------------------------------------------------

local DUST_STRANGE, DUST_SOUL, DUST_VISION, DUST_DREAM, DUST_ILLUSION = 10940, 11083, 11137, 11176, 16204
local ESS_MAGIC_LESSER, ESS_MAGIC_GREATER = 10938, 10939
local ESS_ASTRAL_LESSER, ESS_ASTRAL_GREATER = 10998, 11082
local ESS_MYSTIC_LESSER, ESS_MYSTIC_GREATER = 11134, 11135
local ESS_NETHER_LESSER, ESS_NETHER_GREATER = 11174, 11175
local ESS_ETERNAL_LESSER, ESS_ETERNAL_GREATER = 16202, 16203
local SHARD_GLIMMER_SMALL, SHARD_GLIMMER_LARGE = 10978, 11084
local SHARD_GLOW_SMALL, SHARD_GLOW_LARGE = 11138, 11139
local SHARD_RADIANT_SMALL, SHARD_RADIANT_LARGE = 11177, 11178
local SHARD_BRILLIANT_SMALL, SHARD_BRILLIANT_LARGE = 14343, 14344
local NEXUS_CRYSTAL = 20725

-- Level bands are by ITEM level: the game sorts that way, and the required
-- level on the tooltip sits about five levels lower.
--   maxIlvl, dust, avgDust, essence, avgEssence, shard
local ROWS = {
    { maxIlvl = 15,  dust = DUST_STRANGE,   dustN = 1.5, ess = ESS_MAGIC_LESSER,   essN = 1.5 },
    { maxIlvl = 20,  dust = DUST_STRANGE,   dustN = 2.5, ess = ESS_MAGIC_GREATER,  essN = 1.5, shard = SHARD_GLIMMER_SMALL },
    { maxIlvl = 25,  dust = DUST_STRANGE,   dustN = 5.0, ess = ESS_ASTRAL_LESSER,  essN = 1.5, shard = SHARD_GLIMMER_SMALL },
    { maxIlvl = 30,  dust = DUST_SOUL,      dustN = 1.5, ess = ESS_ASTRAL_GREATER, essN = 1.5, shard = SHARD_GLIMMER_LARGE },
    { maxIlvl = 35,  dust = DUST_SOUL,      dustN = 3.5, ess = ESS_MYSTIC_LESSER,  essN = 1.5, shard = SHARD_GLOW_SMALL },
    { maxIlvl = 40,  dust = DUST_VISION,    dustN = 1.5, ess = ESS_MYSTIC_GREATER, essN = 1.5, shard = SHARD_GLOW_LARGE },
    { maxIlvl = 45,  dust = DUST_VISION,    dustN = 3.5, ess = ESS_NETHER_LESSER,  essN = 1.5, shard = SHARD_RADIANT_SMALL },
    { maxIlvl = 50,  dust = DUST_DREAM,     dustN = 1.5, ess = ESS_NETHER_GREATER, essN = 1.5, shard = SHARD_RADIANT_LARGE },
    { maxIlvl = 55,  dust = DUST_DREAM,     dustN = 3.5, ess = ESS_ETERNAL_LESSER, essN = 1.5, shard = SHARD_BRILLIANT_SMALL },
    { maxIlvl = 60,  dust = DUST_ILLUSION,  dustN = 1.5, ess = ESS_ETERNAL_GREATER, essN = 1.5, shard = SHARD_BRILLIANT_LARGE },
    { maxIlvl = 1e9, dust = DUST_ILLUSION,  dustN = 3.5, ess = ESS_ETERNAL_GREATER, essN = 2.0, shard = SHARD_BRILLIANT_LARGE },
}

-- Odds by quality and kind. Green armor is mostly dust, green weapons mostly
-- essence; both drop a shard now and then.
local GREEN_ARMOR  = { dust = 0.75, ess = 0.20, shard = 0.05 }
local GREEN_WEAPON = { dust = 0.20, ess = 0.75, shard = 0.05 }

local QUALITY_UNCOMMON, QUALITY_RARE, QUALITY_EPIC = 2, 3, 4
local CLASS_WEAPON, CLASS_ARMOR = 2, 4

-- Enough to keep every consumer off a nil.
PW.DE_MATERIALS = {
    DUST_STRANGE, DUST_SOUL, DUST_VISION, DUST_DREAM, DUST_ILLUSION,
    ESS_MAGIC_LESSER, ESS_MAGIC_GREATER, ESS_ASTRAL_LESSER, ESS_ASTRAL_GREATER,
    ESS_MYSTIC_LESSER, ESS_MYSTIC_GREATER, ESS_NETHER_LESSER, ESS_NETHER_GREATER,
    ESS_ETERNAL_LESSER, ESS_ETERNAL_GREATER,
    SHARD_GLIMMER_SMALL, SHARD_GLIMMER_LARGE, SHARD_GLOW_SMALL, SHARD_GLOW_LARGE,
    SHARD_RADIANT_SMALL, SHARD_RADIANT_LARGE, SHARD_BRILLIANT_SMALL, SHARD_BRILLIANT_LARGE,
    NEXUS_CRYSTAL,
}

---------------------------------------------------------------------------
-- What an item gives
---------------------------------------------------------------------------

local function RowFor(itemLevel)
    if not itemLevel or itemLevel <= 0 then return end
    for _, row in ipairs(ROWS) do
        if itemLevel <= row.maxIlvl then return row end
    end
end

-- Item details we need, or nil when the client hasn't cached the item yet.
function PW:ItemFacts(itemID)
    if not itemID then return end
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not get then return end
    local ok, name, _, quality, itemLevel, _, _, _, _, _, _, classID = pcall(get, itemID)
    if not ok or not name then return end
    return { name = name, quality = quality, itemLevel = itemLevel, classID = classID }
end

-- Expected materials for one disenchant, as a list of { itemID, count }.
-- Returns nil when the item cannot be disenchanted.
function PW:DisenchantLoot(itemID)
    local f = self:ItemFacts(itemID)
    if not f then return end
    -- Only green, blue and purple weapons and armor disenchant.
    if f.classID ~= CLASS_WEAPON and f.classID ~= CLASS_ARMOR then return end
    local q = f.quality
    if q ~= QUALITY_UNCOMMON and q ~= QUALITY_RARE and q ~= QUALITY_EPIC then return end
    local row = RowFor(f.itemLevel)
    if not row then return end

    local loot = {}
    if q == QUALITY_UNCOMMON then
        local odds = (f.classID == CLASS_WEAPON) and GREEN_WEAPON or GREEN_ARMOR
        if row.dust and odds.dust > 0 then
            loot[#loot + 1] = { itemID = row.dust, count = row.dustN * odds.dust }
        end
        if row.ess and odds.ess > 0 then
            loot[#loot + 1] = { itemID = row.ess, count = row.essN * odds.ess }
        end
        if row.shard and odds.shard > 0 then
            loot[#loot + 1] = { itemID = row.shard, count = odds.shard }
        end
    elseif q == QUALITY_RARE then
        -- Always one shard of the row.
        if row.shard then loot[#loot + 1] = { itemID = row.shard, count = 1 } end
    else
        -- Epic: shards up to required level 50, a crystal above it. The guide
        -- gives no count, so this is a floor of one.
        if (f.itemLevel or 0) > 55 then
            loot[#loot + 1] = { itemID = NEXUS_CRYSTAL, count = 1 }
        elseif row.shard then
            loot[#loot + 1] = { itemID = row.shard, count = 1 }
        end
    end
    if #loot == 0 then return end
    return loot, f
end

-- Copper value of the materials, or nil when any of them is unpriced.
-- `input` true means the materials are for your own Enchanting, so the auction
-- house cut does not apply.
function PW:DisenchantValue(itemID, input)
    local loot = self:DisenchantLoot(itemID)
    if not loot then return end
    local total, complete = 0, true
    for _, part in ipairs(loot) do
        local unit = self:UnitPrice(part.itemID)
        if unit then
            total = total + unit * part.count
        else
            complete = false
        end
    end
    if total == 0 and not complete then return end
    if not input then total = total * (1 - PW.AH_CUT) end
    return total, complete, loot
end

---------------------------------------------------------------------------
-- Vendor / auction / disenchant
---------------------------------------------------------------------------

-- What a vendor pays for the item.
function PW:VendorValue(itemID)
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not get or not itemID then return end
    local ok, _, _, _, _, _, _, _, _, _, sellPrice = pcall(get, itemID)
    if ok and sellPrice and sellPrice > 0 then return sellPrice end
end

-- Compare the three ways to get rid of one item.
-- Returns a table with each value that is known, plus the best one.
function PW:Disposition(itemID)
    local vendor = self:VendorValue(itemID)
    local ahUnit = self:UnitPrice(itemID)
    local ah = ahUnit and (ahUnit * (1 - PW.AH_CUT))
    local de, deComplete, loot = self:DisenchantValue(itemID, false)

    local best, bestValue
    local function Consider(kind, value)
        if value and (not bestValue or value > bestValue) then
            best, bestValue = kind, value
        end
    end
    Consider("vendor", vendor)
    Consider("auction", ah)
    Consider("disenchant", de)

    return {
        itemID = itemID,
        vendor = vendor,
        auction = ah,
        auctionUnit = ahUnit,
        disenchant = de,
        disenchantComplete = deComplete,
        loot = loot,
        best = best,
        bestValue = bestValue,
    }
end

-- One-line summary for chat and tooltips.
function PW:DispositionText(itemID)
    local d = self:Disposition(itemID)
    if not d then return "No information for that item." end

    local parts = {}
    if d.vendor then parts[#parts + 1] = "vendor " .. PW.Money(d.vendor, true) end
    if d.auction then parts[#parts + 1] = "auction " .. PW.Money(d.auction, true) end
    if d.disenchant then
        parts[#parts + 1] = "disenchant " .. PW.Money(d.disenchant, true)
            .. (d.disenchantComplete and "" or "+")
    end
    if #parts == 0 then return "No prices for that item yet." end

    local text = table.concat(parts, ", ")
    local label = ({ vendor = "sell to a vendor", auction = "sell on the auction house",
                     disenchant = "disenchant" })[d.best]
    if label then text = text .. "  |cff66ff66best: " .. label .. "|r" end
    return text
end

-- What the materials are, for a tooltip line: "2x Strange Dust, 1x Lesser Magic Essence".
function PW:LootText(itemID)
    local loot = self:DisenchantLoot(itemID)
    if not loot then return end
    local parts = {}
    for _, part in ipairs(loot) do
        local name = self:ItemName(part.itemID) or ("item " .. part.itemID)
        parts[#parts + 1] = format("%s x%.1f", name, part.count)
    end
    return table.concat(parts, ", ")
end

function PW:ItemName(itemID)
    local f = self:ItemFacts(itemID)
    return f and f.name
end
