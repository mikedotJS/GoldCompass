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

