-- Pure tests of where to learn a recipe, plus the real data coverage.
local ns = {}
for _, f in ipairs({ "Data/Zones", "Data/Recipes", "Data/Locations", "ZoneRank", "Leveling", "Where" }) do
  assert(loadfile(f .. ".lua"))("GoldCompass", ns)
end
local Wh = ns.Where

local maps = { ["Elwynn Forest"] = { 1429, "E" }, ["Durotar"] = { 1411, "K" }, ["Orgrimmar"] = { 1454, "K" },
  ["Stormwind City"] = { 1453, "E" }, ["Darnassus"] = { 1457, "K" } }
local function env(over)
  local e = { trainers = {}, npcs = {}, where = {}, maps = maps, faction = "A" }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

describe("Where.NeededRank", function()
  it("Journeyman up to 150, Expert up to 225, Artisan above", function()
    assert.are.equal(1, Wh.NeededRank(1)); assert.are.equal(1, Wh.NeededRank(150))
    assert.are.equal(2, Wh.NeededRank(151)); assert.are.equal(2, Wh.NeededRank(225))
    assert.are.equal(3, Wh.NeededRank(226))
  end)
end)

describe("Where.Target for a trainer recipe", function()
  local trainers = { Alchemy = {
    { "Horde Journeyman", "Durotar", 56, 74, "H", 1 },
    { "Elwynn Journeyman", "Elwynn Forest", 32.8, 49, "A", 1 },
    { "Stormwind Expert", "Stormwind City", 55.5, 85.5, "A", 2 },
    { "Darnassus Journeyman", "Darnassus", 54, 20.5, "A", 1 },
    { "Neutral Expert", "Durotar", 10, 10, nil, 2 },
    { "Specialisation", "Elwynn Forest", 1, 1, "A", 0 },
  } }
  local rec = { id = 1, learn = 60 }

  it("keeps trainers of the player's faction (or neutral) whose rank covers the recipe", function()
    local t = Wh.Target(rec, "Alchemy", env({ trainers = trainers, faction = "A", continent = "E" }))
    assert.are.equal("Elwynn Journeyman", t.name)      -- Eastern Kingdoms first; among them by name: Elwynn < Stormwind
    assert.are.equal(1429, t.mapID); assert.are.equal(32.8, t.x); assert.are.equal(49, t.y)
    t = Wh.Target({ id = 1, learn = 200 }, "Alchemy", env({ trainers = trainers, faction = "A", continent = "E" }))
    assert.are.equal("Stormwind Expert", t.name)        -- Journeyman trainers cannot teach a skill 200 recipe
    t = Wh.Target(rec, "Alchemy", env({ trainers = trainers, faction = "H", continent = "K" }))
    assert.are.equal("Horde Journeyman", t.name)
  end)

  it("prefers the player's continent, then the nearest, unknown distances last", function()
    local e = env({ trainers = trainers, faction = "A", continent = "K" })
    assert.are.equal("Darnassus Journeyman", Wh.Target(rec, "Alchemy", e).name)   -- Kalimdor beats Eastern Kingdoms
    e.dist = function(mapID) return mapID == 1429 and 10 or 500 end
    e.continent = nil                                                             -- unknown continent: distance decides
    assert.are.equal("Elwynn Journeyman", Wh.Target(rec, "Alchemy", e).name)
  end)

  it("uses the rank of the Forever table: Journeyman trainers do not teach an Expert recipe of skill 130", function()
    local e = env({ trainers = trainers, faction = "A", continent = "E" })
    assert.are.equal("Elwynn Journeyman", Wh.Target({ id = 1, learn = 130, way = { rank = "Journeyman" } }, "Alchemy", e).name)
    assert.are.equal("Stormwind Expert", Wh.Target({ id = 1, learn = 130, way = { rank = "Expert" } }, "Alchemy", e).name)
    assert.are.equal("Elwynn Journeyman", Wh.Target({ id = 1, learn = 30, way = { rank = "Apprentice" } }, "Alchemy", e).name)
    local t = Wh.Target({ id = 1, learn = 130, way = { rank = "Artisan" } }, "Alchemy", e)
    assert.is_nil(t.mapID)                                    -- no Artisan trainer of the faction on the list
  end)

  it("gives a text-only target when no trainer fits", function()
    local t = Wh.Target(rec, "Alchemy", env({ trainers = {} }))
    assert.is_nil(t.mapID); assert.is_nil(t.text)
    t = Wh.Target(rec, "Alchemy", env({ trainers = { Alchemy = { { "Nowhere", "Unknown Zone", 5, 5, nil, 3 } } } }))
    assert.is_nil(t.mapID)                                -- a zone with no map ID cannot be pinned
  end)
end)

