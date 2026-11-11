-- Profession Workbench: craft queue and shopping list.
--
-- A queue is a list of { index = <recipe key>, count = <how many crafts> }.
-- Turning a queue into a shopping list walks each recipe's reagents, and when
-- a reagent is itself something we can make, the missing ones are added to the
-- queue instead of being bought. That is what makes "silk cloth -> bolts ->
-- hood" work without the player spelling out the intermediate steps.

local ADDON, ns = ...
local PW = assert(ns.PW, "Profession WorkBench: Queue.lua must load after Core.lua")

local floor, max, min, format = math.floor, math.max, math.min, string.format

-- How deep to follow reagent -> recipe before giving up.
local MAX_DEPTH = 4

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

-- Queues are per profession, and shared by every character on the account,
-- because the plan is about the profession rather than the alt doing it.
function PW:QueueStore()
    self.db.queues = self.db.queues or {}
    return self.db.queues
end

function PW:Queue()
    local store = self:QueueStore()
    local key = self.profession or "?"
    store[key] = store[key] or {}
    return store[key]
end

function PW:SaveQueue(queue)
    local store = self:QueueStore()
    store[self.profession or "?"] = queue or {}
end

-- Recipes are found by name so a queue survives a reload, a re-scan and any
-- change in recipe ordering. Returns the live recipe or nil.
function PW:FindRecipeByName(name)
    if not name or not self.recipes then return end
    -- Case-insensitive: the slash command lowercases what the player types.
    local wanted = name:lower()
    for _, r in ipairs(self.recipes) do
        if r.name and r.name:lower() == wanted then return r end
    end
end

function PW:AddToQueue(index, count)
    local r = self.byIndex and self.byIndex[index]
    if not r then return end
    local queue = self:Queue()
    for _, entry in ipairs(queue) do
        if entry.name == r.name then
            entry.count = entry.count + (count or 1)
            self:SaveQueue(queue)
            return entry
        end
    end
    local entry = { name = r.name, count = count or 1 }
    queue[#queue + 1] = entry
    self:SaveQueue(queue)
    return entry
end

function PW:RemoveFromQueue(name)
    local queue = self:Queue()
    for i, entry in ipairs(queue) do
        if entry.name == name then
            table.remove(queue, i)
            self:SaveQueue(queue)
            return true
        end
    end
end

function PW:ClearQueue()
    self:SaveQueue({})
end

function PW:QueueCount()
    local n = 0
    for _, entry in ipairs(self:Queue()) do n = n + entry.count end
    return n
end

---------------------------------------------------------------------------
-- Totals
--
-- Every item known to be needed, how much is wanted, and how much is on this
-- character (bags, and optionally the bank).
---------------------------------------------------------------------------

-- `key` is the itemID, or "name:<reagent name>" for a reagent whose item isn't
-- cached yet (so it still shows up instead of silently vanishing).
local function AddNeed(totals, order, key, itemID, count, name)
    if not key or count <= 0 then return end
    local t = totals[key]
    if not t then
        t = { itemID = itemID, need = 0, name = name }
        totals[key] = t
        order[#order + 1] = key
    end
    t.need = t.need + count
    t.name = t.name or name
end

-- Walk the queue, expanding any reagent we can make ourselves.
-- Returns a list of { itemID, name, need, have, missing }.
function PW:ShoppingList(queue, includeBank)
    queue = queue or self:Queue()
    local totals, order = {}, {}
    local depthGuard = 0
    -- Stock already set aside for earlier reagents in this walk, so two
    -- recipes that both need the same 4 bolts don't each count them as theirs.
    local reserved = {}

    local function NeedRecipe(r, crafts, depth)
        if not r or crafts <= 0 then return end
        if depth > MAX_DEPTH then return end
        local reagents = self:GetReagents(r.index)
        for _, rg in ipairs(reagents) do
            local itemID = rg.itemID or PW.ItemIDFromLink(rg.link)
            local want = (rg.need or 1) * crafts
            if not itemID then
                local name = rg.name or "Unknown reagent"
                AddNeed(totals, order, "name:" .. name, nil, want, name)
            else
                local have = max(self:CountOf(itemID, includeBank) - (reserved[itemID] or 0), 0)
                local use = min(have, want)
                reserved[itemID] = (reserved[itemID] or 0) + use
                local short = want - use

                -- Can we make the shortfall ourselves instead of buying it?
                local sub = short > 0 and self:FindRecipeByOutput(itemID)
                if sub and sub ~= r and depth < MAX_DEPTH and depthGuard < 200 then
                    depthGuard = depthGuard + 1
                    local made = max(self:AmountMade(sub.index), 1)
                    NeedRecipe(sub, math.ceil(short / made), depth + 1)
                else
                    -- Buy it (or it's already in stock). Also the fallback when
                    -- the recursion guard trips, so nothing is ever dropped.
                    AddNeed(totals, order, itemID, itemID, want, rg.name)
                end
            end
        end
    end

    for _, entry in ipairs(queue) do
        local r = self:FindRecipeByName(entry.name)
        if r then NeedRecipe(r, entry.count, 0) end
    end

    local list = {}
    for _, key in ipairs(order) do
        local t = totals[key]
        local have = t.itemID and self:CountOf(t.itemID, includeBank) or 0
        list[#list + 1] = {
            itemID = t.itemID,
            name = t.name,
            need = t.need,
            have = have,
            missing = max(t.need - have, 0),
        }
    end
    table.sort(list, function(a, b)
        -- Short items first, then alphabetical, so what to buy is at the top.
        local am, bm = a.missing > 0, b.missing > 0
        if am ~= bm then return am end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

-- How much of an item this character has, in bags and optionally the bank.
function PW:CountOf(itemID, includeBank)
    if not itemID then return 0 end
    local n = 0
    if C_Item and C_Item.GetItemCount then
        local ok, count = pcall(C_Item.GetItemCount, itemID, false)
        if ok and type(count) == "number" then n = count end
    end
    if includeBank then n = n + self:BankCount(itemID) end
    return n
end

---------------------------------------------------------------------------
-- Reagent -> recipe lookup
---------------------------------------------------------------------------

-- Which of our known recipes makes this item? Cached per scan.
function PW:FindRecipeByOutput(itemID)
    if not itemID then return end
    self.outputIndex = self.outputIndex or {}
    return self.outputIndex[itemID]
end

-- `recipes` is the list just scanned; self.recipes may still be the old one.
function PW:BuildOutputIndex(recipes)
    local index = {}
    for _, r in ipairs(recipes or self.recipes or {}) do
        local out = self.API.OutputItemID and self.API.OutputItemID(r.index)
        -- First recipe wins, which is the cheapest-to-reach one in practice.
        if out and not index[out] then index[out] = r end
    end
    self.outputIndex = index
end

---------------------------------------------------------------------------
-- Shopping list as text, for pasting into chat or a note
---------------------------------------------------------------------------

function PW:ShoppingListText(list)
    local lines = {}
    for _, entry in ipairs(list) do
        if entry.missing > 0 then
            lines[#lines + 1] = format("%s x%d", entry.name or ("item " .. entry.itemID), entry.missing)
        end
    end
    if #lines == 0 then return "Everything needed for the queue is in your bags." end
    return table.concat(lines, "\n")
end
