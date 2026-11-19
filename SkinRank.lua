-- Skinning gold per hour per zone, from Data/ForeverSkinZones.lua. Pure Lua: no WoW API, unit tested outside the game.
-- Same prices, rows and statuses as ZoneRank.Rank, so the window can show skinning like the gathering professions.
local _, ns = ...

local ZR = ns.ZoneRank
local SR = {}
ns.SkinRank = SR

-- Assumptions, NOT verified on Forever:
SR.DEFAULTS = setmetatable({
  pace = 60,           -- beasts killed and skinned per hour (one a minute, travel and fights included), the same for everyone
  paceFullSpots = 100, -- zones with fewer known spawn points (Classic or Forever-seen, the higher) get a proportionally lower pace
}, { __index = ZR.DEFAULTS })

-- Spawn weight of a beast: its Classic spawn points, or the points players saw in Forever when they saw more.
local function weight(beast)
  return math.max(beast.spots or 0, beast.foreverSpots or 0)
end

-- input = {
--   zones  = ns.SkinZones,
--   skill  = the player's skinning skill (nil = no skinning: nothing skinnable),
--   price, vendor, ageKnown, constants: as in ZoneRank.Rank,
-- }
-- Returns what ZoneRank.Rank returns. Each row also has noYield = true when a beast gives an item whose yield is unknown (counted 0).
-- Beasts whose skill is above the player's are left out. A zone's value per skin is the spawn-weighted average over its beasts.
function SR.Rank(input)
  local c = setmetatable(input.constants or {}, { __index = SR.DEFAULTS })
  local ageKnown = input.ageKnown ~= false
  local skill = input.skill or -1
  local rows, anyAhPrice, anyOld = {}, false, false

  for zoneID, beasts in pairs(input.zones) do
    local spots, total = 0, 0
    local old, stale, unseen, unpriced, noYield, maxAge = false, false, false, false, false, nil
    local contribution, unitOf = {}, {}
    for _, beast in ipairs(beasts) do
      local w = weight(beast)
      if beast[5] <= skill and w > 0 then
        spots = spots + w
        for _, it in ipairs(beast.items) do
          local item, perSkin = it[1], it[2]
          if not perSkin then
            noYield = true
          else
            local unit, kind, age = ZR.UnitValue(item, input.price, input.vendor, c, ageKnown)
            local value = w * perSkin * unit
            total = total + value
            contribution[item] = (contribution[item] or 0) + value
            unitOf[item] = unit
            if kind == "fresh" or kind == "old" then anyAhPrice = true end
            if kind == "old" then old = true end
            if kind == "stale" then stale = true elseif kind == "unseen" then unseen = true elseif kind == "none" then unpriced = true end
            if age and (not maxAge or age > maxAge) then maxAge = age end
          end
        end
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
        items = items, detail = detail, old = old, partial = stale or unseen or unpriced or noYield, maxAge = maxAge,
        stale = stale, unseen = unseen, unpriced = unpriced, noYield = noYield,
      }
    end
  end

  table.sort(rows, function(a, b)
    if a.copperPerHour ~= b.copperPerHour then return a.copperPerHour > b.copperPerHour end
    return a.zone < b.zone
  end)
  while #rows > c.maxRows do rows[#rows] = nil end
  if #rows == 0 then return { status = "no_nodes", rows = rows, unknownSpots = 0 } end
  if not anyAhPrice then return { status = "no_scan", rows = rows, unknownSpots = 0 } end
  return { status = "ok", rows = rows, unknownSpots = 0, anyOld = anyOld }
end
