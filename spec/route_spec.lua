-- Unit tests of the gathering routes (Route.lua): skill-up colours, zone choice, the steps up to the next rank, and the loop order.
-- Expected values are worked out in the comments, then checked by running the code.
local ns = {}
assert(loadfile("Route.lua"))("GoldCompass", ns)
local R = ns.Route

describe("Route.Color", function()
  it("is orange below req + 25, yellow below + 50, green below + 100, gray after, nil below the requirement", function()
    assert.is_nil(R.Color(64, 65))
    assert.equals(0, R.Color(65, 65))
    assert.equals(0, R.Color(89, 65))
    assert.equals(1, R.Color(90, 65))
    assert.equals(2, R.Color(115, 65))
    assert.equals(2, R.Color(164, 65))
    assert.equals(3, R.Color(165, 65))
  end)
end)

-- nodes 1 (skill 1), 2 (skill 65) and 3 (skill 150) of Mining; node 4 is an herb
local nodes = {
  [1] = { type = "Mining", skill = 1 }, [2] = { type = "Mining", skill = 65 }, [3] = { type = "Mining", skill = 150 },
  [4] = { type = "Herb Gathering", skill = 1 },
}
local counts = {
  [10] = { [1] = 30, [2] = 5, [4] = 99 },   -- node 4 is an herb: not counted for Mining
  [20] = { [1] = 40 },
  [30] = { [3] = 50, [2] = 1 },
  [40] = { [2] = 0 },                         -- no spot: left out
}

