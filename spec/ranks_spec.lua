-- The generated rank table (Data/ForeverRanks.lua) and the fixes of tools/build-foreverdb.py and tools/build-forever-fixes.lua:
-- what is Forever data (caps, the expert books, NPCs seen in Forever) and what stays labelled as Classic's rule.
local ns = {}
for _, f in ipairs({ "Data/ForeverNpcs", "Data/ForeverRanks", "Data/ForeverFixes" }) do assert(loadfile(f .. ".lua"))("GoldCompass", ns) end
local LINES = { 171, 164, 333, 202, 165, 197, 185, 129, 356, 393, 186, 182 }

describe("profession ranks (Data/ForeverRanks.lua)", function()
  it("has the four ranks of every profession, Forever's caps and Classic's skill and level steps", function()
    for _, line in ipairs(LINES) do
      local r = ns.Ranks[line]
      assert.are.equal(4, #r, tostring(line))
      for i, want in ipairs({ { "Apprentice", 1, 5, 75 }, { "Journeyman", 50, 10, 150 }, { "Expert", 125, 20, 225 }, { "Artisan", 200, 35, 300 } }) do
        assert.are.same(want, { r[i][1], r[i][2], r[i][3], r[i][4] })
        assert.is_false(r[i].forever)                  -- the skill and level steps are Classic's: never presented as Forever's
        assert.is_true(r[i].way.kind == "trainer" or r[i].way.kind == "book" or r[i].way.kind == "quest")
      end
    end
  end)

  it("sells the expert books at vendors seen in Forever, for both factions, at ForeverDB's price", function()
    local function vendors(line)
      local w = ns.Ranks[line][3].way
      assert.are.equal("book", w.kind); assert.is_true(ns.Ranks[line][3].wayForever)
      local sides = {}
      for _, v in ipairs(w.vendors) do
        local n = ns.FdbNpcs[v[1]]
        assert.is_true(n[6], n[1]); assert.are.equal(10000, v[2])
        sides[n[5]] = true
      end
      return w.itemID, sides
    end
    local item, sides = vendors(185)
    assert.are.equal(16072, item); assert.is_true(sides.A and sides.H)          -- Expert Cookbook: Shandrina, Wulan
    item, sides = vendors(129)
    assert.are.equal(16084, item); assert.is_true(sides.A and sides.H)          -- Expert First Aid: Deneb Walker, Balai Lok'Wein
    item, sides = vendors(356)
    assert.are.equal(16083, item); assert.is_true(sides.AH)                     -- The Bass and You: Old Man Heming (Booty Bay)
  end)

  it("names trainers of the profession, an Artisan only where the title says so, never a specialization master", function()
    for _, line in ipairs(LINES) do
      for _, r in ipairs(ns.Ranks[line]) do
        if r.way.kind == "trainer" then
          assert.is_true(#r.way.ids > 0)
          for _, id in ipairs(r.way.ids) do assert.is_truthy(ns.FdbNpcs[id], tostring(id)) end
          assert.is_false(r.wayForever)               -- a trainer's rank is read from its title by Classic's rule
        end
      end
    end
    local artisan = {}
    for _, id in ipairs(ns.Ranks[165][4].way.ids) do artisan[id] = true end
    assert.is_nil(artisan[7866])                       -- Peter Galen, Master Dragonscale Leatherworker
    assert.is_nil(artisan[11041])                      -- a Journeyman alchemist is no Expert trainer either
    for _, id in ipairs(ns.Ranks[171][3].way.ids) do assert.are_not.equal(11041, id) end
  end)

  it("keeps Artisan Fishing's quest unconfirmed: it is not in Forever's quest list", function()
    assert.are.equal("quest", ns.Ranks[356][4].way.kind); assert.is_false(ns.Ranks[356][4].wayForever)
    assert.is_true(ns.Ranks[185][4].wayForever)        -- Clamlette Surprise is, and Dirge Quikcleave was seen in Forever
  end)
end)

describe("Forever fixes of this pass", function()
  it("places an NPC where ForeverDB's quest data saw it in Forever, not at its Classic place", function()
    local pratt = ns.FdbNpcs[7852]                      -- Pratt McGrubben, Feralas: Classic place until the quest data saw him
    assert.is_true(pratt[6]); assert.are.same({ 1444, 30.6, 42.7 }, { pratt[2], pratt[3], pratt[4] })
    assert.is_true(ns.FdbNpcs[7854][6]); assert.are.equal(74.5, ns.FdbNpcs[7854][3])   -- Jangdor Swiftstrider: Forever's 74.5, not Classic's 74.4
    assert.is_false(ns.FdbNpcs[989][6])                 -- Banalash: nothing from Forever, stays a Classic place
  end)

  it("knows the faction a reputation recipe asks (ForeverDB), not only the vendor text", function()
    assert.are.equal(529, ns.ForeverFixes.rep[17559])  -- Argent Dawn
    assert.are.equal(270, ns.ForeverFixes.rep[24366])  -- Zandalar Tribe
  end)

  it("still proposes a Journeyman-titled trainer for Apprentice recipes only", function()
    assert.are.equal(0, ns.FdbTrainers.Alchemy[1215])  -- Alchemist Mallory, Journeyman Alchemist
    assert.is_true(ns.FdbTrainers.Alchemy[4160])       -- Ainethil, Artisan Alchemist
  end)
end)
