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

-- Evaluates one recipe. Returns { rec, chance, color, cost, result, net, perPoint, missing = { itemIDs }, noSale, floor }
-- (floor = a reagent was valued at its vendor sell value, so the cost is a lower bound).
-- net = reagents - best sale value of the output (negative when crafting earns money); perPoint = net / chance;
-- resale = the profit exists only if the crafted item is sold at the auction house; ahSale = the sale value is an AH price
-- (saleAge: its age in days when known; noAge: the price addon cannot date it, so it may not win a money ranking);
-- oldAh = an AH price exists but is older than the configured old days (the vendor value is used instead: "prix HV ancien");
-- profit = -net, the money one craft makes (negative = it costs); uncertain = the sale price is undated or older than the fresh days.
function V.Evaluate(rec, ctx)
  local chance = V.CHANCE[rec.d] or 0
  local cost, missing, floor = 0, {}, false
  for _, m in ipairs(rec.mats or {}) do
    local unit, isFloor = buyCost(m[1], ctx)
    if unit then cost = cost + unit * m[2]; floor = floor or isFloor else missing[#missing + 1] = m[1] end
  end
  local result, noSale, ahSale, saleAge, oldAh = 0, true, false, nil, false
  if rec.out then
    local unit, kind, age = ZR.UnitValue(rec.out, ctx.price, ctx.vendor, ZR.DEFAULTS, ctx.ageKnown ~= false)
    result, noSale, ahSale = unit * (rec.oq or 1), kind == "none", kind == "fresh" or kind == "old"
    if ahSale and ctx.ageKnown ~= false then saleAge = age end
    oldAh = kind == "stale" and ctx.price(rec.out) ~= nil
  end
  local net = cost - result
  return { rec = rec, chance = chance, color = V.COLOR[rec.d] or "?", cost = cost, result = result, net = net,
    perPoint = chance > 0 and net / chance or nil, missing = missing, noSale = noSale, floor = floor,
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
  for _, rec in pairs(prof.recipes or {}) do
    known = known + 1
    local e = V.Evaluate(rec, ctx)
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
    if count then
      if math.abs(a.points - b.points) > 1e-9 then return a.points > b.points end
    elseif a.rec.d ~= b.rec.d then
      return a.rec.d < b.rec.d
    end
    if a.uncertain ~= b.uncertain then return not a.uncertain end        -- within a colour, reliable figures first
    if a.perPoint ~= b.perPoint then return a.perPoint < b.perPoint end
    return a.rec.id < b.rec.id
  end)
  table.sort(unpriced, function(a, b) return a.rec.id < b.rec.id end)
  while limit and #rows > limit do rows[#rows] = nil end
  local best, second = rows[1], nil
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
      local rec = { id = c.id, name = c.name, learn = at, src = src, out = c.out, oq = c.oq, mats = c.mats, way = way,
        d = V.EstimateColor(math.max(skill, at), at, c.y, c.g, c.gr), trainer = offer, fee = fee, feeAge = feeAge,
        npcNames = way and way.npcs, teachItem = way and way.itemID }
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
      local e = V.Evaluate(rec, own)
      e.recommend = recommend
      e.target = place
      -- how sure the place is: 0 a position seen on Forever, 1 a hint (Classic position or a zone), 2 text only
      e.placeRank = place and ((place.kind == "pin" and place.confirmed) and 0 or ((place.kind == "pin" or place.kind == "zone") and 1 or 2)) or 2
      e.priceKnown = (way and way.kind == "quest") or fee ~= nil          -- the price of learning it is known in gold
      e.useful = math.max(1, (c.gr or at + 60) - math.max(skill, at))      -- skill points it stays useful for from now
      -- a trainer recipe whose rank the character has not trained yet (ctx.maxSkill = profession maximum)
      e.rankGated = ctx.maxSkill and way and way.rank and ctx.maxSkill < (RANK_MAX[way.rank] or 0) or false
      if offer and offer.status == "unavailable" and isNow then e.rankGated = true end   -- the trainer window itself says it cannot be learned yet
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
  table.sort(now, byLearnRank)
  table.sort(soon, byLearnRank)
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
  -- a recipe whose learning price is known in gold comes before one whose price is unknown (currency, item, not in the data)
  for _, known in ipairs({ true, false }) do
    for _, gated in ipairs({ false, true }) do
      for _, e in ipairs(now) do
        if e.recommend and not e.unpriced and e.rankGated == gated and e.priceKnown == known and (not best or better(e, best)) then best = e end
      end
      if best then break end
    end
    if best then break end
  end
  local gain = (best and not best.floor and knownBest and rankValue(best) < knownBest) and (knownBest - rankValue(best)) or nil
  return { now = now, soon = soon, gray = gray, best = best, gain = gain, candidates = candidates, unpriced = unpriced,
    nowTotal = nowTotal, soonTotal = soonTotal, books = books, beyond = beyond, otherFaction = otherFaction }
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
