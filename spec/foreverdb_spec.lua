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
