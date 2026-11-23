-- Static effort of one unit of a reagent, for the levelling plan (Leveling.lua). Pure Lua: no WoW API, unit tested outside the game.
-- The unit is the minutes it takes at the addon's own pace (ZoneRank, SkinRank: 60 nodes or beasts an hour). The effort depends on the
-- static data only (vendors, nodes, beasts, loot tables, recipes): no price, no bag, no bank, so the plan is the same from one day to the next.
-- For each item the LOWEST of the sources it has counts:
--   vendor   a vendor with unlimited stock: 0.25 for 10c up to 0.5 for 50s, whatever it costs more
--   gathered a node: 0.5 (two items a node) at the zone with the most points, slower where the zone has fewer than 100 points
--   skinned  a beast: 1 / what a skin gives in the zone with the most spawns (slower below 100 spawns)
--   crafted  one of the recipes that makes it: the effort of its reagents, divided by what it makes
--   drop     100 / its chance (%); a drop whose chance is not known counts the median one, and only when nothing else is known
--   unknown  1
local _, ns = ...

local E = {}
ns.Effort = E

E.VENDOR_BASE, E.VENDOR_CAP = 0.25, 0.5   -- 10c, and the most a vendor item weighs (50s and more)
E.YIELD = 2                               -- items one node gives (Forever's own yield is not known)
E.PACE_SPOTS = 100                        -- spawn points under which the zone is slower to work
E.CAP = 10                                -- the most a gathered, skinned or drop item weighs
E.UNKNOWN = 1

-- static = { sources = ns.ReagentSources, gather = ns.GatherSources, skin = ns.SkinZones,
--            recipes = { [item made] = { { mats = { { item, n }, ... }, oq = n made }, ... } } }
-- Returns E(itemID), the effort of one unit (E.UNKNOWN when nothing is known about the item).
function E.Reagents(static)
  local sources, gather, skin, recipes = static.sources or {}, static.gather or {}, static.skin or {}, static.recipes or {}

  -- skinning: items per skin, in the zone where it is best, with the pace of the zone (beasts weighed by their spawn points)
  local skinned = {}
  for _, beasts in pairs(skin) do
    local total, per = 0, {}
    for _, b in ipairs(beasts) do
      local w = math.max(b.spots or 0, b.foreverSpots or 0)
      total = total + w
      for _, it in ipairs(b.items or {}) do
        if it[2] then per[it[1]] = (per[it[1]] or 0) + w * it[2] end
      end
    end
    for item, s in pairs(per) do
      local rate = s / math.max(total, 1) * math.min(1, total / E.PACE_SPOTS)
      if rate > (skinned[item] or 0) then skinned[item] = rate end
    end
  end

  -- the chance of a drop that has none: the median of the known ones
  local chances = {}
  for _, src in pairs(sources) do
    for _, d in ipairs(src.drops or {}) do if d[4] then chances[#chances + 1] = d[4] end end
  end
  table.sort(chances)
  local dropDefault = chances[math.floor(#chances / 2) + 1] or 50

  local done, busy, loops = {}, {}, 0
  local function effort(item)
    if done[item] then return done[item] end
    if busy[item] then loops = loops + 1; return E.UNKNOWN end   -- A makes B, B makes A: the second visit counts as unknown
    busy[item] = true
    local before = loops
    local src = sources[item]
    local best, priced, unlimited
    for _, v in ipairs(src and src.vendors or {}) do
      if v[7] and v[7] > 0 then
        priced = math.min(priced or v[7], v[7])
        if not v.limited then unlimited = true end
      end
    end
    local list = {}
    if priced and unlimited then
      list[#list + 1] = math.min(E.VENDOR_CAP, E.VENDOR_BASE + 0.25 * math.log(math.max(priced, 10) / 10) / math.log(500))
    end
    if skinned[item] then list[#list + 1] = math.min(E.CAP, 1 / skinned[item]) end
    if gather[item] then
      local points = 0
      for _, z in ipairs(gather[item].zones or {}) do points = math.max(points, z[2] or 0, z[3] or 0) end
      list[#list + 1] = math.min(E.CAP, (1 / E.YIELD) / math.max(0.05, math.min(1, points / E.PACE_SPOTS)))
    end
    for _, r in ipairs(recipes[item] or {}) do
      local sum = 0
      for _, m in ipairs(r.mats) do sum = sum + m[2] * effort(m[1]) end
      list[#list + 1] = sum / math.max(r.oq or 1, 1)
    end
    local chance
    for _, d in ipairs(src and src.drops or {}) do if d[4] then chance = math.max(chance or 0, d[4]) end end
    if chance then list[#list + 1] = math.min(E.CAP, 100 / chance)
    elseif src and src.drops and #src.drops > 0 and #list == 0 then list[1] = 100 / dropDefault end
    for _, w in ipairs(list) do if not best or w < best then best = w end end
    busy[item] = nil
    best = best or E.UNKNOWN
    -- a value reached inside a loop depends on where the walk entered it: only the item the walk started from is kept
    if loops == before or not next(busy) then done[item] = best end
    return best
  end

  -- every reagent in id order, so the answer never depends on the order the plan asks in
  local ids, seen = {}, {}
  for _, list in pairs(recipes) do
    for _, r in ipairs(list) do
      for _, m in ipairs(r.mats) do if not seen[m[1]] then seen[m[1]] = true; ids[#ids + 1] = m[1] end end
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do effort(id) end
  return effort
end
