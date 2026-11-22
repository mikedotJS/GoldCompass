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
-- The usable auction price of an item (not too old), or nil.
local function ahPrice(id, ctx)
  local price, age = ctx.price(id)
  if price and (ctx.ageKnown == false or (age and age <= ZR.DEFAULTS.oldDays)) then return price end
end

local function buyCost(id, ctx)
  local best = ahPrice(id, ctx)
  local buy = ctx.buy and ctx.buy(id)
  if buy and (not best or buy < best) then best = buy end
  if best then return best end
  local floor = ctx.floor and ctx.floor(id)
  if floor and floor > 0 then return floor, true end
end

-- Colour of a recipe at `skill` from its thresholds { orange, yellow, green, gray } (0 orange .. 3 gray).
function V.ColorAt(skill, th)
  if skill >= th[4] then return 3 elseif skill >= th[3] then return 2 elseif skill >= th[2] then return 1 end
  return 0
end

-- Chance of a skill point, the Classic formula (ProfessionsTracker, MIT, does the same): orange 1, gray 0, and between yellow and gray
-- (gray - skill) / (gray - yellow), clamped to 0..1. Without the thresholds the flat estimate of V.CHANCE. Second result: exact (the
-- game's colour or the real thresholds), false for the estimate.
function V.Chance(d, skill, yellow, gray)
  if d == 0 then return 1, true end
  if d == nil or d >= 3 then return 0, true end
  if skill and yellow and gray and gray > yellow then return math.max(0, math.min(1, (gray - skill) / (gray - yellow))), true end
  return V.CHANCE[d] or 0, false
end

-- Cost of making one unit of an intermediate item from its own reagents (market prices): nil when one of them has no price.
local function craftCost(sub, ctx)
  local cost = 0
  for _, m in ipairs(sub.mats or {}) do
    local unit = buyCost(m[1], ctx)
    if not unit then return nil end
    cost = cost + unit * m[2]
  end
  return cost / math.max(sub.oq or 1, 1)
end

-- Evaluates one recipe. Returns { rec, chance, exact, d, color, cost, result, net, perPoint, missing = { itemIDs }, noSale, floor, subs }
-- (floor = a reagent was valued at its vendor sell value, so the cost is a lower bound).
-- mode "level" (Monter le métier): what comes back is only the GUARANTEED recovery, the vendor sale of the output (an AH resale is
-- uncertain and slow, never counted); any other mode ("gold"): the best sale value, the AH price (net of the cut) when it is fresh.
-- `skill` and `th` ({ yellow, gray }) give the real chance (V.Chance); when `th` has the four thresholds the colour is taken from them
-- at `skill` (a colour remembered from an older visit may be stale).
-- A reagent the player does not carry that a recipe he knows makes (`ctx.sub(itemID)` -> that recipe) is valued at the cheaper of
-- its market price and the cost of crafting it: e.subs = { { item, need, rec, unit } } lists the ones to craft first.
-- net = reagents - recovery (negative when crafting earns money); perPoint = net / chance;
-- resale = the profit exists only if the crafted item is sold at the auction house; ahSale = the sale value is an AH price
-- (saleAge: its age in days when known; noAge: the price addon cannot date it, so it may not win a money ranking);
-- oldAh = an AH price exists but is older than the configured old days (the vendor value is used instead: "prix HV ancien");
-- profit = -net, the money one craft makes (negative = it costs); uncertain = the sale price is undated or older than the fresh days.
function V.Evaluate(rec, ctx, mode, skill, th)
  local level = mode == "level"
  local d = rec.d
  if th and th[1] and th[3] and skill then d = V.ColorAt(skill, th) end
  local chance, exact = V.Chance(d, skill, th and (th.y or th[2]), th and (th.gr or th[4]))
  local cost, missing, floor, subs = 0, {}, false, {}
  -- Ingredients: the units of reagents one craft takes, a reagent any trade-goods vendor sells (ctx.buy: thread, salt, vials...) counts half
  -- (easy to get), the rest 1. An intermediate reagent the player lacks and knows how to make counts as the units of its own reagents.
  -- `gather` = the same, the units the bags do not already hold.
  local units, gather = 0, 0
  local function weight(id) return (ctx.buy and ctx.buy(id)) and 0.5 or 1 end
  for _, m in ipairs(rec.mats or {}) do
    local unit, isFloor = buyCost(m[1], ctx)
    local sub = ctx.sub and ctx.sub(m[1])
    local owned = ctx.owned and ctx.owned(m[1]) or 0
    local lacking = math.max(0, m[2] - owned)
    if sub and sub ~= rec then
      local made = craftCost(sub, ctx)
      if made and (not unit or isFloor or made < unit) then unit, isFloor = made, false end
      if lacking > 0 then
        local subUnits = 0
        for _, sm in ipairs(sub.mats or {}) do subUnits = subUnits + sm[2] * weight(sm[1]) end
        subUnits = subUnits / math.max(sub.oq or 1, 1)
        subs[#subs + 1] = { item = m[1], need = lacking, rec = sub, unit = made }
        units = units + lacking * subUnits + (m[2] - lacking) * weight(m[1])
        gather = gather + lacking * subUnits
      else
        units = units + m[2] * weight(m[1])
      end
    else
      units = units + m[2] * weight(m[1])
      gather = gather + lacking * weight(m[1])
    end
    if unit then cost = cost + unit * m[2]; floor = floor or isFloor else missing[#missing + 1] = m[1] end
  end
  local result, noSale, ahSale, saleAge, oldAh = 0, true, false, nil, false
  if rec.out and level then
    local v = ctx.vendor(rec.out) or 0
    result, noSale = v * (rec.oq or 1), v == 0
  elseif rec.out then
    local unit, kind, age = ZR.UnitValue(rec.out, ctx.price, ctx.vendor, ZR.DEFAULTS, ctx.ageKnown ~= false)
    result, noSale, ahSale = unit * (rec.oq or 1), kind == "none", kind == "fresh" or kind == "old"
    if ahSale and ctx.ageKnown ~= false then saleAge = age end
    oldAh = kind == "stale" and ctx.price(rec.out) ~= nil
  end
  local net = cost - result
  return { rec = rec, chance = chance, exact = exact, d = d, color = V.COLOR[d] or "?", cost = cost, result = result, net = net,
    perPoint = chance > 0 and net / chance or nil, missing = missing, noSale = noSale, floor = floor, subs = subs,
    -- levelling effort: ingredients and crafts per skill point (the gold figure `perPoint` is only a last tie-break)
    units = units, gather = gather, unitsPerPoint = chance > 0 and units / chance or nil,
    gatherPerPoint = chance > 0 and gather / chance or nil, craftsPerPoint = chance > 0 and 1 / chance or nil,
    resale = net < 0 and ahSale, ahSale = ahSale, saleAge = saleAge, profit = -net,
    oldAh = oldAh, noAge = ahSale and ctx.ageKnown == false,
    -- the figure rests on an AH price of the crafted item that is undated or past the "fresh" days: "prix HV incertain". (Auctionator
    -- only tells the age of the last scan, not how many days of history stand behind it.)
    uncertain = ahSale and (ctx.ageKnown == false or (saleAge ~= nil and saleAge > ZR.DEFAULTS.freshDays)) or false }
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

-- Levelling order: fewer ingredients per skill point; ties: fewer crafts per point (higher chance), craftable now, no intermediate craft to make
-- first, then the gold cost per point, then the id.
function V.EasierThan(a, b)
  local ua, ub = math.floor(a.unitsPerPoint * 100 + 0.5), math.floor(b.unitsPerPoint * 100 + 0.5)
  if ua ~= ub then return ua < ub end
  if math.abs(a.chance - b.chance) > 1e-9 then return a.chance > b.chance end
  if (a.craftNow or false) ~= (b.craftNow or false) then return a.craftNow or false end
  if (#a.subs == 0) ~= (#b.subs == 0) then return #a.subs == 0 end
  local pa, pb = math.floor(a.perPoint + 0.5), math.floor(b.perPoint + 0.5)
  if pa ~= pb then return pa < pb end
  return a.rec.id < b.rec.id
end

-- Best of the rows (sorted by V.EasierThan) without the bag filter: among the recipes within 15 % of the fewest ingredients per point, the ones
-- that can be crafted right now come first, then fewer crafts per point (orange before yellow before green), then no intermediate craft, then gold.
function V.EasiestWithin(rows)
  local top = rows[1]
  if not top then return end
  local limit = top.unitsPerPoint * 1.15
  local best
  local function better(a, b)
    if (a.craftNow or false) ~= (b.craftNow or false) then return a.craftNow or false end
    if math.abs(a.chance - b.chance) > 1e-9 then return a.chance > b.chance end
    if (#a.subs == 0) ~= (#b.subs == 0) then return #a.subs == 0 end
    return V.EasierThan(a, b)
  end
  for _, e in ipairs(rows) do
    if e.unitsPerPoint <= limit and (not best or better(e, best)) then best = e end
  end
  return best
end

-- prof = { skill, max, recipes = { [id] = rec } }. Returns { rows = ranked, best, unpriced = { evaluations with a reagent without
-- price and a chance above 0 }, known = number of recipes }. A figure resting on an uncertain AH price of the crafted item (`uncertain`:
-- undated or older than the fresh days) comes after the reliable ones (within a colour) and never gives the "gold" best. The goal is to LEVEL the profession: skill points first, money second.
--   With `count` ("Avec mon sac"): rows are ranked by the skill points expected now (`points` = times craftable x chance),
--   then by cost per point. `second` = { e, times, points } is the next recipe the leftover bag can craft, given when the
--   best one gives fewer points than the gap to its next colour change (`thresholds(id)` -> { orange, yellow, green, gray }).
--   Without it: by colour (orange, yellow, green; gray never), then by cost per point inside a colour.
--   goal "gold" ("Gagner de l'or"): skill points are ignored, gray recipes are included (they still sell), rows are ranked by
--   profit per craft, or by total profit (`total` = times craftable x profit) with `count`; `best` needs a profit above 0.
function V.Plan(prof, ctx, limit, count, thresholds, goal)
  local gold = goal == "gold"
  local rows, unpriced, known, all = {}, {}, 0, {}
  -- the recipes the player knows make intermediate reagents (a Light Hide -> a Cured Light Hide): valued by what crafting them costs
  local byOut = {}
  for _, rec in pairs(prof.recipes or {}) do if rec.out then byOut[rec.out] = rec end end
  ctx = setmetatable({ sub = function(item) return byOut[item] end }, { __index = ctx })
  for _, rec in pairs(prof.recipes or {}) do
    known = known + 1
    local e = V.Evaluate(rec, ctx, gold and "gold" or "level", prof.skill, thresholds and thresholds(rec.id) or nil)
    if ctx.owned then e.craftNow = V.Craftable(rec, ctx.owned) >= 1 end
    if e.chance > 0 or gold then
      if count then
        e.times, e.short = V.Craftable(rec, count)
        e.points = e.times * e.chance
        e.total = e.times * e.profit
      end
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
    if gold then
      if a.uncertain ~= b.uncertain then return not a.uncertain end      -- a profit that rests on an uncertain AH price comes last
      local ka, kb = count and a.total or a.profit, count and b.total or b.profit
      if ka ~= kb then return ka > kb end
      if a.profit ~= b.profit then return a.profit > b.profit end
      return a.rec.id < b.rec.id
    end
    return V.EasierThan(a, b)
  end)
  table.sort(unpriced, function(a, b) return a.rec.id < b.rec.id end)
  while limit and #rows > limit do rows[#rows] = nil end
  local best, second = rows[1], nil
  if best and not gold then
    best = V.EasiestWithin(rows)                                  -- levelling: the easiest recipe (ingredients, then ease), bag or not
    for i, e in ipairs(rows) do if e == best then table.remove(rows, i); break end end
    table.insert(rows, 1, best)
  end
  if gold then                                                    -- money: nothing earning, or priced from an undated AH price, wins
    best = nil
    for _, e in ipairs(rows) do if e.profit > 0 and not e.uncertain then best = e; break end end
  end
  if count and best and not gold then
    local gap, th = nil, thresholds and thresholds(best.rec.id)
    for i = 2, 4 do                                  -- skill points until the recipe changes colour
      local t = th and th[i]
      if t and t > (prof.skill or 0) and (not gap or t - prof.skill < gap) then gap = t - prof.skill end
    end
    if not th or gap then
      if not gap or best.points < gap then
        local used = {}
        for _, m in ipairs(best.rec.mats or {}) do used[m[1]] = m[2] * best.times end
        local left = function(id) return (count(id) or 0) - (used[id] or 0) end
        for i = 2, #rows do
          local times = V.Craftable(rows[i].rec, left)
          if times >= 1 then second = { e = rows[i], times = times, points = times * rows[i].chance }; break end
        end
      end
    end
  end
  return { rows = rows, best = best, second = second, unpriced = unpriced, known = known, craftable = craftable, almost = almost,
    goal = gold and "gold" or "level" }
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

-- How a recipe can be obtained, from the vendored LibProfessionDB data (world databases: NOT Forever-verified, except what it
-- flags as its own). `DB` is the library, `e` the recipe entry, `faction` "A" or "H". Returns
--   { kind, confirmed, npcs = { English NPC names }, ids = { their NPC ids }, vendorCost = copper | nil, currency = { id | item, amount } | nil (the vendor
--     asks a currency or an item instead of gold), itemID = teaching item | nil }
-- kind: trainer, vendor, quest, item (a teaching item and no source), container, drop, unknown.
-- Priority: trainer, vendor, quest, container, drop, item (a teaching item and no source). A recipe with no source and no teaching item but a
-- requiredSkill of the client's own (captured at a Forever trainer) is a trainer recipe. `confirmed`: the data is the
-- client's own, not borrowed from Vanilla (trainer: the required skill; vendor and quest: the sources).
-- `forever` (ns.ForeverTrainers, in-game observed data of wowforever.be) is the truth about trainers when given: a recipe
-- is trainer-taught on Forever only when it has a cost there (way.cost, way.rank); a trainer source of the library that is
-- not in the table is dropped, the other sources stay. A vendor of the table is used when the library has none.
-- `who` (optional, Where.Who: the Forever NPC data) says whether the player's faction can use a vendor or a quest of the recipe
-- (false: every one a source names belongs to the other faction, then it is no way to learn it: way.onlyFaction = "A" | "H"),
-- which quest it is (way.questID) and what the teaching item costs at a vendor (gold, or Merchant's Favor: way.currency).
V.FAVOR = 3402                                      -- currency id of Merchant's Favor
function V.Way(DB, id, e, faction, forever, who, fixes)
  local ft = forever and forever[id]
  local own = function(field) return not (DB.IsBorrowed and DB:IsBorrowed(id, field)) end
  local ownSkill = e.requiredSkill ~= nil and own("requiredSkill")
  local src = DB.GetRecipeSources and DB:GetRecipeSources(id)
  local libQuest = src and src.quest                -- the library's quest givers, kept for the faction check
  -- The site observed in game where the recipe comes from: its kinds (ft.k) win over sources the library borrowed from world
  -- databases (flag "s") or lacks; the library's own Forever sources (vendors seen on live merchants) stay.
  local site = false                                -- the site's kinds replaced the library's (way.site)
  local ownVendors = DB.HasOwnVendors and DB:HasOwnVendors(id)
  if ft and ft.k and ft.k ~= "" and (not src or (DB.IsBorrowed and DB:IsBorrowed(id, "sources") and not ownVendors)) then
    src = {}
    site = true
    if ft.k:find("v", 1, true) then src.vendor = { total = 1 } end
    if ft.k:find("q", 1, true) then src.quest = { total = 1 } end
    if ft.k:find("[dpf]") then src.drop = { total = 1 } end
  end
  local function has(kind) local l = src and src[kind]; return l and (l.total or #l) > 0 end
  local item = DB.GetRecipeItem and DB:GetRecipeItem(id)
  -- where: "NPC (Zone)" of wowforever.be; zone: where it drops; questName: the quest that gives it
  -- the site's vendor list for the player's faction (two lists: Alliance, Horde), or its one list of unknown faction
  local vtext = ft and ((faction == "H" and ft.vh) or (faction ~= "H" and ft.va) or ft.vendor) or nil
  -- "NPC (Zone) · Merchant's Favor 30 · Honored": the price and the standing asked are not part of the NPC list
  local favor = vtext and tonumber(vtext:match("Merchant's Favor (%d+)"))
  if vtext then vtext = vtext:gsub("%s*\194\183[^,]*", "") end
  -- the standing the vendor asks ("... · Merchant's Favor 240 · Honored")
  local standing = ft and (ft.vh or ft.va or ft.vendor or ""):match("Merchant's Favor %d+%s*\194\183%s*(%a+)") or nil
  local vendorOK, questOK, questID, questTitle, questLevel = true, true, nil, nil, nil
  if who then
    vendorOK = who.vendors(id, faction, vtext) ~= false
    local ok, qid, title, level = who.quest(id, faction, libQuest)
    questOK, questID, questTitle, questLevel = ok ~= false, qid, title, level
  end
  local way = { npcs = {}, ids = {}, itemID = item, site = site, where = vtext, zone = ft and ft.zone, questName = ft and ft.quest,
    zoneMore = ft and ft.zmore,     -- the site cut its drop-zone list: there are more zones than `zone` names
    kinds = ft and ft.k }          -- the site's source kinds (t v q d p f s c): where the recipe comes from, to show next to a teaching item
  local wanted = faction == "H" and "Horde" or "Alliance"
  local function names(kind)
    for _, n in ipairs(src[kind]) do
      local f = n.faction or (DB.GetSourceFaction and DB:GetSourceFaction(n.id))
      if f == nil or f == wanted then way.ids[#way.ids + 1] = n.id end
      if n.name and (f == nil or f == wanted) then way.npcs[#way.npcs + 1] = n.name end
    end
  end
  -- a vendor counts only if one of its vendors can be used by the player's faction (or has none)
  local function vendorUsable()
    if #src.vendor == 0 then return true end        -- the site's vendor kind: no NPC list, no faction to check
    for _, n in ipairs(src.vendor) do
      local f = n.faction or (DB.GetSourceFaction and DB:GetSourceFaction(n.id))
      if f == nil or f == wanted then return true end
    end
  end
  if ft and ft.cost then
    -- the fee before any reputation discount: ForeverDB's observation when it is higher than the one the site observed
    way.kind, way.confirmed, way.cost, way.rank = "trainer", true, math.max(ft.cost, fixes and fixes.fee and fixes.fee[id] or 0), ft.rank
    way.costDoubt = fixes and fixes.feeDoubt and fixes.feeDoubt[id] or nil   -- the sources disagree on the fee: shown as not verified
  elseif not forever and has("trainer") then
    way.kind, way.confirmed = "trainer", ownSkill
  elseif has("vendor") and vendorOK and vendorUsable() then
    way.kind, way.confirmed = "vendor", own("sources") or (ft ~= nil and ft.k ~= nil and #src.vendor == 0)
    names("vendor")
    if #way.npcs == 0 and vtext then way.npcs[1] = (vtext:gsub("%s*%(.*%)%s*$", "")) end
    for _, n in ipairs(src.vendor) do
      local f = n.faction or (DB.GetSourceFaction and DB:GetSourceFaction(n.id))
      local parts = n.cost or (DB.GetVendorCost and DB:GetVendorCost(id, n.id))
      if (f == nil or f == wanted) and parts then
        -- parts: { copper = n } (gold) | { currencyID = n, amount = n } | { itemID = n, amount = n }
        local copper, other = nil, nil
        for _, part in ipairs(parts) do
          local gold = part.copper or (#part == 1 and part[1] or nil)
          if gold then copper = (copper or 0) + gold elseif part.currencyID or part.itemID then other = other or part end
        end
        if other then   -- a currency or an item: no gold price (way.currency says what it is)
          way.currency = way.currency or { id = other.currencyID, item = other.itemID, amount = other.amount }
        elseif copper and (not way.vendorCost or copper < way.vendorCost) then
          way.vendorCost = copper
        end
      end
    end
  elseif vtext and vendorOK and not has("quest") then
    way.kind, way.confirmed = "vendor", true
    way.npcs[1] = vtext:gsub("%s*%(.*%)%s*$", "")
  elseif has("quest") and questOK then
    way.kind, way.confirmed, way.questID = "quest", own("sources"), questID
    if questTitle then way.questName, way.questLevel = questTitle, questLevel end   -- the quest ForeverDB names (its giver is the one pinned)
    names("quest")
  elseif has("container") then
    way.kind = "container"
  elseif has("drop") then
    way.kind = "drop"                    -- the pattern itself drops (Fine Leather Boots); priced, Learnable turns it into "item"
  elseif item then
    way.kind = "item"
  elseif ownSkill and not forever then
    way.kind, way.confirmed = "trainer", true
  else
    way.kind = "unknown"
  end
  -- a vendor or a quest of the other faction only is no way to learn it: said as such, the recipe is left to its other sources
  if way.kind ~= "trainer" and way.kind ~= "vendor" and way.kind ~= "quest"
    and ((not vendorOK and (has("vendor") or vtext ~= nil)) or (not questOK and has("quest"))) then
    way.onlyFaction = faction == "H" and "A" or "H"
  end
  if way.kind == "vendor" and not way.currency then
    -- the price: Merchant's Favor (ForeverDB's, else the site's amount), else gold. The library's gold price was captured with a
    -- reputation discount where ForeverDB's is higher: the full price is shown.
    local price, fav
    if who then price, fav = who.cost(id) end
    fav = fav or favor
    if fav and not way.vendorCost then way.currency = { id = V.FAVOR, amount = fav }
    elseif price and (not way.vendorCost or price > way.vendorCost) then way.vendorCost = price end
  end
  if way.kind == "vendor" then way.standing = standing end
  return way
end

-- Crafts of a profession (skill line, e.g. 165 Leatherworking) from the vendored Forever data (ForeverDB.lua), in the shape of
-- V.Crafts plus `how` (V.Way). Never-implemented and auto-granted recipes are left out. The colour thresholds
-- (yellow, green, gray) are the library's, unless its tiers are unanchored (requiredSkill absent or borrowed and
-- difficulty[1] == 1: a placeholder), then they are left nil and the estimate applies. `fallback(id)` gives a craft of
-- Data/Recipes.lua (output quantity, vendor value, reagents) for what the library lacks. `forever` (ns.ForeverTrainers):
-- see V.Way; its learn skill replaces the library's, and recipes known from the start are left out.
-- Thresholds { orange, yellow, green, gray } of a recipe: the library's (they match the game), unless they are degenerate (the
-- orange placeholder 1 below the learn skill, or yellow == green == gray): then the site's `th` of the Forever table, when it has one.
function V.Difficulty(d, learn, ft)
  local degenerate = d and ((learn and learn > 1 and d[1] < learn) or (d[2] == d[3] and d[3] == d[4]))
  if degenerate and ft and ft.th then return ft.th end
  return d
end

function V.LibCrafts(DB, profId, faction, fallback, forever, who, fixes)
  local out = {}
  -- `fixes` (ns.ForeverFixes): the Forever client's own values where the other sources differ: recipes that are not in the client
  -- (gone, never listed), skill needed (learn), { yellow, green, gray } (th), crafted quantity (oq)
  local gone, fixLearn, fixTh, fixOq = fixes and fixes.gone or {}, fixes and fixes.learn or {}, fixes and fixes.th or {}, fixes and fixes.oq or {}
  for id, e in pairs(DB:GetRecipes(profId) or {}) do
    local ft = forever and forever[id]
    if not (DB.IsHiddenRecipe and DB:IsHiddenRecipe(id)) and not (DB.IsAutoTaughtRecipe and DB:IsAutoTaughtRecipe(id))
      and not (ft and ft.start) and not gone[id] then
      local d = V.Difficulty(e.difficulty, ft and ft.learn or e.requiredSkill, ft)
      local borrowed = DB.IsBorrowed and DB:IsBorrowed(id, "requiredSkill")
      local unanchored = (e.requiredSkill == nil or borrowed) and d and d[1] == 1
      local mats = {}
      for item, qty in pairs(e.reagents or {}) do mats[#mats + 1] = { item, qty } end
      table.sort(mats, function(a, b) return a[1] < b[1] end)
      local fb = fallback and fallback(id)
      if #mats == 0 and fb then mats = fb.mats end
      local th = fixTh[id]
      if th then d, unanchored = { 0, th[1], th[2], th[3] }, false end
      out[#out + 1] = { id = id, name = e.name, learn = fixLearn[id] or (ft and ft.learn) or e.requiredSkill,
        borrowed = borrowed and not ft and not fixLearn[id] and true or false,
        y = (d and not unanchored) and d[2] or nil, g = (d and not unanchored) and d[3] or nil,
        gr = (d and not unanchored) and d[4] or nil, out = e.craftedItemId or (fb and fb.out),
        oq = fixOq[id] or (fb and fb.oq) or 1, sell = fb and fb.sell, mats = mats, how = V.Way(DB, id, e, faction, forever, who, fixes) }
    end
  end
  return out
end

-- Source key of a recipe: trainer (no source in the data: assumed), v vendor, m monster drop, d other drop, q quest.
function V.Source(rec) return rec.src or "trainer" end

-- Trainer recipes from skill 50 up may need a higher profession rank first (Journeyman 50, Expert 125, Artisan 200,
-- with character level gates 10 / 20 / 35). With the Forever table the rank is known (way.rank) and shown by the source
-- label; without it the line says it "may" be required.
function V.MayNeedRank(rec) return rec.src == nil and rec.learn >= 50 and not (rec.way and rec.way.rank) end

-- Profession maximum skill a character needs to be at the rank a trainer recipe asks for (rank trained: 150 Journeyman,
-- 225 Expert, 300 Artisan).
local RANK_MAX = { Apprentice = 0, Journeyman = 150, Expert = 225, Artisan = 300 }

-- Value a learnable recipe is ranked by: its cost per point, plus the learning fee spread over the points it gives
-- (`amortised`, see Learnable); the plain cost per point for a recipe with no known fee.
local function rankValue(e) return e.amortised or e.perPoint end
local function byCost(a, b)
  if rankValue(a) ~= rankValue(b) then return rankValue(a) < rankValue(b) end
  return a.rec.id < b.rec.id
end
local function learnAt(e) return e.rec.learn end

-- Priced recipes first (cheapest per point), then the ones with an unknown reagent price by required skill.
-- A figure that rests on an uncertain AH price of the crafted item comes after the reliable ones (so after them within a colour too).
local function byLearnRank(a, b)
  if a.unpriced ~= b.unpriced then return not a.unpriced end
  if not a.unpriced then
    if a.uncertain ~= b.uncertain then return not a.uncertain end
  end
  if a.unpriced then
    if learnAt(a) ~= learnAt(b) then return learnAt(a) < learnAt(b) end
    return a.rec.id < b.rec.id
  end
  return byCost(a, b)
end

-- Levelling order of the recipes to learn: the effort rule of the known recipes (V.EasierThan: ingredients per point, then fewer crafts per point,
-- craftable now, no intermediate craft) with the points the recipe stays useful for as a tie-break (the longer, the better); recipes with an
-- unknown reagent price last, by required skill.
local function byLearnEffort(a, b)
  if a.unpriced ~= b.unpriced then return not a.unpriced end
  if a.unpriced then
    if learnAt(a) ~= learnAt(b) then return learnAt(a) < learnAt(b) end
    return a.rec.id < b.rec.id
  end
  local ua, ub = math.floor(a.unitsPerPoint * 100 + 0.5), math.floor(b.unitsPerPoint * 100 + 0.5)
  if ua ~= ub then return ua < ub end
  if math.abs(a.chance - b.chance) > 1e-9 then return a.chance > b.chance end
  if (a.craftNow or false) ~= (b.craftNow or false) then return a.craftNow or false end
  if (#a.subs == 0) ~= (#b.subs == 0) then return #a.subs == 0 end
  if a.useful ~= b.useful then return a.useful > b.useful end
  return byCost(a, b)
end

-- Recipes the character does not know, ranked by estimated cost per skill point (same maths as Evaluate; the colour
-- is the estimate above, taken at the skill the character will have when the recipe can be learned). `ctx.known(id)`
-- says which recipes are known. A reagent without an AH price falls back to its vendor buy price (ctx.buy), then to
-- its vendor sell value (ctx.vendor, a floor: `floor` on the row), then is unknown; a recipe with an unknown reagent
-- is still listed (`unpriced`, no cost per point) after the priced ones. A craft whose output has no market and no
-- vendor price uses the sale value of the data.
-- A trainer window recorded in game (ctx.offer(craftID) -> { skill, cost, status, npc, mapID, x, y, zone }, see
-- Trainers.lua) is the truth for that recipe: it gives the real skill needed and the real fee, makes recipes the data
-- does not know learnable (Forever recipes), hides recipes the trainer lists as already known, and gives the recipe its
-- `trainer` place. The fee is spread over the points the recipe can still give you: from your skill (or the skill
-- needed, when higher) to the skill where it turns gray (data threshold, else learn + 60). That gives
-- `amortised` = cost per point + fee / points (points at least 1), the value used to rank and to compare with the best
-- known recipe. Without a recorded trainer the fee is unknown and not included.
--   now  = learnable at the current skill; soon = learnable within V.SOON more points (optional limits: { now = n, soon = n }; none by default).
--   count = optional bag count function: only recipes whose reagents are carried are kept ("Avec mon sac").
--   knownBest = cost per point of the best KNOWN recipe: when the best learnable one is cheaper, `gain` is the
--   difference per point (not given when that best recipe relies on a floor price).
-- Goal "gold" (ctx.goal == "gold", "Gagner de l'or"): the rank is money, not skill points. A recipe to learn is worth its profit per
-- craft minus its learning fee spread over V.GOLD_CRAFTS (10) crafts: `score` (`profit` is the plain profit per craft, negative
-- when crafting costs). Gray recipes count (they still sell); the best has the highest score. `knownBest` is then minus the best
-- known profit per craft, so `gain` is the extra money per craft. e.perPoint = -score there, so the lists sort best first.
-- Library crafts (c.how, see V.Way): the rows say how they are obtained (rec.src, rec.way), what learning costs (rec.fee: the
-- recorded trainer's fee, the vendor's gold price or the teaching item's auction price) and only a trainer, vendor, quest
-- or priced teaching item may be recommended; drops and containers are listed, never recommended. Recipes with no known
-- way are not listed. `gray` = recipes in reach that give no skill point any more (listed, never ranked).
-- Returns { now, soon, gray, best (priced, recommendable rows only), gain, candidates (priced and not gray, before the bag filter), unpriced
-- (same, with an unknown reagent price), nowTotal, soonTotal (learnable in reach, gray or not) }. Nothing learnable:
-- nowTotal + soonTotal = 0; everything gray: candidates + unpriced = 0; hidden by the bag filter: both lists empty.
-- The rank that raises a profession cap: the cap now -> the rank to train (Apprentice 75, Journeyman 150, Expert 225, Artisan 300).
local NEXT_RANK = { [75] = "Journeyman", [150] = "Expert", [225] = "Artisan" }
local SRC_OF_KIND = { vendor = "v", quest = "q", item = "i", container = "c", drop = "d" } -- trainer = nil

V.GOLD_CRAFTS = 10

-- A recorded trainer window said "not available" although the character's skill was enough then (offer.seenAt, see TrainerLog.Offers):
-- something else is missing, a rank. A window seen at a lower skill proves nothing: the recipe was simply out of reach that day.
function V.WindowGated(offer, at)
  return offer ~= nil and offer.status == "unavailable" and offer.seenAt ~= nil and offer.seenAt >= at
end

-- How a craft is obtained and what learning it costs: way (V.Way, or the recorded trainer), fee, src, recommend (a trainer, a vendor, a
-- quest or a teaching item with an auction price) and the age of that auction price.
local function obtain(c, offer, ctx)
  local way, fee, src, recommend, feeAge = c.how, nil, c.src, true, nil
  if offer then
    -- the recorded trainer gives the fee; the rank the recipe needs stays the Forever table's (a recorded offer is no proof the
    -- rank is trained: the window lists what it teaches, "unavailable" included)
    way, fee, src = { kind = "trainer", confirmed = true, npcs = {}, rank = c.how and c.how.rank }, offer.cost, nil
  elseif way then
    local kind = way.kind
    local price = way.itemID and ahPrice(way.itemID, ctx)
    if price then feeAge = select(2, ctx.price(way.itemID)) end
    if (kind == "drop" or kind == "container") and price then way = setmetatable({ kind = "item" }, { __index = way }); kind = "item" end
    if kind == "item" then fee = price elseif kind == "vendor" then fee = way.vendorCost elseif kind == "trainer" then fee = way.cost end
    src = SRC_OF_KIND[kind]
    recommend = kind == "trainer" or kind == "vendor" or kind == "quest" or (kind == "item" and price ~= nil)
  end
  return way, fee, src, recommend, feeAge
end


function V.Learnable(crafts, skill, ctx, count, limits, knownBest)
  limits = limits or {}
  local gold = ctx.goal == "gold"
  local now, soon, gray, candidates, unpriced, nowTotal, soonTotal = {}, {}, {}, 0, 0, 0, 0
  local books, beyond, otherFaction = {}, nil, {}
  local maxSkill = ctx.maxSkill
  local nearCap = not maxSkill or skill >= maxSkill - 2 * V.SOON
  for _, c in ipairs(crafts) do
    local offer = ctx.offer and ctx.offer(c.id)
    local skip = (offer and offer.status == "used")             -- the trainer lists it as already known
      or (c.how and c.how.kind == "unknown" and not offer)      -- no known way to get it
    -- a recipe whose learn skill is unknown (and no trainer offers it) is not listed: mostly crafts not learnable yet
    local at = not skip and (offer and math.max(1, offer.skill or 1) or c.learn)
    if at and not ctx.known(c.id) and at <= skill + V.SOON and maxSkill and at > maxSkill and c.out then
      -- above the profession cap: a higher rank must be trained first (one line "Au-delà de <max>", not a recipe to learn)
      beyond = beyond or { max = maxSkill, rank = NEXT_RANK[maxSkill], count = 0 }
      beyond.count = beyond.count + 1
    elseif at and not ctx.known(c.id) and at <= skill + V.SOON then
      local isNow = at <= skill
      if isNow then nowTotal = nowTotal + 1 else soonTotal = soonTotal + 1 end
      -- how it is obtained, what it costs to learn, and whether it may be recommended
      local way, fee, src, recommend, feeAge = obtain(c, offer, ctx)
      local rec = { id = c.id, name = c.name, learn = at, src = src, out = c.out, oq = c.oq, mats = c.mats, way = way,
        d = V.EstimateColor(math.max(skill, at), at, c.y, c.g, c.gr), trainer = offer, fee = fee, feeAge = feeAge,
        npcNames = way and way.npcs, teachItem = way and way.itemID, th = { at, c.y or at + 30, c.g or at + 45, c.gr or at + 60 } }
      -- where to go (ctx.place -> Where.Target): a recipe whose every way belongs to the other faction is no recipe for this player
      local place = ctx.place and ctx.place(rec)
      if place and place.onlyFaction then
        if isNow then nowTotal = nowTotal - 1 else soonTotal = soonTotal - 1 end
        otherFaction[#otherFaction + 1] = { rec = rec, faction = place.onlyFaction }
      elseif not c.out and #c.mats == 0 then
        -- a rank book or a rank quest (no crafted item, no reagents): never a craft. Near the cap it gets its own line.
        if isNow then nowTotal = nowTotal - 1 else soonTotal = soonTotal - 1 end
        if nearCap then books[#books + 1] = { rec = rec, book = true, recommend = false, target = place } end
      else
      local own = setmetatable({
        vendor = function(id) return ctx.vendor(id) or (id == c.out and c.sell or nil) end,
        floor = function(id) return ctx.vendor(id) end,
      }, { __index = ctx })
      -- the thresholds (the data's, else the common Classic spacing estimated from the learn skill) give the real chance formula
      local th = { at, c.y or at + 30, c.g or at + 45, c.gr or at + 60 }
      local e = V.Evaluate(rec, own, gold and "gold" or "level", math.max(skill, at), th)
      e.exact = (c.y and c.g and c.gr) ~= nil or e.d == 0
      e.recommend = recommend
      if ctx.owned then e.craftNow = V.Craftable(rec, ctx.owned) >= 1 end
      e.target = place
      -- how sure the place is: 0 a position seen on Forever, 1 a hint (Classic position or a zone), 2 text only
      e.placeRank = place and ((place.kind == "pin" and place.confirmed) and 0 or ((place.kind == "pin" or place.kind == "zone") and 1 or 2)) or 2
      e.priceKnown = (way and way.kind == "quest") or fee ~= nil          -- the price of learning it is known in gold
      e.useful = math.max(1, (c.gr or at + 60) - math.max(skill, at))      -- skill points it stays useful for from now
      -- a trainer recipe whose rank the character has not trained yet (ctx.maxSkill = profession maximum)
      e.rankGated = ctx.maxSkill and way and way.rank and ctx.maxSkill < (RANK_MAX[way.rank] or 0) or false
      if isNow and V.WindowGated(offer, at) then e.rankGated = true end   -- the trainer window itself says it cannot be learned yet
      if e.chance == 0 and not gold then
        e.gray, e.perPoint = true, nil                          -- gives no skill point any more
      elseif #e.missing > 0 or #c.mats == 0 then
        e.unpriced, e.perPoint = true, nil
        unpriced = unpriced + 1
      else
        candidates = candidates + 1
        if gold then
          e.score = e.profit - (fee or 0) / V.GOLD_CRAFTS
          e.perPoint = -e.score
        elseif fee and fee > 0 then
          local points = math.max(1, (c.gr or at + 60) - math.max(skill, at))
          e.points, e.amortised = points, e.perPoint + fee / points
        end
      end
      if count then e.times, e.short = V.Craftable(rec, count) end
      if not count or e.times >= 1 then
        local list = e.gray and gray or (isNow and now or soon)
        list[#list + 1] = e
      end
      end
    end
  end
  table.sort(books, function(a, b)
    if a.rec.learn ~= b.rec.learn then return a.rec.learn < b.rec.learn end
    return a.rec.id < b.rec.id
  end)
  table.sort(now, gold and byLearnRank or byLearnEffort)
  table.sort(soon, gold and byLearnRank or byLearnEffort)
  table.sort(gray, function(a, b)
    if a.rec.learn ~= b.rec.learn then return a.rec.learn < b.rec.learn end
    return a.rec.id < b.rec.id
  end)
  while limits.now and #now > limits.now do now[#now] = nil end
  while limits.soon and #soon > limits.soon do soon[#soon] = nil end
  local best
  -- only a known way to get it; a recipe at a rank already trained is preferred to one that first needs the rank. Then
  -- orange/yellow before green, the one that stays useful longest (gray threshold - skill), then the cheapest
  local function better(a, b)
    if a.uncertain ~= b.uncertain then return not a.uncertain end   -- an uncertain AH price never decides
    if gold then return byCost(a, b) end
    if (a.rec.d <= 1) ~= (b.rec.d <= 1) then return a.rec.d <= 1 end
    if a.placeRank ~= b.placeRank then return (a.placeRank or 2) < (b.placeRank or 2) end   -- a place we can send you to beats a text
    if a.useful ~= b.useful then return a.useful > b.useful end
    return byCost(a, b)
  end
  -- levelling: within 15 % of the fewest ingredients per point, more chance (fewer crafts), then a place to pin, no intermediate craft, the longest useful
  local function leaner(a, b)
    if math.abs(a.chance - b.chance) > 1e-9 then return a.chance > b.chance end
    if (a.placeRank or 2) ~= (b.placeRank or 2) then return (a.placeRank or 2) < (b.placeRank or 2) end
    if (#a.subs == 0) ~= (#b.subs == 0) then return #a.subs == 0 end
    if a.useful ~= b.useful then return a.useful > b.useful end
    return byLearnEffort(a, b)
  end
  -- a recipe whose learning price is known in gold comes before one whose price is unknown (currency, item, not in the data)
  for _, known in ipairs({ true, false }) do
    for _, gated in ipairs({ false, true }) do
      local tier, lean = {}, math.huge
      for _, e in ipairs(now) do
        if e.recommend and not e.unpriced and e.rankGated == gated and e.priceKnown == known then
          tier[#tier + 1] = e
          lean = math.min(lean, e.unitsPerPoint or math.huge)
        end
      end
      for _, e in ipairs(tier) do
        if gold then
          if not best or better(e, best) then best = e end
        elseif (e.unitsPerPoint or math.huge) <= lean * 1.15 and (not best or leaner(e, best)) then
          best = e
        end
      end
      if best then break end
    end
    if best then break end
  end
  -- better than the best known recipe: gold: money per point; levelling: ingredients per point (from -> to)
  local gain, from, to
  if best and knownBest then
    if gold then
      if not best.floor and rankValue(best) < knownBest then gain = knownBest - rankValue(best) end
    elseif best.unitsPerPoint and best.unitsPerPoint < knownBest then
      gain, from, to = knownBest - best.unitsPerPoint, knownBest, best.unitsPerPoint
    end
  end
  return { now = now, soon = soon, gray = gray, best = best, gain = gain, gainFrom = from, gainTo = to, candidates = candidates, unpriced = unpriced,
    nowTotal = nowTotal, soonTotal = soonTotal, books = books, beyond = beyond, otherFaction = otherFaction }
end

-- Every recipe the character does not know and may learn on the way to the maximum, for V.Roadmap (opts.candidates). The rules of
-- V.Learnable (a recorded trainer window is the truth for the skill and the fee; only a trainer, a vendor, a quest or a teaching item
-- with an auction price may be recommended; a rank book is not a craft), without its horizon, its money figures and its place lookup:
-- nothing here reads a price of a reagent or an item the game may not have loaded yet, so the list is the same from one refresh to the
-- next. ctx = { known(id), offer(id) (optional), price (for the teaching items) }.
-- Returns rows { rec (the shape V.Learnable gives), recommend = true, needMax = the profession maximum the recipe's rank asks for,
-- rankGated = the recorded trainer window lists it as not available yet, effort = V.LEARN_EFFORT of its source }.
function V.Candidates(crafts, skill, ctx)
  local out = {}
  for _, c in ipairs(crafts) do
    local offer = ctx.offer and ctx.offer(c.id)
    local at = offer and math.max(1, offer.skill or 1) or c.learn
    if at and #c.mats > 0 and not (offer and offer.status == "used") and not (c.how and c.how.kind == "unknown" and not offer)
      and not ctx.known(c.id) then
      local way, fee, src, recommend, feeAge = obtain(c, offer, ctx)
      if recommend then
        local rec = { id = c.id, name = c.name, learn = at, src = src, out = c.out, oq = c.oq, mats = c.mats, way = way,
          d = V.EstimateColor(math.max(skill, at), at, c.y, c.g, c.gr), trainer = offer, fee = fee, feeAge = feeAge,
          npcNames = way and way.npcs, teachItem = way and way.itemID, th = { at, c.y or at + 30, c.g or at + 45, c.gr or at + 60 } }
        local kind = way and way.kind or "trainer"
        local gold = kind == "vendor" and way.vendorCost and not way.currency and not way.standing   -- a vendor, for gold, to anyone
        out[#out + 1] = { rec = rec, recommend = true, needMax = way and way.rank and RANK_MAX[way.rank] or nil,
          rankGated = at <= skill and V.WindowGated(offer, at) or nil,
          effort = kind == "trainer" and V.LEARN_EFFORT.trainer or (gold and V.LEARN_EFFORT.vendor) or V.LEARN_EFFORT.other }
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Roadmap ("Monter le métier", tab Métier): the whole way from the current skill to the maximum, and its first steps. Pure: no WoW API,
-- the caller gives everything.
--   prof = { skill, max, recipes = { [id] = rec } } (the known recipes)
--   ctx  = { buy(itemID) -> a vendor sells it, owned(itemID) = what the character owns of an item, optional how(itemID) -> where a missing
--          reagent comes from, optional bagOwned(itemID) -> the part of `owned` that is in the bags (the rest is in the bank; absent = all
--          of it is in the bags) }
--   opts = { thresholds(id) -> { orange, yellow, green, gray } of a known recipe, candidates = the rows of V.Candidates (every recipe that
--            can be learned on the way; `learn`, rows of V.Learnable, is read the same way), steps = 5 }
-- THE PLAN is the cheapest way to the maximum, in ingredients: each skill point costs the ingredients of one craft divided by its chance
-- of a point (the Classic formula), and a recipe to learn costs V.LEARN_EFFORT once, so it is learned only when it saves more than that
-- (V.Cheapest). The plan reads neither the bags, the bank nor the auction prices, and it is solved from the maximum backwards: following
-- it never changes it (the plan from a later skill is the end of the plan from an earlier one, and a recipe learned as told becomes a
-- known one that the plan already counted on).
-- THE STEPS are the first ones of that plan: a rank at the first step that starts where it can be trained (25 points below the cap it
-- lifts; a craft that would pass the cap is cut there), a recipe to learn right before the crafts that use it, with the reason (`why`), and the crafts with what is owned and what is missing. A visit to a trainer (a
-- rank, a trainer recipe) notes the later trainer recipes of the plan that can already be learned (`also`): one visit, not three.
-- Before the plan, up to V.BAG_STEPS steps use up what the bags already hold (`bonus`): a known recipe that still gives points and either
-- needs nothing the first recipe of the plan needs, or is within 15 % of it.
-- Returns { steps, path, stopped = "cap" | "steps" | "none", capped, skill, skillEnd, cap, nextRank, rankAt, rankNow, reach, target }.
--   path = the whole plan: { { kind = "rank", rank, at } | { kind = "craft", rec, from, to, times, learn = true when it is to learn } }
--   reach = the skill the plan gets to (below `target` when no recipe gives a point from there on)
--   a step is { kind = "craft", rec, d, state = "bag" | "missing", from, to, times, subs = { {item, need} }, missing = { {item, n, how} },
--     used = { [item] = n taken from what is owned }, banked = { {item, n} } (the part of `used` that is in the bank),
--     inBag = crafts the bags alone feed, bagTimes = crafts what is owned feeds, learned = learned earlier in the roadmap, bonus } or
--   { kind = "learn", rec, row, at, d, from, to (the skill range it is crafted for), why = { from, to, perPoint, alt (the best recipe
--     known by then, nil when none gives a point), altPerPoint }, also = { { rec, from, to } } } or { kind = "rank", rank, at, also }.
V.ROADMAP_STEPS = 5
V.MIN_CHANCE = 0.2   -- below this a craft is not worth a step (the chance only falls towards gray, it never reaches 0 by crafting)
V.MAX_SKILL = 300
V.BAG_STEPS = 2
-- What a recipe to learn must save, in ingredients, to be part of the plan (the trip, the fee). Estimates: a trainer is on the way, a
-- vendor selling for gold less so, and the rest (a quest, a pattern from the auction house, a vendor asking a currency, a standing or
-- an unknown price) is taken only when it saves a lot.
V.LEARN_EFFORT = { trainer = 12, vendor = 20, other = 30 }

-- Chance of a skill point at `s` from the thresholds { orange, yellow, green, gray } (the Classic formula, as V.Chance).
local function chanceAt(th, s)
  if s >= th[4] then return 0 end
  if s < th[2] then return 1 end
  return (th[4] - s) / (th[4] - th[2])
end
V.ChanceAt = chanceAt

-- Thresholds the plan uses for a known recipe: the real ones, else a guess around the colour the game showed at `skill` (yellow, green and
-- gray offsets from it), so a recipe without data lasts a few points only.
local GUESS = { [0] = { 10, 25, 40 }, [1] = { -10, 10, 25 }, [2] = { -25, -10, 10 } }
local function planTh(rec, th, skill)
  if th and th[2] and th[3] and th[4] then return th end
  local g = GUESS[rec.d or 0]
  if not g then return { 0, 0, 0, 0 } end
  return { 0, skill + g[1], skill + g[2], skill + g[3] }
end

-- Ingredients one craft takes, whatever the bags hold: a reagent a vendor sells counts half, one a known recipe makes (and that is neither
-- sold nor gathered) counts as its own reagents.
local GATHERED = { skin = true, herb = true, ore = true }
local function planUnits(rec, ctx, byOut)
  local function weight(id) return (ctx.buy and ctx.buy(id)) and 0.5 or 1 end
  local n = 0
  for _, m in ipairs(rec.mats or {}) do
    local sub, made = byOut[m[1]], 0
    if sub and sub ~= rec and weight(m[1]) == 1 and not GATHERED[ctx.how and ctx.how(m[1]) or ""] then
      for _, sm in ipairs(sub.mats or {}) do made = made + sm[2] * weight(sm[1]) end
      made = made / math.max(sub.oq or 1, 1)
    end
    n = n + m[2] * (made > 0 and made or weight(m[1]))
  end
  return n
end

-- The cheapest way from `start` to `target`. list = { { id, th, units (ingredients per craft), lo (the skill it can be used from),
-- entry (what learning it costs, 0 for a known recipe) } }. A recipe is usable at a skill when it can be learned by then and its chance of
-- a point is at least V.MIN_CHANCE; where no recipe reaches that chance, the ones with any chance bridge the hole, if it ends on a usable
-- recipe or on the target. Where nothing gives a point the plan stops (`reach`).
-- Solved backwards: cost[s][i] = what recipe i costs for the point s -> s + 1, plus the cheaper of staying on it and switching to the best
-- recipe at s + 1 (its `entry` included). Ties go to the lowest id, so the answer is the same whatever skill it is asked from.
-- Returns { reach, first(s) -> the entry of `list` the plan uses at s, path(s) -> { { r = entry, from, to, crafts } } from s on }.
function V.Cheapest(list, start, target)
  local strict, any = {}, {}
  for s = start, target do strict[s], any[s] = 0, 0 end
  local function mark(t, a, b)
    if a >= b or a >= target then return end
    t[a] = t[a] + 1
    if b <= target then t[b] = t[b] - 1 end
  end
  for _, r in ipairs(list) do
    local a = math.max(r.lo, start)
    mark(strict, a, r.eS)
    mark(any, a, r.eA)
  end
  for s = start + 1, target do strict[s], any[s] = strict[s] + strict[s - 1], any[s] + any[s - 1] end
  local low, reach, s = {}, target, start
  while s < target do
    if strict[s] > 0 then
      s = s + 1
    else
      local h = s
      while h < target and strict[h] == 0 and any[h] > 0 do h = h + 1 end
      if h == s or (h < target and strict[h] == 0) then reach = s; break end   -- nothing gives a point at s, or the hole leads nowhere
      for k = s, h - 1 do low[k] = true end
      s = h
    end
  end
  local act = {}
  for k = start, reach - 1 do act[k] = {} end
  for i, r in ipairs(list) do
    for k = math.max(r.lo, start), math.min(r.eA, reach) - 1 do
      if k < r.eS or low[k] then local t = act[k]; t[#t + 1] = i end
    end
  end
  local cost, bestV, bestI = {}, { [reach] = 0 }, {}
  for k = reach - 1, start, -1 do
    local row, nextRow, nextBest = {}, cost[k + 1], bestV[k + 1]
    local bv, bi = math.huge, nil
    for _, i in ipairs(act[k]) do
      local r = list[i]
      local stay = k + 1 == reach and 0 or (nextRow and nextRow[i])
      local c = r.units / chanceAt(r.th, k) + ((stay and stay < nextBest) and stay or nextBest)
      row[i] = c
      local v = c + r.entry
      if v < bv or (v == bv and r.id < list[bi].id) then bv, bi = v, i end
    end
    cost[k], bestV[k], bestI[k] = row, bv, bi
  end
  local function path(from)
    local segs, seg, i = {}, nil, bestI[from]
    for k = from, reach - 1 do
      if not seg or seg.r ~= list[i] then
        seg = { r = list[i], from = k, crafts = 0 }
        segs[#segs + 1] = seg
      end
      seg.to, seg.crafts = k + 1, seg.crafts + 1 / chanceAt(list[i].th, k)
      if k + 1 < reach then
        local stay, nv, ni = cost[k + 1][i], bestV[k + 1], bestI[k + 1]
        if not stay or nv < stay or (nv == stay and list[ni].id < list[i].id) then i = ni end
      end
    end
    return segs
  end
  return { reach = reach, path = path, first = function(k) return bestI[k] and list[bestI[k]] or nil end }
end

function V.Roadmap(prof, ctx, opts)
  opts = opts or {}
  local maxSteps = opts.steps or V.ROADMAP_STEPS
  local start = math.floor((prof.skill or 0) + 0.5)
  local result = { steps = {}, path = {}, skill = start, cap = prof.max, nextRank = NEXT_RANK[prof.max or 0],
    rankAt = prof.max and prof.max - 25 or nil }
  result.capped = prof.max ~= nil and start >= prof.max
  if result.capped then result.stopped, result.skillEnd = "cap", result.skill; return result end
  -- the ranks on the way: each can be trained 25 points below the cap it lifts
  local ranks, cap = {}, prof.max
  while cap and NEXT_RANK[cap] do
    ranks[#ranks + 1] = { at = math.max(start, cap - 25), rank = NEXT_RANK[cap], cap = cap + 75 }
    cap = cap + 75
  end
  local target = cap or V.MAX_SKILL
  result.target = target
  if result.nextRank and start >= result.rankAt then result.rankNow = true end

  -- the recipes of the plan: the known ones, usable now, and the ones to learn, from the skill (and the rank) they ask for
  local byOut = {}
  for _, rec in pairs(prof.recipes or {}) do if rec.out then byOut[rec.out] = rec end end
  local list, seen = {}, {}
  local function add(rec, th, lo, entry, row)
    local units = planUnits(rec, ctx, byOut)
    if units <= 0 or lo >= th[4] then return end
    local eS = th[4]
    if th[4] > th[2] then eS = math.min(th[4], math.floor(th[4] - V.MIN_CHANCE * (th[4] - th[2]) + 1e-9) + 1) end
    list[#list + 1] = { rec = rec, id = rec.id, th = th, units = units, lo = lo, eS = eS, eA = th[4], entry = entry, known = entry == 0, row = row }
  end
  for _, rec in pairs(prof.recipes or {}) do
    seen[rec.id] = true
    add(rec, planTh(rec, opts.thresholds and opts.thresholds(rec.id), start), start, 0)
  end
  for _, row in ipairs(opts.candidates or opts.learn or {}) do
    local rec = row.rec
    if not seen[rec.id] and row.recommend ~= false and not row.unpriced and not row.gray and rec.th and rec.learn then
      seen[rec.id] = true
      local lo = math.max(rec.learn, start)
      if row.needMax and (prof.max or math.huge) < row.needMax then
        lo = math.max(lo, row.needMax - 100)                         -- the rank that gives this maximum is trained 100 points below it
      elseif row.rankGated then
        lo = result.nextRank and math.max(lo, result.rankAt) or math.huge
      end
      local kind = rec.way and rec.way.kind or "trainer"
      add(rec, rec.th, lo, row.effort or V.LEARN_EFFORT[kind] or V.LEARN_EFFORT.other, row)
    end
  end
  local plan = V.Cheapest(list, start, target)
  result.reach = plan.reach
  local function costAt(r, s)
    local p = chanceAt(r.th, s)
    return p > 0 and r.units / p or math.huge
  end

  -- the stock the steps draw from: what is owned (bags + bank), the bags first
  local bag, inBags = {}, {}
  local function owned(id)
    if bag[id] == nil then bag[id] = ctx.owned and ctx.owned(id) or 0 end
    return bag[id]
  end
  local function inBagsLeft(id)
    if inBags[id] == nil then inBags[id] = math.min(owned(id), ctx.bagOwned and ctx.bagOwned(id) or math.huge) end
    return inBags[id]
  end
  local function order(p, q)
    if (p.n or p.need) ~= (q.n or q.need) then return (p.n or p.need) > (q.n or q.need) end
    return p.item < q.item
  end
  local function craftStep(r, from, to, times, bonus)
    local rec = r.rec
    local step = { kind = "craft", rec = rec, d = V.ColorAt(from, r.th), from = from, to = to, times = times, used = {}, bonus = bonus,
      learned = not r.known or nil }
    local missing, subs, banked, full, fromBags = {}, {}, {}, times, times
    for _, m in ipairs(rec.mats) do
      local item, have, need = m[1], owned(m[1]), m[2] * times
      local take = math.min(have, need)
      local bagTake = math.min(inBagsLeft(item), take)
      full, fromBags = math.min(full, math.floor(have / m[2])), math.min(fromBags, math.floor(inBagsLeft(item) / m[2]))
      bag[item], inBags[item] = have - take, inBagsLeft(item) - bagTake
      if take > 0 then step.used[item] = (step.used[item] or 0) + take end
      if take > bagTake then banked[#banked + 1] = { item = item, n = take - bagTake } end
      if take < need then
        local how = ctx.how and ctx.how(item) or nil   -- a reagent you gather (Light Leather) is gathered, not crafted from scraps
        if byOut[item] and byOut[item] ~= rec and not GATHERED[how or ""] then subs[#subs + 1] = { item = item, need = need - take }
        else missing[#missing + 1] = { item = item, n = need - take, how = how } end
      end
    end
    table.sort(missing, order)
    table.sort(subs, order)
    table.sort(banked, order)
    step.bagTimes, step.inBag, step.state = full, fromBags, full == times and "bag" or "missing"
    step.missing, step.subs, step.banked = missing, subs, banked
    return step
  end

  local trained, ri = prof.max or math.huge, 1        -- the cap of the rank held as the steps go, the next rank of `ranks` to place
  local events, learned = {}, {}                      -- the plan in order: ranks, recipes to learn, crafts
  local function byTrainer(r) return (r.rec.way and r.rec.way.kind or "trainer") == "trainer" end
  local segs
  -- why a recipe is learned: against the best recipe known by the skill it is used from (the known ones and the ones learned before it)
  local function why(si)
    local seg, alt, altCost = segs[si], nil, math.huge
    local function try(r)
      local c = costAt(r, seg.from)
      if r ~= seg.r and c < math.huge and (c < altCost or (c == altCost and r.id < alt.id)) then alt, altCost = r, c end
    end
    for _, r in ipairs(list) do if r.known then try(r) end end
    for j = 1, si - 1 do try(segs[j].r) end
    return { from = seg.from, to = seg.to, perPoint = costAt(seg.r, seg.from), alt = alt and alt.rec or nil, altPerPoint = alt and altCost or nil }
  end
  -- at a trainer (a rank, a trainer recipe): the later trainer recipes of the plan that can be learned by then, a note on that step
  -- (`also`). Their own step stays where they are first crafted, so nothing moves once the visit is done.
  local function visit(si, skill)
    local also = {}
    for j = si, #segs do
      local r = segs[j].r
      local need = r.row and r.row.needMax
      if not r.known and not learned[r.id] and byTrainer(r) and segs[j].from > skill and (r.rec.learn or math.huge) <= skill
        and not (r.row and r.row.rankGated) and (not need or need <= trained) then
        also[#also + 1] = { rec = r.rec, from = segs[j].from, to = segs[j].to }
      end
    end
    return #also > 0 and also or nil
  end
  local function learn(si, skill)
    local seg = segs[si]
    local r = seg.r
    learned[r.id] = true
    events[#events + 1] = { kind = "learn", rec = r.rec, row = r.row, at = skill, d = V.ColorAt(math.max(skill, r.rec.learn or skill), r.th),
      from = seg.from, to = seg.to, why = why(si), also = byTrainer(r) and visit(si + 1, skill) or nil }
  end
  local function rankEvents(si, skill)                -- the ranks that can be trained by `skill` and are not placed yet
    while ranks[ri] and ranks[ri].at <= skill do
      trained = ranks[ri].cap
      events[#events + 1] = { kind = "rank", rank = ranks[ri].rank, at = skill, also = visit(si, skill) }
      ri = ri + 1
    end
  end

  -- what the bags already hold, before the plan: a known recipe that still gives points and needs nothing the first recipe of the plan
  -- needs, or, when the bags cannot feed that first recipe at all, one within 15 % of it
  local limit = result.rankNow and ranks[1].cap or trained
  local at, skip, bagSteps = start, {}, {}
  while #bagSteps < V.BAG_STEPS and at < limit do
    local first, firstMats = plan.first(at), {}
    for _, m in ipairs(first and first.rec.mats or {}) do firstMats[m[1]] = true end
    local firstFed = first ~= nil and first.known and V.Craftable(first.rec, owned) >= 1
    local best, bestCost
    for _, r in ipairs(list) do
      if r.known and r ~= first and not skip[r] and chanceAt(r.th, at) >= V.MIN_CHANCE and V.Craftable(r.rec, owned) >= 1 then
        local c, free = costAt(r, at), true
        for _, m in ipairs(r.rec.mats) do if firstMats[m[1]] then free = false end end
        if (free or (first and not firstFed and c <= costAt(first, at) * 1.15))
          and (not best or c < bestCost or (c == bestCost and r.id < best.id)) then
          best, bestCost = r, c
        end
      end
    end
    if not best then break end
    skip[best] = true
    local times, skill, n = V.Craftable(best.rec, owned), at, 0
    while n < times and skill < limit do
      local p = chanceAt(best.th, math.floor(skill))
      if p < V.MIN_CHANCE then break end
      skill, n = skill + p, n + 1
    end
    local to = math.min(math.floor(skill + 0.5), limit)
    if n > 0 and to > at then                         -- a step must move the skill: less than one point is not a step
      bagSteps[#bagSteps + 1] = craftStep(best, at, to, n, true)
      at = to
    end
  end

  -- the plan from there: the rank that can be trained now (and what to learn at that visit) comes before the bags
  segs = plan.path(at)
  if result.rankNow then rankEvents(1, start) end
  local head = #events
  for si, seg in ipairs(segs) do
    local r, a = seg.r, seg.from
    while a < seg.to do
      rankEvents(si, a)
      if not r.known and not learned[r.id] then learn(si, a) end
      local b, crafts = seg.to, 0
      -- a craft that would pass the cap of the rank held stops where the next rank can be trained; otherwise the rank waits for the
      -- next step that starts at or above that skill (often a recipe to learn at the same trainer)
      if ranks[ri] and b > ranks[ri].cap - 75 then b = ranks[ri].at end
      for k = a, b - 1 do crafts = crafts + 1 / chanceAt(r.th, k) end
      events[#events + 1] = { kind = "craft", r = r, from = a, to = b, times = math.max(1, math.ceil(crafts - 1e-9)) }
      a = b
    end
  end
  rankEvents(#segs + 1, plan.reach)

  local steps = result.steps
  local function show(e)
    if #steps >= maxSteps then return false end
    steps[#steps + 1] = e.kind == "craft" and not e.rec and craftStep(e.r, e.from, e.to, e.times) or e
    return true
  end
  local full = false
  for i, e in ipairs(events) do
    if i == head + 1 then for _, b in ipairs(bagSteps) do full = full or not show(b) end end
    full = full or not show(e)
    result.path[i] = e.kind == "craft" and { kind = "craft", rec = e.r.rec, from = e.from, to = e.to, times = e.times, learn = not e.r.known or nil } or e
  end
  if #events == head then for _, b in ipairs(bagSteps) do full = full or not show(b) end end
  result.stopped = full and "steps" or (plan.reach >= target and "cap") or "none"
  result.skillEnd = at
  for _, s in ipairs(steps) do if s.kind == "craft" then result.skillEnd = math.max(result.skillEnd, s.to) end end
  return result
end

-- State of the "Fabriquer" button of the recommended recipe. s = { times = how many can be crafted from the bags,
-- open = the profession's window is open (and ready), combat, crafting = a craft is in progress }.
-- Returns { state, enabled, action }: state is busy, combat, none (nothing craftable), closed (window not open: the
-- button opens it) or ready; action is "craft" or "open" when a click does something.
function V.CraftButton(s)
  if s.crafting then return { state = "busy", enabled = false } end
  if s.combat then return { state = "combat", enabled = false } end
  if (s.times or 0) < 1 then return { state = "none", enabled = false } end
  if not s.open then return { state = "closed", enabled = true, action = "open" } end
  return { state = "ready", enabled = true, action = "craft" }
end
