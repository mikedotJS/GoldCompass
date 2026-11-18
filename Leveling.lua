-- "Monter un métier" (leveling advisor): ranks the KNOWN recipes of a profession by expected cost per skill point.
-- Pure Lua, no WoW API. Everything here is an estimate.
--
-- ctx = { price(itemID) -> copper|nil, ageDays|nil, vendor(itemID) -> sell copper|nil, buy(itemID) -> copper|nil,
--         ageKnown = bool }
-- rec = { id, name, d = relative difficulty (0 orange, 1 yellow, 2 green, 3 gray), out, oq, mats = { {itemID, n}, ... }, greenAt }
local _, ns = ...

local V = {}
ns.Leveling = V

local ZR = ns.ZoneRank

-- Chance of gaining a skill point by difficulty colour (Enum.TradeskillRelativeDifficulty: 0 optimal/orange, 1 medium/
-- yellow, 2 easy/green, 3 trivial/gray). Estimates, not game data.
V.CHANCE = { [0] = 1, [1] = 0.75, [2] = 0.25, [3] = 0 }
V.COLOR = { [0] = "orange", [1] = "jaune", [2] = "vert", [3] = "gris" }

-- What buying one unit of a reagent costs: the cheaper of the usable AH price (gross: you pay it) and the vendor buy
-- price. When neither is known, `ctx.floor(id)` (optional: the vendor SELL value, a floor of the real cost) is used and
-- the second result is true. nil when nothing is known.
local function buyCost(id, ctx)
  local best
  local price, age = ctx.price(id)
  local c = ZR.DEFAULTS
  if price and (ctx.ageKnown == false or (age and age <= c.oldDays)) then best = price end
  local buy = ctx.buy and ctx.buy(id)
  if buy and (not best or buy < best) then best = buy end
  if best then return best end
  local floor = ctx.floor and ctx.floor(id)
  if floor and floor > 0 then return floor, true end
end

