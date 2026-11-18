-- The single "what to do with this item" rule (PLAN.md steps 4 and 5). Pure Lua, no WoW API: the tooltip and the
-- bags tab both call Decide, so the logic exists once.
--
-- ctx = {
--   price(itemID) -> copper|nil, ageDays|nil      vendor(itemID) -> copper|nil      ageKnown = bool
--   skills = { [profession] = skill }             known(craftSpellID) -> bool
--   quests(itemID) -> list of { quest, zone, level, faction, count } | nil
--   level = player level, faction = "A" | "H"     disenchant(itemID) -> copper|nil (nil = not possible for this character)
--   index = result of Advice.NewIndex
-- }
local _, ns = ...

local A = {}
ns.Advice = A

local ZR = ns.ZoneRank
local DEF = ZR.DEFAULTS

-- Profession names in Data/Recipes.lua that differ from the skill names used for gathering.
local PROF_KEY = { Herbalism = "Herb Gathering" }

-- A quest is worth keeping items for when it is not a repeatable city donation (zone "a capital city"), suits the
-- character's faction, and its level is from 2 below to 5 above the character's.
function A.QuestRelevant(q, ctx)
  -- the quest's level: Forever's own when ForeverDB's quest list has it (ns.FdbQuestSeen[title] = level), else the Classic one
  local seen = ns.FdbQuestSeen and ns.FdbQuestSeen[q.quest]
  local level = type(seen) == "number" and seen or q.level
  return q.zone ~= "a capital city" and (q.faction == "B" or q.faction == ctx.faction)
    and level + 2 >= ctx.level and level <= ctx.level + 5
end

