-- Profession Workbench: profession API backends.
--
-- The rest of the addon talks to ns.API, which is one of:
--   * "classic"        - GetNumTradeSkills / GetTradeSkillInfo / DoTradeSkill ...
--   * "C_TradeSkillUI" - the recipe-ID based API used by newer clients.
-- A recipe is identified by an opaque key stored in recipe.index: the list
-- index for the classic backend, the recipe ID for C_TradeSkillUI.

local ADDON, ns = ...

local floor = math.floor

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function Try(fn, ...)
    if type(fn) == "function" then
        return pcall(fn, ...)
    end
end

-- Blizzard windows we may need to hide: [frame name] = load-on-demand addon.
local BLIZZARD_FRAMES = {
    TradeSkillFrame = "Blizzard_TradeSkillUI",
    ProfessionsFrame = "Blizzard_Professions",
}

---------------------------------------------------------------------------
-- Classic backend
---------------------------------------------------------------------------

local Classic = { kind = "classic" }

function Classic.IsReady() return true end
function Classic.CanReplace() return true end

function Classic.GetLine()
    local name, rank, maxRank = GetTradeSkillLine()
    return name, rank, maxRank
end

-- Clear Blizzard's filters so the list contains every recipe.
function Classic.Prepare()
    Classic.expandTries = 0
    Try(TradeSkillOnlyShowMakeable, false)
    Try(SetTradeSkillSubClassFilter, 0, 1, 1)
    Try(SetTradeSkillInvSlotFilter, 0, 1, 1)
    Try(SetTradeSkillItemNameFilter, "")
    Try(ExpandTradeSkillSubClass, 0)
end

function Classic.Scan()
    local recipes = {}
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
            end
        end
    end

    -- Make sure every category is expanded so we see every recipe.
    if collapsedFound and (Classic.expandTries or 0) < 3 then
        Classic.expandTries = (Classic.expandTries or 0) + 1
        Try(ExpandTradeSkillSubClass, 0)
    end

    return recipes
end

function Classic.GetReagents(index)
    local list = {}
    for j = 1, (GetTradeSkillNumReagents(index) or 0) do
        local name, texture, need, bags = GetTradeSkillReagentInfo(index, j)
        local link = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(index, j)
        list[j] = {
            name = name,
            icon = texture,
            need = need or 1,
            bags = bags or 0,
            link = link,
            itemID = ItemIDFromLink(link),
        }
    end
    return list
end

-- GetTradeSkillInfo already reports the craftable count on this backend, so
-- there is nothing extra to ask for.
function Classic.CraftableCount() return nil end

function Classic.NumMade(index)
    return GetTradeSkillNumMade(index)
end

-- Item ID of what the recipe makes, for pricing. "item:12345:" -> 12345.
function Classic.OutputItemID(index)
    return ItemIDFromLink(GetTradeSkillItemLink and GetTradeSkillItemLink(index))
end

function Classic.Craft(index, count)
    DoTradeSkill(index, count)
end

function Classic.Select(index)
    Try(SelectTradeSkill, index)
end

function Classic.ItemLink(index)
    return GetTradeSkillItemLink(index)
end

function Classic.RecipeLink(index)
    return (GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index)) or GetTradeSkillItemLink(index)
end

function Classic.SetResultTooltip(tt, index)
    tt:SetTradeSkillItem(index)
end

function Classic.SetReagentTooltip(tt, index, reagentIndex)
    tt:SetTradeSkillItem(index, reagentIndex)
end

function Classic.Close()
    Try(CloseTradeSkill)
end

-- The classic API has no way to aim an enchant at an item from an addon.
function Classic.SupportsEnchantTarget() return false end
function Classic.IsValidEnchantTarget() return false end
function Classic.EnchantTargets() return {} end
function Classic.CraftEnchant() end

---------------------------------------------------------------------------
-- C_TradeSkillUI backend
---------------------------------------------------------------------------

local T = C_TradeSkillUI
local Modern = { kind = "C_TradeSkillUI" }

local function Pass(ok, ...)
    if ok then return ... end
end

-- Safe call into C_TradeSkillUI: nil if the function is missing or errors.
local function S(fname, ...)
    local f = T and T[fname]
    if type(f) == "function" then
        return Pass(pcall(f, ...))
    end
end

-- Some functions return a table, older ones return varargs.
local function List(...)
    local first = ...
    if type(first) == "table" then return first end
    return { ... }
end

local GetItemInfoF = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemIconF = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local GetItemCountF = (C_Item and C_Item.GetItemCount) or GetItemCount

local DIFF_ORDER = { optimal = 1, medium = 2, easy = 3, trivial = 4 }