describe("Where.Target for a vendor, drop or quest recipe", function()
  local npcs = { Kania = { "Stormwind City", 50, 60, "A" }, Kithas = { "Orgrimmar", 40, 30, "H" }, Anyone = { "Durotar", 5, 5, nil } }
  local where = { [7] = { "Kania (Stormwind) [A] / Kithas (Orgrimmar) [H]", "Kania", "Kithas" }, [8] = { "World drop" } }

  it("pins the NPC of the player's faction", function()
    local t = Wh.Target({ id = 7, src = "v", learn = 45 }, "Alchemy", env({ npcs = npcs, where = where, faction = "H" }))
    assert.are.equal("Kithas", t.name); assert.are.equal(1454, t.mapID)
    t = Wh.Target({ id = 7, src = "v", learn = 45 }, "Alchemy", env({ npcs = npcs, where = where, faction = "A" }))
    assert.are.equal("Kania", t.name)
  end)

  it("falls back to the free text, then to nothing", function()
    local t = Wh.Target({ id = 8, src = "d", learn = 45 }, "Alchemy", env({ npcs = npcs, where = where }))
    assert.is_nil(t.mapID); assert.are.equal("World drop", t.text)
    t = Wh.Target({ id = 99, src = "q", learn = 45 }, "Alchemy", env({ npcs = npcs, where = where }))
    assert.is_nil(t.mapID); assert.is_nil(t.text)
  end)
end)

