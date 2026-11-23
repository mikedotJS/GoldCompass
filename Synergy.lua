-- Hints that connect the professions: "ton Dépeçage : ~35 bêtes, Les Tarides" under a reagent the Métier tab says is missing, "Sert à ton
-- Travail du cuir : ..." on the gathering profession's tab, "À farmer d'abord" on the shopping list. VIEW ONLY: this module reads the finished
-- roadmaps (their missing lines) and the character's gathering skills, and returns text and numbers. It never writes into a roadmap, never
-- enters the profession cache and never changes a plan; ns.char.routeZone is only read (RouteMap.Plan owns it). Pure Lua: the data comes in
-- through `data`, so the tests give their own.
--
-- The rule, for one item and one gathering profession the character has: every zone where some beast or node the skill reaches (gray ones
-- too: they still give the item) gives it is a candidate; its rate is pace x min(1, spots / 100) x items per action (the model of SkinRank
-- and ZoneRank, Classic yields: estimates, always written with "~"). The zone the gathering roadmap already sends the player to is kept
-- while its rate is at least half of the best one; else the best zones are ordered as the roadmap orders them (Route.Order).
local _, ns = ...

local SY = {}
ns.Synergy = SY

SY.MAX_HOURS = 2   -- above this a farm is "rare", no itinerary
SY.STAY = 0.5      -- the roadmap's zone is kept while it yields at least this share of the best zone's rate
SY.TTL = 120       -- seconds a zone choice is kept (counts and measured yields move slowly)

-- the gathering professions: English name (the key of ns.Skills) -> skill line
SY.LINES = { ["Skinning"] = 393, ["Herb Gathering"] = 182, ["Mining"] = 186 }
local KIND = { ["Herb Gathering"] = "herb", ["Mining"] = "ore" }

-- ---------------------------------------------------------------------------------------------------------------------
-- What the data gives: which item comes from which profession.

-- data = {
--   skinZones = ns.SkinZones, nodes = ns.GatherNodes,
--   counts = function() -> { [zone] = { [nodeID] = spots } },
--   yields = function(beast) -> { { itemID, perSkin } } (measured in game, else the Classic list; default beast.items),
--   bar = function(itemID) -> { ore = itemID, per = ore per craft, out = bars per craft } | nil,
--   routeZone = function(english) -> the zone the roadmap sends to | nil,
--   order = function() -> the ctx of Route.Order | nil, price = function(itemID) -> copper | nil, now = function() -> seconds,
-- }
local indexes = setmetatable({}, { __mode = "k" })
local function index(data)
  local ix = indexes[data]
  if ix then return ix end
  ix = { skin = {}, node = {} }   -- skin[item] = true when a beast gives it, node[item] = the node type that gives it
  for _, beasts in pairs(data.skinZones or {}) do
    for _, b in ipairs(beasts) do
      for _, it in ipairs(b.items or {}) do if it[2] then ix.skin[it[1]] = true end end
    end
  end
  for _, node in pairs(data.nodes or {}) do
    if node.item and node.skill and (node.type == "Herb Gathering" or node.type == "Mining") then ix.node[node.item] = node.type end
  end
  indexes[data] = ix
  return ix
end

