-- The vendored Forever data (Data/ForeverRecipes.lua, Data/ForeverTrainers.lua) through ForeverDB.lua and Leveling, with no stub:
-- the owner's Leatherworking 61 case.
local ns = {}
for _, f in ipairs({ "Data/Recipes", "Data/ForeverTrainers", "Data/ForeverRecipes", "ZoneRank", "ForeverDB", "Leveling" }) do
  assert(loadfile(f .. ".lua"))("GoldCompass", ns)
end
local V, DB = ns.Leveling, ns.ForeverDB

describe("vendored Forever data", function()
  it("is the LibProfessionDB v1.10.1 data of the Forever build", function()
    local version, build = DB:GetVersion()
    assert.are.equal("v1.10.1", version); assert.are.equal("1.60.1.70938", build)
    assert.is_true(DB:IsReady()); assert.are.equal(2517, DB:Count())
    assert.is_true(DB:HasProfession(165)); assert.is_true(DB:ProfessionCount(165) > 500)
  end)

  it("answers like the library: recipe, thresholds, reagents, teaching item, hidden and auto-granted flags", function()
    local fine = DB:GetRecipes(165)[2158]
    assert.are.equal(2307, fine.craftedItemId); assert.are.equal(65, fine.requiredSkill)
    assert.are.same({ 65, 95, 110, 125 }, fine.difficulty); assert.are.same({ [2318] = 7, [2320] = 2 }, fine.reagents)
    assert.are.equal("Fine Leather Boots", fine.name)             -- English fallback of Data/Recipes.lua
    assert.are.equal(2406, DB:GetRecipeItem(2158))
    assert.is_true(DB:IsAutoTaughtRecipe(2149))                    -- granted with the profession
    assert.is_true(DB:IsHiddenRecipe(2671)); assert.is_false(DB:IsHiddenRecipe(2158))
    assert.are.equal("Vanilla", DB:IsBorrowed(2158, "sources")); assert.is_nil(DB:IsBorrowed(1255143, "sources"))
    assert.is_true(DB:GetRecipeSources(2158).drop.total > 0); assert.is_nil(DB:GetRecipeSources(2158).trainer)
  end)

  it("knows Forever's own vendor prices", function()
    local vendors = DB:GetRecipeSources(25704).vendor
    local v
    for _, n in ipairs(vendors) do if n.id == 3085 then v = n end end
    assert.is_not_nil(v); assert.are.equal("Alliance", v.faction)
    assert.are.same({ { copper = 450 } }, DB:GetVendorCost(25704, 3085))
    assert.are.same({ { currencyID = 3402, amount = 240 } }, DB:GetVendorCost(1213622, 256732))
  end)
end)