describe("location data (real)", function()
  it("maps every zone named in the trainers and NPCs to a Classic map ID", function()
    local missing = {}
    for _, list in pairs(ns.Trainers) do
      for _, t in ipairs(list) do if not ns.MapIDs[t[2]] then missing[t[2]] = true end end
    end
    for name, n in pairs(ns.NPCs) do if not ns.MapIDs[n[1]] then missing[n[1] .. " (" .. name .. ")"] = true end end
    local list = {}
    for z in pairs(missing) do list[#list + 1] = z end
    assert.are.same({}, list)
  end)

  it("keeps the map IDs consistent with the gathering zones table", function()
    for id, z in pairs(ns.Zones) do
      if ns.MapIDs[z[1]] then assert.are.equal(id, ns.MapIDs[z[1]][1], z[1]) end
    end
  end)

  it("has a trainer for each profession of the crafts data, usable by each faction", function()
    for _, prof in ipairs({ "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering", "First Aid", "Leatherworking", "Tailoring" }) do
      for _, faction in ipairs({ "A", "H" }) do
        local t = Wh.Target({ id = 1, learn = 50 }, prof, { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs, faction = faction })
        assert.is_not_nil(t.mapID, prof .. " " .. faction)
      end
    end
  end)

  it("pins most learnable recipes and gives text for the rest", function()
    local pins, text = 0, 0
    for _, prof in ipairs({ "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering", "First Aid", "Leatherworking", "Tailoring" }) do
      for _, c in ipairs(ns.Leveling.Crafts(ns.RecipeRows, prof)) do
        if c.learn then
          local t = Wh.Target(c, prof, { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs, faction = "A" })
          if t.mapID then pins = pins + 1 else text = text + 1 end
        end
      end
    end
    assert.is_true(pins > 0 and text >= 0)
    assert.is_true(pins > text)
  end)
end)

describe("Where.Target prefers the recorded trainer", function()
  it("pins the NPC where the trainer window was opened, not the Classic coordinates", function()
    local trainers = { Alchemy = { { "Classic Trainer", "Durotar", 56, 74, nil, 1 } } }
    local rec = { id = 1, learn = 35, trainer = { npc = "Kamari", mapID = 1454, x = 61.5, y = 40, zone = "Orgrimmar" } }
    local t = Wh.Target(rec, "Alchemy", env({ trainers = trainers }))
    assert.are.equal("Kamari", t.name); assert.are.equal(1454, t.mapID)
    assert.are.equal(61.5, t.x); assert.are.equal(40, t.y)
    assert.is_true(t.recorded)
    t = Wh.Target({ id = 1, learn = 35 }, "Alchemy", env({ trainers = trainers }))
    assert.are.equal("Classic Trainer", t.name); assert.is_nil(t.recorded)     -- no record: Classic data as before
  end)
end)

describe("Where.Target for a library recipe (NPC names, no coordinates there)", function()
  local npcs = { Kania = { "Stormwind City", 50, 60, "A" } }
  it("pins a library vendor through the Classic NPC positions", function()
    local t = Wh.Target({ id = 77, src = "v", learn = 40, npcNames = { "Kania" } }, "Alchemy", env({ npcs = npcs }))
    assert.are.equal("Kania", t.name); assert.are.equal(1453, t.mapID)
  end)
  it("gives no pin for a drop, a container or a teaching item", function()
    for _, src in ipairs({ "d", "c", "i" }) do
      local t = Wh.Target({ id = 77, src = src, learn = 40, npcNames = {} }, "Alchemy", env({ npcs = npcs }))
      assert.is_nil(t.mapID)
    end
  end)
end)


describe("Where.Target with the real NPC database (pfQuest)", function()
  local real = {}
  for _, f in ipairs({ "Data/Zones", "Data/Locations", "Data/Npcs" }) do assert(loadfile(f .. ".lua"))("GoldCompass", real) end
  local contOf = {}
  for _, m in pairs(real.MapIDs) do contOf[m[1]] = m[2] end
  local function renv(faction, over)
    local e = { trainers = real.Trainers, npcs = real.NPCs, where = real.RecipeWhere, maps = real.MapIDs, db = real.Npcs,
      byName = real.NpcByName, ntrainers = real.NpcTrainers, contOf = contOf, faction = faction }
    for k, v in pairs(over or {}) do e[k] = v end
    return e
  end

  it("every NPC position uses a map the data knows, and every zone used by the sources has a uiMapID", function()
    local known = {}
    for _, m in pairs(real.MapIDs) do known[m[1]] = true end
    local n = 0
    for id, npc in pairs(real.Npcs) do
      assert.is_truthy(npc[1]); assert.is_truthy(npc[2] == "A" or npc[2] == "H" or npc[2] == "AH")
      for _, s in ipairs(npc[3]) do assert.is_true(known[s[1]], "NPC " .. id .. " map " .. s[1]); n = n + 1 end
    end
    assert.is_true(n > 300)
  end)

  it("Kamari (5811) is pinned in Orgrimmar for a Horde leatherworker learning an Apprentice recipe", function()
    local t = Wh.Target({ id = 1, learn = 1, src = nil, way = { rank = "Apprentice" } }, "Leatherworking",
      renv("H", { continent = "K", dist = function(m) return m == 1454 and 1 or 90 end }))        -- the player stands in Orgrimmar
    assert.are.equal("pin", t.kind); assert.are.equal("Kamari", t.name); assert.are.equal(5811, t.id)
    assert.are.equal(1454, t.mapID); assert.are.equal(63.3, t.x)
  end)

  it("Kilxx (3497) is pinned in The Barrens for a vendor recipe of the Horde", function()
    local t = Wh.Target({ id = 7755, src = "v", way = { site = true, ids = { 3497 }, where = "Kilxx (The Barrens)" } }, "Cooking", renv("H"))
    assert.are.equal("pin", t.kind); assert.are.equal("Kilxx", t.name); assert.are.equal(1413, t.mapID)
  end)

  it("Lindea Rabonne (2383, Alliance) is never proposed to the Horde, who are told it is Alliance only", function()
    local rec = { id = 7755, src = "v", way = { site = true, ids = { 2383 }, where = "Lindea Rabonne (Hillsbrad Foothills)" } }
    local t = Wh.Target(rec, "Cooking", renv("H"))
    assert.are_not.equal("pin", t.kind); assert.are.equal("A", t.onlyFaction)
    local a = Wh.Target(rec, "Cooking", renv("A"))
    assert.are.equal("pin", a.kind); assert.are.equal("Lindea Rabonne", a.name)
  end)

  it("a Forever-only NPC (not in pfQuest) falls back to the zone and the site's text", function()
    local t = Wh.Target({ id = 9, src = "v", way = { site = true, where = "Vayn Moongaze (Zephras Isle)" } }, "Tailoring", renv("H"))
    assert.are.equal("text", t.kind); assert.are.equal("Vayn Moongaze", t.vendors[1].name)
    local z = Wh.Target({ id = 9, src = "v", way = { site = true, where = "Vayn Moongaze (Durotar)" } }, "Tailoring", renv("H"))
    assert.are.equal("zone", z.kind); assert.are.equal(1411, z.mapID)
  end)

  it("a position recorded in game wins over pfQuest's", function()
    local rec = { id = 7755, src = "v", way = { site = true, ids = { 3497 }, where = "Kilxx (The Barrens)" } }
    local t = Wh.Target(rec, "Cooking", renv("H", { recorded = { [3497] = { name = "Kilxx", mapID = 1413, x = 11.1, y = 22.2 } } }))
    assert.are.equal("pin", t.kind); assert.are.equal(11.1, t.x); assert.is_true(t.recorded)
  end)

  it("the nearest candidate of the player's continent wins", function()
    local t = Wh.Target({ id = 1, learn = 100, src = nil, way = { rank = "Journeyman" } }, "Leatherworking",
      renv("H", { continent = "K", dist = function(m) return m == 1454 and 5 or 50 end }))
    assert.are.equal(1454, t.mapID)
  end)

  it("a drop recipe opens the drop zone, no NPC", function()
    local t = Wh.Target({ id = 2, src = "d", way = { kind = "drop", site = true, zone = "Durotar" } }, "Leatherworking", renv("H"))
    assert.are.equal("zone", t.kind); assert.is_true(t.dropZone); assert.are.equal(1411, t.mapID)
  end)
end)

describe("Where.Target for teaching items (patterns)", function()
  local real = {}
  for _, f in ipairs({ "Data/Zones", "Data/Locations", "Data/Npcs" }) do assert(loadfile(f .. ".lua"))("GoldCompass", real) end
  local contOf = {}
  for _, m in pairs(real.MapIDs) do contOf[m[1]] = m[2] end
  local function renv(faction, over)
    local e = { trainers = real.Trainers, npcs = real.NPCs, where = real.RecipeWhere, maps = real.MapIDs, db = real.Npcs,
      byName = real.NpcByName, ntrainers = real.NpcTrainers, auctioneers = real.NpcAuctioneers, contOf = contOf, faction = faction }
    for k, v in pairs(over or {}) do e[k] = v end
    return e
  end
  local city = { [1454] = "Orgrimmar", [1456] = "Thunder Bluff", [1458] = "Undercity", [1453] = "Stormwind City", [1455] = "Ironforge",
    [1457] = "Darnassus" }
  local pattern = { id = 70, src = "i", fee = 25000, feeAge = 1, way = { kind = "item", itemID = 555, site = true, kinds = "d", zone = "Durotar" } }

  it("a pattern with an auction price pins an auction house of the player's faction, whatever its drop zone", function()
    local h = Wh.Target(pattern, "Leatherworking", renv("H"))
    assert.are.equal("pin", h.kind); assert.is_true(h.auction)
    assert.is_truthy(h.name:find("^Auctioneer")); assert.is_truthy(city[h.mapID]); assert.are_not.equal(1453, h.mapID)
    assert.are.equal("H", real.Npcs[h.id][2])
    local a = Wh.Target(pattern, "Leatherworking", renv("A"))
    assert.are.equal("pin", a.kind); assert.are.equal("A", real.Npcs[a.id][2])
    assert.is_true(({ [1453] = true, [1455] = true, [1457] = true, [1438] = true })[a.mapID] or false)
  end)

  it("the nearest auction house wins, and the neutral goblin ones only when no auction house of the faction exists", function()
    local t = Wh.Target(pattern, "Leatherworking", renv("H", { continent = "K", dist = function(m) return m == 1456 and 1 or 80 end }))
    assert.are.equal(1456, t.mapID)                              -- the player stands in Thunder Bluff
    local gob = Wh.Target(pattern, "Leatherworking", renv("H", { auctioneers = { 8661, 9857 } }))     -- goblin houses only
    assert.are.equal("AH", real.Npcs[gob.id][2])
  end)

  it("a pattern with no auction price keeps the drop zone (no auction house pinned)", function()
    local free = { id = 71, src = "i", way = { kind = "item", itemID = 556, site = true, kinds = "d", zone = "Durotar" } }
    local t = Wh.Target(free, "Leatherworking", renv("H"))
    assert.are.equal("zone", t.kind); assert.is_true(t.dropZone); assert.are.equal(1411, t.mapID); assert.is_nil(t.auction)
  end)

  it("a pattern sold by a vendor of the player's faction pins that vendor, before the auction house", function()
    local sold = { id = 72, src = "i", fee = 25000, way = { kind = "item", itemID = 557, site = true, kinds = "v", where = "Kilxx (The Barrens)", ids = { 3497 } } }
    local t = Wh.Target(sold, "Cooking", renv("H"))
    assert.are.equal("pin", t.kind); assert.are.equal("Kilxx", t.name); assert.is_nil(t.auction); assert.are.equal(1413, t.mapID)
    -- an Alliance-only vendor is not proposed to the Horde: the auction house takes over (without a price: "uniquement côté Alliance")
    local alliance = { id = 73, src = "i", fee = 25000, way = { kind = "item", itemID = 558, site = true, kinds = "v", where = "Lindea Rabonne (Hillsbrad Foothills)", ids = { 2383 } } }
    local viaAh = Wh.Target(alliance, "Cooking", renv("H"))
    assert.is_true(viaAh.auction); assert.are.equal("H", real.Npcs[viaAh.id][2])
    alliance.fee = nil
    assert.are.equal("A", Wh.Target(alliance, "Cooking", renv("H")).onlyFaction)
  end)

  it("every auctioneer of the data has a faction and a map position", function()
    assert.is_true(#real.NpcAuctioneers >= 20)
    for _, id in ipairs(real.NpcAuctioneers) do
      local n = real.Npcs[id]
      assert.is_truthy(n, tostring(id)); assert.is_truthy(n[1]:find("^Auctioneer")); assert.is_true(#n[3] > 0)
    end
  end)
end)

describe("Where.Target: positions seen on Forever first, Classic ones flagged, Forever sources rule", function()
  local maps = { ["Thunder Bluff"] = { 1456, "K" }, Mulgore = { 1412, "K" }, ["The Barrens"] = { 1413, "K" }, Durotar = { 1411, "K" } }
  local function fenv(over)
    local e = { trainers = {}, npcs = {}, where = {}, maps = maps, faction = "H", contOf = { [1456] = "K", [1412] = "K", [1413] = "K", [1411] = "K" },
      db = { [1] = { "City Cook", "H", { { 1412, 40.2, 27.5 }, { 1456, 51, 52.5 } } }, [2] = { "Far Cook", "H", { { 1413, 10, 10 } } },
        [3] = { "Alli Cook", "A", { { 1413, 20, 20 } } }, [4] = { "Old Cook", "H", { { 1411, 30, 30 } } } },
      byName = { ["City Cook"] = { 1 }, ["Far Cook"] = { 2 }, ["Alli Cook"] = { 3 }, ["Old Cook"] = { 4 } } }
    for k, v in pairs(over or {}) do e[k] = v end
    return e
  end
  local rec = { id = 50, src = "v", way = { site = true, where = "City Cook (Thunder Bluff), Far Cook (The Barrens)" } }

  it("a city NPC is pinned on the city map, never on the zone around it, and a Classic position is not confirmed", function()
    local t = Wh.Target(rec, "Cooking", fenv({ dist = function(m) return m == 1412 and 1 or 5 end }))
    assert.are.equal("City Cook", t.name); assert.are.equal(1456, t.mapID); assert.are.equal(51, t.x)
    assert.is_false(t.confirmed); assert.are.equal("pfquest", t.source)
  end)

  it("a position seen on Forever wins over a nearer Classic one; ForeverDB's Classic places stay unconfirmed", function()
    local far = function(m) return m == 1413 and 900 or 1 end
    local t = Wh.Target(rec, "Cooking", fenv({ dist = far, fdb = { [2] = { "Far Cook", 1413, 11, 12, "H", true } } }))
    assert.are.equal("Far Cook", t.name); assert.are.same({ 1413, 11, 12 }, { t.mapID, t.x, t.y })
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    local c = Wh.Target(rec, "Cooking", fenv({ dist = far, fdb = { [2] = { "Far Cook", 1413, 11, 12, "H", false } } }))
    assert.are.equal("City Cook", c.name); assert.is_false(c.confirmed)          -- nothing confirmed: the nearest one, flagged
    local only = Wh.Target({ id = 50, src = "v", way = { site = true, where = "Far Cook (The Barrens)" } }, "Cooking",
      fenv({ fdb = { [2] = { "Far Cook", 1413, 11, 12, "H", false } } }))
    assert.is_false(only.confirmed); assert.are.equal("fdbclassic", only.source)
  end)

  it("an NPC new to Forever, known to ForeverDB only, is found by its name", function()
    local t = Wh.Target({ id = 50, src = "v", way = { site = true, where = "New Cook (Zephras Isle)" } }, "Cooking",
      fenv({ fdb = { [900] = { "New Cook", 2521, 63.8, 36, "AH", true } } }))
    assert.are.equal("pin", t.kind); assert.are.equal(900, t.id); assert.are.equal(2521, t.mapID); assert.is_true(t.confirmed)
  end)

  it("ForeverDB's vendor list of a recipe rules every other NPC out, and says when only the other faction sells it", function()
    local t = Wh.Target(rec, "Cooking", fenv({ fdbVendors = { [50] = { 4 } }, fdb = { [4] = { "Old Cook", 1411, 31, 32, "H", true } } }))
    assert.are.equal("Old Cook", t.name); assert.is_true(t.confirmed)
    local a = Wh.Target(rec, "Cooking", fenv({ fdbVendors = { [50] = { 3 } }, fdb = { [3] = { "Alli Cook", 1413, 20, 20, "A", true } } }))
    assert.are.equal("text", a.kind); assert.are.equal("A", a.onlyFaction)
  end)

  it("with the Forever data loaded, names only Classic data gives are never pinned: no source, the name as an unverified hint", function()
    local classic = { id = 51, src = "v", npcNames = { "Old Cook" }, way = { ids = { 4 } } }
    assert.are.equal("pin", Wh.Target(classic, "Cooking", fenv()).kind)          -- no Forever data: the older behaviour
    local t = Wh.Target(classic, "Cooking", fenv({ fdb = {} }))
    assert.are.equal("text", t.kind); assert.is_true(t.unverified); assert.are.equal("Old Cook", t.hint); assert.is_nil(t.mapID)
    local own = Wh.Target({ id = 51, src = "v", npcNames = { "Old Cook" }, way = { ids = { 4 }, confirmed = true } }, "Cooking", fenv({ fdb = {} }))
    assert.are.equal("pin", own.kind)                                            -- the library's own Forever capture names it
  end)

  it("a trainer ForeverDB does not list for the profession is not proposed", function()
    local learn = { id = 1, learn = 1, src = nil, way = { rank = "Apprentice" } }
    local e = { ntrainers = { Cooking = { { 2, 3 }, { 4, 3 } } }, fdb = {}, fdbTrainers = { Cooking = { [4] = true } } }
    assert.are.equal("Old Cook", Wh.Target(learn, "Cooking", fenv(e)).name)
    e.fdbTrainers = { Cooking = {} }
    local t = Wh.Target(learn, "Cooking", fenv(e))
    assert.are.equal("text", t.kind); assert.is_true(t.unverified)
  end)

  it("a quest recipe pins where Forever players were offered the quest, for the player's faction only", function()
    local quest = { id = 60, src = "q", way = { kind = "quest", site = true, questName = "Stew" } }
    local e = { fdb = {}, fdbQuests = { [60] = { { 7, "A", 3, "Alli Cook", 1413, 20, 20 }, { 8, "", 4, "Old Cook", 1411, 33, 34 } } } }
    local t = Wh.Target(quest, "Cooking", fenv(e))
    assert.are.equal("Old Cook", t.name); assert.are.same({ 1411, 33, 34 }, { t.mapID, t.x, t.y }); assert.is_true(t.confirmed)
    local who = Wh.Who(fenv(e))
    assert.are.same({ true, 8 }, { who.quest(60, "H") }); assert.are.same({ true, 7 }, { who.quest(60, "A") })
    e.fdbQuests[60][2] = nil
    assert.is_false((Wh.Who(fenv(e)).quest(60, "H")))
    assert.is_nil(Wh.Who(fenv(e)).quest(61, "H")); assert.is_false(Wh.Who(fenv(e)).quest(61, "H", { { id = 3 } }))
    assert.is_true(Wh.Who(fenv(e)).quest(61, "H", { { id = 3 }, { id = 99, faction = "Horde" } }))
  end)

  it("Who.vendors: false only when every vendor a source names belongs to the other faction", function()
    local who = Wh.Who(fenv({ fdbVendors = { [50] = { 3 } }, fdb = { [3] = { "Alli Cook", 1413, 20, 20, "A", true } } }))
    assert.is_false(who.vendors(50, "H")); assert.is_true(who.vendors(50, "A"))
    assert.is_false(who.vendors(51, "H", "Alli Cook (The Barrens)"))             -- the site's text, the NPC data knows the faction
    assert.is_true(who.vendors(51, "H", "Alli Cook (The Barrens), Far Cook (The Barrens)"))
    assert.is_nil(who.vendors(51, "H", "Nobody Known (Durotar)")); assert.is_nil(who.vendors(51, "H", nil))
  end)
end)

describe("shipped text is Latin-1 (what the game font draws)", function()
  it("no data or string file holds a character above U+00FF, and no cut list keeps its ellipsis", function()
    for _, f in ipairs({ "Strings.lua", "Data/ForeverTrainers.lua", "Data/Npcs.lua", "Data/ForeverNpcs.lua", "Data/ForeverRecipes.lua",
      "Data/Locations.lua", "Data/Recipes.lua", "Data/QuestItems.lua", "Data/Zones.lua", "Data/GatherNodes.lua" }) do
      local h = assert(io.open(f, "rb"))
      local text = h:read("a")
      h:close()
      for _, c in utf8.codes(text) do assert.is_true(c <= 255, ("%s: U+%04X"):format(f, c)) end
    end
    local data = {}
    assert(loadfile("Data/ForeverTrainers.lua"))("GoldCompass", data)
    assert(loadfile("Data/Zones.lua"))("GoldCompass", data)
    local cut = 0
    for id, e in pairs(data.ForeverTrainers) do
      if e.zmore then
        cut = cut + 1
        assert.is_nil(e.zone:find("%.%.%.")); assert.is_truthy(e.zone:match("%a$"), id .. ": " .. e.zone)
      end
    end
    assert.is_true(cut > 50)
    assert.is_true(data.ForeverTrainers[3505].zmore); assert.are.equal("Scarlet Monastery, Arathi Highlands, Badlands", data.ForeverTrainers[3505].zone)
  end)
end)
