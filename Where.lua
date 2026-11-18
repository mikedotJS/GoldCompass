-- Where to learn a recipe: picks the trainer, vendor or quest giver to go to. Pure Lua, no WoW API.
-- Data: ns.Npcs / ns.NpcByName / ns.NpcTrainers (Data/Npcs.lua, pfQuest: spawn positions and faction of the NPCs we can point to),
-- ns.Trainers, ns.NPCs, ns.RecipeWhere (Data/Locations.lua, the older fallback) and ns.MapIDs (Data/Zones.lua). All of it is
-- original Classic data, NOT confirmed on Forever: every answer is a hint to check; positions recorded in game win.
--
-- env = { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs,
--         db = ns.Npcs, byName = ns.NpcByName, ntrainers = ns.NpcTrainers, recorded = ns.db.npcs (npcID -> { name, mapID, x, y, f }),
--         contOf = { [uiMapID] = "K" | "E" },
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
    local mapID, cont
    if c.mapID then                                   -- a candidate of the NPC database: its map is known
      mapID, cont = c.mapID, env.contOf and env.contOf[c.mapID]
    else
      local map = env.maps[c.zone]
      mapID, cont = map and map[1], map and map[2]
    end
    if mapID and c.x > 0 and c.y > 0 then
      local key = { (env.continent == nil or cont == nil or cont == env.continent) and 0 or 1,
        env.dist and env.dist(mapID, c.x, c.y) or math.huge, c.name }
      if not bestKey or key[1] < bestKey[1] or (key[1] == bestKey[1] and (key[2] < bestKey[2]
        or (key[2] == bestKey[2] and key[3] < bestKey[3]))) then
        best, bestKey = { name = c.name, zone = c.zone, mapID = mapID, x = c.x, y = c.y, id = c.id, fr = c.fr, recorded = c.recorded }, key
      end
    end
  end
  return best
end

-- Can this faction letter ("A", "H", "AH", nil = unknown) be used by the player's faction?
local function fits(fac, faction) return fac == nil or fac == "AH" or fac:find(faction, 1, true) ~= nil end

-- Positions of one NPC: what the player recorded in game wins over pfQuest's spawns. Second result: the NPC's faction.
local function spawnsOf(id, env)
  local rec, npc = env.recorded and env.recorded[id], env.db[id]
  local name, fr, fac = npc and npc[1], npc and npc[4], npc and npc[2]
  if rec and rec.mapID and rec.x then
    return { { id = id, name = rec.name or name, fr = fr, mapID = rec.mapID, x = rec.x, y = rec.y, recorded = true } }, fac or rec.f
  end
  local out = {}
  for _, s in ipairs(npc and npc[3] or {}) do out[#out + 1] = { id = id, name = name, fr = fr, mapID = s[1], x = s[2], y = s[3] } end
  return out, fac
end

-- NPC ids of an English name; when the text gave a zone, the ones that spawn there (several NPCs can share a name).
local function idsOfName(name, zone, env)
  local ids = env.byName and env.byName[name] or {}
  local map = zone and env.maps[zone]
  if map and #ids > 1 then
    local out = {}
    for _, id in ipairs(ids) do
      for _, s in ipairs(select(1, spawnsOf(id, env))) do if s.mapID == map[1] then out[#out + 1] = id; break end end
    end
    if #out > 0 then return out end
  end
  return ids
end

-- Candidate spawns of these NPC ids for the player's faction, and whether NPCs of the other faction were left out.
local function fromDb(ids, env)
  local cands, other = {}, false
  for _, id in ipairs(ids) do
    local sp, fac = spawnsOf(id, env)
    if #sp > 0 then
      if fits(fac, env.faction) then for _, s in ipairs(sp) do cands[#cands + 1] = s end else other = true end
    end
  end
  return cands, other
end

-- "uniquement côté <faction>": the faction that CAN use the NPCs, when only the other faction's were found.
local function onlyFor(env) return env.faction == "H" and "A" or "H" end

-- Trainer rank (0 Apprentice only, 1 Journeyman, 2 Expert, 3 Artisan) a trainer of the NPC database needs for a recipe.
local TOPS = { Apprentice = 0, Journeyman = 1, Expert = 2, Artisan = 3 }
local function neededTop(rec)
  local rank = rec.way and rec.way.rank
  if TOPS[rank] then return TOPS[rank] end
  local learn = rec.learn or 0
  return learn < 50 and 0 or learn < 125 and 1 or learn < 200 and 2 or 3
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
    if env.db then   -- the NPC database: nearest trainer of the player's faction whose rank covers the recipe
      local ids, top = {}, neededTop(rec)
      for _, t in ipairs(env.ntrainers and env.ntrainers[prof] or {}) do if t[2] >= top then ids[#ids + 1] = t[1] end end
      local cands, other = fromDb(ids, env)
      local best = pick(cands, env)
      if best then best.kind = "pin"; return best end
      if other then return { kind = "text", onlyFaction = onlyFor(env) } end
    end
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
  -- a drop has no NPC: the drop zone of the site, and the map of that zone when it is known
  local way = rec.way
  if way and way.zone and (way.kind == "drop" or way.kind == "container" or way.kind == "item") then
    for part in way.zone:gmatch("[^,]+") do
      local zone = part:match("^%s*(.-)%s*$")
      if env.maps[zone] then return { zone = zone, mapID = env.maps[zone][1], kind = "zone", dropZone = true } end
    end
  end
  if env.db then   -- the NPC database: the NPCs the sources name (library ids, the site's vendors, the Classic names), by faction
    local ids, taken = {}, {}
    local function add(id) if not taken[id] then taken[id] = true; ids[#ids + 1] = id end end
    for _, id in ipairs(way and way.ids or {}) do add(id) end
    for _, v in ipairs(siteVendors) do for _, id in ipairs(idsOfName(v.name, v.zone, env)) do add(id) end end
    for _, n in ipairs(rec.npcNames or {}) do for _, id in ipairs(idsOfName(n, nil, env)) do add(id) end end
    for i = 2, #(info or {}) do for _, id in ipairs(idsOfName(info[i], nil, env)) do add(id) end end
    local cands, other = fromDb(ids, env)
    local best = pick(cands, env)
    if best then best.kind = "pin"; return best end
    if other then return { kind = "text", onlyFaction = onlyFor(env) } end
  end
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
