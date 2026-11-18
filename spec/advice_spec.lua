-- Unit tests of Advice and Here. Prices: item 100 = 100c (95c net of the 5% AH cut), 200 = 200c (190 net),
-- 300 = 1000c (950 net), all fresh. Every expected value is worked out in the comments.
local ns = {}
assert(loadfile("ZoneRank.lua"))("GoldCompass", ns)
assert(loadfile("Advice.lua"))("GoldCompass", ns)
assert(loadfile("Here.lua"))("GoldCompass", ns)
local A, H = ns.Advice, ns.Here

local rows = {
  { 1, "Alchemy", 10, 300, 1, 1, 5, "Potion", "100:2,200:1" },
  { 2, "Alchemy", 10, 300, 1, 1, 5, "Elixir", "100:1" },
  { 3, "Tailoring", 10, 300, 1, 1, 5, "Bag", "100:1" },
}

local function ctx(extra)
  local prices = { [100] = { 100, 0 }, [200] = { 200, 0 }, [300] = { 1000, 0 }, [500] = { 50, 0 } }
  local c = {
    price = function(id) local p = prices[id]; if p then return p[1], p[2] end end,
    vendor = function(id) return ({ [100] = 10, [500] = 20, [700] = 122 })[id] end,
    skills = { Alchemy = 50 }, known = function(id) return id == 1 end,
    quests = function() return nil end, level = 10, faction = "A",
    disenchant = function() return nil end, index = A.NewIndex(rows),
  }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

describe("Advice.Evaluate and Uses", function()
  it("values a recipe: result minus the ingredients' opportunity cost", function()
    -- recipe 1: result 1 x 950 net; cost 2 x 95 + 1 x 190 = 380; profit 570
    local e = A.Evaluate(A.NewIndex(rows).byMat[200][1], ctx())
    assert.are.equal(950, e.result)
    assert.are.equal(380, e.cost)
    assert.are.equal(570, e.profit)
    assert.are.equal("known", e.status)
  end)

  it("gives each status and sorts usable recipes first", function()
    local uses = A.Uses(100, ctx())
    assert.are.equal(3, uses.total)
    assert.are.equal("known", uses.list[1].status)   -- recipe 1, known
    assert.are.equal("learn", uses.list[2].status)   -- recipe 2: Alchemy 50 >= 10, not known
    assert.are.equal("noprof", uses.list[3].status)  -- recipe 3: no Tailoring
    assert.are.equal("locked", A.Uses(100, ctx({ skills = { Alchemy = 5 }, known = function() return false end })).list[1].status)
    local q = A.NewIndex({ { 9, "Alchemy", 10, 300, 1, 1, 5, "Q", "100:1", "q", 10 } })
    assert.are.equal("quest", A.Uses(100, ctx({ index = q, known = function() return false end })).list[1].status)
  end)
end)

