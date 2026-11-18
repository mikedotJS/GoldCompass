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
-- price. nil when neither is known.
local function buyCost(id, ctx)
  local best
  local price, age = ctx.price(id)
  local c = ZR.DEFAULTS
  if price and (ctx.ageKnown == false or (age and age <= c.oldDays)) then best = price end
  local buy = ctx.buy and ctx.buy(id)
  if buy and (not best or buy < best) then best = buy end
  return best
end

-- Evaluates one recipe. Returns { rec, chance, color, cost, result, net, perPoint, missing = { itemIDs }, noSale }.
-- net = reagents - best sale value of the output (negative when crafting earns money); perPoint = net / chance.
function V.Evaluate(rec, ctx)
  local chance = V.CHANCE[rec.d] or 0
  local cost, missing = 0, {}
  for _, m in ipairs(rec.mats or {}) do
    local unit = buyCost(m[1], ctx)
    if unit then cost = cost + unit * m[2] else missing[#missing + 1] = m[1] end
  end
  local result, noSale = 0, true
  if rec.out then
    local unit, kind = ZR.UnitValue(rec.out, ctx.price, ctx.vendor, ZR.DEFAULTS, ctx.ageKnown ~= false)
    result, noSale = unit * (rec.oq or 1), kind == "none"
  end
  local net = cost - result
  return { rec = rec, chance = chance, color = V.COLOR[rec.d] or "?", cost = cost, result = result, net = net,
    perPoint = chance > 0 and net / chance or nil, missing = missing, noSale = noSale }
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

-- prof = { skill, max, recipes = { [id] = rec } }. Returns { rows = ranked (cheapest per point first, at most `limit`),
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
  while #rows > (limit or 5) do rows[#rows] = nil end
  return { rows = rows, best = rows[1], unpriced = unpriced, known = known, craftable = craftable, almost = almost }
end
