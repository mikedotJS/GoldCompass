-- "Où monter" for the gathering professions: which zones still give skill points, the steps up to the next rank, and the loop
-- through the known spots of a zone. Pure Lua: no WoW API, so it is unit tested outside the game.
-- Skill-up colours follow the Classic rule of CMaNGOS (NOT verified on Forever): with `req` the skill a node or beast needs, a gather
-- is orange below req + 25, yellow below req + 50, green below req + 100, gray after (no skill point). Below req it cannot be done.
local _, ns = ...

local R = {}
ns.Route = R

R.STEPS = 3        -- steps shown at most (zones and the rank together)
R.FOCUS = 5        -- beasts of a zone the skinning route is built on (the most numerous ones)
R.NAMES = 2        -- names written on the dim line of a step
R.MAX_POINTS = 12  -- points of a loop at most
R.MIN_FOREVER = 4  -- points players saw in Forever from which a skinning step leaves its Classic points out
R.FAR = 4          -- a zone whose lowest level is more than this above the player's goes last (as the map tab does)

-- 0 orange, 1 yellow, 2 green, 3 gray, nil = the skill is below the requirement.
function R.Color(skill, req)
  if skill < req then return nil end
  local d = skill - req
  return d < 25 and 0 or d < 50 and 1 or d < 100 and 2 or 3
end

local function bySpots(a, b)
  if a.spots ~= b.spots then return a.spots > b.spots end
  return a.id < b.id
end

