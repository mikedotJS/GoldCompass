-- Where to learn a recipe: picks the trainer, vendor or quest giver to go to. Pure Lua, no WoW API.
-- Data: ns.Trainers, ns.NPCs, ns.RecipeWhere (Data/Locations.lua) and ns.MapIDs (Data/Zones.lua). All of it is
-- original Classic data, NOT confirmed on Forever: every answer is a hint to check.
--
-- env = { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs,
--         faction = "A" | "H", continent = "K" | "E" | nil (where the player is),
--         dist = function(mapID, x, y) -> number | nil (distance from the player, same continent only) }
local _, ns = ...

local Wh = {}
ns.Where = Wh

-- Trainer rank needed to be taught a recipe of a given learn skill: Journeyman trainers teach up to skill 150, Expert
-- ones up to 225, Artisan ones the rest (rank 0 = specialisation trainers, never used here).
-- `rank` (optional) is the rank name of the Forever table (Apprentice, Journeyman, Expert, Artisan): trainers listed here
-- are Journeyman or better (1, 2, 3), so an Apprentice recipe needs any of them.
local RANKS = { Apprentice = 1, Journeyman = 1, Expert = 2, Artisan = 3 }
function Wh.NeededRank(learn, rank) return RANKS[rank] or (learn <= 150 and 1 or (learn <= 225 and 2 or 3)) end

-- Picks the best candidate { name, zone, x, y }: same continent as the player first, then the nearest one (unknown
-- distances last), then by name so the answer is stable. Candidates in a zone with no map ID are skipped.
local function pick(candidates, env)
  local best, bestKey
  for _, c in ipairs(candidates) do
    local map = env.maps[c.zone]
    if map and c.x > 0 and c.y > 0 then
      local key = { (env.continent == nil or map[2] == env.continent) and 0 or 1,
        env.dist and env.dist(map[1], c.x, c.y) or math.huge, c.name }
      if not bestKey or key[1] < bestKey[1] or (key[1] == bestKey[1] and (key[2] < bestKey[2]
        or (key[2] == bestKey[2] and key[3] < bestKey[3]))) then
        best, bestKey = { name = c.name, zone = c.zone, mapID = map[1], x = c.x, y = c.y }, key
      end
    end
  end
  return best
end

-- Target for a recipe to learn: { name, zone, mapID, x, y } (a place to pin), or { text = "..." } when only a free-text
-- description exists (or nothing: text = nil, "lieu non précis"). `prof` is the English profession name of the data.
-- "Name (Zone), Name (Zone)" of wowforever.be -> { { name, zone }, ... }
function Wh.ParseVendors(text)
  local out = {}
  for name, zone in (text or ""):gmatch("%s*([^,()]+)%s*%(([^)]*)%)") do
    out[#out + 1] = { name = name:match("^%s*(.-)%s*$"), zone = zone }
  end
  return out
end

-- Every target has a `kind`: "pin" (an exact position), "zone" (a vendor whose zone has a map but no coordinates: open that map)
-- or "text" (the free text, or nothing: the caller words it).
function Wh.Target(rec, prof, env)
  -- a trainer window recorded in game beats the Classic coordinates: the NPC and where it really stands
  local seen = rec.trainer
  if seen and seen.mapID and seen.x and seen.y then
    return { name = seen.npc, zone = seen.zone or "", mapID = seen.mapID, x = seen.x, y = seen.y, recorded = true, kind = "pin" }
  end
  if rec.src == nil then
    local rank, found = Wh.NeededRank(rec.learn or 0, rec.way and rec.way.rank), {}
    for _, t in ipairs(env.trainers[prof] or {}) do
      if t[6] >= rank and (t[5] == nil or t[5] == env.faction) then found[#found + 1] = { name = t[1], zone = t[2], x = t[3], y = t[4] } end
    end
    local best = pick(found, env)
    if best then best.kind = "pin"; return best end
    return { kind = "text" }
  end
  -- vendors and quest givers: the NPC names of LibProfessionDB (rec.npcNames, no coordinates there) and of the
  -- Classic "where" text, both looked up in the Classic NPC positions
  local info = not (rec.way and rec.way.site) and env.where[rec.id] or nil   -- Classic texts do not apply to what the site observed
  local names, found = {}, {}
  for _, n in ipairs(rec.npcNames or {}) do names[#names + 1] = n end
  for i = 2, #(info or {}) do names[#names + 1] = info[i] end
  local siteVendors = Wh.ParseVendors(rec.way and rec.way.where)
  for _, v in ipairs(siteVendors) do names[#names + 1] = v.name end
  for _, name in ipairs(names) do
    local n = env.npcs[name]
    if n and (n[4] == nil or n[4] == env.faction) then found[#found + 1] = { name = name, zone = n[1], x = n[2], y = n[3] } end
  end
  local best = pick(found, env)
  if best then best.kind = "pin"; return best end
  -- no coordinates anywhere: the "NPC (Zone)" of wowforever.be, as a zone to open when its map is known
  local where = rec.way and rec.way.where
  if where then
    -- only the vendors the player's faction can use: the Classic NPC table knows the faction of many of them (unknown: kept)
    local list = {}
    for _, v in ipairs(siteVendors) do
      local n = env.npcs[v.name]
      if not (n and n[4] ~= nil and n[4] ~= env.faction) then
        v.mapID = env.maps[v.zone] and env.maps[v.zone][1]
        list[#list + 1] = v
      end
    end
    if #list > 0 then
      for _, v in ipairs(list) do   -- the first vendor whose zone has a map: open it
        if v.mapID then return { name = v.name, zone = v.zone, mapID = v.mapID, vendors = list, kind = "zone" } end
      end
      return { name = list[1].name, zone = list[1].zone, vendors = list, text = where, kind = "text" }
    end
  end
  return { text = info and info[1] or nil, kind = "text" }
end