describe("Advice.Decide", function()
  it("recommends crafting a known recipe when it beats selling, and counts whole crafts", function()
    -- item 100 x5: sale 95. Recipe 1 (qty 2): (950 - (380 - 2 x 95)) / 2 = 380 per unit > 95.
    -- crafts = floor(5/2) = 2; total = 2 x 2 x 380 + 1 x 95 = 1615
    local d = A.Decide({ id = 100, count = 5 }, ctx())
    assert.are.equal("craft", d.action)
    assert.are.equal(1, d.recipe.recipe.id)
    assert.are.equal(2, d.crafts)
    assert.are.equal(380, d.unit)
    assert.are.equal(1615, d.total)
  end)

  it("sells on the AH when no known recipe beats it", function()
    -- recipe not known: 5 x 95 = 475
    local d = A.Decide({ id = 100, count = 5 }, ctx({ known = function() return false end }))
    assert.are.equal("ah", d.action)
    assert.are.equal(475, d.total)
    assert.is_true(d.hasAh)
  end)

  it("falls back to the vendor when the AH price is over 7 days old, and to nothing without any price", function()
    local old = ctx({ price = function(id) if id == 100 then return 100, 10 end end, known = function() return false end })
    local d = A.Decide({ id = 100, count = 3 }, old)
    assert.are.equal("vendor", d.action)
    assert.are.equal(30, d.total) -- 3 x 10
    local none = A.Decide({ id = 999, count = 3 }, ctx())
    assert.are.equal("none", none.action)
    assert.are.equal(0, none.total)
  end)

  it("keeps what an open quest asks for and values only the rest", function()
    local quests = function(id) if id == 100 then return { { quest = "Pie", zone = "Westfall", level = 10, faction = "B", count = 3 } } end end
    local d = A.Decide({ id = 100, count = 5 }, ctx({ quests = quests, known = function() return false end }))
    assert.are.equal(3, d.keep)
    assert.are.equal("Pie", d.quest)
    assert.are.equal(190, d.total) -- 2 x 95
    -- out-levelled by more than 2 levels (10 + 2 < 20): nothing kept
    assert.are.equal(0, A.Decide({ id = 100, count = 5 }, ctx({ quests = quests, level = 20, known = function() return false end })).keep)
    -- other faction: nothing kept
    local horde = function() return { { quest = "X", zone = "Z", level = 10, faction = "H", count = 3 } } end
    assert.are.equal(0, A.Decide({ id = 100, count = 5 }, ctx({ quests = horde, known = function() return false end })).keep)
  end)

  it("never recommends the AH for a soulbound item", function()
    -- item 100 is worth 95c on the AH and 10c at the vendor; bound -> vendor, 3 x 10 = 30
    local d = A.Decide({ id = 100, count = 3, bound = true }, ctx({ known = function() return false end }))
    assert.are.equal("vendor", d.action)
    assert.are.equal(30, d.total)
  end)

  it("keeps for quests only within 2 levels below and 5 above the character, and never for city donations", function()
    local function keepFor(quests, level)
      return A.Decide({ id = 100, count = 20 }, ctx({ quests = function() return quests end, level = level, known = function() return false end })).keep
    end
    local function q(level, count, zone) return { quest = "Q" .. level, zone = zone or "Z", level = level, faction = "B", count = count } end
    assert.are.equal(5, keepFor({ q(14, 5) }, 14))   -- same level
    assert.are.equal(5, keepFor({ q(19, 5) }, 14))   -- 5 above: kept
    assert.are.equal(0, keepFor({ q(20, 5) }, 14))   -- 6 above: not yet
    assert.are.equal(5, keepFor({ q(12, 5) }, 14))   -- 2 below: kept
    assert.are.equal(0, keepFor({ q(11, 5) }, 14))   -- 3 below: out-levelled
    -- a level-14 character with 20 Silk and the 60-silk city donation (level 26, zone "a capital city"): nothing kept
    assert.are.equal(0, keepFor({ q(26, 60, "a capital city") }, 14))
    assert.are.equal(0, keepFor({ q(14, 60, "a capital city") }, 14)) -- even at the right level, donations are skipped
  end)

  it("takes the largest quest need, not the sum", function()
    local quests = { { quest = "A", zone = "Z", level = 14, faction = "B", count = 4 },
      { quest = "B", zone = "Z", level = 15, faction = "B", count = 6 }, { quest = "C", zone = "Z", level = 16, faction = "B", count = 3 } }
    local d = A.Decide({ id = 100, count = 20 }, ctx({ quests = function() return quests end, level = 14, known = function() return false end }))
    assert.are.equal(6, d.keep) -- max(4, 6, 3), not 13
    assert.are.equal("B", d.quest)
    assert.are.equal(14 * 95, d.total) -- the other 14 are valued
  end)

  it("matches Herbalism, Skinning and Fishing recipe rows to the character's skills", function()
    local idx = A.NewIndex({ { 70, "Herbalism", 1, 300, 1, 1, 5, "Herb row", "100:1" }, { 71, "Fishing", 1, 300, 1, 1, 5, "Fish row", "100:1" },
      { 72, "Skinning", 1, 300, 1, 1, 5, "Skin row", "100:1" } })
    local skills = { ["Herb Gathering"] = 40, Fishing = 10 }
    local u = A.Uses(100, ctx({ index = idx, skills = skills, known = function() return false end }))
    local st = {}
    for _, e in ipairs(u.list) do st[e.recipe.name] = e.status end
    assert.are.equal("learn", st["Herb row"])
    assert.are.equal("learn", st["Fish row"])
    assert.are.equal("noprof", st["Skin row"])
  end)

  it("marks recipes without any source as guessed", function()
    local idx = A.NewIndex({ { 80, "Alchemy", 1, 300, 1, 1, 5, "No source", "100:1" }, { 81, "Alchemy", 1, 300, 1, 1, 5, "Vendor", "100:1", "v", 40 } })
    local u = A.Uses(100, ctx({ index = idx, known = function() return false end }))
    local g = {}
    for _, e in ipairs(u.list) do g[e.recipe.name] = e.recipe.guessed end
    assert.is_true(g["No source"])
    assert.is_false(g["Vendor"])
  end)

  it("does not recommend a craft whose ingredient cost is only a vendor sell price, and flags it", function()
    -- recipe 1 needs item 100 x2 and item 200 x1; make item 200 (a vial) have no AH price, vendor sell 1c.
    local c = ctx({ price = function(id) local p = ({ [100] = { 100, 0 }, [300] = { 1000, 0 } })[id]; if p then return p[1], p[2] end end,
      vendor = function(id) return ({ [100] = 10, [200] = 1 })[id] end })
    local e = A.Evaluate(A.NewIndex(rows).byMat[200][1], c)
    assert.is_true(e.uncertain)
    local d = A.Decide({ id = 100, count = 5 }, c)
    assert.are_not.equal("craft", d.action)
    assert.are.equal("Potion", d.maybe)
    -- once the vendor BUY price is known (40c), the cost is certain and the craft is recommended
    c.buy = function(id) if id == 200 then return 40 end end
    local e2 = A.Evaluate(A.NewIndex(rows).byMat[200][1], c)
    assert.is_false(e2.uncertain)
    assert.are.equal(2 * 95 + 40, e2.cost) -- 230
    assert.are.equal("craft", A.Decide({ id = 100, count = 5 }, c).action)
  end)

  it("recommends disenchanting gear when it beats selling", function()
    -- item 500: AH 50c -> 47.5 net, vendor 20. Disenchant 1000c -> 950 net. 950 > 47.5
    local d = A.Decide({ id = 500, count = 1, gear = true }, ctx({ disenchant = function() return 1000 end }))
    assert.are.equal("disenchant", d.action)
    assert.are.equal(950, d.total)
    -- not gear: never disenchanted
    assert.are.equal("ah", A.Decide({ id = 500, count = 1 }, ctx({ disenchant = function() return 1000 end })).action)
  end)
end)