local DIFF_BY_ENUM = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
do
    local e = Enum and Enum.TradeskillRelativeDifficulty
    if e and e.Optimal then
        DIFF_BY_ENUM = {
            [e.Optimal] = "optimal",
            [e.Medium] = "medium",
            [e.Easy] = "easy",
            [e.Trivial] = "trivial",
        }
    end
end

local BASIC_REAGENT = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1

-- A recipe's schematic is static, and the reagent list, the amount made and the
-- recipe type all need it, so fetch each one once instead of three times.
local schemCache = {}
local function Schematic(id)
    if id == nil then return end
    local s = schemCache[id]
    if s == nil then
        s = T.GetRecipeSchematic and S("GetRecipeSchematic", id, false)
        -- Only cache a real answer: nil can just mean "not loaded yet".
        if s then schemCache[id] = s end
    end
    return s or nil
end

-- The open profession's skill line, used to scope GetAllRecipeIDs. Recipes of
-- an expansion's tier are checked against that tier's line as well.
local function SkillLines()
    local lines = {}
    local base = S("GetBaseProfessionInfo")
    if base and base.professionID then lines[#lines + 1] = base.professionID end
    local child = S("GetChildProfessionInfo")
    if child and (child.maxSkillLevel or 0) > 0 and child.professionID then
        lines[#lines + 1] = child.professionID
    end
    return lines
end

local function InAnySkillLine(id, lines)
    -- Without the check function, filtering would hide every recipe.
    if #lines == 0 or type(T.IsRecipeInSkillLine) ~= "function" then return true end
    for _, line in ipairs(lines) do
        if S("IsRecipeInSkillLine", id, line) then return true end
    end
    return false
end

local function Difficulty(info)
    if type(info.difficulty) == "string" then return info.difficulty end
    if type(info.relativeDifficulty) == "number" then
        return DIFF_BY_ENUM[info.relativeDifficulty] or "trivial"
    end
    return "trivial"
end

function Modern.IsReady()
    return S("IsTradeSkillReady") ~= false
end

-- Leave linked, guild and NPC crafting windows to Blizzard.
function Modern.CanReplace()
    return not (S("IsTradeSkillLinked") or S("IsTradeSkillGuild")
        or S("IsNPCCrafting") or S("IsRuneforging"))
end

function Modern.GetLine()
    local name, rank, maxRank
    local base = S("GetBaseProfessionInfo")
    if base then
        name, rank, maxRank = base.professionName, base.skillLevel, base.maxSkillLevel
    end
    -- A child profession (an expansion's skill line) is only worth using when
    -- it really reports both a name and a skill, which this client doesn't
    -- always do.
    local child = S("GetChildProfessionInfo")
    if child and (child.maxSkillLevel or 0) > 0 and (child.skillLevel or 0) > 0
        and child.professionName and child.professionName ~= "" then
        name, rank, maxRank = child.professionName, child.skillLevel, child.maxSkillLevel
    end
    if (not name or name == "") and type(T.GetTradeSkillLine) == "function" then
        local n, r, m = S("GetTradeSkillLine")
        name, rank, maxRank = n, r, m
    end
    if name == "" then name = nil end
    return name, rank, maxRank
end

-- GetAllRecipeIDs ignores Blizzard's search/filters, so nothing to reset.
function Modern.Prepare() end

local catCache = {}
local function CategoryName(id)
    if not id then return end
    local c = catCache[id]
    if c == nil then
        c = S("GetCategoryInfo", id)
        if c then catCache[id] = c end -- nil may just mean "not loaded yet"
    end
    return c and c.name or nil
end

-- Position of every category in Blizzard's own ordering.
local function CategoryOrder()
    local order, n = {}, 0
    local function Add(id, depth)
        if not id or order[id] or depth > 4 then return end
        n = n + 1
        order[id] = n
        if T.GetSubCategories then
            for _, sub in ipairs(List(S("GetSubCategories", id))) do Add(sub, depth + 1) end
        end
    end
    if T.GetCategories then
        for _, id in ipairs(List(S("GetCategories"))) do Add(id, 0) end
    end
    return order
end

function Modern.Scan()
    local recipes = {}
    if not Modern.IsReady() then return recipes end

    local now = GetTime()
    local order = CategoryOrder()
    local lines = SkillLines()

    for _, id in ipairs(List(S("GetAllRecipeIDs"))) do
        local info = S("GetRecipeInfo", id)
        local keep = info and info.name and info.learned ~= false
            and not info.isDummyRecipe and not info.isRecraft and not info.isGatheringRecipe
        -- GetAllRecipeIDs is undocumented, so keep only the open profession's
        -- recipes, the way Blizzard's own recipe list does.
        if keep then
            keep = InAnySkillLine(id, lines)
        end
        -- Ranked recipes: only show the highest rank learned.
        if keep and info.nextRecipeID then
            local nextInfo = S("GetRecipeInfo", info.nextRecipeID)
            if nextInfo and nextInfo.learned then keep = false end
        end
        if keep then
            local r = {
                index = id,
                name = info.name,
                difficulty = Difficulty(info),
                icon = info.icon,
                categoryID = info.categoryID,
                header = CategoryName(info.categoryID),
            }
            local cd, _, charges, maxCharges = S("GetRecipeCooldown", id)
            local hasCharge = maxCharges and maxCharges > 0 and charges and charges > 0
            if cd and cd > 0 and not hasCharge then
                r.cooldownEnds = now + cd
                r.cooldown = cd
            end
            recipes[#recipes + 1] = r
        end
    end

    local huge = math.huge
    table.sort(recipes, function(a, b)
        local oa, ob = order[a.categoryID] or huge, order[b.categoryID] or huge
        if oa ~= ob then return oa < ob end
        local ha, hb = a.header or "", b.header or ""
        if ha ~= hb then return ha < hb end
        local da, db = DIFF_ORDER[a.difficulty] or 5, DIFF_ORDER[b.difficulty] or 5
        if da ~= db then return da < db end
        return a.name < b.name
    end)

    return recipes
end

local function ItemReagent(itemID, need, bags)
    local name, link = GetItemInfoF(itemID)
    return {
        name = name,
        icon = GetItemIconF and GetItemIconF(itemID),
        need = need or 1,
        bags = bags or 0,
        link = link,
        itemID = itemID,
    }
end

function Modern.GetReagents(id)
    local list = {}
    local s = Schematic(id)
    if s then
        for _, slot in ipairs(s.reagentSlotSchematics or {}) do
            local basic
            if slot.reagentType ~= nil then
                basic = slot.reagentType == BASIC_REAGENT
            else
                basic = slot.required
            end
            local first = basic and slot.reagents and slot.reagents[1]
            if first and first.itemID then
                -- Reagents with several qualities: count all of them.
                local bags = 0
                for _, rg in ipairs(slot.reagents) do
                    if rg.itemID and GetItemCountF then
                        bags = bags + (GetItemCountF(rg.itemID) or 0)
                    end
                end
                -- Variable-quantity slots change what one craft needs.
                local need = slot.quantityRequired
                for _, vq in ipairs(slot.variableQuantities or {}) do
                    if vq.reagent and vq.reagent.itemID == first.itemID then
                        need = vq.quantity
                        break
                    end
                end
                list[#list + 1] = ItemReagent(first.itemID, need, bags)
            end
        end
    elseif T.GetRecipeNumReagents then
        for j = 1, (S("GetRecipeNumReagents", id) or 0) do
            local name, icon, need, have = S("GetRecipeReagentInfo", id, j)
            local link = S("GetRecipeReagentItemLink", id, j)
            list[#list + 1] = {
                name = name,
                icon = icon,
                need = need or 1,
                bags = have or 0,
                link = link,
                itemID = ItemIDFromLink(link),
            }
        end
    end
    return list
end

function Modern.CraftableCount(id)
    return S("GetCraftableCount", id)
end

function Modern.NumMade(id)
    local s = Schematic(id)
    if s then return s.quantityMin, s.quantityMax end
    return S("GetRecipeNumItemsProduced", id)
end

-- Item ID of what the recipe makes. Read from the schematic first because the
-- output data call needs a reagent table to take qualities into account.
function Modern.OutputItemID(id)
    local s = Schematic(id)
    if s and s.outputItemID then return s.outputItemID end
    local out = S("GetRecipeOutputItemData", id)
    if out then return out.itemID end
end

function Modern.Craft(id, count)
    T.CraftRecipe(id, count)
end

function Modern.Select() end

function Modern.ItemLink(id)
    local link = S("GetRecipeItemLink", id)
    if link then return link end
    local out = S("GetRecipeOutputItemData", id)
    if out then
        if out.hyperlink then return out.hyperlink end
        if out.itemID then
            local _, l = GetItemInfoF(out.itemID)
            if l then return l end
        end
    end
    return S("GetRecipeLink", id)
end

function Modern.RecipeLink(id)
    return S("GetRecipeLink", id) or Modern.ItemLink(id)
end

function Modern.SetResultTooltip(tt, id)
    if tt.SetRecipeResultItem and pcall(tt.SetRecipeResultItem, tt, id) and tt:NumLines() > 0 then
        return
    end
    local link = Modern.ItemLink(id)
    if link then
        tt:SetHyperlink(link)
    elseif tt.SetSpellByID then
        tt:SetSpellByID(id)
    end
end

function Modern.SetReagentTooltip(tt, id, reagentIndex, reagent)
    if reagent and reagent.link then
        tt:SetHyperlink(reagent.link)
    elseif reagent and reagent.itemID and tt.SetItemByID then
        tt:SetItemByID(reagent.itemID)
    end
end

function Modern.Close()
    S("CloseTradeSkill")
end

---------------------------------------------------------------------------
-- Enchanting gear directly (C_TradeSkillUI.CraftEnchant + an ItemLocation)
---------------------------------------------------------------------------

local ENCHANT_TYPE = Enum and Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Enchant

local canTarget = T and type(T.CraftEnchant) == "function"
    and ItemLocation and ItemLocation.CreateFromEquipmentSlot
    and C_Item and C_Item.DoesItemExist and C_Item.GetItemLink

-- Recipe is an enchant that goes on an item (not one that makes an item).
function Modern.SupportsEnchantTarget(r)
    if not canTarget or not r then return false end
    if r.isEnchant == nil then
        -- isEnchantingRecipe marks every recipe of the Enchanting profession,
        -- runed rods and oils included. Only an Enchant-type schematic is
        -- applied to an item, so that is the test.
        local s = Schematic(r.index)
        r.isEnchant = (s and ENCHANT_TYPE and s.recipeType == ENCHANT_TYPE) or false
    end
    return r.isEnchant and true or false
end

-- Valid targets as item GUIDs, or nil if the client can't tell us.
local function EnchantGUIDs(id)
    if not T.GetEnchantItems then return end
    local guids = S("GetEnchantItems", id)
    return type(guids) == "table" and guids or nil
end

local function GUIDOf(loc)
    if not (C_Item.GetItemGUID and loc and C_Item.DoesItemExist(loc)) then return end
    return C_Item.GetItemGUID(loc)
end

function Modern.IsValidEnchantTarget(id, loc)
    if not (loc and C_Item.DoesItemExist(loc)) then return false end
    local guids = EnchantGUIDs(id)
    if not guids then return true end -- let the server decide
    local guid = GUIDOf(loc)
    if not guid then return true end -- can't compare, so let the server decide
    for _, g in ipairs(guids) do
        if g == guid then return true end
    end
    return false
end

local function TargetEntry(loc)
    if not (loc and C_Item.DoesItemExist(loc)) then return end
    return {
        location = loc,
        link = C_Item.GetItemLink(loc),
        icon = C_Item.GetItemIcon and C_Item.GetItemIcon(loc),
        equipped = loc.IsEquipmentSlot and loc:IsEquipmentSlot() or false,
    }
end

-- Items that can receive the enchant: equipped gear first, then bags.
function Modern.EnchantTargets(id)
    local list = {}
    local guids = EnchantGUIDs(id)
    if guids and C_Item.GetItemLocation then
        for _, guid in ipairs(guids) do
            local ok, loc = pcall(C_Item.GetItemLocation, guid)
            local e = ok and TargetEntry(loc)
            if e then list[#list + 1] = e end
        end
        table.sort(list, function(a, b)
            if a.equipped ~= b.equipped then return a.equipped end
            return (a.link or "") < (b.link or "")
        end)
    else
        -- No list from the client: offer equipped gear (not shirt/tabard).
        for slot = 1, 19 do
            if slot ~= 4 and slot ~= 19 then
                local e = TargetEntry(ItemLocation:CreateFromEquipmentSlot(slot))
                if e then list[#list + 1] = e end
            end
        end
    end
    return list
end

function Modern.CraftEnchant(id, loc)
    T.CraftEnchant(id, 1, {}, loc)
end

---------------------------------------------------------------------------
-- Pick a backend
---------------------------------------------------------------------------

local hasClassic = type(GetNumTradeSkills) == "function"
    and type(GetTradeSkillInfo) == "function"
    and type(GetTradeSkillReagentInfo) == "function"

local hasModern = T and type(T.GetAllRecipeIDs) == "function"
    and type(T.GetRecipeInfo) == "function"
    and type(T.CraftRecipe) == "function"

local API
if hasClassic then
    API = Classic
elseif hasModern then
    API = Modern
end

if API then
    API.blizzardFrames = BLIZZARD_FRAMES
    API.ItemIDFromLink = ItemIDFromLink
end
ns.API = API
ns.BLIZZARD_FRAMES = BLIZZARD_FRAMES

-- Names checked by /pwb debug.
ns.MODERN_FUNCS = {
    "GetAllRecipeIDs", "GetRecipeInfo", "CraftRecipe", "GetRecipeSchematic",
    "GetCraftableCount", "IsRecipeInSkillLine", "GetBaseProfessionInfo",
    "GetRecipeNumReagents", "GetRecipeReagentInfo", "GetCategories", "GetCategoryInfo",
    "GetRecipeCooldown", "GetChildProfessionInfo",
    "GetTradeSkillLine", "GetRecipeOutputItemData", "GetRecipeItemLink",
    "GetRecipeLink", "IsTradeSkillReady", "CloseTradeSkill",
}
