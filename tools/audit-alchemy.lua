-- Alchemy (skill line 171) only: lists EVERY disagreement, with both values and the source of each, between
--   addon = what Gold Compass shows (Data/ForeverRecipes.lua + Data/ForeverTrainers.lua + Data/ForeverFixes.lua, through Leveling.LibCrafts),
--   site  = Data/ForeverTrainers.lua (wowforever.be, observed in game),
--   fdb   = the ForeverDB addon files of tools/cache-foreverdb (client extraction + what players' addons recorded).
-- Run from the repo: lua tools/audit-alchemy.lua tools/cache-foreverdb       (prints one line per disagreement, then the counts)
-- The downloaded files are loaded as text chunks with an empty environment: data only. Data from ForeverDB.net (GPL-3.0, section 7(b)).
local dir = arg[1]
local F = {}
for _, f in ipairs({ "Recipes", "NPCs", "Gather", "Zones", "QuestForever", "Favor" }) do
  assert(loadfile(dir .. "/" .. f .. ".lua", "t", {}))("ForeverDB", F)
end
local ns = {}
for _, f in ipairs({ "Strings", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/Locations", "Data/ForeverTrainers", "Data/ForeverRecipes",
  "Data/Npcs", "Data/ForeverNpcs", "Data/ForeverFixes", "Data/QuestItems", "ZoneRank", "ForeverDB", "Leveling", "Where" }) do
  assert(loadfile(f .. ".lua"))("GoldCompass", ns)
end
local LINE = 171
local fdb = {}
for _, r in ipairs(F.recipes.Alchemy or {}) do fdb[r[1]] = r end
local who = ns.Where.Who({ db = ns.Npcs, byName = ns.NpcByName, maps = ns.MapIDs, fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors,
  fdbQuests = ns.FdbQuests, fdbPrice = ns.FdbPrice, fdbFavor = ns.FdbFavor })
local byId = {}
for _, c in ipairs(ns.Leveling.Crafts(ns.RecipeRows, "Alchemy")) do byId[c.id] = c end
local shown = {}
for _, c in ipairs(ns.Leveling.LibCrafts(ns.ForeverDB, LINE, "H", function(id) return byId[id] end, ns.ForeverTrainers, who, ns.ForeverFixes)) do shown[c.id] = c end

local function key(mats)
  local p = {}
  for _, m in ipairs(mats or {}) do p[#p + 1] = m[1] .. ":" .. m[2] end
  table.sort(p)
  return table.concat(p, ",")
end
local function strKey(s)
  local p = {}
  for i, n in (s or ""):gmatch("(%d+):(%d+)") do p[#p + 1] = i .. ":" .. n end
  table.sort(p)
  return table.concat(p, ",")
end
local counts, lines = {}, {}
local function check(topic, same, label, a, b, sa, sb)
  local c = counts[topic] or { n = 0, bad = 0 }
  counts[topic] = c
  c.n = c.n + 1
  if not same then c.bad = c.bad + 1; lines[#lines + 1] = ("%-22s %s: %s = %s  vs  %s = %s"):format(topic, label, sa, tostring(a), sb, tostring(b)) end
end

local ids = {}
for id in pairs(shown) do ids[#ids + 1] = id end
table.sort(ids)
for _, id in ipairs(ids) do
  local c, ft, r = shown[id], ns.ForeverTrainers[id], fdb[id]
  local label = ("%d %s"):format(id, tostring(c.name))
  local info = F.recipeInfo[id] or {}
  if r then
    if r[13] ~= 1 and r[3] > 0 then check("learn addon/fdb", c.learn == r[3], label, c.learn, r[3], "addon", "fdb")
    elseif r[3] > 0 then check("learn addon/fdb(classic)", c.learn == r[3], label, c.learn, r[3], "addon", "fdb Classic trainer data") end
    if r[4] > 0 and r[6] > 0 and c.y then
      check("yellow addon/fdb", c.y == r[4], label, c.y, r[4], "addon", "fdb")
      check("green addon/fdb", c.g == r[5], label, c.g, r[5], "addon", "fdb")
      check("gray addon/fdb", c.gr == r[6], label, c.gr, r[6], "addon", "fdb")
    end
    if r[7] ~= 0 or c.out then check("crafted item addon/fdb", (c.out or 0) == r[7], label, c.out, r[7], "addon", "fdb") end
    if r[8] > 0 then check("quantity addon/fdb", c.oq == r[8], label, c.oq, r[8], "addon", "fdb") end
    check("reagents addon/fdb", key(c.mats) == strKey(r[9]), label, key(c.mats), strKey(r[9]), "addon", "fdb")
    if r[3] > 0 and ft then check("learn site/fdb", ft.learn == r[3] or r[13] == 1, label, ft.learn, r[3], "site", "fdb") end
    if ft and ft.th and r[4] > 0 and r[6] > 0 then
      check("thresholds site/fdb", ft.th[2] == r[4] and ft.th[3] == r[5] and ft.th[4] == r[6], label,
        table.concat(ft.th, "/", 2, 4), r[4] .. "/" .. r[5] .. "/" .. r[6], "site y/g/gr", "fdb y/g/gr")
    end
    -- who teaches it: the site's kind t = trainer; ForeverDB: learned from t, seen at a Forever trainer (tf), or a trainer fee (tc)
    if ft then
      local theirs = r[10] == "t" or info.tf == 1 or info.tc ~= nil
      check("trainer-taught site/fdb", (ft.cost ~= nil) == theirs, label, ft.cost ~= nil, theirs, "site (fee)", "fdb (t/tf/tc, learned from " .. tostring(r[10]) .. ")")
      if ft.cost and info.tc then check("trainer fee site/fdb", ft.cost == info.tc, label, ft.cost, info.tc, "site", "fdb") end
      if ft.k == "v" or ft.k == "q" or ft.k == "d" then
        local fromItem = tostring(r[10]):sub(1, 1) == "i"
        check("item-taught site/fdb", fromItem or r[10] == "t", label, ft.k, r[10], "site kind", "fdb learned from")
      end
    end
    if c.how and c.how.kind == "trainer" and ft and ft.rank then
      local lo = c.learn
      local want = lo < 50 and "Apprentice" or (lo < 125 and "Journeyman" or (lo < 200 and "Expert" or "Artisan"))
      check("rank site/Classic bands", ft.rank == want, label, ft.rank, want, "site rank", "Classic band of skill " .. tostring(lo))
    end
  else
    check("in the Forever client", false, label, "listed", "absent", "addon", "fdb")
  end
  if ft then
    if ft.learn then check("learn addon/site", c.learn == ft.learn, label, c.learn, ft.learn, "addon", "site") end
    if ft.th and c.y then
      check("thresholds addon/site", c.y == ft.th[2] and c.g == ft.th[3] and c.gr == ft.th[4], label,
        c.y .. "/" .. c.g .. "/" .. c.gr, table.concat(ft.th, "/", 2, 4), "addon y/g/gr", "site y/g/gr")
    end
    if ft.cost or ft.rank then
      check("trainer addon/site", (c.how and c.how.kind == "trainer") == (ft.cost ~= nil), label, c.how and c.how.kind, ft.cost and "trainer" or ft.k, "addon way", "site")
      if ft.rank and c.how then check("rank addon/site", c.how.rank == ft.rank, label, c.how.rank, ft.rank, "addon", "site") end
    end
  end
end
local missing = 0
for id, r in pairs(fdb) do if not shown[id] and r[10] ~= "a" and not (F.recipeInfo[id] or {}).sp then missing = missing + 1; lines[#lines + 1] = ("%-22s %d %s: absent from the addon, in fdb (learned from %s, skill %s)"):format("not listed", id, r[2], tostring(r[10]), tostring(r[3])) end end
table.sort(lines)
for _, l in ipairs(lines) do print(l) end
local names = {}
for t in pairs(counts) do names[#names + 1] = t end
table.sort(names)
print(("\nAlchemy: %d recipes shown by the addon, %d in ForeverDB"):format(#ids, (function() local n = 0 for _ in pairs(fdb) do n = n + 1 end return n end)()))
for _, t in ipairs(names) do print(("%-28s compared %4d  disagree %3d"):format(t, counts[t].n, counts[t].bad)) end
print(("ForeverDB recipes not listed by the addon: %d"):format(missing))
