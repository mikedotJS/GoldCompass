-- Audits what Gold Compass shows against the ForeverDB.net data files (the cache of tools/build-foreverdb.py: client extraction of the
-- current build plus what its players' addons recorded in game) and, when given, the owner's SavedVariables (what the game really
-- showed). Read-only: it prints, per item, how many values were compared and how many agree, and the first disagreements.
-- Run from the repo: lua tools/audit-forever.lua tools/cache-foreverdb [path to SavedVariables/GoldCompass.lua] [-v]
-- The downloaded files and the SavedVariables are loaded as text chunks with an empty environment: data only, no code can reach the system.
local dir, sv = arg[1], arg[2] ~= "-v" and arg[2] or nil
local verbose = arg[2] == "-v" or arg[3] == "-v"
local F = {}
for _, f in ipairs({ "Recipes", "NPCs", "Gather", "Zones", "QuestForever", "Favor" }) do
  assert(loadfile(dir .. "/" .. f .. ".lua", "t", {}))("ForeverDB", F)
end
local ns = {}
for _, f in ipairs({ "Strings", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/Locations", "Data/ForeverTrainers", "Data/ForeverRecipes",
  "Data/Npcs", "Data/ForeverNpcs", "Data/ForeverFixes", "Data/QuestItems", "ZoneRank", "ForeverDB", "Leveling", "Where" }) do
  local chunk = loadfile(f .. ".lua")
  if chunk then chunk("GoldCompass", ns) end
end

local LINES = { [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering", [165] = "Leatherworking",
  [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [356] = "Fishing", [393] = "Skinning", [186] = "Mining", [182] = "Herbalism" }

local results = {}
local function tally(item)
  local t = { item = item, n = 0, ok = 0, bad = {} }
  results[#results + 1] = t
  return function(same, what)
    t.n = t.n + 1
    if same then t.ok = t.ok + 1 elseif #t.bad < (verbose and 400 or 6) then t.bad[#t.bad + 1] = what end
  end, t
end
local function matsKey(mats)
  local parts = {}
  for _, m in ipairs(mats or {}) do parts[#parts + 1] = m[1] .. ":" .. m[2] end
  table.sort(parts)
  return table.concat(parts, ",")
end
local function strKey(s)
  local parts = {}
  for item, n in (s or ""):gmatch("(%d+):(%d+)") do parts[#parts + 1] = item .. ":" .. n end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- 1. Recipes ----------------------------------------------------------------------------------------------------------
local fdb = {}                                         -- [spell] = { prof, row }
for prof, rows in pairs(F.recipes) do for _, r in ipairs(rows) do fdb[r[1]] = { prof = prof, r = r } end end
local who = ns.Where.Who({ db = ns.Npcs, byName = ns.NpcByName, maps = ns.MapIDs, fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors,
  fdbQuests = ns.FdbQuests, fdbPrice = ns.FdbPrice, fdbFavor = ns.FdbFavor })
local shown, shownProf = {}, {}                        -- [spell] = the craft as the addon lists it
for line, english in pairs(LINES) do
  if ns.ForeverDB:HasProfession(line) then
    local byId = {}
    for _, c in ipairs(ns.Leveling.Crafts(ns.RecipeRows, english)) do byId[c.id] = c end
    for _, c in ipairs(ns.Leveling.LibCrafts(ns.ForeverDB, line, "H", function(id) return byId[id] end, ns.ForeverTrainers, who, ns.ForeverFixes)) do
      shown[c.id], shownProf[c.id] = c, english
    end
  end
end
local exists, tExists = tally("1 recipes: listed by the addon and present in the Forever client (ForeverDB)")
local prof = tally("1 recipes: profession")
local learn = tally("1 recipes: skill needed to learn (ForeverDB's own Forever values only)")
local learnClassic = tally("1 recipes: skill needed, where ForeverDB itself only has Classic trainer data")
local yel, grn, gry = tally("1 recipes: yellow threshold"), tally("1 recipes: green threshold"), tally("1 recipes: gray threshold")
local noThreshold = 0
local item, qty, reag = tally("1 recipes: crafted item"), tally("1 recipes: crafted quantity"), tally("1 recipes: reagents and counts")
for id, c in pairs(shown) do
  local f = fdb[id]
  local label = ("%d %s"):format(id, tostring(c.name))
  exists(f ~= nil, label .. " (" .. tostring(c.how and c.how.kind) .. ")")
  if f then
    local r = f.r
    prof(f.prof == shownProf[id], label .. ": " .. shownProf[id] .. " vs " .. f.prof)
    -- 0 = ForeverDB has no value: nothing to compare
    if r[13] == 1 then learnClassic(c.learn == r[3], ("%s: %s vs %d"):format(label, tostring(c.learn), r[3]))
    elseif r[3] > 0 then learn(c.learn == r[3], ("%s: %s vs %d"):format(label, tostring(c.learn), r[3])) end
    if c.y == nil then noThreshold = noThreshold + 1 elseif r[4] > 0 and r[6] > 0 then
      yel(c.y == r[4], ("%s: %s vs %d"):format(label, tostring(c.y), r[4]))
      grn(c.g == r[5], ("%s: %s vs %d"):format(label, tostring(c.g), r[5]))
      gry(c.gr == r[6], ("%s: %s vs %d"):format(label, tostring(c.gr), r[6]))
    end
    if r[7] ~= 0 or c.out then item((c.out or 0) == r[7], ("%s: %s vs %d"):format(label, tostring(c.out), r[7])) end
    if r[8] > 0 then qty(c.oq == r[8], ("%s: %s vs %s"):format(label, tostring(c.oq), tostring(r[8]))) end
    reag(matsKey(c.mats) == strKey(r[9]), ("%s: %s vs %s"):format(label, matsKey(c.mats), strKey(r[9])))
  end
end
local missing, missingAuto, missingSpec = 0, 0, 0
for id, f in pairs(fdb) do
  if not shown[id] then
    local info = F.recipeInfo[id] or {}
    if f.r[10] == "a" then missingAuto = missingAuto + 1 elseif info.sp then missingSpec = missingSpec + 1 else missing = missing + 1 end
  end
end
print(("ForeverDB recipes the addon does not list: %d learnable, %d granted with the profession, %d ForeverDB calls speculation; "
  .. "addon recipes with no thresholds shown (estimate): %d"):format(missing, missingAuto, missingSpec, noThreshold))

-- 2. Trainers ---------------------------------------------------------------------------------------------------------
local taught = tally("2 trainers: recipe is trainer-taught (site table vs ForeverDB)")
local fee = tally("2 trainers: trainer fee shown is the full price (not below ForeverDB's observation)")
for id, c in pairs(shown) do
  local f, ft = fdb[id], ns.ForeverTrainers[id]
  if f and ft then
    local info = F.recipeInfo[id] or {}
    -- ForeverDB: learned from a trainer, or seen at a Forever trainer (tf), or it has a trainer fee, even when a recipe item exists too
    local theirs = f.r[10] == "t" or info.tf == 1 or info.tc ~= nil
    taught((ft.cost ~= nil) == theirs, ("%d %s: site fee %s, ForeverDB learned from %s, seen at a trainer %s"):format(id, c.name, tostring(ft.cost), f.r[10], tostring(info.tf)))
    local ours = c.how and c.how.cost or ft.cost           -- the fee the addon shows: the higher of the two observations
    if ours and info.tc then fee(ours >= info.tc, ("%d %s: %d vs %d"):format(id, c.name, ours, info.tc)) end
  end
end
-- the rank a trainer recipe asks (the site's table, observed in game) against the bands Classic used: Journeyman from skill 50,
-- Expert from 125, Artisan from 200 (the caps are 75 / 150 / 225 / 300, which ForeverDB states for every profession)
local band = tally("2 trainers: rank a trainer recipe asks follows the bands 1-45 / 50-120 / 125-195 / 200-300")
for id, ft in pairs(ns.ForeverTrainers) do
  if ft.cost and ft.learn then
    local expected = ft.learn >= 200 and "Artisan" or ft.learn >= 125 and "Expert" or ft.learn >= 50 and "Journeyman" or "Apprentice"
    band((ft.rank or "Apprentice") == expected, ("%d: skill %d, rank %s"):format(id, ft.learn, tostring(ft.rank)))
  end
end
local listed, tListed = tally("2 trainers: NPC of the addon's trainer list is a trainer of that profession for ForeverDB")
local placed = tally("2 trainers: listed trainer has a place seen in Forever")
for english, list in pairs(ns.NpcTrainers) do
  local set = {}
  for _, id in ipairs(F.profTrainers[english] or {}) do set[id] = true end
  for _, t in ipairs(list) do
    listed(set[t[1]] == true, english .. ": " .. ns.Npcs[t[1]][1])
    if set[t[1]] then placed(F.npcs[t[1]] ~= nil and F.npcs[t[1]][7] == 1, english .. ": " .. ns.Npcs[t[1]][1]) end
  end
end

-- 3. Vendors ----------------------------------------------------------------------------------------------------------
local soldBy = {}                                      -- [item][npc] = copper
for it, list in pairs(F.sold) do
  soldBy[it] = {}
  for i = 1, #list, 4 do soldBy[it][list[i]] = list[i + 1] end
end
local vname = tally("3 vendors: vendor named by the site sells the recipe for ForeverDB")
local vside = tally("3 vendors: the site's first list is the Alliance's, the second the Horde's (ForeverDB sides)")
local vfav = tally("3 vendors: Merchant's Favor price (site vs ForeverDB)")
local byName = {}
for id, n in pairs(F.npcs) do byName[n[1]] = byName[n[1]] or {}; byName[n[1]][#byName[n[1]] + 1] = id end
for id, ft in pairs(ns.ForeverTrainers) do
  local fv = ns.FdbVendors and ns.FdbVendors[id]
  for _, key in ipairs({ "va", "vh", "vendor" }) do
    local text = ft[key]
    if text then
      local fav = tonumber(text:match("Merchant's Favor (%d+)"))
      local info = F.recipeInfo[id] or {}
      if fav and info.fav then vfav(fav == info.fav, ("%d: %d vs %d"):format(id, fav, info.fav)) end
      for _, v in ipairs(ns.Where.ParseVendors((text:gsub("%s*\194\183[^,]*", "")))) do
        local ids, inList, side = byName[v.name] or {}, false, nil
        for _, npc in ipairs(ids) do
          side = side or F.npcs[npc][6]
          for _, x in ipairs(fv or {}) do inList = inList or x == npc end
        end
        if fv then vname(inList, ("%d: %s"):format(id, v.name)) end
        if key ~= "vendor" and #ids > 0 and side ~= "" then
          vside(side == (key == "va" and "A" or "H"), ("%d: %s is %s in the %s list"):format(id, v.name, side, key))
        end
      end
    end
  end
end
local vcost = tally("3 vendors: gold price of a recipe at a vendor (LibProfessionDB capture vs ForeverDB)")
for spell, perNpc in pairs(ns.ForeverData.cost or {}) do
  local itemID = ns.ForeverDB:GetRecipeItem(spell)
  for npc, parts in pairs(perNpc) do
    local gold = parts[1] and parts[1].g
    local theirs = itemID and soldBy[itemID] and soldBy[itemID][npc]
    if gold and theirs and theirs > 0 then vcost(gold == theirs, ("%d at %d: %d vs %d"):format(spell, npc, gold, theirs)) end
  end
end

-- 4. Quests -----------------------------------------------------------------------------------------------------------
local qname = tally("4 quests: quest that gives the recipe (site name vs ForeverDB)")
local qknown, tKnown = tally("4 quests: ForeverDB quest of a recipe has a side and a place players saw")
for id, ft in pairs(ns.ForeverTrainers) do
  local info = F.recipeInfo[id]
  if ft.quest and info and info.q then
    qname(info.q == ft.quest or info.q:find(ft.quest, 1, true) ~= nil, ("%d: %s vs %s"):format(id, ft.quest, info.q))
  end
end
for id, list in pairs(ns.FdbQuests or {}) do
  for _, q in ipairs(list) do qknown(q[2] ~= "" and q[5] > 0, ("%d: quest %d %s side '%s' map %d"):format(id, q[1], q[4], q[2], q[5])) end
end

-- 5. Gathering and zones ------------------------------------------------------------------------------------------------
local gskill = tally("5 gathering: skill needed for a node's item (addon vs ForeverDB, both Classic's rule)")
local gitem, tItem = tally("5 gathering: node item is a gathering item for ForeverDB")
local kinds = {}                                       -- [item] = { n = a node name, skills = { [skill] = true } }: several nodes give one item
for _, k in pairs(F.gatherData.kinds) do
  if k.item then
    kinds[k.item] = kinds[k.item] or { n = k.n, skills = {} }
    if k.sk then kinds[k.item].skills[k.sk] = true end
  end
end
for node, g in pairs(ns.GatherNodes) do
  if g.item then
    local k = kinds[g.item]
    gitem(k ~= nil, ("node %d item %d (%s)"):format(node, g.item, g.type))
    if k and next(k.skills) and g.type ~= "Fishing" then gskill(k.skills[g.skill] == true, ("node %d %s: %s"):format(node, tostring(k.n), tostring(g.skill))) end
  end
end
local zlevel = tally("5 zones: level range within 3 levels of ForeverDB's (quest levels players saw)")
local zsrc = {}
for map, z in pairs(ns.Zones) do
  local d = F.zoneData[map]
  if d then
    local src, lo, hi = d:match("^[^|]*|[^|]*|(%a)|(%d*)%-?(%d*)|")
    zsrc[src or "?"] = (zsrc[src or "?"] or 0) + 1
    if lo and lo ~= "" then
      -- the addon's ranges are the nominal ones, ForeverDB's the levels of the quests players saw: the same band within 3 levels
      zlevel(z[2] ~= nil and math.abs(z[2] - tonumber(lo)) <= 3 and math.abs(z[3] - tonumber(hi)) <= 3,
        ("%d %s: %s-%s vs %s-%s (%s)"):format(map, z[1], tostring(z[2]), tostring(z[3]), lo, hi, src))
    end
  end
end

-- 6. Items --------------------------------------------------------------------------------------------------------------
local titles = {}
for qid, row in pairs(F.qfQuests) do
  local title, level, _, _, starts, _, _, _, _, _, side = row:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
  if title and title ~= "" then
    -- the side: the quest's own, else the side of the NPC that gives it (ForeverDB's NPC list)
    local giver = F.npcs[tonumber((starts or ""):match("^n(%d+)"))]
    if side == "" and giver and (giver[6] == "A" or giver[6] == "H") then side = giver[6] end
    titles[title] = titles[title] or {}
    titles[title][#titles[title] + 1] = { id = qid, level = tonumber(level), side = side }
  end
end
local qiExists = tally("6 quest items: the quest exists in Forever (ForeverDB quest list, by title)")
local qiLevel = tally("6 quest items: quest level used (where ForeverDB has one)")
local qiSide = tally("6 quest items: quest faction (where ForeverDB knows the quest's or its giver's side)")
for itemID, list in pairs(ns.QuestItems) do
  for _, q in ipairs(list) do
    local t = titles[q.quest]
    qiExists(t ~= nil, ("item %d: %s"):format(itemID, q.quest))
    if t then
      -- the level the addon uses: Forever's own when the generated data carries it (ns.FdbQuestSeen[title] = level)
      local seen = ns.FdbQuestSeen and ns.FdbQuestSeen[q.quest]
      local ours = type(seen) == "number" and seen or q.level
      local lv, known, sides = false, false, {}
      for _, x in ipairs(t) do
        if (x.level or 0) > 0 then known = true; lv = lv or x.level == ours end
        local s = x.side:upper()
        if s == "A" or s == "H" then sides[s] = true elseif s == "B" then sides.A, sides.H = true, true end
      end
      if known then qiLevel(lv, ("item %d %s: %s vs %s"):format(itemID, q.quest, tostring(ours), tostring(t[1].level))) end
      local theirs = sides.A and sides.H and "B" or sides.A and "A" or sides.H and "H" or nil
      if theirs then qiSide(theirs == q.faction, ("item %d %s: %s vs %s"):format(itemID, q.quest, q.faction, theirs)) end
    end
  end
end

-- The owner's game: what the client itself showed (recipes read in profession windows, trainer windows, merchant prices) ----------
if sv then
  local env = {}
  assert(loadfile(sv, "t", env))()
  local db = env.GoldCompassDB or {}
  local gOut, gMats = tally("game: crafted item of a known recipe (ForeverDB vs the owner's profession windows)"), tally("game: reagents of a known recipe (ForeverDB vs the owner's profession windows)")
  local aOut, aMats = tally("game: crafted item (addon data vs the owner's profession windows)"), tally("game: reagents (addon data vs the owner's profession windows)")
  local aQty = tally("game: crafted quantity (addon data vs the owner's profession windows)")
  local gQty = tally("game: crafted quantity (ForeverDB vs the owner's profession windows)")
  local cap = tally("game: a profession's maximum is a rank cap, 75 / 150 / 225 / 300 (the owner's profession windows)")
  for _, char in pairs(db.chars or {}) do
    for name, p in pairs(char.profs or {}) do
      if (p.max or 0) > 0 then cap(p.max == 75 or p.max == 150 or p.max == 225 or p.max == 300, ("%s: %s"):format(tostring(name), tostring(p.max))) end
      for id, rec in pairs(p.recipes or {}) do
        local f, c = fdb[id], shown[id]
        local label = ("%d %s"):format(id, tostring(rec.name))
        if f then
          gOut(f.r[7] == (rec.out or 0), label .. ": " .. f.r[7] .. " vs " .. tostring(rec.out))
          gMats(strKey(f.r[9]) == matsKey(rec.mats), label .. ": " .. strKey(f.r[9]) .. " vs " .. matsKey(rec.mats))
          gQty(f.r[8] == rec.oq, label .. ": " .. tostring(f.r[8]) .. " vs " .. tostring(rec.oq))
        end
        if c then
          aOut((c.out or 0) == (rec.out or 0), label .. ": " .. tostring(c.out) .. " vs " .. tostring(rec.out))
          aMats(matsKey(c.mats) == matsKey(rec.mats), label .. ": " .. matsKey(c.mats) .. " vs " .. matsKey(rec.mats))
          aQty(c.oq == rec.oq, label .. ": " .. tostring(c.oq) .. " vs " .. tostring(rec.oq))
        end
      end
    end
  end
  local tSkill, tCost = tally("game: skill a trainer asks (addon data vs the owner's trainer windows)"), tally("game: trainer fee (addon data vs the owner's trainer windows)")
  local fSkill, fCost = tally("game: skill a trainer asks (ForeverDB vs the owner's trainer windows)"), tally("game: trainer fee (ForeverDB vs the owner's trainer windows)")
  for _, t in pairs(db.trainers or {}) do
    for id, o in pairs(t.offers or {}) do
      local c, f, info = shown[id], fdb[id], F.recipeInfo[id] or {}
      if c then
        tSkill(c.learn == o.skill, ("%d: %s vs %d"):format(id, tostring(c.learn), o.skill))
        tCost((c.how and c.how.cost) == o.cost, ("%d: %s vs %d"):format(id, tostring(c.how and c.how.cost), o.cost))
      end
      if f then
        fSkill(f.r[3] == o.skill, ("%d: %d vs %d"):format(id, f.r[3], o.skill))
        if info.tc then fCost(info.tc == o.cost, ("%d: %d vs %d"):format(id, info.tc, o.cost)) end
      end
    end
  end
  local buy = tally("game: what a merchant charged the owner for an item (ForeverDB vs the recorded price)")
  for itemID, copper in pairs(db.buy or {}) do
    local any, same = false, false
    for _, p in pairs(soldBy[itemID] or {}) do any = true; same = same or p == copper end
    if any then buy(same, ("item %d: recorded %d"):format(itemID, copper)) end
  end
  local n = 0
  for _ in pairs(db.npcs or {}) do n = n + 1 end
  print(("owner's saved data: %d NPC positions recorded in game"):format(n))
end

print(("\n%-98s %8s %8s %7s"):format("item", "compared", "agree", "%"))
for _, t in ipairs(results) do
  print(("%-98s %8d %8d %6.1f%%"):format(t.item, t.n, t.ok, t.n > 0 and 100 * t.ok / t.n or 0))
  for _, b in ipairs(t.bad) do print("      differs: " .. b) end
end
local unseen = tExists.n - tExists.ok
print(("\nzone level sources in ForeverDB for the addon's zones: b Blizzard, s seen by players, d derived, u unknown, c capital:"))
for k, v in pairs(zsrc) do io.write(("  %s=%d"):format(k, v)) end
print(("\nrecipes the addon lists that the Forever client data does not have: %d; trainers of the list ForeverDB does not know: %d; "
  .. "recipe quests without side or place: %d; node items ForeverDB does not gather: %d"):format(unseen, tListed.n - tListed.ok, tKnown.n - tKnown.ok, tItem.n - tItem.ok))