-- Candidate zones for an item: { { zone, rate (items per hour), per (items per action), pace (actions per hour), ids } }.
local function candidates(item, prof, skill, data)
  local D = ns.ZoneRank.DEFAULTS
  local out = {}
  local function add(zone, spots, v, ids)
    if v <= 0 then return end
    local pace = D.pace * math.min(1, spots / D.paceFullSpots)
    local per = v / spots
    table.sort(ids, function(a, b) return a.id < b.id end)
    out[#out + 1] = { zone = zone, rate = pace * per, per = per, pace = pace, ids = ids }
  end
  if prof == "Skinning" then
    for zone, beasts in pairs(data.skinZones or {}) do
      local spots, v, ids = 0, 0, {}
      for _, b in ipairs(beasts) do
        local w = math.max(b.spots or 0, b.foreverSpots or 0)
        if w > 0 and b[5] <= skill then
          spots = spots + w
          for _, it in ipairs(data.yields and data.yields(b) or b.items or {}) do
            if it[1] == item and it[2] and it[2] > 0 then v = v + w * it[2]; ids[#ids + 1] = { id = b[1] } end
          end
        end
      end
      if spots > 0 then add(zone, spots, v, ids) end
    end
  else
    local nodes = data.nodes or {}
    for zone, per in pairs(data.counts and data.counts() or {}) do
      local spots, v, ids = 0, 0, {}
      for id, n in pairs(per) do
        local node = nodes[id]
        if node and node.type == prof and node.item and node.skill and n > 0 and skill >= node.skill then
          spots = spots + n
          if node.item == item then v = v + n * (node.yield or 1); ids[#ids + 1] = { id = id } end
        end
      end
      if spots > 0 then add(zone, spots, v, ids) end
    end
  end
  return out
end

-- The zone to farm an item in, kept per (item, skill, routeZone) for SY.TTL seconds. nil = no zone gives it at this skill.
local caches = setmetatable({}, { __mode = "k" })
local function choice(item, prof, skill, data)
  local stay = data.routeZone and data.routeZone(prof) or nil
  local cache = caches[data]
  if not cache then cache = {}; caches[data] = cache end
  local key = item .. ":" .. skill .. ":" .. (stay or 0)
  local now = (data.now or time)()
  local hit = cache[key]
  if hit and now - hit.at < SY.TTL then return hit.value or nil end
  local list = candidates(item, prof, skill, data)
  local best = 0
  for _, c in ipairs(list) do best = math.max(best, c.rate) end
  local pool, picked = {}, nil
  for _, c in ipairs(list) do
    if c.rate >= SY.STAY * best then
      pool[#pool + 1] = { zone = c.zone, spots = c.rate, c = c }   -- Route.Order sorts by `spots`: the rate here
      if c.zone == stay then picked = c end
    end
  end
  if not picked and #pool > 0 then
    ns.Route.Order(pool, data.order and data.order() or {})
    picked = pool[1].c
  end
  if picked then
    picked = { zone = picked.zone, per = picked.per, pace = picked.pace, ids = picked.ids, here = picked.zone == stay,
      ah = data.price and data.price(item) ~= nil or false }
  end
  cache[key] = { at = now, value = picked or false }
  return picked
end

-- The hint for `n` units of an item, or nil: the character lacks the gathering profession, no zone gives the item at the skill, or no data.
-- { kind = "skin" | "herb" | "ore" | "bar", prof = English name, zone, count (actions), hours, rare (over MAX_HOURS), here (the roadmap's zone),
--   ah (an auction price is known), ids (the beasts or nodes that give it, for the itinerary), ore = { item, n } for a bar }
function SY.Hint(item, n, skills, data)
  if not (item and n and n >= 1) then return nil end
  local ix = index(data)
  local need, ore, bar, barItem = n, nil, nil, item
  if not ix.skin[item] and not ix.node[item] then
    bar = data.bar and data.bar(item)
    if not (bar and ix.node[bar.ore] == "Mining") then return nil end
    ore = { item = bar.ore, n = math.ceil(n / (bar.out or 1)) * bar.per }
    item, need = bar.ore, ore.n
  end
  local prof = ix.skin[item] and "Skinning" or ix.node[item]
  local skill = prof and skills and skills[prof]
  if not skill then return nil end
  local c = choice(item, prof, skill, data)
  if not c then return nil end
  local count = math.ceil(need / c.per - 1e-9)
  local hours = count / c.pace
  local ah = c.ah
  if bar and data.price and data.price(barItem) ~= nil then ah = true end   -- the bar's own auction price first, the ore's (c.ah) when unknown
  return { kind = bar and "bar" or (KIND[prof] or "skin"), prof = prof, zone = c.zone, count = count, hours = hours, rare = hours > SY.MAX_HOURS,
    here = c.here, ah = ah, ids = c.ids, ore = ore }
end

-- The professions of `profs` (ns.RunLeveling entries) the character's gathering feeds, as { [skill line] = { { prof, units, items =
-- { { item, name, n } } } } }: the missing reagents of every other roadmap that a hint exists for, summed per profession.
local function feeds(profs, hint)
  local out = {}
  for _, p in ipairs(profs) do
    local road = p.road
    if road and not road.capped and not road.gathering then
      local mine = {}
      for _, s in ipairs(road.steps or {}) do
        if s.kind == "craft" then
          for _, list in ipairs({ s.missing or {}, s.subs or {} }) do
            for _, m in ipairs(list) do
              local n = m.n or m.need
              local h = n and hint(m.item, n)
              if h then
                local row = mine[h.prof] or { prof = p.name, units = 0, items = {}, by = {} }
                mine[h.prof] = row
                local e = row.by[m.item]
                if not e then e = { item = m.item, name = m.name or tostring(m.item), n = 0 }; row.by[m.item] = e; row.items[#row.items + 1] = e end
                e.n, row.units = e.n + n, row.units + n
              end
            end
          end
        end
      end
      for english, row in pairs(mine) do
        row.by = nil
        table.sort(row.items, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.item < b.item end)
        local line = SY.LINES[english]
        out[line] = out[line] or {}
        table.insert(out[line], row)
      end
    end
  end
  for _, list in pairs(out) do
    table.sort(list, function(a, b) if a.units ~= b.units then return a.units > b.units end return a.prof < b.prof end)
  end
  return out
end

-- profs = ns.RunLeveling entries, skills = ns.Skills(), data as above (a persistent table: the zone choices are cached in it).
-- Returns { hint = function(item, n) -> hint | nil, feeds = { [skill line] = { { prof, units, items } } } }. A failure inside `hint` is
-- reported once through data.log and answers nil: the screen stays as without hints.
function SY.Build(profs, skills, data)
  local function hint(item, n)
    local ok, h = pcall(SY.Hint, item, n, skills, data)
    if ok then return h end
    if data.log then data.log(tostring(h)) end
  end
  return { hint = hint, feeds = feeds(profs or {}, hint) }
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Text (French strings come in as S, the zone and item names through `names`): never an arrow, check mark or ellipsis (Latin-1 font).

-- "~40 min" under an hour (never "~60 min"), else "~2 h". Only the text is rounded: `rare` is decided on the raw hours.
local function duration(hours, S)
  local minutes = math.max(1, math.floor(hours * 60 + 0.5))
  if minutes < 60 then return S.syn_minutes:format(minutes) end
  return S.syn_hours:format(math.floor(hours + 0.5))
end

-- "bête" for one, "bêtes" otherwise.
local function unit(kind, count, S) return S.syn_unit[kind][count == 1 and 1 or 2] end

-- The dim line under a missing reagent: "ton Dépeçage : ~35 bêtes, Les Tarides (ta zone)", or "rare au dépeçage (~400 bêtes, ~7 h) · plutôt à l'HV".
-- names = { zone = function(zoneID) -> text, item = function(itemID) -> text }
function SY.Line(h, S, names)
  local u = unit(h.kind, h.count, S)
  if h.rare then return S.syn_rare[h.kind]:format(h.count, u, duration(h.hours, S)) .. (h.ah and S.syn_ah or "") end
  local zone = names.zone(h.zone) .. (h.here and S.syn_here or "")
  if h.kind == "bar" then return S.syn_line.bar:format(h.ore.n, names.item(h.ore.item), h.count, u, zone) end
  return S.syn_line[h.kind]:format(h.count, u, zone)
end

-- The short form of a shopping-list row: "ton Dépeçage · ~35 bêtes · Les Tarides", "rare au dépeçage (~7 h)".
function SY.Short(h, S, names)
  if h.rare then return S.syn_rare_row[h.kind]:format(duration(h.hours, S)) end
  return S.syn_row[h.kind]:format(h.count, unit(h.kind, h.count, S), names.zone(h.zone))
end

-- "Sert pour Travail du cuir : 26 × Cuir léger, 14 × Peau légère", or with several professions "Sert pour Travail du cuir (40) et Ingénierie (12)".
function SY.FeedsText(list, S)
  if not list or #list == 0 then return nil end
  if #list == 1 then
    local parts = {}
    for i = 1, math.min(3, #list[1].items) do parts[i] = S.syn_feed_item:format(list[1].items[i].n, list[1].items[i].name) end
    return S.syn_feeds_one:format(list[1].prof, table.concat(parts, ", ") .. (#list[1].items > 3 and (", " .. S.shop_more:format(#list[1].items - 3)) or ""))
  end
  local parts = {}
  for i, row in ipairs(list) do parts[i] = S.syn_feed_prof:format(row.prof, row.units) end
  local last = table.remove(parts)
  return S.syn_feeds_many:format(#parts > 0 and (table.concat(parts, ", ") .. S.syn_and .. last) or last)
end

-- "À farmer d'abord : Les Tarides (Dépeçage, ~1 h)".
function SY.FarmText(farm, S, names)
  return S.shop_farm:format(names.zone(farm.zone), S.prof_names[farm.prof] or farm.prof, duration(farm.hours, S))
end
