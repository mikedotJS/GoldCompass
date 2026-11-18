-- The only file that talks to GatherMate2 (GatherMate:GetNodesForZone, PLAN.md section 3 S2).
local _, ns = ...

local N = {}
ns.Nodes = N

local TYPES = { "Mining", "Herb Gathering" } -- GatherMate2 node types, as in its Constants.lua
local MAX_MAP_ID = 3000                       -- GatherMate2 has no zone list to ask for, so every map ID is tried

function N.Installed() return GatherMate2 ~= nil and GatherMate2.GetNodesForZone ~= nil end

-- Counts the known spots per node and zone, ignoring the player's GatherMate display filters.
-- Returns { [zoneMapID] = { [nodeID] = spots } } and the total number of spots.
function N.Counts()
  local zones, total = {}, 0
  for _, nodeType in ipairs(TYPES) do
    for zone = 1, MAX_MAP_ID do
      for _, nodeID in GatherMate2:GetNodesForZone(zone, nodeType, true) do
        local z = zones[zone]
        if not z then z = {}; zones[zone] = z end
        z[nodeID] = (z[nodeID] or 0) + 1
        total = total + 1
      end
    end
  end
  return zones, total
end

function N.ZoneName(zoneID)
  local info = C_Map and C_Map.GetMapInfo(zoneID)
  return info and info.name or ("#" .. zoneID)
end
