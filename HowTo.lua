-- "Comment l'obtenir": the hover tooltips of the roadmap ("Ton parcours", Monter le métier). Pure Lua, no WoW API: everything the game
-- knows comes through `env` (built by ns.HowToEnv in Core.lua), so the tests give their own.
-- Data: ns.ReagentSources, ns.Skinning / ns.SkinSpots, ns.GatherSources (all ForeverDB.net, Forever-seen or Classic), ns.Ranks, ns.GatherNodes
-- and the player's own GatherMate2 counts and Auctionator price.
-- A tooltip is { title, loading, item, target, lines = { { style, text, right, gap } } }; style is one of
--   "info" (white), "head" (gold section header), "row" (white left, dim right), "dim", "click" (green last line).
-- `target` is what a click pins: { name, zone, mapID, x, y, kind = "pin" | "zone", confirmed, source }, in the shape of W.GoTo.
-- env = { faction = "A" | "H", mapID = the player's map, dist(mapID, x, y) -> number | nil, itemName(id) -> string | nil (nil = not cached),
--         owned(id), price(id) -> copper, age in days, money(copper) -> string (rounded), exact(copper) -> string (a fee, to the copper; optional), zone(mapID) -> string | nil, npcName(id, english),
--         creature(english) -> name, mapID | nil, nodeCounts() -> { [mapID] = { [gatherMateNodeID] = spots } }, npc(id) -> { name, mapID, x, y, side, seen } }
local _, ns = ...
local S = ns.S

local H = {}
ns.HowTo = H

local MAX = 3   -- vendors, beasts, zones or sources shown per section

-- Can this side ("A", "H", "AH", nil = unknown) be used by the player's faction?
local function fits(side, faction) return side == nil or side == "" or side == "AH" or side:find(faction, 1, true) ~= nil end

local function known(c) return c.mapID ~= nil and c.mapID > 0 and c.x ~= nil and c.y ~= nil and (c.x > 0 or c.y > 0) end

