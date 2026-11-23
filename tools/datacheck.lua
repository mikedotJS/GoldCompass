-- Consistency checks of the generated Data/*.lua files (plain Lua 5.4, offline, no cache needed). Used by tools/check-data.lua (the
-- update bot runs it after every regeneration) and by spec/datacheck_spec.lua (CI).
--   local report = require("datacheck").run(dataDir [, baselineDir [, known]])
--   report.errors   = problems that are not in `known` (one line each), sorted
--   report.warnings = size changes of more than 30 percent against the files in baselineDir
--   report.all      = every problem including the known ones; report.counts = what was looked at
-- `known` = { ["<exact problem line>"] = true }: data that is wrong or unfinished upstream, listed in tools/check-data-known.lua so
-- that only NEW problems stop the bot.
local M = {}

local SIZE_TOLERANCE = 0.30        -- a generated file may grow or shrink by this share before a warning
-- craft spell id -> true: recipes that really have no reagent: the rank spells of First Aid (7924), Cooking (3413) and Fishing (7732)
local EMPTY_REAGENTS_OK = { [3413] = true, [7732] = true, [7924] = true }

local function loadData(dir)
  local ns, names, errs = {}, {}, {}
  local p = io.popen('ls "' .. dir .. '"')
  for f in p:lines() do if f:match("%.lua$") then names[#names + 1] = f end end
  p:close()
  table.sort(names)
  for _, f in ipairs(names) do
    local chunk, err = loadfile(dir .. "/" .. f)
    if not chunk then errs[#errs + 1] = ("Data/%s: does not load (%s)"):format(f, err)
    else
      local ok, e = pcall(chunk, "GoldCompass", ns)
      if not ok then errs[#errs + 1] = ("Data/%s: error while running (%s)"):format(f, e) end
    end
  end
  return ns, names, errs
end

-- Lua silently merges a key written twice in a table constructor, so duplicates are looked for in the text: a key at the first indent
-- level, twice between two top-level lines.
local function duplicateKeys(dir, f, out)
  local seen
  for line in io.lines(dir .. "/" .. f) do
    if line:match("^[%}%a]") then seen = {} end
    local key = line:match("^  %[(%-?%d+)%]%s*=") or line:match('^  %["(.-)"%]%s*=') or line:match("^R%[(%d+)%]=")
    if key and seen then
      if seen[key] then out[#out + 1] = ("Data/%s: duplicated key %s"):format(f, key) end
      seen[key] = true
    end
  end
end

local function fileSize(path)
  local h = io.open(path, "rb")
  if not h then return nil end
  local n = h:seek("end")
  h:close()
  return n
end

local function badPoint(x, y) return type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 100 or y < 0 or y > 100 end

function M.run(dir, baselineDir, known)
  known = known or {}
  local errors, warnings, said = {}, {}, {}
  local function err(msg)                      -- once per message: the same npc or map used a hundred times is one problem
    if not said[msg] then said[msg] = true; errors[#errors + 1] = msg end
  end
  local counts = { files = 0, npcs = 0, maps = 0, recipes = 0, points = 0, beasts = 0 }
  local ns, files, loadErrs = loadData(dir)
  counts.files = #files
  for _, e in ipairs(loadErrs) do errors[#errors + 1] = e end

  local zoneOK = {}
  for id in pairs(ns.Zones or {}) do zoneOK[id] = true end
  for _, v in pairs(ns.MapIDs or {}) do zoneOK[v[1]] = true end
  local function checkMap(file, _, id)
    counts.maps = counts.maps + 1
    if not zoneOK[id] then err(("Data/%s: uiMapID %s is in neither ns.Zones nor ns.MapIDs"):format(file, tostring(id))) end
  end
  local function checkPoint(file, what, x, y)
    counts.points = counts.points + 1
    if badPoint(x, y) then err(("Data/%s: %s has a point outside 0..100 (%s, %s)"):format(file, what, tostring(x), tostring(y))) end
  end

  -- NPCs that have a position
  local positioned = {}
  for id, n in pairs(ns.Npcs or {}) do
    counts.npcs = counts.npcs + 1
    if #n[3] > 0 then positioned[id] = true end
    for _, s in ipairs(n[3]) do
      checkMap("Npcs.lua", "npc " .. id, s[1]); checkPoint("Npcs.lua", "npc " .. id, s[2], s[3])
    end
  end
  for id, n in pairs(ns.FdbNpcs or {}) do
    positioned[id] = true
    checkMap("ForeverNpcs.lua", "npc " .. id, n[2]); checkPoint("ForeverNpcs.lua", "npc " .. id, n[3], n[4])
  end
  local function needNpc(file, what, id)             -- what: the kind of use, not the row, so that the message stays the same
    if not positioned[id] then err(("Data/%s: npc %s (%s) has no position in Npcs.lua or ForeverNpcs.lua"):format(file, tostring(id), what)) end
  end

  -- recipe sources, vendors, trainers
  local fd = ns.ForeverData or {}
  for spell, src in pairs(fd.src or {}) do
    if type(src) == "table" then
      for _, list in ipairs({ src[2] or {}, src[3] or {} }) do
        for _, id in ipairs(list) do needNpc("ForeverRecipes.lua", "recipe source", id) end
      end
    end
  end
  for spell, list in pairs(ns.FdbVendors or {}) do
    for _, id in ipairs(list) do needNpc("ForeverNpcs.lua", "recipe vendor", id) end
  end
  for prof, list in pairs(ns.NpcTrainers or {}) do
    for _, t in ipairs(list) do needNpc("Npcs.lua", "trainer", t[1]) end
  end
  for line, ranks in pairs(ns.Ranks or {}) do
    for _, r in ipairs(ranks) do
      local way = r.way or {}
      if way.kind == "trainer" then
        for _, id in ipairs(way.ids or {}) do needNpc("ForeverRanks.lua", "rank trainer", id) end
      elseif way.kind == "book" then
        for _, v in ipairs(way.vendors or {}) do needNpc("ForeverRanks.lua", "rank book vendor", v[1]) end
      end
    end
  end

  -- recipes without reagents (the ones ForeverFixes.gone lists are not recipes of the Forever client)
  local gone = ns.ForeverFixes and ns.ForeverFixes.gone or {}
  for _, row in ipairs(ns.RecipeRows or {}) do
    counts.recipes = counts.recipes + 1
    if (row[9] or "") == "" and not EMPTY_REAGENTS_OK[row[1]] and not gone[row[1]] then
      err(("Data/Recipes.lua: recipe %s (%s) has an empty reagent list"):format(row[1], tostring(row[8])))
    end
  end
  for line, rows in pairs(fd.recipes or {}) do
    for _, r in ipairs(rows) do
      counts.recipes = counts.recipes + 1
      if (r[8] or "") == "" and not (r[10] or ""):find("a", 1, true) and not EMPTY_REAGENTS_OK[r[1]] and not gone[r[1]] then
        err(("Data/ForeverRecipes.lua: recipe %s of line %s has an empty reagent list"):format(r[1], line))
      end
    end
  end

  -- other tables with positions or maps
  for item, g in pairs(ns.GatherSources or {}) do
    for _, z in ipairs(g.zones or {}) do
      checkMap("ForeverGather.lua", "gathering item " .. item, z[1])
      if z.best then checkPoint("ForeverGather.lua", "gathering item " .. item, z.best[1], z.best[2]) end
    end
  end
  for map in pairs(ns.FishZones or {}) do checkMap("ForeverGather.lua", "fishing zone", map) end
  for kind, spots in pairs(ns.SkinSpots or {}) do
    for _, s in ipairs(spots) do
      checkMap("ForeverSkinning.lua", "skin spot " .. kind, s[1]); checkPoint("ForeverSkinning.lua", "skin spot " .. kind, s[2], s[3])
    end
  end
  for item, list in pairs(ns.ReagentSources or {}) do
    for _, v in ipairs(list.vendors or {}) do
      if v[3] ~= 0 then
        checkMap("ForeverReagentSources.lua", "reagent " .. item, v[3]); checkPoint("ForeverReagentSources.lua", "reagent " .. item, v[4], v[5])
      end
    end
  end
  for name, v in pairs(ns.NPCs or {}) do
    if ns.MapIDs and not ns.MapIDs[v[1]] then err(("Data/Locations.lua: npc '%s' is in zone '%s', which ns.MapIDs lacks"):format(name, v[1])) end
    checkPoint("Locations.lua", "npc '" .. name .. "'", v[2], v[3])
  end
  for prof, list in pairs(ns.Trainers or {}) do
    for _, t in ipairs(list) do
      if ns.MapIDs and not ns.MapIDs[t[2]] then err(("Data/Locations.lua: trainer '%s' of %s is in zone '%s', which ns.MapIDs lacks"):format(t[1], prof, t[2])) end
      checkPoint("Locations.lua", "trainer '" .. t[1] .. "'", t[3], t[4])
    end
  end

  -- skinning: zones, beasts, packed points
  local listed, inZones = {}, {}
  for map, list in pairs(ns.SkinZones or {}) do
    checkMap("ForeverSkinZones.lua", "skin zones", map)
    for _, b in ipairs(list) do inZones[b[1]] = true; listed[b[1] .. ":" .. map] = true; counts.beasts = counts.beasts + 1 end
  end
  local withPoints = {}
  for key, packed in pairs(ns.SkinPoints or {}) do
    local npc, map = key // 10000, key % 10000
    withPoints[npc] = true
    if not inZones[npc] then
      err(("Data/ForeverSkinPoints.lua: beast %d is not in ForeverSkinZones.lua"):format(npc))
    elseif not listed[npc .. ":" .. map] then
      err(("Data/ForeverSkinPoints.lua: beast %d has points on map %d, which ForeverSkinZones.lua does not list for it"):format(npc, map))
    end
    checkMap("ForeverSkinPoints.lua", "beast " .. npc, map)
    local f, c = packed:match("^([0-9a-z]*)%.([0-9a-z]*)$")
    if not f or #f % 4 ~= 0 or #c % 4 ~= 0 then
      err(("Data/ForeverSkinPoints.lua: key %d is not 'points.points' of 4 characters each"):format(key))
    else
      for _, part in ipairs({ f, c }) do
        for i = 1, #part, 4 do
          local x, y = tonumber(part:sub(i, i + 1), 36), tonumber(part:sub(i + 2, i + 3), 36)
          counts.points = counts.points + 1
          if x > 1000 or y > 1000 then
            err(("Data/ForeverSkinPoints.lua: beast %d on map %d has a point outside 0..100 (%s, %s)"):format(npc, map, x / 10, y / 10))
          end
        end
      end
    end
  end
  for npc in pairs(inZones) do
    if not withPoints[npc] then err(("Data/ForeverSkinZones.lua: beast %d has no point in ForeverSkinPoints.lua"):format(npc)) end
  end

  for _, f in ipairs(files) do duplicateKeys(dir, f, errors) end

  -- sizes against the committed files
  if baselineDir then
    for _, f in ipairs(files) do
      local old, new = fileSize(baselineDir .. "/" .. f), fileSize(dir .. "/" .. f)
      if old and old > 0 and math.abs(new - old) / old > SIZE_TOLERANCE then
        warnings[#warnings + 1] = ("Data/%s: size %d bytes against %d committed (%+.0f%%)"):format(f, new, old, (new - old) / old * 100)
      end
    end
  end

  local fresh = {}
  counts.known = 0
  for _, e in ipairs(errors) do
    if known[e] then counts.known = counts.known + 1 else fresh[#fresh + 1] = e end
  end
  table.sort(fresh)
  return { errors = fresh, warnings = warnings, counts = counts, all = errors }
end

return M