describe("Leatherworking 61 with the vendored data (owner's case)", function()
  local known = {}
  for _, id in ipairs(dofile("spec/fixtures/owner_profiles.lua")[1].known) do known[id] = true end
  local byId = {}
  for _, c in ipairs(V.Crafts(ns.RecipeRows, "Leatherworking")) do byId[c.id] = c end
  local ctx = { price = function(id) if id == 2318 or id == 2320 then return 100, 0 end end, vendor = function() return 10 end,
    buy = function() end, ageKnown = false, known = function(id) return known[id] end }

  for _, faction in ipairs({ "H", "A" }) do
    it("faction " .. faction .. ": 29 learnable now, 37 soon, 12 already gray; the trainer, rank and drop answers", function()
      local crafts = V.LibCrafts(DB, 165, faction, function(id) return byId[id] end, ns.ForeverTrainers)
      local r = V.Learnable(crafts, 61, ctx)
      assert.are.equal(29, #r.now); assert.are.equal(37, #r.soon); assert.are.equal(12, #r.gray)
      local by = {}
      for _, bucket in ipairs({ r.now, r.soon, r.gray }) do for _, e in ipairs(bucket) do by[e.rec.id] = e end end
      assert.are.equal("trainer", by[9062].rec.way.kind); assert.are.equal(100, by[9062].rec.fee)        -- Petite giberne, 1s
      for _, id in ipairs({ 1255143, 1255144, 1255146 }) do                                              -- the Forever boots
        assert.are.equal("trainer", by[id].rec.way.kind, tostring(id)); assert.are.equal(500, by[id].rec.fee)
        assert.is_true(by[id].gray, tostring(id))
      end
      assert.are.equal("trainer", by[3763].rec.way.kind)                                                  -- Ceinture élégante
      assert.are.equal("Journeyman", by[3763].rec.way.rank); assert.are.equal(300, by[3763].rec.fee)
      assert.are.equal("drop", by[2158].rec.way.kind); assert.is_false(by[2158].recommend)                -- Fine Leather Boots
    end)
  end
end)

describe("the site's observed sources and thresholds against the library's borrowed ones", function()
  local function crafts(line, faction, forever)
    local by = {}
    for _, c in ipairs(V.LibCrafts(DB, line, faction or "H", nil, forever)) do by[c.id] = c end
    return by
  end
  local site = crafts(185, "H", ns.ForeverTrainers)          -- Cooking, with the site's data
  local lib = crafts(185, "H")                                -- Cooking, the library alone

  it("Dig Rat Stew: the library's borrowed vendor becomes the quest the site observed", function()
    assert.are.equal("vendor", lib[6417].how.kind)           -- borrowed world-database source
    assert.are.equal("quest", site[6417].how.kind)
    assert.are.equal("Dig Rat Stew", site[6417].how.questName)
  end)

  it("the library's own Forever vendors are kept", function()
    assert.is_true(DB:HasOwnVendors(25704)); assert.is_false(DB:HasOwnVendors(6417))
    local mine = V.Way(DB, 25704, DB:GetRecipes(185)[25704] or DB:GetRecipes(171)[25704] or {}, "A", { [25704] = { k = "q", quest = "x" } })
    assert.are.equal("vendor", mine.kind)                      -- seen on live merchants: the site's "quest" does not replace it
  end)

  it("a borrowed drop with a site zone carries the zone text; the site's kinds with no zone leave it empty", function()
    local camp = site[1283400]                                -- Journeyman Campfire
    assert.are.equal("drop", camp.how.kind); assert.are.equal("Wailing Caverns", camp.how.zone)
  end)

  it("degenerate library thresholds are replaced by the site's: Journeyman Campfire 95/100/105, Camp Tent 20/22/25", function()
    assert.are.same({ 90, 95, 95, 95 }, DB:GetRecipes(185)[1283400].difficulty)      -- the library: yellow == green == gray
    assert.are.same({ 95, 100, 105 }, { site[1283400].y, site[1283400].g, site[1283400].gr })
    local tent = crafts(165, "H", ns.ForeverTrainers)[1229432]
    assert.are.same({ 20, 22, 25 }, { tent.y, tent.g, tent.gr })                    -- the library says 20/20/20/20
  end)

  it("non-degenerate library thresholds are kept even when the site's differ", function()
    local c = crafts(165, "H", ns.ForeverTrainers)[435819]                          -- Faintly Glowing Leather: lib 205/210/220, site 200/210/220
    assert.are.same({ 205, 210, 220 }, { c.y, c.g, c.gr })
  end)

  it("the colours the game gave the owner (recorded profession windows) all agree with the thresholds used", function()
    local checked = 0
    for _, p in ipairs(dofile("spec/fixtures/owner_profiles.lua")) do
      for id, d in pairs(p.recorded) do
        local e, ft = DB:GetRecipes(p.line)[id], ns.ForeverTrainers[id]
        assert.is_not_nil(e, tostring(id))
        local th = V.Difficulty(e.difficulty, ft and ft.learn or e.requiredSkill, ft)
        assert.are.equal(d, V.EstimateColor(p.skill, th[1], th[2], th[3], th[4]), ("%s %d %s"):format(p.english, id, e.name))
        checked = checked + 1
      end
    end
    assert.are.equal(33, checked)
  end)
end)