describe("Route.GatherZones", function()
  local function zones(skill)
    local out = R.GatherZones("Mining", skill, nodes, counts)
    table.sort(out, function(a, b) return a.zone < b.zone end)
    return out
  end
  it("counts the spots of the nodes the skill can still gain from, best node first", function()
    -- skill 70: node 1 (req 1) is gray from 101, node 2 (req 65) is orange, node 3 (req 150) is out of reach
    local z = zones(70)
    assert.equals(3, #z)
    assert.same({ 10, 35, 165 }, { z[1].zone, z[1].spots, z[1].last })    -- 30 + 5 spots; node 2 turns gray at 165
    assert.same({ 1, 2 }, { z[1].nodes[1].id, z[1].nodes[2].id })
    assert.same({ 20, 40 }, { z[2].zone, z[2].spots })
    assert.same({ 30, 1 }, { z[3].zone, z[3].spots })                     -- only node 2 there
  end)
  it("leaves out the gray nodes", function()
    local z = zones(110)    -- node 1 is gray from 101
    assert.equals(2, #z)
    assert.same({ 10, 5 }, { z[1].zone, z[1].spots })
    assert.same({ 30, 1 }, { z[2].zone, z[2].spots })
  end)
  it("finds nothing when everything is gray or out of reach", function()
    assert.equals(0, #zones(400))
  end)
end)

describe("Route.SkinZones", function()
  local zones = {
    [10] = {   -- { npcID, name, lvMin, lvMax, skill, spots =, foreverSpots = }
      { 1, "Boar", 5, 6, 1, spots = 60, foreverSpots = 20 },       -- req 1: gray from 101
      { 2, "Hyena", 20, 22, 100, spots = 10, foreverSpots = 30 },   -- weight max(10, 30) = 30, orange at 105
      { 3, "Bear", 30, 31, 155, spots = 40, foreverSpots = 0 },     -- out of reach
      { 4, "Hare", 1, 1, 1, spots = 0, foreverSpots = 0 },         -- no spot
      { 6, "Jackal", 12, 13, 40, spots = 25, foreverSpots = 0 },    -- green at 105 (diff 65)
    },
    [20] = { { 5, "Wolf", 1, 2, 1, spots = 5, foreverSpots = 0 } },   -- gray at 105
  }
  it("takes the beasts that still give points, weighted by max(spots, foreverSpots), the most numerous first", function()
    local z = R.SkinZones(105, zones)
    assert.equals(1, #z)
    assert.same({ 10, 55, 12, 22, 200 }, { z[1].zone, z[1].spots, z[1].lo, z[1].hi, z[1].last })   -- 30 + 25 spots, Hyena + Jackal levels, Hyena gray at 200
    assert.same({ 2, 6 }, { z[1].beasts[1].id, z[1].beasts[2].id })
  end)
  it("builds the zone on the FOCUS most numerous beasts", function()
    local many = {}
    for i = 1, 8 do many[i] = { i, "B" .. i, 10, 10 + i, 1, spots = i, foreverSpots = 0 } end
    local z = R.SkinZones(1, { [7] = many })[1]
    assert.equals(R.FOCUS, #z.beasts)
    assert.same({ 8, 7, 6, 5, 4 }, { z.beasts[1].id, z.beasts[2].id, z.beasts[3].id, z.beasts[4].id, z.beasts[5].id })
    assert.equals(8 + 7 + 6 + 5 + 4, z.spots)
  end)
end)

describe("Route.Order", function()
  local function ids(list) local out = {} for i, z in ipairs(list) do out[i] = z.zone end return out end
  local cont = { [1] = "K", [2] = "K", [3] = "E", [4] = "K", [5] = nil }
  local low = { [1] = 10, [2] = 10, [3] = 10, [4] = 40, [5] = 10 }
  local ctx = { level = 16, continent = "K", contOf = function(z) return cont[z] end, lowest = function(z) return low[z] end }
  it("puts far zones last, then the player's continent, an unknown one, the other continent, then the most spots", function()
    local list = { { zone = 3, spots = 99 }, { zone = 4, spots = 99 }, { zone = 1, spots = 10 }, { zone = 5, spots = 50 }, { zone = 2, spots = 30 } }
    -- zone 4 starts at 40 (24 above 16): last; then K zones by spots (2: 30, 1: 10), the unknown one (5), the other continent (3)
    assert.same({ 2, 1, 5, 3, 4 }, ids(R.Order(list, ctx)))
  end)
  it("does not drop continent or level when they are unknown, and breaks ties by map ID", function()
    local list = { { zone = 9, spots = 5 }, { zone = 8, spots = 5 } }
    assert.same({ 8, 9 }, ids(R.Order(list, { })))
  end)
end)

describe("Route.Plan", function()
  -- a lookup that gives the zone by skill: zone 1 up to 125, zone 2 after
  local function lookup(skill)
    if skill < 125 then return { { zone = 1, last = 125 } } end
    return { { zone = 2, last = 180 } }
  end
  local function shape(plan)
    local out = {}
    for i, s in ipairs(plan) do out[i] = s.kind == "rank" and ("rank@" .. s.at) or ("zone" .. s.zone.zone .. ":" .. s.from .. ">" .. s.to) end
    return out
  end
  it("goes zone, rank, zone around a rank not reached yet", function()
    -- skill 110 of 150: the rank can be learned at 125 (max - 25); the second zone runs to 180 where its best node turns gray
    assert.same({ "zone1:110>125", "rank@125", "zone2:125>180" },
      shape(R.Plan({ skill = 110, max = 150, nextRank = "Expert", rankAt = 125, lookup = lookup })))
  end)
  it("starts with the rank when the skill already allows it", function()
    assert.same({ "rank@130", "zone2:130>180" },
      shape(R.Plan({ skill = 130, max = 150, nextRank = "Expert", rankNow = true, rankAt = 125, lookup = lookup })))
  end)
  it("is the rank step only at the cap", function()
    assert.same({ "rank@150" }, shape(R.Plan({ skill = 150, max = 150, nextRank = "Expert", capped = true, rankAt = 125, lookup = lookup })))
    assert.same({}, shape(R.Plan({ skill = 300, max = 300, capped = true, lookup = lookup })))
  end)
  it("chains a second zone when the first turns gray before the rank, at three steps at most", function()
    local function short(skill)
      if skill < 115 then return { { zone = 1, last = 115 } } end
      if skill < 125 then return { { zone = 3, last = 125 } } end
      return { { zone = 2, last = 300 } }
    end
    assert.same({ "zone1:100>115", "zone3:115>125", "rank@125" },
      shape(R.Plan({ skill = 100, max = 150, nextRank = "Expert", rankAt = 125, lookup = short })))
  end)
  it("stops when no zone gives points", function()
    assert.same({}, shape(R.Plan({ skill = 110, max = 150, nextRank = "Expert", rankAt = 125, lookup = function() return {} end })))
  end)
  it("has no rank step when there is no rank above", function()
    assert.same({ "zone1:110>125" }, shape(R.Plan({ skill = 110, max = 125, lookup = lookup })))
  end)
end)

describe("Route.Loop", function()
  it("is empty without points and a single point alone", function()
    assert.same({ points = {}, length = 0 }, R.Loop({}))
    local one = R.Loop({ { x = 10, y = 10 } })
    assert.equals(1, #one.points)
    assert.equals(0, one.length)
  end)
  it("starts at the point closest to the player and untangles the loop (2-opt)", function()
    -- the corners of a square, given in a crossing order: the shortest loop is its perimeter (4 x 20 = 80)
    local pts = { { x = 10, y = 10 }, { x = 30, y = 30 }, { x = 30, y = 10 }, { x = 10, y = 30 } }
    local loop = R.Loop(pts, { x = 29, y = 31 })
    assert.same({ 30, 30 }, { loop.points[1].x, loop.points[1].y })
    assert.is_true(math.abs(loop.length - 80) < 1e-6)
  end)
  it("begins with the westmost point when the player is nowhere", function()
    local loop = R.Loop({ { x = 50, y = 50 }, { x = 20, y = 70 }, { x = 80, y = 10 } })
    assert.equals(20, loop.points[1].x)
  end)
  it("merges points closer than a radius and counts them", function()
    local loop = R.Loop({ { x = 10, y = 10 }, { x = 10.4, y = 10 }, { x = 10, y = 10.5 }, { x = 60, y = 60 } })
    assert.equals(2, #loop.points)
    assert.equals(3, loop.points[1].n)
  end)
  it("keeps at most 12 points by widening the merge radius", function()
    local pts = {}
    for i = 0, 49 do pts[#pts + 1] = { x = 5 + (i % 10) * 9, y = 5 + math.floor(i / 10) * 18 } end
    local loop = R.Loop(pts, { x = 0, y = 0 })
    assert.is_true(#loop.points <= R.MAX_POINTS)
    local total = 0
    for _, p in ipairs(loop.points) do total = total + p.n end
    assert.equals(50, total)    -- no point is lost, they are merged
  end)
  it("gives the same loop on every run", function()
    local pts = {}
    for i = 1, 30 do pts[i] = { x = (i * 37) % 97, y = (i * 53) % 89 } end
    local a, b = R.Loop(pts, { x = 50, y = 50 }), R.Loop(pts, { x = 50, y = 50 })
    assert.same(a, b)
  end)
end)

describe("Route.Unpack", function()
  it("reads 4 base-36 characters per point (x then y, tenths of a percent), Forever points before the dot", function()
    -- "ad" = 10 x 36 + 13 = 373 -> 37.3 ; "0a" = 10 -> 1.0 ; "rs" = 27 x 36 + 28 = 1000 -> 100 ; "00" = 0
    local f, c = R.Unpack("ad0arsrs.0a00")
    assert.same({ { x = 37.3, y = 1 }, { x = 100, y = 100 } }, f)
    assert.same({ { x = 1, y = 0 } }, c)
  end)
  it("takes a string without a dot as Forever points, and tolerates an empty side, nil and a cut point", function()
    local f, c = R.Unpack("0a0b")
    assert.same({ { x = 1, y = 1.1 } }, f)
    assert.same({}, c)
    f, c = R.Unpack(".0a0b")
    assert.same({}, f)
    assert.equals(1, #c)
    f, c = R.Unpack(nil)
    assert.same({}, f); assert.same({}, c)
    f = R.Unpack("0a0b0")                            -- a trailing partial point is ignored
    assert.equals(1, #f)
  end)
end)

describe("Route.Plan merge", function()
  it("keeps one zone step when the same zone comes back after the rank", function()
    local ns = {}
    assert(loadfile("Route.lua"))("GoldCompass", ns)
    local z = { zone = 1413, last = 185 }
    local steps = ns.Route.Plan({ skill = 110, max = 150, nextRank = "Expert", rankAt = 125, lookup = function() return { z } end })
    assert.are.equal(2, #steps)
    assert.are.same({ "zone", 110, 185 }, { steps[1].kind, steps[1].from, steps[1].to })
    assert.are.same({ "rank", 125 }, { steps[2].kind, steps[2].at })
  end)
end)

describe("Route.Plan one step per zone", function()
  local function plan(lookup, input)
    local ns = {}
    assert(loadfile("Route.lua"))("GoldCompass", ns)
    input.lookup = lookup
    return ns.Route.Plan(input)
  end

  it("two zone steps in a row in the same zone are one step (another herb turns gray, the zone is the same)", function()
    local zones = { [100] = { zone = 1413, last = 140 }, [140] = { zone = 1413, last = 190 } }
    local steps = plan(function(skill) return { skill >= 140 and zones[140] or zones[100] } end, { skill = 100, max = 225 })
    assert.are.equal(1, #steps)
    assert.are.same({ "zone", 100, 190 }, { steps[1].kind, steps[1].from, steps[1].to })
  end)

  it("different zones stay different steps", function()
    local steps = plan(function(skill) return { skill >= 140 and { zone = 1442, last = 190 } or { zone = 1413, last = 140 } } end, { skill = 100, max = 225 })
    assert.are.equal(2, #steps)
    assert.are.equal(1413, steps[1].zone.zone)
    assert.are.equal(1442, steps[2].zone.zone)
  end)
end)
