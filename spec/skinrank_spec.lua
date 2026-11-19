-- Unit tests of the skinning ranking. Every expected value is worked out by hand in the comments, then checked by running the code.
local ns = {}
assert(loadfile("ZoneRank.lua"))("GoldCompass", ns)
assert(loadfile("SkinRank.lua"))("GoldCompass", ns)
local SR = ns.SkinRank

-- zones[uiMapID] = { { npcID, name, lvMin, lvMax, skill, spots =, foreverSpots =, items = { { itemID, perSkin, forever = } } } }
local zones = {
  [10] = {
    { 1, "Boar", 5, 6, 1, spots = 60, foreverSpots = 20, items = { { 100, 0.5, forever = true }, { 200, 0.5, forever = false } } },
    { 2, "Bear", 30, 31, 155, spots = 40, foreverSpots = 0, items = { { 300, 1, forever = false } } },
  },
  [20] = {
    { 3, "Wolf", 10, 11, 10, spots = 10, foreverSpots = 50, items = { { 200, 1, forever = true } } },
  },
}

-- prices[item] = { copper, ageDays }, vendors[item] = copper
local function run(skill, prices, vendors, extra)
  local input = {
    zones = zones, skill = skill,
    price = function(id) local p = prices[id]; if p then return p[1], p[2] end end,
    vendor = function(id) return (vendors or {})[id] end,
  }
  for k, v in pairs(extra or {}) do input[k] = v end
  return SR.Rank(input)
end

local fresh = { [100] = { 100, 0 }, [200] = { 200, 0 }, [300] = { 1000, 0 } }

describe("SkinRank.Rank", function()
  it("ranks zones by skinning gold per hour, spawn-weighted, with the AH cut", function()
    -- Skill 300, every beast skinnable.
    -- Zone 10: Boar weight 60 (Classic 60 > Forever 20): per skin 0.5 x 95 + 0.5 x 190 = 142.5 -> 60 x 142.5 = 8550
    --          Bear weight 40: 1 x 950 = 950 -> 40 x 950 = 38000. Average = 46550 / 100 = 465.5 -> pace 60 -> 27930
    -- Zone 20: Wolf weight 50 (Forever 50 > Classic 10): 190 per skin; pace 60 x 50/100 = 30 -> 5700
    local r = run(300, fresh)
    assert.are.equal("ok", r.status)
    assert.are.equal(10, r.rows[1].zone)
    assert.is_near(27930, r.rows[1].copperPerHour, 1e-6)
    assert.are.equal(100, r.rows[1].spots)
    assert.are.same({ 300, 200 }, r.rows[1].items)
    assert.are.equal(20, r.rows[2].zone)
    assert.is_near(5700, r.rows[2].copperPerHour, 1e-6)
  end)

  it("leaves out beasts whose skill is above the player's", function()
    -- Skill 100: the Bear (155) is out. Zone 10 = Boar only: 142.5 per skin, 60 spots -> pace 36 -> 5130,
    -- now below zone 20 (5700).
    local r = run(100, fresh)
    assert.are.equal(20, r.rows[1].zone)
    assert.are.equal(10, r.rows[2].zone)
    assert.is_near(5130, r.rows[2].copperPerHour, 1e-6)
    assert.are.equal(60, r.rows[2].spots)
  end)

  it("ranks nothing without skinning", function()
    assert.are.equal("no_nodes", run(nil, fresh).status)
    assert.are.equal("no_nodes", run(0, fresh).status)
  end)

  it("ranks on vendor prices alone (no_scan, rows sorted) and tags the zones partial", function()
    -- Vendors 10c / 20c / 50c, no cut. Zone 10: (60 x 15 + 40 x 50) / 100 = 29 -> 60 x 29 = 1740
    -- Zone 20: 20 per skin -> pace 30 -> 600
    local r = run(300, {}, { [100] = 10, [200] = 20, [300] = 50 })
    assert.are.equal("no_scan", r.status)
    assert.are.equal(10, r.rows[1].zone)
    assert.is_near(1740, r.rows[1].copperPerHour, 1e-6)
    assert.is_near(600, r.rows[2].copperPerHour, 1e-6)
    assert.is_true(r.rows[1].partial)
    assert.is_true(r.rows[1].unseen)
  end)

  it("counts an item with an unknown yield as 0 and tags the zone partial", function()
    local z = { [30] = { { 4, "Cat", 5, 6, 1, spots = 100, foreverSpots = 0,
      items = { { 200, 1, forever = false }, { 400, nil, forever = true } } } } }
    -- 190 per skin, 100 spots -> 60 x 190 = 11400
    local r = SR.Rank({ zones = z, skill = 300, price = function(id) if fresh[id] then return fresh[id][1], 0 end end,
      vendor = function() end })
    assert.is_near(11400, r.rows[1].copperPerHour, 1e-6)
    assert.is_true(r.rows[1].noYield)
    assert.is_true(r.rows[1].partial)
  end)

  it("takes the pace from the constants", function()
    local r = run(300, fresh, nil, { constants = { pace = 30 } })
    assert.is_near(13965, r.rows[1].copperPerHour, 1e-6)
  end)
end)

describe("Data/ForeverSkinZones.lua", function()
  local data = {}
  assert(loadfile("Data/ForeverSkinZones.lua"))("GoldCompass", data)
  local zoneNames = {}
  assert(loadfile("Data/Zones.lua"))("GoldCompass", zoneNames)

  it("uses Data/Zones.lua map IDs and well-formed beasts", function()
    local n = 0
    for zone, beasts in pairs(data.SkinZones) do
      assert.is_truthy(zoneNames.Zones[zone])
      for _, b in ipairs(beasts) do
        n = n + 1
        assert.is_number(b[1]); assert.is_string(b[2]); assert.is_number(b[5])
        assert.is_true(b[3] <= b[4])
        assert.is_true(b.spots + b.foreverSpots > 0)
        assert.is_boolean(b.skillForever)
        for _, it in ipairs(b.items) do
          assert.is_boolean(it.forever)
          assert.is_true(it[2] == nil or (it[2] > 0 and it[2] <= 6))
        end
      end
    end
    assert.is_true(n > 100)
  end)

  it("ranks real zones for a skinning 110 player on vendor prices", function()
    local r = SR.Rank({ zones = data.SkinZones, skill = 110, price = function() end, vendor = function() return 10 end })
    assert.are.equal("no_scan", r.status)
    assert.is_true(#r.rows >= 5)
    assert.is_true(r.rows[1].copperPerHour >= r.rows[5].copperPerHour)
  end)
end)
