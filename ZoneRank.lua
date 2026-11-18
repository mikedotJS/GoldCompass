-- Gold-per-hour calculation (PLAN.md section 5). Pure Lua: no WoW API, so it is unit tested outside the game.
local _, ns = ...

local ZR = {}
ns.ZoneRank = ZR

-- Constants, all stated in PLAN.md section 5 (unverified on Forever; spike S6 checks the pace).
ZR.DEFAULTS = {
  pace = 60,         -- nodes gathered per hour, the same for everyone
  paceFullSpots = 100, -- zones with fewer known spots get a proportionally lower pace
  ahCut = 0.05,      -- auction house cut taken off every sale
  freshDays = 2,     -- price age 0..2 days: used as is
  oldDays = 7,       -- 3..7 days: used, zone tagged "old"; beyond: vendor price, zone tagged "partial"
  maxRows = 10,
}

-- Value in copper of one unit of an item, and how it was obtained.
-- Returns value, kind, age. kind: "fresh" and "old" (AH price used), "stale" (AH price too old, vendor price used),
-- "unseen" (never scanned, vendor price used), "none" (nothing usable, worth 0).
function ZR.UnitValue(itemID, price, vendor, c, ageKnown)
  local copper, age = price(itemID)
  if copper then
    if not ageKnown or (age and age <= c.freshDays) then return copper * (1 - c.ahCut), "fresh", age end
    if age and age <= c.oldDays then return copper * (1 - c.ahCut), "old", age end
  end
  local v = vendor(itemID)
  if v then return v, copper and "stale" or "unseen", age end
  return 0, "none", age
end

-- input = {
--   zones  = { [zoneID] = { [nodeID] = knownSpots } },
--   nodes  = ns.GatherNodes-like table,
--   skills = { ["Mining"] = skill, ["Herb Gathering"] = skill },  (a missing profession = nothing gatherable)
--   price  = function(itemID) -> copper|nil, ageInDays|nil,
--   vendor = function(itemID) -> copper|nil,
--   ageKnown = false when the price addon cannot tell the age (default true),
--   constants = optional overrides of ZR.DEFAULTS,
-- }
-- Returns { status = "no_nodes" | "no_scan" | "ok", rows = {...}, unknownSpots = n, anyOld = bool }.
-- Each row: { zone, copperPerHour, spots, items, detail, old, partial, maxAge } where partial = stale or unseen or unpriced:
-- stale = AH price over 7 days old (vendor price used), unseen = never scanned (vendor price used), unpriced = no price at all (counted 0).
function ZR.Rank(input)
  local c = setmetatable(input.constants or {}, { __index = ZR.DEFAULTS })
  local ageKnown = input.ageKnown ~= false
  local rows, unknownSpots, anyAhPrice, anyOld = {}, 0, false, false

  for zoneID, spotsByNode in pairs(input.zones) do
    local spots, total = 0, 0
    local old, stale, unseen, unpriced, maxAge = false, false, false, false, nil
    local contribution, unitOf = {}, {}
    for nodeID, count in pairs(spotsByNode) do
      local node = input.nodes[nodeID]
      if not (node and node.item) then
        unknownSpots = unknownSpots + count
      elseif (input.skills[node.type] or -1) >= node.skill then
        local unit, kind, age = ZR.UnitValue(node.item, input.price, input.vendor, c, ageKnown)
        local value = node.yield * unit
        spots = spots + count
        total = total + count * value
        contribution[node.item] = (contribution[node.item] or 0) + count * value
        unitOf[node.item] = unit
        if kind == "fresh" or kind == "old" then anyAhPrice = true end
        if kind == "old" then old = true end
        if kind == "stale" then stale = true elseif kind == "unseen" then unseen = true elseif kind == "none" then unpriced = true end
        if age and (not maxAge or age > maxAge) then maxAge = age end
      end
    end
    if spots > 0 then
      local pace = c.pace * math.min(1, spots / c.paceFullSpots)
      local items = {}
      for item in pairs(contribution) do items[#items + 1] = item end
      table.sort(items, function(a, b)
        if contribution[a] ~= contribution[b] then return contribution[a] > contribution[b] end
        return a < b
      end)
      local detail = {}
      for i, item in ipairs(items) do detail[i] = { item = item, unit = unitOf[item] } end
      while #items > 2 do items[#items] = nil end
      anyOld = anyOld or old
      rows[#rows + 1] = {
        zone = zoneID, copperPerHour = pace * total / spots, spots = spots,
        items = items, detail = detail, old = old, partial = stale or unseen or unpriced, maxAge = maxAge,
        stale = stale, unseen = unseen, unpriced = unpriced,
      }
    end
  end

  if #rows == 0 then return { status = "no_nodes", rows = rows, unknownSpots = unknownSpots } end
  if not anyAhPrice then return { status = "no_scan", rows = rows, unknownSpots = unknownSpots } end

  table.sort(rows, function(a, b)
    if a.copperPerHour ~= b.copperPerHour then return a.copperPerHour > b.copperPerHour end
    return a.zone < b.zone
  end)
  while #rows > c.maxRows do rows[#rows] = nil end
  return { status = "ok", rows = rows, unknownSpots = unknownSpots, anyOld = anyOld }
end

-- Rounded so figures do not look more precise than they are: whole gold from 10g up, silver below.
function ZR.FormatMoney(copper)
  local silver = math.floor(copper / 100 + 0.5)
  if silver >= 1000 then return string.format("%dg", math.floor(copper / 10000 + 0.5)) end
  if silver >= 100 then return string.format("%dg %ds", math.floor(silver / 100), silver % 100) end
  if silver >= 1 then return string.format("%ds", silver) end
  return "<1s"
end

-- The amount actually shown: whole gold from 10g up, whole silver from 1s up, exact copper below, so a coin display
-- does not look more precise than the estimate (same rounding as FormatMoney).
function ZR.RoundCopper(copper)
  local silver = math.floor(copper / 100 + 0.5)
  if silver >= 1000 then return math.floor(copper / 10000 + 0.5) * 10000 end
  if silver >= 1 then return silver * 100 end
  return math.floor(copper + 0.5)
end