-- Evaluates one recipe. Returns { rec, chance, color, cost, result, net, perPoint, missing = { itemIDs }, noSale, floor }
-- (floor = a reagent was valued at its vendor sell value, so the cost is a lower bound).
-- net = reagents - best sale value of the output (negative when crafting earns money); perPoint = net / chance.
function V.Evaluate(rec, ctx)
  local chance = V.CHANCE[rec.d] or 0
  local cost, missing, floor = 0, {}, false
  for _, m in ipairs(rec.mats or {}) do
    local unit, isFloor = buyCost(m[1], ctx)
    if unit then cost = cost + unit * m[2]; floor = floor or isFloor else missing[#missing + 1] = m[1] end
  end
  local result, noSale = 0, true
  if rec.out then
    local unit, kind = ZR.UnitValue(rec.out, ctx.price, ctx.vendor, ZR.DEFAULTS, ctx.ageKnown ~= false)
    result, noSale = unit * (rec.oq or 1), kind == "none"
  end
  local net = cost - result
  return { rec = rec, chance = chance, color = V.COLOR[rec.d] or "?", cost = cost, result = result, net = net,
    perPoint = chance > 0 and net / chance or nil, missing = missing, noSale = noSale, floor = floor }
end

-- How many times the recipe can be crafted from what is carried: min over reagents of floor(owned / needed), and the
-- reagents that are short as { { itemID, missingCount }, ... }. `count(itemID)` returns how many the player carries.
function V.Craftable(rec, count)
  local times, short = math.huge, {}
  for _, m in ipairs(rec.mats or {}) do
    local have = count(m[1]) or 0
    times = math.min(times, math.floor(have / m[2]))
    if have < m[2] then short[#short + 1] = { m[1], m[2] - have } end
  end
  if times == math.huge then times = 0 end -- no known reagents: nothing can be said, so nothing is craftable
  return times, short
end

-- prof = { skill, max, recipes = { [id] = rec } }. Returns { rows = ranked (cheapest per point first, at most `limit` when given),
-- best, unpriced = { evaluations with a reagent without price and a chance above 0 }, known = number of recipes }.
function V.Plan(prof, ctx, limit, count)
  local rows, unpriced, known, all = {}, {}, 0, {}
  for _, rec in pairs(prof.recipes or {}) do
    known = known + 1
    local e = V.Evaluate(rec, ctx)
    if e.chance > 0 then
      if count then e.times, e.short = V.Craftable(rec, count) end
      all[#all + 1] = e
      if #e.missing > 0 or not rec.mats or #rec.mats == 0 then unpriced[#unpriced + 1] = e else rows[#rows + 1] = e end
    end
  end
  local almost, craftable
  if count then
    -- only what can be crafted now; the closest alternative is the recipe missing the fewest reagents (then units)
    local function keep(list)
      local out = {}
      for _, e in ipairs(list) do if e.times >= 1 then out[#out + 1] = e end end
      return out
    end
    rows, unpriced = keep(rows), keep(unpriced)
    craftable = #rows + #unpriced
    local function units(e) local n = 0; for _, s in ipairs(e.short) do n = n + s[2] end; return n end
    for _, e in ipairs(all) do
      if e.times == 0 then
        local better = not almost or #e.short < #almost.short
          or (#e.short == #almost.short and (units(e) < units(almost)
            or (units(e) == units(almost) and ((e.perPoint or math.huge) < (almost.perPoint or math.huge)
              or ((e.perPoint or math.huge) == (almost.perPoint or math.huge) and e.rec.id < almost.rec.id)))))
        if better then almost = e end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.perPoint ~= b.perPoint then return a.perPoint < b.perPoint end
    return a.rec.id < b.rec.id
  end)
  table.sort(unpriced, function(a, b) return a.rec.id < b.rec.id end)
  while limit and #rows > limit do rows[#rows] = nil end
  return { rows = rows, best = rows[1], unpriced = unpriced, known = known, craftable = craftable, almost = almost }
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Recipes to learn. Source data: Data/Recipes.lua rows (Classic sources, NOT confirmed on Forever).

V.SOON = 25 -- a recipe is "soon" when it is learnable within this many skill points

-- Estimated colour of a recipe to learn, for a given skill (0 orange, 1 yellow, 2 green, 3 gray). `learnAt` is the skill
-- needed to learn it (orange from there). The data gives the skills at which it turns yellow / green / gray (`y`, `g`,
-- `gr`) for some recipes; for the others the common Classic spacing is ESTIMATED: yellow = learnAt + 30, green =
-- learnAt + 45, gray = learnAt + 60. A recipe the character knows keeps the colour the game gives it instead.
function V.EstimateColor(skill, learnAt, y, g, gr)
  y, g, gr = y or learnAt + 30, g or learnAt + 45, gr or learnAt + 60
  if skill >= gr then return 3 elseif skill >= g then return 2 elseif skill >= y then return 1 end
  return 0
end

-- Rows of Data/Recipes.lua for one profession (English name) as crafts:
-- { id, name, learn (skill needed to learn, nil = unknown), src, y, g, gr (colour thresholds, optional), out, oq, sell, mats }.
function V.Crafts(rows, prof)
  local out = {}
  for _, r in ipairs(rows) do
    if r[2] == prof then
      local mats = {}
      for mat, n in (r[9] or ""):gmatch("(%d+):(%d+)") do mats[#mats + 1] = { tonumber(mat), tonumber(n) } end
      out[#out + 1] = { id = r[1], name = r[8], learn = r[11], src = r[10], y = r[12], g = r[13], gr = r[14], out = r[4],
        oq = ((r[5] or 1) + (r[6] or 1)) / 2, sell = r[7], mats = mats }
    end
  end
  return out
end

-- Source key of a recipe: trainer (no source in the data: assumed), v vendor, m monster drop, d other drop, q quest.
function V.Source(rec) return rec.src or "trainer" end

-- Trainer recipes from skill 50 up may need a higher profession rank first (Journeyman 50, Expert 125, Artisan 200,
-- with character level gates 10 / 20 / 35). The rank gates are not modelled: the line says it "may" be required.
function V.MayNeedRank(rec) return rec.src == nil and rec.learn >= 50 end

local function byCost(a, b)
  if a.perPoint ~= b.perPoint then return a.perPoint < b.perPoint end
  return a.rec.id < b.rec.id
end
local function learnAt(e) return e.rec.learn end

-- Priced recipes first (cheapest per point), then the ones with an unknown reagent price by required skill.
local function byLearnRank(a, b)
  if a.unpriced ~= b.unpriced then return not a.unpriced end
  if a.unpriced then
    if learnAt(a) ~= learnAt(b) then return learnAt(a) < learnAt(b) end
    return a.rec.id < b.rec.id
  end
  return byCost(a, b)
end

-- Recipes the character does not know, ranked by estimated cost per skill point (same maths as Evaluate; the colour
-- is the estimate above, taken at the skill the character will have when the recipe can be learned). `ctx.known(id)`
-- says which recipes are known. A reagent without an AH price falls back to its vendor buy price (ctx.buy), then to
-- its vendor sell value (ctx.vendor, a floor: `floor` on the row), then is unknown; a recipe with an unknown reagent
-- is still listed (`unpriced`, no cost per point) after the priced ones. A craft whose output has no market and no
-- vendor price uses the sale value of the data. The learning fee is unknown and not included.
--   now  = learnable at the current skill; soon = learnable within V.SOON more points (optional limits: { now = n, soon = n }; none by default).
--   count = optional bag count function: only recipes whose reagents are carried are kept ("Avec mon sac").
--   knownBest = cost per point of the best KNOWN recipe: when the best learnable one is cheaper, `gain` is the
--   difference per point (not given when that best recipe relies on a floor price).
-- Returns { now, soon, best (priced rows only), gain, candidates (priced and not gray, before the bag filter), unpriced
-- (same, with an unknown reagent price), nowTotal, soonTotal (learnable in reach, gray or not) }. Nothing learnable:
-- nowTotal + soonTotal = 0; everything gray: candidates + unpriced = 0; hidden by the bag filter: both lists empty.
function V.Learnable(crafts, skill, ctx, count, limits, knownBest)
  limits = limits or {}
  local now, soon, candidates, unpriced, nowTotal, soonTotal = {}, {}, 0, 0, 0, 0
  for _, c in ipairs(crafts) do
    local at = c.learn -- a recipe whose learn skill is unknown is not listed (mostly crafts not learnable in this phase)
    if at and not ctx.known(c.id) and at <= skill + V.SOON then
      local isNow = at <= skill
      if isNow then nowTotal = nowTotal + 1 else soonTotal = soonTotal + 1 end
      local rec = { id = c.id, name = c.name, learn = at, src = c.src, out = c.out, oq = c.oq, mats = c.mats,
        d = V.EstimateColor(math.max(skill, at), at, c.y, c.g, c.gr) }
      local own = setmetatable({
        vendor = function(id) return ctx.vendor(id) or (id == c.out and c.sell or nil) end,
        floor = function(id) return ctx.vendor(id) end,
      }, { __index = ctx })
      local e = V.Evaluate(rec, own)
      if e.chance > 0 then
        if #e.missing > 0 or #c.mats == 0 then
          e.unpriced, e.perPoint = true, nil
          unpriced = unpriced + 1
        else
          candidates = candidates + 1
        end
        if count then e.times, e.short = V.Craftable(rec, count) end
        if not count or e.times >= 1 then
          local list = isNow and now or soon
          list[#list + 1] = e
        end
      end
    end
  end
  table.sort(now, byLearnRank)
  table.sort(soon, byLearnRank)
  while limits.now and #now > limits.now do now[#now] = nil end
  while limits.soon and #soon > limits.soon do soon[#soon] = nil end
  local best = now[1] and not now[1].unpriced and now[1] or nil
  local gain = (best and not best.floor and knownBest and best.perPoint < knownBest) and (knownBest - best.perPoint) or nil
  return { now = now, soon = soon, best = best, gain = gain, candidates = candidates, unpriced = unpriced,
    nowTotal = nowTotal, soonTotal = soonTotal }
end
