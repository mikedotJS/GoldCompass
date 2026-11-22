-- Records what a profession trainer really teaches on this client (read-only: nothing is clicked, no filter changed, no
-- hook on Blizzard frames). When a trainer window opens, every recipe service is matched to a craft of Data/Recipes.lua
-- through the item of its link (language independent; the localized name is only a fallback) and saved with its
-- required skill and cost, plus where the trainer stands. The record is the truth for that trainer: each visit replaces
-- the previous one. Saved account-wide (ns.db.trainers), since a trainer teaches the same to every character of a faction.
local _, ns = ...

local T = {}
ns.TrainerLog = T

-- Index of the crafts by output item: { [itemID] = { { id, prof, name }, ... } } (built once, from the data rows).
local byOutput
local function outputIndex()
  if not byOutput then
    byOutput = {}
    for _, r in ipairs(ns.RecipeRows or {}) do
      local list = byOutput[r[4]] or {}
      byOutput[r[4]] = list
      list[#list + 1] = { id = r[1], prof = r[2], name = r[8] }
    end
  end
  return byOutput
end

-- Builds the record of an open trainer window. api = { count(), service(i) -> name, rank, category,
-- req(i) -> skillName, skillLevel, cost(i) -> copper, link(i) -> item link }, index = { [itemID] = crafts },
-- byName(prof, localizedName) -> craft | nil (fallback). Returns { prof, offers = { [craftID] = { skill, cost, status,
-- name } } } or nil, and the names of the services that matched no recipe.
-- The state of a service is the third value of GetTrainerServiceInfo on the Classic client (name, rank, state) and the second on
-- Forever's (name, state, icon, level): the owner's saved data held the icon's number as the state. Whichever is a known state.
local STATE = { available = true, unavailable = true, used = true, header = true }
function T.Read(api, index, byName)
  local services, votes, skipped = {}, {}, {}
  for i = 1, api.count() or 0 do
    local name, second, third = api.service(i)
    local category = STATE[third] and third or STATE[second] and second or nil
    if name and category ~= "header" then
      local link = api.link and api.link(i)
      local item = link and tonumber(link:match("item:(%d+)"))
      local _, skill = api.req(i)
      local s = { name = name, status = category, skill = tonumber(skill) or 0, cost = tonumber(api.cost(i)) or 0,
        cands = item and index[item] or {} }
      services[#services + 1] = s
      local profs, n = {}, 0
      for _, c in ipairs(s.cands) do if not profs[c.prof] then profs[c.prof] = true; n = n + 1 end end
      if n == 1 then votes[s.cands[1].prof] = (votes[s.cands[1].prof] or 0) + 1 end -- an unambiguous match votes
    end
  end
  local prof, top = nil, 0
  for p, n in pairs(votes) do if n > top or (n == top and p < prof) then prof, top = p, n end end
  if not prof then
    for _, s in ipairs(services) do skipped[#skipped + 1] = s.name end
    return nil, skipped
  end
  local offers, any = {}, false
  for _, s in ipairs(services) do
    local craft
    for _, c in ipairs(s.cands) do if c.prof == prof and (not craft or c.id < craft.id) then craft = c end end
    craft = craft or (byName and byName(prof, s.name))
    if craft then
      offers[craft.id] = { skill = s.skill, cost = s.cost, status = s.status, name = s.name }
      any = true
    else
      skipped[#skipped + 1] = s.name
    end
  end
  if not any then return nil, skipped end
  return { prof = prof, offers = offers }, skipped
end

-- Saves a record of trainer `npc` (name) standing at map position (mapID, x, y in percent). Replaces that trainer's
-- previous record entirely.
-- `by` = the character who saw the window and `skill` = its skill in the profession then: "already known" and "not available" are
-- that character's, at that skill (T.Offers); the skill asked and the fee hold for everyone.
function T.Save(db, record, npc, faction, where, now, by, skill)
  db.trainers = db.trainers or {}
  db.trainers[("%s|%s|%s"):format(faction, npc, record.prof)] = { npc = npc, f = faction, prof = record.prof,
    mapID = where.mapID, x = where.x, y = where.y, zone = where.zone, seen = now, offers = record.offers, by = by, skill = skill }
end

-- NPC id of a creature GUID ("Creature-0-4379-1-76-3497-00001A2B3C"), nil for anything else.
function T.NpcID(guid)
  local kind, id = (guid or ""):match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
  return kind == "Creature" and tonumber(id) or nil
end

-- Remembers where an NPC (trainer or merchant) stands, account-wide: db.npcs[npcID] = { name, mapID, x, y, f = the faction of the
-- player who saw it }. A recorded position beats the pfQuest one (Where.Target), which covers the NPCs new to Forever.
function T.SaveNpc(db, id, name, faction, where)
  if not (id and where) then return end
  db.npcs = db.npcs or {}
  db.npcs[id] = { name = name, mapID = where.mapID, x = where.x, y = where.y, f = faction }
end

-- The NPCs whose place was recorded in game (merchant, trainer and auction house windows), one per NPC, sorted by name:
-- { { name, mapID, x, y, zone }, ... }. /gc pnj lists them, so the player sees which places are confirmed on Forever. Pure.
function T.Recorded(db)
  local seen, list = {}, {}
  local function add(name, rec)
    if name and rec.mapID and rec.x and rec.y and not seen[name] then
      seen[name] = true
      list[#list + 1] = { name = name, mapID = rec.mapID, x = rec.x, y = rec.y, zone = rec.zone }
    end
  end
  for _, rec in pairs(db.npcs or {}) do add(rec.name, rec) end
  for _, t in pairs(db.trainers or {}) do add(t.npc, t) end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- What the recorded trainers of this faction offer for a profession (English name): { [craftID] = { skill, cost, status,
-- npc, mapID, x, y, zone, mine, seenAt } } with the cheapest offer when several trainers teach a recipe; a recipe a trainer lists as
-- already known (status "used") is marked used. `me` = the character asking: the status of a window another character saw is read as
-- "available"; mine = `me` saw it; seenAt = the skill `me` had then (a recipe "unavailable" although that skill was enough needs
-- something else, a rank). Pure.
function T.Offers(db, prof, faction, me)
  local best = {}
  for _, t in pairs(db.trainers or {}) do
    if t.prof == prof and t.f == faction then
      -- a window another character saw says nothing about what `me` knows or may learn (a record without `by` is an older one: kept as is)
      local mine = t.by == nil or t.by == me
      for id, o in pairs(t.offers) do
        local cur = best[id]
        local offer = { skill = o.skill, cost = o.cost, status = mine and o.status or "available", npc = t.npc, mapID = t.mapID, x = t.x, y = t.y,
          zone = t.zone, mine = t.by ~= nil and t.by == me or nil, seenAt = mine and t.skill or nil }
        if not cur or (offer.status == "used") or (cur.status ~= "used" and (o.cost < cur.cost or (o.cost == cur.cost and t.npc < cur.npc))) then
          best[id] = offer
        end
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Game glue
local function gameApi()
  if not (GetNumTrainerServices and GetTrainerServiceInfo) then return end
  return {
    count = GetNumTrainerServices,
    service = GetTrainerServiceInfo,
    req = function(i) if GetTrainerServiceSkillReq then return GetTrainerServiceSkillReq(i) end end,
    cost = function(i) if GetTrainerServiceCost then return (GetTrainerServiceCost(i)) end end,
    link = function(i) if GetTrainerServiceItemLink then return GetTrainerServiceItemLink(i) end end,
  }
end

-- Where the player stands (next to the trainer): map, position in percent, zone name as the client shows it.
local function playerLocation()
  local C = C_Map
  local mapID = C and C.GetBestMapForUnit and C.GetBestMapForUnit("player")
  if not mapID then return end
  local info = C.GetMapInfo and C.GetMapInfo(mapID)
  local pos = C.GetPlayerMapPosition and C.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local x, y = pos.x, pos.y
  if pos.GetXY then x, y = pos:GetXY() end
  return { mapID = mapID, x = x * 100, y = y * 100, zone = info and info.name }
end

-- Reads the open trainer window and saves it. Returns the record or nil. Never raises.
function T.Scan()
  local api = gameApi()
  if not (api and ns.db) then return end
  if IsTradeskillTrainer and not IsTradeskillTrainer() then return end -- class trainer
  local localByName = function(prof, name)
    for _, c in ipairs(ns.Leveling.Crafts(ns.RecipeRows, prof)) do
      if ns.Fmt.LocalName({ id = c.id }) == name then return c end
    end
  end
  local ok, record, skipped = pcall(T.Read, api, outputIndex(), localByName)
  if not ok then return ns.Log("trainer", "read failed: " .. tostring(record)) end
  if not record then
    if #skipped > 0 then ns.Log("trainer", "no recipe matched: " .. table.concat(skipped, ", ")) end
    return
  end
  local where = playerLocation()
  if not where then return ns.Log("trainer", "no player position, trainer not recorded") end
  local npc = (UnitName and UnitName("npc")) or "?"
  local faction = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A"
  T.SaveNpc(ns.db, T.NpcID(UnitGUID and UnitGUID("npc")), npc, faction, where)
  T.Save(ns.db, record, npc, faction, where, time(), ns.charKey, ns.Skills()[record.prof])
  local count = 0
  for _ in pairs(record.offers) do count = count + 1 end
  ns.Log("trainer", ("%s (%s) at %s %.1f,%.1f: %d recipes%s"):format(npc, record.prof, tostring(where.zone), where.x, where.y, count,
    #skipped > 0 and ("; skipped (no matching recipe): " .. table.concat(skipped, ", ")) or ""))
  if ns.Window and ns.Window.OnData then ns.Window.OnData() end
  return record
end

-- A merchant or auction house window: where the NPC stands (a vendor of a recipe, or the auctioneer a pattern is bought from, is a
-- place to go to as much as a trainer).
function T.ScanMerchant()
  if not ns.db then return end
  local id = T.NpcID(UnitGUID and UnitGUID("npc"))
  local where = id and playerLocation()
  if not where then return end
  local faction = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A"
  T.SaveNpc(ns.db, id, (UnitName and UnitName("npc")) or "?", faction, where)
  ns.Log("merchant", ("%s (%d) at %s %.1f,%.1f"):format((UnitName and UnitName("npc")) or "?", id, tostring(where.zone), where.x, where.y))
end

local pending = false
local frame = CreateFrame("Frame")
for _, e in ipairs({ "TRAINER_SHOW", "TRAINER_UPDATE", "MERCHANT_SHOW", "AUCTION_HOUSE_SHOW" }) do pcall(frame.RegisterEvent, frame, e) end
frame:SetScript("OnEvent", function(_, event)
  if event == "MERCHANT_SHOW" or event == "AUCTION_HOUSE_SHOW" then return pcall(T.ScanMerchant) end
  if pending then return end
  pending = true
  C_Timer.After(0.4, function() pending = false; pcall(T.Scan) end)
end)