-- Turns the generated rows (Data/Recipes.lua) into recipes, and indexes them by ingredient.
function A.NewIndex(rows)
  local byMat = {}
  for _, r in ipairs(rows) do
    local recipe = { id = r[1], prof = r[2], skill = r[3], out = r[4], low = r[5], high = r[6], sell = r[7],
      name = r[8], src = r[10], learn = r[11], mats = {}, guessed = r[11] == nil }
    for mat, count in r[9]:gmatch("(%d+):(%d+)") do
      recipe.mats[#recipe.mats + 1] = { tonumber(mat), tonumber(count) }
      byMat[tonumber(mat)] = byMat[tonumber(mat)] or {}
      table.insert(byMat[tonumber(mat)], recipe)
    end
  end
  return { byMat = byMat }
end

-- Value in copper of one unit (after the AH cut for AH prices), kind: fresh, old, vendor, none.
local function val(id, ctx)
  return ZR.UnitValue(id, ctx.price, ctx.vendor, DEF, ctx.ageKnown ~= false)
end

-- Evaluates one recipe for this character. status: known, noprof, locked, quest, learn.
function A.Evaluate(recipe, ctx)
  local status
  local skill = ctx.skills[PROF_KEY[recipe.prof] or recipe.prof]
  if ctx.known(recipe.id) then status = "known"
  elseif not skill then status = "noprof"
  elseif skill < (recipe.learn or recipe.skill) then status = "locked"
  elseif recipe.src == "q" then status = "quest"
  else status = "learn" end

  local unit, kind = val(recipe.out, ctx)
  if kind == "none" then unit = recipe.sell end
  local result = unit * (recipe.low + recipe.high) / 2
  -- Ingredients: the AH value when there is one; otherwise the vendor BUY price when known; otherwise only the
  -- vendor sell price (or 0) is known, which understates the cost, so the profit is flagged "high estimate".
  local cost, uncertain = 0, false
  for _, m in ipairs(recipe.mats) do
    local u, k = val(m[1], ctx)
    if k ~= "fresh" and k ~= "old" then
      local buy = ctx.buy and ctx.buy(m[1])
      if buy then u = buy else uncertain = true end
    end
    cost = cost + m[2] * u
  end
  return { recipe = recipe, status = status, result = result, cost = cost, profit = result - cost, uncertain = uncertain,
    craftable = status == "known" and (skill or 0) >= recipe.skill }
end

local ORDER = { known = 1, learn = 2, quest = 2, locked = 3, noprof = 3 }

-- Every recipe the item is an ingredient of, usable ones first then by result price. { total = n, list = {...} }
function A.Uses(itemID, ctx)
  local list = {}
  for _, recipe in ipairs(ctx.index.byMat[itemID] or {}) do list[#list + 1] = A.Evaluate(recipe, ctx) end
  table.sort(list, function(a, b)
    if ORDER[a.status] ~= ORDER[b.status] then return ORDER[a.status] < ORDER[b.status] end
    if a.result ~= b.result then return a.result > b.result end
    return a.recipe.id < b.recipe.id
  end)
  return { total = #list, list = list }
end

-- How many of the item to keep for quests the character may still do: the largest single need (a quest is done once,
-- so needs are not added up), at most what the character owns.
local function keepCount(item, ctx)
  local keep, name = 0, nil
  for _, q in ipairs(ctx.quests(item.id) or {}) do
    if A.QuestRelevant(q, ctx) and q.count > keep then keep, name = q.count, q.quest end
  end
  return math.min(keep, item.count), name
end

-- item = { id, count, gear = bool (armour or weapon of uncommon quality or better), bound = bool (cannot be auctioned) }
-- Returns { action = "ah" | "vendor" | "disenchant" | "craft" | "none" for what is not kept, unit = copper per unit,
--   keep = n kept for a quest, quest = name, recipe = evaluated recipe, crafts = n, total = copper for the part not kept,
--   hasAh = an AH price was usable, sale = best plain sale price per unit }
function A.Decide(item, ctx)
  local own, kind = val(item.id, ctx)
  local hasAh = (kind == "fresh" or kind == "old") and not item.bound
  local vendor = ctx.vendor(item.id) or 0
  local best = { action = "none", unit = 0 }
  if hasAh then best = { action = "ah", unit = own } end -- item.bound: soulbound items cannot be auctioned
  if vendor > best.unit then best = { action = "vendor", unit = vendor } end
  local sale = best.unit
  local maybe -- (recipe) a craft that looks better but whose ingredient cost is not known well enough to recommend

  local de = item.gear and ctx.disenchant(item.id)
  if de and de * (1 - DEF.ahCut) > best.unit then best = { action = "disenchant", unit = de * (1 - DEF.ahCut) } end

  for _, recipe in ipairs(ctx.index.byMat[item.id] or {}) do
    local e = A.Evaluate(recipe, ctx)
    if e.craftable then
      local qty = 0
      for _, m in ipairs(recipe.mats) do if m[1] == item.id then qty = qty + m[2] end end
      local perUnit = (e.result - (e.cost - qty * own)) / qty
      if perUnit > best.unit and item.count >= qty then
        if e.uncertain then maybe = maybe or recipe
        else best = { action = "craft", unit = perUnit, recipe = e, qty = qty } end
      end
    end
  end

  local keep, quest = keepCount(item, ctx)
  local rest = item.count - keep
  local total, crafts
  if best.action == "craft" then
    crafts = math.floor(rest / best.qty)
    total = crafts * best.qty * best.unit + (rest - crafts * best.qty) * sale
  else
    total = rest * best.unit
  end
  return { action = best.action, unit = best.unit, keep = keep, quest = quest, recipe = best.recipe, crafts = crafts,
    total = total, hasAh = hasAh, sale = sale, maybe = maybe }
end

local GROUP = { ah = "ah", vendor = "vendor", craft = "craft", disenchant = "craft", none = "none" }

-- Groups a list of items by action. Returns { groups = { ah, craft, keep, vendor, none (lists of { item, decision }) },
-- totals = { ah, craft, vendor }, total = copper (kept items excluded), anyAh = bool }.
function A.Bags(items, ctx)
  local r = { groups = { ah = {}, craft = {}, keep = {}, vendor = {}, none = {} }, totals = { ah = 0, craft = 0, vendor = 0, keep = 0, none = 0 },
    total = 0, anyAh = false }
  for _, item in ipairs(items) do
    local d = A.Decide(item, ctx)
    local g = d.keep > 0 and "keep" or GROUP[d.action]
    table.insert(r.groups[g], { item = item, decision = d })
    r.totals[g] = r.totals[g] + d.total
    r.total = r.total + d.total
    r.anyAh = r.anyAh or d.hasAh
  end
  for _, list in pairs(r.groups) do
    table.sort(list, function(a, b)
      if a.decision.total ~= b.decision.total then return a.decision.total > b.decision.total end
      return a.item.id < b.item.id
    end)
  end
  return r
end
