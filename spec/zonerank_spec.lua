-- Unit tests of the pure ranking module. Every expected value is worked out by hand in the comments.
local ns = {}
assert(loadfile("ZoneRank.lua"))("GoldCompass", ns)
local ZR = ns.ZoneRank

local MINING, HERB = "Mining", "Herb Gathering"
local nodes = {
  [1] = { type = MINING, item = 100, skill = 1, yield = 2 },
  [2] = { type = HERB, item = 200, skill = 1, yield = 2 },
  [3] = { type = MINING, item = 300, skill = 100, yield = 2 },
  [4] = { type = HERB, item = nil },                 -- Forever-only node with no known item
}
local skills = { [MINING] = 300, [HERB] = 300 }

-- prices[item] = { copper, ageDays }, vendors[item] = copper
local function run(zones, prices, vendors, extra)
  local input = {
    zones = zones, nodes = nodes, skills = skills,
    price = function(id) local p = prices[id]; if p then return p[1], p[2] end end,
    vendor = function(id) return (vendors or {})[id] end,
  }
  for k, v in pairs(extra or {}) do input[k] = v end
  return ZR.Rank(input)
end

describe("ZoneRank.Rank", function()
  it("ranks zones by gold per hour, best first", function()
    -- item 100: 1000c, item 200: 3000c, both fresh. Per node: 2 x price x 0.95.
    -- Zone 10: 100 spots of node 1 -> 1900 per node -> pace 60 -> 60 x 1900 = 114000
    -- Zone 20: 100 spots of node 2 -> 5700 per node -> 60 x 5700 = 342000
    local r = run({ [10] = { [1] = 100 }, [20] = { [2] = 100 } }, { [100] = { 1000, 0 }, [200] = { 3000, 1 } })
    assert.are.equal("ok", r.status)
    assert.are.equal(20, r.rows[1].zone)
    assert.are.equal(10, r.rows[2].zone)
    assert.is_near(342000, r.rows[1].copperPerHour, 1e-6)
    assert.is_near(114000, r.rows[2].copperPerHour, 1e-6)
  end)

  it("takes the 5% auction house cut off every sale", function()
    -- 1000c x 2 items = 2000c gross; x 0.95 = 1900c per node; 60 x 1900 = 114000 (not 120000)
    local r = run({ [10] = { [1] = 100 } }, { [100] = { 1000, 0 } })
    assert.is_near(114000, r.rows[1].copperPerHour, 1e-6)
  end)

  it("falls back to the vendor price (no cut) when the AH price is over 7 days old, and tags the zone partial", function()
    -- Zone 10: 50 spots of node 1 (price 1000c but 10 days old, vendor 50c -> 2 x 50 = 100 per node, no cut)
    --          50 spots of node 2 (3000c, age 0 -> 5700 per node)
    -- Weighted average = (50 x 100 + 50 x 5700) / 100 = 2900; 100 spots -> pace 60 -> 60 x 2900 = 174000
    local r = run({ [10] = { [1] = 50, [2] = 50 } },
      { [100] = { 1000, 10 }, [200] = { 3000, 0 } }, { [100] = 50 })
    assert.is_near(174000, r.rows[1].copperPerHour, 1e-6)
    assert.is_true(r.rows[1].partial)
    assert.is_false(r.rows[1].old)
  end)

  it("treats a price seen but of unknown age (nil age, above 21 days) as stale", function()
    local r = run({ [10] = { [1] = 50, [2] = 50 } },
      { [100] = { 1000, nil }, [200] = { 3000, 0 } }, { [100] = 50 })
    assert.is_near(174000, r.rows[1].copperPerHour, 1e-6)
  end)

  it("keeps the AH price when the price addon cannot give the age", function()
    local r = run({ [10] = { [1] = 100 } }, { [100] = { 1000, nil } }, nil, { ageKnown = false })
    assert.is_near(114000, r.rows[1].copperPerHour, 1e-6)
  end)

  it("uses prices of 3 to 7 days but tags the zone old; 2 days is still fresh; 8 days is not used", function()
    local function oneZone(age) return run({ [10] = { [1] = 100 } }, { [100] = { 1000, age } }, { [100] = 50 }) end
    assert.is_false(oneZone(2).rows[1].old)
    assert.is_true(oneZone(3).rows[1].old)
    assert.is_near(114000, oneZone(7).rows[1].copperPerHour, 1e-6) -- still the AH price
    assert.is_true(oneZone(7).anyOld)
    -- 8 days: vendor 50c -> 2 x 50 = 100 per node -> 60 x 100 = 6000; but then no fresh AH price anywhere
    assert.are.equal("no_scan", oneZone(8).status)
  end)

  it("tells why a zone is partial: stale price, never scanned, or no price at all", function()
    -- one fresh item (200) so the ranking exists; the other node varies
    local fresh = { [200] = { 3000, 0 } }
    local function zoneWith(prices, vendors)
      local p = { [200] = fresh[200] }
      for k, v in pairs(prices) do p[k] = v end
      return run({ [10] = { [1] = 50, [2] = 50 } }, p, vendors).rows[1]
    end
    local stale = zoneWith({ [100] = { 1000, 10 } }, { [100] = 50 })
    assert.is_true(stale.stale); assert.is_false(stale.unseen); assert.is_false(stale.unpriced)
    local unseen = zoneWith({}, { [100] = 50 })
    assert.is_true(unseen.unseen); assert.is_false(unseen.stale); assert.is_false(unseen.unpriced)
    local unpriced = zoneWith({}, {})
    assert.is_true(unpriced.unpriced); assert.is_false(unpriced.stale); assert.is_false(unpriced.unseen)
    assert.is_true(unpriced.partial)
  end)

  it("counts an item with no AH price and no vendor price as worth 0 and tags the zone partial", function()
    -- 50 spots node 1 (no price, no vendor -> 0), 50 spots node 2 (5700) -> average 2850 -> 60 x 2850 = 171000
    local r = run({ [10] = { [1] = 50, [2] = 50 } }, { [200] = { 3000, 0 } })
    assert.is_near(171000, r.rows[1].copperPerHour, 1e-6)
    assert.is_true(r.rows[1].partial)
  end)

  it("answers no_scan when no item has an AH price at all", function()
    local r = run({ [10] = { [1] = 100 } }, {}, { [100] = 50 })
    assert.are.equal("no_scan", r.status)
  end)

  it("lowers the pace in zones with fewer than 100 known spots, in proportion", function()
    -- 50 spots -> pace 60 x 50/100 = 30; 30 x 1900 = 57000
    local r = run({ [10] = { [1] = 50 } }, { [100] = { 1000, 0 } })
    assert.is_near(57000, r.rows[1].copperPerHour, 1e-6)
  end)

  it("leaves out zones with no gatherable spot and answers no_nodes when nothing is left", function()
    local r = run({ [10] = {}, [20] = { [4] = 30 } }, { [100] = { 1000, 0 } })
    assert.are.equal("no_nodes", r.status)
    assert.are.equal(0, #r.rows)
    assert.are.equal(30, r.unknownSpots) -- node 4 has no known item
    local r2 = run({ [10] = {}, [20] = { [1] = 100 } }, { [100] = { 1000, 0 } })
    assert.are.equal(1, #r2.rows)
    assert.are.equal(20, r2.rows[1].zone)
  end)

  it("only counts nodes the character has the skill for", function()
    -- node 3 needs skill 100; with Mining 50 it is ignored, so zone 10 only has node 1 (100 spots -> 114000)
    local r = run({ [10] = { [1] = 100, [3] = 100 } }, { [100] = { 1000, 0 }, [300] = { 99999, 0 } }, nil,
      { skills = { [MINING] = 50 } })
    assert.is_near(114000, r.rows[1].copperPerHour, 1e-6)
    assert.are.equal(100, r.rows[1].spots)
    -- no Herbalism at all: herb node ignored
    local r2 = run({ [10] = { [2] = 100 } }, { [200] = { 3000, 0 } }, nil, { skills = { [MINING] = 50 } })
    assert.are.equal("no_nodes", r2.status)
  end)

  it("lists the two items that contribute most, best first", function()
    -- item 100: 40 spots x 1900 = 76000; item 200: 40 spots x 5700 = 228000; item 300: 20 spots x 2 x 950 x ... = 20 x 1900 = 38000
    local r = run({ [10] = { [1] = 40, [2] = 40, [3] = 20 } },
      { [100] = { 1000, 0 }, [200] = { 3000, 0 }, [300] = { 1000, 0 } })
    assert.are.same({ 200, 100 }, r.rows[1].items)
  end)

  it("keeps at most 10 rows", function()
    local zones = {}
    for z = 1, 12 do zones[z] = { [1] = 100 } end
    assert.are.equal(10, #run(zones, { [100] = { 1000, 0 } }).rows)
  end)
end)

describe("ZoneRank.FormatMoney", function()
  it("rounds to the gold from 10g up, to the silver below", function()
    assert.are.equal("123g", ZR.FormatMoney(1234567)) -- 123.4567g
    assert.are.equal("10g", ZR.FormatMoney(99999))    -- rounds up to 10g, not "9g 100s"
    assert.are.equal("5g 0s", ZR.FormatMoney(50000))
    assert.are.equal("1g 24s", ZR.FormatMoney(12449)) -- 124.49s -> 124s
    assert.are.equal("35s", ZR.FormatMoney(3520))
    assert.are.equal("<1s", ZR.FormatMoney(40))
  end)
end)