-- Zones of Herb Gathering or Mining that still give skill points at `skill`.
-- counts = { [zoneID] = { [nodeID] = known spots } }, nodes = ns.GatherNodes.
-- Returns { { zone, spots, nodes = { { id, spots } best first }, last = the skill where the best node turns gray } }, in no particular order.
function R.GatherZones(prof, skill, nodes, counts)
  local out = {}
  for zone, per in pairs(counts) do
    local z
    for id, n in pairs(per) do
      local node = nodes[id]
      local c = node and node.type == prof and node.skill and n > 0 and R.Color(skill, node.skill)
      if c and c < 3 then
        z = z or { zone = zone, spots = 0, nodes = {}, last = 0 }
        z.spots = z.spots + n
        z.nodes[#z.nodes + 1] = { id = id, spots = n }
        z.last = math.max(z.last, node.skill + 100)
      end
    end
    if z then
      table.sort(z.nodes, bySpots)
      out[#out + 1] = z
    end
  end
  return out
end

-- Zones of Skinning that still give skill points at `skill`: the one place to change when the beast data changes shape.
-- skinZones = ns.SkinZones: { [zoneID] = { { npcID, name, lvMin, lvMax, skill, spots, foreverSpots }, ... } }; a beast weighs
-- max(spots, foreverSpots). Returns { { zone, spots, beasts = { { id, name, lo, hi, spots } best first, FOCUS at most, the ones named
-- and counted }, all = every beast that still gives points (the route goes through all their known points), lo, hi (levels of
-- the beasts), last } }.
function R.SkinZones(skill, skinZones)
  local out = {}
  for zone, list in pairs(skinZones) do
    local beasts = {}
    for _, b in ipairs(list) do
      local w = math.max(b.spots or 0, b.foreverSpots or 0)
      local c = w > 0 and R.Color(skill, b[5])
      if c and c < 3 then beasts[#beasts + 1] = { id = b[1], name = b[2], lo = b[3], hi = b[4], spots = w, last = b[5] + 100 } end
    end
    if #beasts > 0 then
      table.sort(beasts, bySpots)
      local z = { zone = zone, spots = 0, beasts = {}, all = beasts, last = 0 }
      for i = 1, math.min(R.FOCUS, #beasts) do
        local b = beasts[i]
        z.beasts[i] = b
        z.spots = z.spots + b.spots
        z.lo = math.min(z.lo or b.lo, b.lo)
        z.hi = math.max(z.hi or b.hi, b.hi)
        z.last = math.max(z.last, b.last)
      end
      out[#out + 1] = z
    end
  end
  return out
end

-- Best zone first. ctx = { level = player level, continent = "K" | "E" | nil, contOf = function(zoneID) -> "K" | "E" | nil,
-- lowest = function(zoneID) -> lowest level of the zone | nil }. Order: zones far above the player's level last, the player's
-- continent first (unknown continent between, the other one last), then the most known spots, then the map ID so the answer is stable.
function R.Order(list, ctx)
  local function key(z)
    local lo = ctx.lowest and ctx.lowest(z.zone)
    local far = (lo and ctx.level and lo - ctx.level > R.FAR) and 1 or 0
    local cont = ctx.contOf and ctx.contOf(z.zone)
    local side = (ctx.continent == nil or cont == ctx.continent) and 0 or (cont == nil and 1 or 2)
    return far, side
  end
  local keys = {}
  for _, z in ipairs(list) do keys[z] = { key(z) } end
  table.sort(list, function(a, b)
    local ka, kb = keys[a], keys[b]
    if ka[1] ~= kb[1] then return ka[1] < kb[1] end
    if ka[2] ~= kb[2] then return ka[2] < kb[2] end
    if a.spots ~= b.spots then return a.spots > b.spots end
    return a.zone < b.zone
  end)
  return list
end

-- The steps of "Où monter": up to R.STEPS of { kind = "zone", from, to, zone = <entry of lookup> } and { kind = "rank", at }.
-- input = { skill, max = skill cap of the rank, nextRank = name of the rank above or nil, capped = skill >= max,
--   rankNow = the skill already allows the next rank (rankAt reached), rankAt = skill from which the rank can be learned (max - 25),
--   lookup = function(skill) -> zones that give points at that skill, best first }.
-- A zone step runs until the skill where its best node turns gray, or until the cap; a second zone follows when that comes first.
-- The rank comes when the skill reaches rankAt, and lifts the cap by 75. At the cap only the rank step is left.
function R.Plan(input)
  local steps, cur = {}, input.skill
  if input.capped then
    if input.nextRank then steps[1] = { kind = "rank", at = cur } end
    return steps
  end
  local max = input.max or math.huge
  local function zones(to)
    while #steps < R.STEPS and cur < to do
      local z = input.lookup(cur)[1]
      if not z then return false end
      local stop = math.min(to, z.last)
      if stop <= cur then return false end
      steps[#steps + 1] = { kind = "zone", from = cur, to = stop, zone = z }
      cur = stop
    end
    return cur >= to
  end
  if input.nextRank and input.rankNow then
    steps[1] = { kind = "rank", at = cur }
    zones(max + 75)
  elseif input.nextRank then
    if zones(input.rankAt) and #steps < R.STEPS then
      steps[#steps + 1] = { kind = "rank", at = cur }
      zones(max + 75)
    end
  else
    zones(max)
  end
  -- two zone steps in a row in the same zone (another beast or herb turns gray, the zone is the same): one step
  for i = #steps, 2, -1 do
    local a, b = steps[i - 1], steps[i]
    if a.kind == "zone" and b.kind == "zone" and a.zone.zone == b.zone.zone then
      a.to = b.to
      table.remove(steps, i)
    end
  end
  -- the same zone on both sides of the rank: one zone step (stay there), the rank after it at the skill it can be learned
  for i = #steps - 1, 2, -1 do
    local a, r, b = steps[i - 1], steps[i], steps[i + 1]
    if r.kind == "rank" and a.kind == "zone" and b.kind == "zone" and a.zone.zone == b.zone.zone then
      a.to = b.to
      table.remove(steps, i + 1)
    end
  end
  return steps
end

-- The points of one beast on one map, from ns.SkinPoints[npc][map] ("<forever points>.<classic points>", 4 base-36 characters per
-- point: x then y in tenths of a percent). Returns two lists of { x, y } in percent of the map: seen in WoW Forever, Classic only.
function R.Unpack(packed)
  packed = tostring(packed or "")
  local dot = packed:find(".", 1, true)
  local function decode(s)
    local pts = {}
    for i = 1, #s - 3, 4 do
      local x, y = tonumber(s:sub(i, i + 1), 36), tonumber(s:sub(i + 2, i + 3), 36)
      if x and y then pts[#pts + 1] = { x = x / 10, y = y / 10 } end
    end
    return pts
  end
  return decode(dot and packed:sub(1, dot - 1) or packed), decode(dot and packed:sub(dot + 1) or "")
end

-- Loop through map points ({ x, y } in percent of the map): points closer than a radius are merged (the radius grows until at most
-- `max` remain), then nearest neighbour from the point closest to `start` ({ x, y } or nil: the westmost one), then 2-opt.
-- opts = { max = R.MAX_POINTS, aspect = width / height of the map (default 1) }.
-- Returns { points = { { x, y, n = spots merged } in walking order }, length = of the closed loop }.
function R.Loop(points, start, opts)
  opts = opts or {}
  local max, aspect = opts.max or R.MAX_POINTS, opts.aspect or 1
  local function dist(a, b) return math.sqrt(((a.x - b.x) * aspect) ^ 2 + (a.y - b.y) ^ 2) end
  local sorted = {}
  for i, p in ipairs(points) do sorted[i] = p end
  table.sort(sorted, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
  local clusters
  local radius = 1
  repeat
    clusters = {}
    for _, p in ipairs(sorted) do
      local hit
      for _, c in ipairs(clusters) do if dist(c, p) <= radius then hit = c; break end end
      if hit then
        hit.x, hit.y, hit.n = (hit.x * hit.n + p.x) / (hit.n + 1), (hit.y * hit.n + p.y) / (hit.n + 1), hit.n + 1
      else
        clusters[#clusters + 1] = { x = p.x, y = p.y, n = 1 }
      end
    end
    radius = radius * 1.35
  until #clusters <= max
  if #clusters == 0 then return { points = {}, length = 0 } end
  -- nearest neighbour from the point closest to the start
  local left, tour = clusters, {}
  local function take(i) tour[#tour + 1] = table.remove(left, i) end
  local first = 1
  for i, c in ipairs(left) do
    if start and dist(c, start) < dist(left[first], start) then first = i end
  end
  take(first)
  while #left > 0 do
    local last, best = tour[#tour], 1
    for i, c in ipairs(left) do if dist(c, last) < dist(left[best], last) then best = i end end
    take(best)
  end
  -- 2-opt on the closed loop, the first point fixed
  local n = #tour
  local improved = n > 3
  while improved do
    improved = false
    for i = 2, n - 1 do
      for j = i + 1, n do
        local a, b, c, d = tour[i - 1], tour[i], tour[j], tour[j % n + 1]
        if dist(a, c) + dist(b, d) < dist(a, b) + dist(c, d) - 1e-9 then
          for k = 0, math.floor((j - i + 1) / 2) - 1 do tour[i + k], tour[j - k] = tour[j - k], tour[i + k] end
          improved = true
        end
      end
    end
  end
  local length = 0
  for i = 1, n do length = length + dist(tour[i], tour[i % n + 1]) end
  if n == 1 then length = 0 end
  return { points = tour, length = length }
end