-- A fee or a vendor price is exact (the game's coin icons down to the copper); an auction price is an estimate (rounded).
local function exact(env, copper) return (env.exact or env.money)(copper) end

local function coords(c) return S.howto_coords:format(c.x, c.y) end

local function add(tip, style, text, right, gap)
  tip.lines[#tip.lines + 1] = { style = style, text = text, right = right, gap = gap }
end

-- Forever-seen first, then the ones with a position, then the player's own map, then the nearest (unknown distance last), then the
-- order of the data. Every candidate: { forever, mapID, x, y }.
local function sortNear(list, env)
  for i, c in ipairs(list) do
    c.i, c.f, c.nopos = i, c.forever and 0 or 1, known(c) and 0 or 1
    c.same = (c.mapID and c.mapID == env.mapID) and 0 or 1
    c.d = known(c) and env.dist and env.dist(c.mapID, c.x, c.y) or math.huge
  end
  table.sort(list, function(a, b)
    if a.f ~= b.f then return a.f < b.f end
    if a.nopos ~= b.nopos then return a.nopos < b.nopos end
    if a.same ~= b.same then return a.same < b.same end
    if a.d ~= b.d then return a.d < b.d end
    return a.i < b.i
  end)
end

local function zoneName(env, mapID) return mapID and mapID > 0 and (env.zone(mapID) or ("#" .. mapID)) or nil end

-- A place to pin from a candidate (nil when its position is unknown).
local function pinOf(env, c, name)
  if not known(c) then return end
  return { name = name, zone = zoneName(env, c.mapID), mapID = c.mapID, x = c.x, y = c.y, kind = "pin", confirmed = c.forever and true or false,
    source = c.forever and "foreverdb" or "fdbclassic" }
end

-- Two lines for one source: name and a detail, then the zone and a detail (dim). The Classic label ends the last line it concerns.
local function entry(tip, name, detail, zone, detail2, classicA, classicB)
  add(tip, "row", name, detail)
  local b = (zone or detail2) and { style = "dim", text = zone or "", right = detail2 } or nil
  if b then tip.lines[#tip.lines + 1] = b end
  local function label(line) if line.right and line.right ~= "" then line.right = line.right .. S.howto_classic else line.text = line.text .. S.howto_classic end end
  if classicA or (classicB and not b) then label(tip.lines[#tip.lines - (b and 1 or 0)]) end
  if classicB and b then label(b) end
end

local function vendors(tip, item, env)
  local src = ns.ReagentSources and ns.ReagentSources[item]
  local list = {}
  for _, v in ipairs(src and src.vendors or {}) do
    if fits(v[6], env.faction) then list[#list + 1] = { id = v[1], name = v[2], mapID = v[3], x = v[4], y = v[5], price = v[7], forever = v.forever == true } end
  end
  if #list == 0 then return end
  sortNear(list, env)
  add(tip, "head", S.howto_vendor:format(exact(env, list[1].price)), nil, true)
  for i = 1, math.min(MAX, #list) do
    local v = list[i]
    entry(tip, env.npcName(v.id, v.name), known(v) and coords(v) or nil, zoneName(env, v.mapID), nil, false, not v.forever)
  end
  return pinOf(env, list[1], env.npcName(list[1].id, list[1].name)), "vendor"
end

local function levels(lo, hi) return lo == hi and S.howto_level:format(lo) or S.howto_levels:format(lo, hi) end

local function skinning(tip, item, env)
  local beasts = ns.Skinning and ns.Skinning[item]
  if not beasts or #beasts == 0 then return end
  local list = {}
  for _, b in ipairs(beasts) do
    local spots = {}
    for _, s in ipairs(ns.SkinSpots and ns.SkinSpots[b[1]] or {}) do spots[#spots + 1] = { mapID = s[1], x = s[2], y = s[3], forever = s.forever == true } end
    sortNear(spots, env)
    local sp = spots[1] or {}
    list[#list + 1] = { id = b[1], name = b[2], lo = b[3], hi = b[4], forever = b.forever == true, spot = sp, mapID = sp.mapID, x = sp.x, y = sp.y }
  end
  sortNear(list, env)
  local shown, lo, hi = {}, math.huge, 0
  for i = 1, math.min(MAX, #list) do
    shown[i] = list[i]
    lo, hi = math.min(lo, list[i].lo), math.max(hi, list[i].hi)
  end
  add(tip, "head", lo == hi and S.howto_skin_one:format(lo) or S.howto_skin:format(lo, hi), nil, true)
  for _, b in ipairs(shown) do
    entry(tip, env.npcName(b.id, b.name), levels(b.lo, b.hi), zoneName(env, b.mapID), known(b) and coords(b) or nil, not b.forever, known(b) and not b.spot.forever)
  end
  local first = shown[1]
  return pinOf(env, first.spot, env.npcName(first.id, first.name)), "spot"
end

-- GatherMate2 node IDs of an item (Data/GatherNodes.lua) and their type.
local function nodesOf(item)
  local ids, kind = {}, nil
  for id, n in pairs(ns.GatherNodes or {}) do
    if n.item == item then ids[#ids + 1], kind = id, n.type end
  end
  return ids, kind
end

local function gathering(tip, item, env)
  local gs = ns.GatherSources and ns.GatherSources[item]
  if not gs then return end
  local ids, kind = nodesOf(item)
  local herb = kind == "Herb Gathering"
  local node = gs.nodes and gs.nodes[1]
  add(tip, "head", herb and S.howto_herb or S.howto_ore, nil, true)
  local nodeName = (herb and env.itemName(item)) or (node and node[1]) or ""
  if node then add(tip, "info", S.howto_node:format(nodeName, node[2] or 0)) end
  -- the player's own GatherMate2 spots first (richest first), then the zones Forever players saw it in
  local mine, taken, rows = {}, {}, {}
  local bestOf = {}
  for _, z in ipairs(gs.zones or {}) do bestOf[z[1]] = z end
  if #ids > 0 then
    for mapID, byNode in pairs(env.nodeCounts()) do
      local n = 0
      for _, id in ipairs(ids) do n = n + (byNode[id] or 0) end
      if n > 0 then mine[#mine + 1] = { mapID = mapID, n = n } end
    end
  end
  table.sort(mine, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.mapID < b.mapID end)
  for _, m in ipairs(mine) do
    if #rows < MAX then
      local z = bestOf[m.mapID]
      rows[#rows + 1] = { mapID = m.mapID, text = S.howto_own:format(m.n), best = z and z.best, confirmed = z ~= nil and (z[2] or 0) > 0 }
    end
    taken[m.mapID] = true
  end
  local rest = {}
  for _, z in ipairs(gs.zones or {}) do
    if not taken[z[1]] and (z[2] or 0) + (z[3] or 0) > 0 then rest[#rest + 1] = z end
  end
  table.sort(rest, function(a, b)
    if (a[2] or 0) ~= (b[2] or 0) then return (a[2] or 0) > (b[2] or 0) end
    if (a[3] or 0) ~= (b[3] or 0) then return (a[3] or 0) > (b[3] or 0) end
    return a[1] < b[1]
  end)
  for _, z in ipairs(rest) do
    if #rows < MAX then
      local seen = (z[2] or 0) > 0
      rows[#rows + 1] = { mapID = z[1], text = (seen and S.howto_forever:format(z[2]) or S.howto_classic_pts:format(z[3] or 0)), best = z.best,
        confirmed = seen, classic = not seen }
    end
  end
  for _, r in ipairs(rows) do add(tip, "row", zoneName(env, r.mapID), r.text .. (r.classic and S.howto_classic or "")) end
  local first = rows[1]
  if not first then return end
  local best = first.best
  return { name = nodeName, zone = zoneName(env, first.mapID), mapID = first.mapID, x = best and best[1], y = best and best[2],
    kind = best and "pin" or "zone", confirmed = first.confirmed, source = first.confirmed and "foreverdb" or "fdbclassic" }, "zone"
end

local function drops(tip, item, env)
  local src = ns.ReagentSources and ns.ReagentSources[item]
  local list = {}
  for i, d in ipairs(src and src.drops or {}) do list[#list + 1] = { name = d[1], chance = d[4], forever = d[3] == true, i = i } end
  if #list == 0 then return end
  table.sort(list, function(a, b) if a.forever ~= b.forever then return a.forever end return a.i < b.i end)
  add(tip, "head", S.howto_drops, nil, true)
  for i = 1, math.min(MAX, #list) do
    local d = list[i]
    local name, mapID = env.creature(d.name)
    local zone = zoneName(env, mapID)
    add(tip, "row", zone and (name .. " · " .. zone) or name, (d.chance and S.howto_chance:format(math.floor(d.chance + 0.5)) or "") .. (d.forever and "" or S.howto_classic))
  end
end

local function quest(tip, item, env)
  local q = ns.ReagentSources and ns.ReagentSources[item] and ns.ReagentSources[item].quest
  if not q or not fits(q[3], env.faction) then return end
  add(tip, "head", S.howto_quest, nil, true)
  add(tip, "row", (q[2] or 0) > 0 and S.howto_quest_level:format(q[1], q[2]) or q[1], q[4] and "" or S.howto_classic)
end

-- "scan il y a 2 h": Auctionator gives the age in days.
local function scanText(age)
  if not age then return S.howto_scan_none end
  local hours = age * 24
  if hours < 1 then return S.howto_scan_min end
  if hours < 24 then return S.howto_scan_h:format(math.floor(hours + 0.5)) end
  return S.howto_scan_d:format(math.floor(age + 0.5))
end

local function auction(tip, item, env)
  local price, age = env.price(item)
  if not price or price <= 0 then return end
  add(tip, "head", S.howto_ah, nil, true)
  add(tip, "row", S.howto_ah_price:format(env.money(price)), scanText(age))
end

-- Tooltip of a missing reagent. `make` = { name, mats = { { itemID, n } } }: the recipe that crafts it, when the character knows one.
function H.Reagent(item, need, env, make)
  local name = env.itemName(item)
  local tip = { item = item, loading = name == nil, title = name or S.howto_loading, lines = {} }
  add(tip, "info", S.howto_missing:format(need or 0, env.owned(item) or 0))
  local before = #tip.lines
  for _, section in ipairs({ vendors, skinning, gathering }) do
    local target, key = section(tip, item, env)
    if target and not tip.target then tip.target, tip.clickKey = target, key end
  end
  drops(tip, item, env)
  quest(tip, item, env)
  auction(tip, item, env)
  if make then
    local mats = {}
    for _, m in ipairs(make.mats or {}) do mats[#mats + 1] = S.howto_mat:format(m[2], env.itemName(m[1]) or S.item_unknown:format(m[1])) end
    add(tip, "info", S.howto_make:format(make.name, table.concat(mats, ", ")), nil, true)
  end
  if #tip.lines == before then add(tip, "dim", S.howto_unknown, nil, true) end
  if tip.target then add(tip, "click", S.howto_click:format(S["howto_click_" .. tip.clickKey]), nil, true) end
  return tip
end

-- What a learn or rank step needs, for H.Step: { title, kind, who, head, note, target, price, priceText, prof, skill, level, standing }.
local KIND = { trainer = "trainer", vendor = "vendor", quest = "quest" }
function H.LearnSpec(rec, name, target, prof)
  local way = rec.way or {}
  local spec = { title = name, kind = KIND[way.kind] or "other", target = target, prof = prof, skill = rec.learn, who = target and target.name,
    whoFr = target and target.fr }
  if way.kind == "vendor" and (way.vendorCost or way.currency) then spec.priceText = ns.Fmt.VendorPrice(way)
  elseif (rec.fee or 0) > 0 then spec.price = rec.fee
  elseif (way.cost or 0) > 0 then spec.price = way.cost end
  spec.standing = way.standing and (S.standings[way.standing] or way.standing) or nil
  if spec.kind == "other" then spec.head = ns.Fmt.Source(rec, true) end
  return spec
end

-- The rank that lifts the cap, from ns.Ranks (Data/ForeverRanks.lua): its requirements, and for a book or a quest the vendor or giver the
-- player's faction can use. `trainer` = the target Where.Target found for the trainer (kept for a trainer rank).
function H.RankSpec(line, rank, env, trainer, prof)
  local found
  for _, r in ipairs(ns.Ranks and ns.Ranks[line] or {}) do if r[1] == rank then found = r end end
  local spec = { title = S.howto_rank:format(S.rank_names[rank] or rank), kind = "trainer", target = trainer, prof = prof, skill = found and found[2],
    level = found and found[3], who = trainer and trainer.name, whoFr = trainer and trainer.fr }
  local way = found and found.way
  if way and way.kind == "book" then
    local cands = {}
    for _, v in ipairs(way.vendors or {}) do
      local npc = env.npc(v[1])
      if npc and fits(npc.side, env.faction) then
        cands[#cands + 1] = { name = npc.name, mapID = npc.mapID, x = npc.x, y = npc.y, forever = npc.seen, price = v[2] }
      end
    end
    sortNear(cands, env)
    local best = cands[1]
    if best then
      spec.kind, spec.who, spec.whoFr, spec.price, spec.target = "vendor", best.name, nil, best.price, pinOf(env, best, best.name) or trainer
      spec.note = S.howto_book:format(env.itemName(way.itemID) or (ns.ItemNames and ns.ItemNames[way.itemID]) or S.item_unknown:format(way.itemID))
    end
  elseif way and way.kind == "quest" then
    local npc = env.npc(way.npc)
    if npc then
      spec.kind, spec.who, spec.whoFr, spec.note = "quest", npc.name, nil, way.quest
      spec.target = pinOf(env, { mapID = npc.mapID, x = npc.x, y = npc.y, forever = npc.seen }, npc.name) or trainer
    end
  end
  return spec
end

-- Tooltip of a learn or rank step: who teaches it, where, what it costs and requires, and whether the position was seen on Forever.
function H.Step(spec, env)
  local tip = { title = spec.title, lines = {}, target = spec.target }
  local t = spec.target
  local kind = S.howto_kind[spec.kind] or S.howto_kind.other
  local who = (env.fr and spec.whoFr) or spec.who
  add(tip, "head", spec.head or (who and (kind .. " · " .. who)) or kind)
  if spec.note then add(tip, "info", spec.note) end
  local pin = t and t.mapID and t.x and t.y
  if t and t.mapID then
    add(tip, "row", env.zone(t.mapID) or t.zone or "", pin and coords(t) or nil)
  elseif t and t.text then
    add(tip, "dim", t.text)
  end
  local price = spec.priceText or (spec.price and spec.price > 0 and exact(env, spec.price)) or nil
  if price then add(tip, "row", S.howto_price, price) end
  if spec.skill and spec.skill > 0 then add(tip, "row", S.howto_req, S.howto_req_skill:format(spec.prof or "", spec.skill)) end
  if spec.level then add(tip, "row", S.howto_req_level, tostring(spec.level)) end
  if spec.standing then add(tip, "row", S.howto_req_rep, spec.standing) end
  if pin then add(tip, "dim", t.confirmed and S.howto_confirmed or S.howto_classic_pos) end
  if t and t.mapID then
    add(tip, "click", S.howto_click:format(S["howto_click_" .. (spec.kind == "trainer" and "trainer" or spec.kind == "vendor" and "merchant" or "place")]), nil, true)
  end
  return tip
end
