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

function Classic.NumMade(index)
    return GetTradeSkillNumMade(index)
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
    if T.GetBaseProfessionInfo then
        local base = S("GetBaseProfessionInfo")
        if base then
            name, rank, maxRank = base.professionName, base.skillLevel, base.maxSkillLevel
        end
        local child = S("GetChildProfessionInfo")
        if child and (child.maxSkillLevel or 0) > 0 then
            rank, maxRank = child.skillLevel, child.maxSkillLevel
            name = name or child.parentProfessionName or child.professionName
        end
    end
    if (not name or name == "") and T.GetTradeSkillLine then
        local _, n, r, m = S("GetTradeSkillLine")
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
        c = S("GetCategoryInfo", id) or false
        catCache[id] = c
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

    for _, id in ipairs(List(S("GetAllRecipeIDs"))) do
        local info = S("GetRecipeInfo", id)
        local keep = info and info.name and info.learned ~= false
            and not info.isDummyRecipe and not info.isRecraft and not info.isGatheringRecipe
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
                numAvailable = info.numAvailable or 0,
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
    if T.GetRecipeSchematic then
        local s = S("GetRecipeSchematic", id, false)
        for _, slot in ipairs(s and s.reagentSlotSchematics or {}) do
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
                    if rg.itemID then bags = bags + (GetItemCountF(rg.itemID) or 0) end
                end
                list[#list + 1] = ItemReagent(first.itemID, slot.quantityRequired, bags)
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

function Modern.NumMade(id)
    if T.GetRecipeSchematic then
        local s = S("GetRecipeSchematic", id, false)
        if s then return s.quantityMin, s.quantityMax end
    end
    return S("GetRecipeNumItemsProduced", id)
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
    "GetRecipeNumReagents", "GetRecipeReagentInfo", "GetCategories", "GetCategoryInfo",
    "GetRecipeCooldown", "GetBaseProfessionInfo", "GetChildProfessionInfo",
    "GetTradeSkillLine", "GetRecipeOutputItemData", "GetRecipeItemLink",
    "GetRecipeLink", "IsTradeSkillReady", "CloseTradeSkill",
}