describe("Advice.Bags", function()
  it("groups by action and totals the value, leaving kept items out of the group totals", function()
    local items = {
      { id = 100, count = 5 },                -- craft: 1615
      { id = 500, count = 1, gear = true },   -- disenchant: 950 (grouped with craft)
      { id = 700, count = 1 },                -- vendor only: 122
    }
    local r = A.Bags(items, ctx({ disenchant = function() return 1000 end }))
    assert.are.equal(2, #r.groups.craft)
    assert.are.equal(1, #r.groups.vendor)
    assert.are.equal(1615 + 950, r.totals.craft)
    assert.are.equal(122, r.totals.vendor)
    assert.are.equal(1615 + 950 + 122, r.total)
    assert.is_true(r.anyAh)
    assert.are.equal(100, r.groups.craft[1].item.id == 100 and 100 or 0) -- the 1615 entry sorts before the 950 one
  end)

  it("reports no AH price anywhere, and an empty bag", function()
    local r = A.Bags({ { id = 700, count = 2 } }, ctx())
    assert.is_false(r.anyAh)
    assert.are.equal(244, r.total) -- 2 x 122
    assert.are.equal(0, A.Bags({}, ctx()).total)
  end)
end)

describe("Here", function()
  local zones = { { zone = 1, copperPerHour = 300 }, { zone = 2, copperPerHour = 100 }, { zone = 3, copperPerHour = 50 } }

  it("compares the current zone with the best or the runner-up", function()
    local c2 = H.Compare(zones, 2)
    assert.are.equal(2, c2.rank)
    assert.are.equal(1, c2.other.zone)
    assert.are.equal(3, c2.ratio) -- 300 / 100
    assert.is_false(c2.best)
    local c1 = H.Compare(zones, 1)
    assert.is_true(c1.best)
    assert.are.equal(2, c1.other.zone)
    assert.are.equal(3, c1.ratio)
    assert.is_nil(H.Compare(zones, 99))
  end)

  it("computes what a missing profession would add", function()
    -- zone 5: 100 Mining spots (item 100, 95 net -> 190/node) and 100 Herb spots (item 200, 190 net -> 380... see below)
    -- node 2 yields 2 x 190 = 380 per node (item 200 net 190). Mining only: avg 190, pace 60 -> 11400.
    -- With herbs: avg = (100 x 190 + 100 x 380) / 200 = 285, 200 spots -> pace 60 -> 17100. Gain 5700.
    local input = {
      zones = { [5] = { [1] = 100, [2] = 100 } },
      nodes = { [1] = { type = "Mining", item = 100, skill = 1, yield = 2 }, [2] = { type = "Herb Gathering", item = 200, skill = 1, yield = 2 } },
      skills = { Mining = 300 }, price = ctx().price, vendor = ctx().vendor,
    }
    assert.is_near(5700, H.ProfessionGain(input, 5, "Herb Gathering", 100), 1e-6)
    assert.is_nil(H.ProfessionGain(input, 5, "Mining", 300)) -- already has it
  end)

  it("lists quest items of the zone that are still relevant, best first", function()
    local items = {
      [100] = { { quest = "Pie", zone = "Westfall", level = 12, faction = "A", count = 4 } },
      [200] = { { quest = "Other", zone = "Elwynn Forest", level = 12, faction = "A", count = 1 } },
      [300] = { { quest = "Horde", zone = "Westfall", level = 12, faction = "H", count = 1 } },
      [500] = { { quest = "Old", zone = "Westfall", level = 1, faction = "A", count = 1 } },
    }
    local list = H.Pickups("Westfall", items, ctx())
    assert.are.equal(1, #list)
    assert.are.equal(100, list[1].item)
    assert.are.equal(4, list[1].count)
    assert.are.equal(95, list[1].unit)
  end)
end)
