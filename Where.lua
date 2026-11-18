-- Where to learn a recipe: picks the trainer, vendor or quest giver to go to. Pure Lua, no WoW API.
-- Data: ns.Npcs / ns.NpcByName / ns.NpcTrainers (Data/Npcs.lua, pfQuest: spawn positions and faction of the NPCs we can point to),
-- ns.Trainers, ns.NPCs, ns.RecipeWhere (Data/Locations.lua, the older fallback) and ns.MapIDs (Data/Zones.lua): original Classic
-- data, NOT confirmed on Forever. ns.FdbNpcs / ns.FdbVendors / ns.FdbTrainers (Data/ForeverNpcs.lua, ForeverDB.net) are Forever's:
-- where vendors and trainers stand (with a "seen in Forever" flag), which vendors sell a recipe, who trains a profession.
-- A target is `confirmed` only when its position was seen on Forever (ForeverDB) or recorded in game by the player; Classic
-- positions are kept as unconfirmed hints, ranked after the confirmed ones. With the Forever data loaded (env.fdb), an NPC that
-- only Classic data names is never pinned, and an NPC ForeverDB does not list for the recipe or the profession is never proposed.
--
-- env = { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs,
--         db = ns.Npcs, byName = ns.NpcByName, ntrainers = ns.NpcTrainers, recorded = ns.db.npcs (npcID -> { name, mapID, x, y, f }),
--         fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors, fdbTrainers = ns.FdbTrainers,
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

-- Picks the best candidate { name, zone, x, y }: a position confirmed on Forever first, then the same continent as the player,
-- then the nearest one (unknown distances last), then by name so the answer is stable. Candidates in a zone with no map ID are skipped.
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
      -- continent: the player's own first, then a map whose continent is unknown (the new Forever zones), then the other one
      local key = { c.confirmed and 0 or 1, (env.continent == nil or cont == env.continent) and 0 or (cont == nil and 1 or 2),
        env.dist and env.dist(mapID, c.x, c.y) or math.huge, c.name }
      local better = not bestKey
      for i = 1, bestKey and 4 or 0 do
        if key[i] ~= bestKey[i] then better = key[i] < bestKey[i]; break end
      end
      if better then
        best, bestKey = { name = c.name, zone = c.zone, mapID = mapID, x = c.x, y = c.y, id = c.id, fr = c.fr, recorded = c.recorded,
          confirmed = c.confirmed and true or false,
          source = c.recorded and "recorded" or (c.fdb and (c.confirmed and "foreverdb" or "fdbclassic")) or (c.id and "pfquest" or "classic") }, key
      end
    end
  end
  return best
end

-- Can this faction letter ("A", "H", "AH", nil = unknown) be used by the player's faction?
local function fits(fac, faction) return fac == nil or fac == "AH" or fac:find(faction, 1, true) ~= nil end

-- The capital city maps. pfQuest also lists a city NPC on the zone around the city: the same spot projected on that zone's map, at
-- ground level, where nobody stands (Naal Mistrunner of Thunder Bluff pinned at Mulgore 40.2, 27.5). A city spawn rules the others out.
local CITY = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }

-- Positions of one NPC, best evidence first: what the player recorded in game, then ForeverDB's place (`confirmed` when it was
-- seen in the Forever game, else still a Classic place), then pfQuest's Classic spawns (never confirmed). Second result: the NPC's faction.
local function spawnsOf(id, env)
  local rec, npc, fdb = env.recorded and env.recorded[id], env.db[id], env.fdb and env.fdb[id]
  local name, fr, fac = npc and npc[1] or fdb and fdb[1], npc and npc[4], fdb and fdb[5] or npc and npc[2]
  if rec and rec.mapID and rec.x then
    return { { id = id, name = rec.name or name, fr = fr, mapID = rec.mapID, x = rec.x, y = rec.y, recorded = true, confirmed = true } }, fac or rec.f
  end
  if fdb then
    return { { id = id, name = name, fr = fr, mapID = fdb[2], x = fdb[3], y = fdb[4], confirmed = fdb[6], fdb = true } }, fac
  end
  local out, city = {}, false
  for _, s in ipairs(npc and npc[3] or {}) do city = city or CITY[s[1]] or false end
  for _, s in ipairs(npc and npc[3] or {}) do
    if not city or CITY[s[1]] then out[#out + 1] = { id = id, name = name, fr = fr, mapID = s[1], x = s[2], y = s[3] } end
  end
  return out, fac
end

-- NPC ids of an English name in ForeverDB's data (NPCs new to Forever are in no Classic list), indexed once per table.
local fdbNames = setmetatable({}, { __mode = "k" })
local function fdbIds(name, env)
  if not env.fdb then return {} end
  local index = fdbNames[env.fdb]
  if not index then
    index = {}
    for id, n in pairs(env.fdb) do
      local list = index[n[1]] or {}
      index[n[1]] = list
      list[#list + 1] = id
    end
    for _, list in pairs(index) do table.sort(list) end
    fdbNames[env.fdb] = index
  end
  return index[name] or {}
end

-- NPC ids of an English name; when the text gave a zone, the ones that spawn there (several NPCs can share a name).
local function idsOfName(name, zone, env)
  local ids, has = {}, {}
  for _, list in ipairs({ env.byName and env.byName[name] or {}, fdbIds(name, env) }) do
    for _, id in ipairs(list) do if not has[id] then has[id] = true; ids[#ids + 1] = id end end
  end
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
    if #sp > 0 and sp[1].mapID and sp[1].mapID > 0 then
      if fits(fac, env.faction) then for _, s in ipairs(sp) do cands[#cands + 1] = s end else other = true end
    end
  end
  return cands, other
end

-- Side of a quest of ns.FdbQuests ({ questID, side, giver npcID, giver name, mapID, x, y, title, level }): ForeverDB's, else the giver's faction.
local function questSide(q, env)
  if q[2] ~= "" then return q[2] end
  local _, fac = spawnsOf(q[3], env)
  return fac
end

-- What the Forever NPC data knows about the sources of a recipe, for Leveling.Way (env: db, byName, maps, fdb, fdbVendors, fdbQuests,
-- fdbPrice, fdbFavor). A verdict is false only when every NPC a source names is known to belong to the other faction; nil = no verdict.
function Wh.Who(env)
  local function sideOf(id) local _, fac = spawnsOf(id, env); return fac end
  return {
    -- vendors: ForeverDB's vendor list of the recipe, else the NPCs named by the site's text ("NPC (Zone), NPC (Zone)")
    vendors = function(id, faction, text)
      local ids = env.fdbVendors and env.fdbVendors[id]
      if not ids then
        ids = {}
        for _, v in ipairs(Wh.ParseVendors(text)) do
          local found = idsOfName(v.name, v.zone, env)
          if #found == 0 then return nil end            -- an NPC no data knows: no verdict
          for _, n in ipairs(found) do ids[#ids + 1] = n end
        end
      end
      if #ids == 0 then return nil end
      for _, n in ipairs(ids) do if fits(sideOf(n), faction) then return true end end
      return false
    end,
    -- quests: ForeverDB's quests of the recipe (then: the quest id, its title, its level), else the library's quest givers ({ id, faction })
    quest = function(id, faction, givers)
      local list = env.fdbQuests and env.fdbQuests[id]
      if list then
        for _, q in ipairs(list) do if fits(questSide(q, env), faction) then return true, q[1], q[8], q[9] end end
        return false
      end
      if not givers or #givers == 0 then return nil end
      for _, g in ipairs(givers) do
        if fits(g.faction and g.faction:sub(1, 1) or sideOf(g.id), faction) then return true end
      end
      return false
    end,
    -- price of the teaching item at a vendor: copper | nil, Merchant's Favor | nil
    cost = function(id) return env.fdbPrice and env.fdbPrice[id], env.fdbFavor and env.fdbFavor[id] end,
  }
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
-- or "text" (the free text, or nothing: the caller words it). A pin says whether its position is `confirmed` on Forever and its
-- `source` (recorded, foreverdb, fdbclassic, pfquest, classic); a text target is `unverified` when no Forever source names a
-- place (`hint`: what Classic data says, to quote as such).
function Wh.Target(rec, prof, env)
  -- a trainer window recorded in game beats the Classic coordinates: the NPC and where it really stands
  local seen = rec.trainer
  if seen and seen.mapID and seen.x and seen.y then
    return { name = seen.npc, zone = seen.zone or "", mapID = seen.mapID, x = seen.x, y = seen.y, recorded = true, confirmed = true,
      kind = "pin", source = "recorded" }
  end
  if rec.src == nil then
    if env.db then   -- the NPC database: nearest trainer of the player's faction whose rank covers the recipe
      local ids, top = {}, neededTop(rec)
      local listed = env.fdbTrainers and env.fdbTrainers[prof]   -- ForeverDB's trainers of the profession: the others are not proposed
      for _, t in ipairs(env.ntrainers and env.ntrainers[prof] or {}) do
        -- a "Journeyman" by its Forever title (0) teaches Apprentice recipes only, whatever the Classic list says of its rank
        local rank = listed and listed[t[1]] == 0 and 0 or t[2]
        if rank >= top and (not listed or listed[t[1]]) then ids[#ids + 1] = t[1] end
      end
      local cands, other = fromDb(ids, env)
      local best = pick(cands, env)
      if best then best.kind = "pin"; return best end
      if other then return { kind = "text", onlyFaction = onlyFor(env) } end
    end
    if env.fdb then return { kind = "text", unverified = true } end   -- the older Classic list is no Forever source: no pin
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
  -- With the Forever data loaded (`strict`), only Forever sources name the NPCs: ForeverDB's vendor list of the recipe (`fv`) and
  -- the site's vendors (each source misses a few the other has), else the library's own captures (way.confirmed). The names
  -- borrowed from Classic world databases give no pin: they are only quoted as an unverified hint.
  local strict = env.fdb ~= nil
  local fv = env.fdbVendors and env.fdbVendors[rec.id]
  local names, found = {}, {}
  if not strict then
    for _, n in ipairs(rec.npcNames or {}) do names[#names + 1] = n end
    for i = 2, #(info or {}) do names[#names + 1] = info[i] end
  end
  local siteVendors = Wh.ParseVendors(rec.way and rec.way.where)
  for _, v in ipairs(siteVendors) do names[#names + 1] = v.name end   -- the site is a Forever source too: its vendors always count
  local way = rec.way
  -- a quest recipe: where Forever players were offered the quest (ForeverDB), for the player's faction
  local fq = rec.src == "q" and env.fdbQuests and env.db and env.fdbQuests[rec.id]
  if fq then
    local cands = {}
    for _, q in ipairs(fq) do
      if q[5] > 0 and fits(questSide(q, env), env.faction) then
        cands[#cands + 1] = { id = q[3], name = q[4], mapID = q[5], x = q[6], y = q[7], confirmed = true, fdb = true }
      end
    end
    local best = pick(cands, env)
    if best then best.kind = "pin"; return best end
  end
  if env.db then   -- the NPC database: the NPCs the sources name, by faction
    local ids, taken = {}, {}
    local function add(id) if not taken[id] then taken[id] = true; ids[#ids + 1] = id end end
    for _, id in ipairs(fv or {}) do add(id) end
    if not fv and (not strict or (way and way.confirmed)) then for _, id in ipairs(way and way.ids or {}) do add(id) end end
    for _, v in ipairs(siteVendors) do for _, id in ipairs(idsOfName(v.name, v.zone, env)) do add(id) end end
    if not fv then for _, n in ipairs(names) do for _, id in ipairs(idsOfName(n, nil, env)) do add(id) end end end
    local cands, other = fromDb(ids, env)
    local best = pick(cands, env)
    if best then best.kind = "pin"; return best end
    -- a teaching item (pattern) with an auction price: the nearest auction house of the player's faction (neutral ones last)
    if way and way.kind == "item" and rec.fee and env.auctioneers then
      local own, neutral = {}, {}
      for _, id in ipairs(env.auctioneers) do
        local npc = env.db[id]
        local list = npc and (npc[2] == "AH" and neutral or own)
        if list then list[#list + 1] = id end
      end
      local a = pick((fromDb(own, env)), env) or pick((fromDb(neutral, env)), env)
      if a then a.kind, a.auction = "pin", true; return a end
    end
    if other then return { kind = "text", onlyFaction = onlyFor(env) } end
  end
  -- a drop has no NPC: the drop zone of the site, and the map of that zone when it is known
  if way and way.zone and (way.kind == "drop" or way.kind == "container" or way.kind == "item") then
    for part in way.zone:gmatch("[^,]+") do
      local zone = part:match("^%s*(.-)%s*$")
      if env.maps[zone] then return { zone = zone, mapID = env.maps[zone][1], kind = "zone", dropZone = true, source = "site" } end
    end
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
        if v.mapID then return { name = v.name, zone = v.zone, mapID = v.mapID, vendors = list, kind = "zone", source = "site" } end
      end
      return { name = list[1].name, zone = list[1].zone, vendors = list, text = where, kind = "text", source = "site" }
    end
  end
  if strict then   -- no Forever source names a place: said plainly, the Classic names only as an unverified hint
    local hint = info and info[1] or (#(rec.npcNames or {}) > 0 and table.concat(rec.npcNames, ", ")) or nil
    return { hint = hint, kind = "text", unverified = true }
  end
  return { text = info and info[1] or nil, kind = "text" }
end
