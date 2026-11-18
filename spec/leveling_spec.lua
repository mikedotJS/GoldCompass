-- Pure tests of the leveling advisor. Every expected value is worked out in the comments.
local ns = {}
assert(loadfile("ZoneRank.lua"))("GoldCompass", ns)
assert(loadfile("Leveling.lua"))("GoldCompass", ns)
local V = ns.Leveling

-- reagent 10: AH 100c (fresh); reagent 20: vendor buy 30c, no AH; output 30: AH 1000c (950 net), vendor sell 50
-- output 31, 32, 33: no AH price, vendor sell 200, 180, 130; reagent 99: no price at all
local function ctx()
  local ah = { [10] = { 100, 0 }, [30] = { 1000, 0 } }
  return {
    price = function(id) local p = ah[id]; if p then return p[1], p[2] end end,
    vendor = function(id) return ({ [30] = 50, [31] = 200, [32] = 180, [33] = 130 })[id] end,
    buy = function(id) return ({ [20] = 30 })[id] end,
  }
end

describe("Leveling.Evaluate", function()
  it("estimates the chance of a skill point by colour", function()
    assert.are.equal(1, V.CHANCE[0])      -- orange
    assert.are.equal(0.75, V.CHANCE[1])   -- yellow
    assert.are.equal(0.25, V.CHANCE[2])   -- green
    assert.are.equal(0, V.CHANCE[3])      -- gray
  end)

  it("computes net cost per point, and a recipe whose sale value beats its cost has a negative cost", function()
    -- cost = 2 x 100 (AH) + 1 x 30 (vendor buy) = 230; result = 950 (AH 1000 less 5%) > vendor 50 -> net = 230 - 950 = -720
    local function at(d) return V.Evaluate({ id = 1, d = d, out = 30, oq = 1, mats = { { 10, 2 }, { 20, 1 } } }, ctx()) end
    local orange = at(0)
    assert.are.equal(230, orange.cost)
    assert.are.equal(950, orange.result)
    assert.are.equal(-720, orange.net)
    assert.are.equal(-720, orange.perPoint)            -- / 1
    assert.are.equal(-960, at(1).perPoint)             -- / 0.75
    assert.are.equal(-2880, at(2).perPoint)            -- / 0.25
    assert.is_nil(at(3).perPoint)                      -- gray: no point can be gained
  end)

  it("uses the cheaper of the AH price and the vendor buy price for a reagent", function()
    local c = ctx()
    c.buy = function(id) if id == 10 then return 60 end end
    -- reagent 10: AH 100 vs vendor 60 -> 60; 2 x 60 = 120
    assert.are.equal(120, V.Evaluate({ id = 1, d = 0, out = 31, oq = 1, mats = { { 10, 2 } } }, c).cost)
  end)

  it("lists reagents with no price instead of guessing", function()
    local e = V.Evaluate({ id = 1, d = 0, out = 31, oq = 1, mats = { { 10, 1 }, { 99, 1 } } }, ctx())
    assert.are.same({ 99 }, e.missing)
  end)
end)

describe("Leveling.Plan", function()
  it("ranks by cost per point, cheapest first, ties by id, leaving out gray and unpriced recipes", function()
    -- A: 10 x reagent 20 (30c) = 300, out 31 sells 200 -> net 100, orange -> 100 per point
    -- B: 8 x 30 = 240, out 32 sells 180 -> net 60, yellow -> 60 / 0.75 = 80
    -- C: 5 x 30 = 150, out 33 sells 130 -> net 20, green -> 20 / 0.25 = 80 (ties with B: id 2 before id 3)
    -- D: gray (never listed). E: reagent 99 has no price -> unpriced.
    local prof = { skill = 50, recipes = {
      [1] = { id = 1, d = 0, out = 31, oq = 1, mats = { { 20, 10 } } },
      [2] = { id = 2, d = 1, out = 32, oq = 1, mats = { { 20, 8 } } },
      [3] = { id = 3, d = 2, out = 33, oq = 1, mats = { { 20, 5 } } },
      [4] = { id = 4, d = 3, out = 31, oq = 1, mats = { { 20, 1 } } },
      [5] = { id = 5, d = 0, out = 31, oq = 1, mats = { { 99, 1 } } },
    } }
    local plan = V.Plan(prof, ctx())
    local order = {}
    for i, e in ipairs(plan.rows) do order[i] = e.rec.id end
    assert.are.same({ 2, 3, 1 }, order)
    assert.are.equal(80, plan.rows[1].perPoint)
    assert.are.equal(2, plan.best.rec.id)
    assert.are.equal(1, #plan.unpriced)
    assert.are.same({ 99 }, plan.unpriced[1].missing)
    assert.are.equal(5, plan.known)
  end)

  it("answers no best recipe when nothing is known", function()
    local plan = V.Plan({ recipes = {} }, ctx())
    assert.is_nil(plan.best)
    assert.are.equal(0, plan.known)
  end)
end)

describe("Leveling bag counts", function()
  -- recipe A needs 2 x 10 and 1 x 20; recipe B needs 1 x 10; recipe C needs 3 x 20 (reagent 20: vendor 30c, 10: AH 100c)
  local function prof()
    return { skill = 50, max = 75, recipes = {
      [1] = { id = 1, d = 0, out = 30, oq = 1, mats = { { 10, 2 }, { 20, 1 } } },
      [2] = { id = 2, d = 0, out = 30, oq = 1, mats = { { 10, 1 } } },
      [3] = { id = 3, d = 0, out = 30, oq = 1, mats = { { 20, 3 } } },
    } }
  end
  local function counts(t) return function(id) return t[id] or 0 end end

  it("crafts min over reagents of floor(owned / needed) times and lists what is short", function()
    local rec = prof().recipes[1]
    local n, short = V.Craftable(rec, counts({ [10] = 5, [20] = 2 })) -- floor(5/2) = 2 ; floor(2/1) = 2
    assert.are.equal(2, n); assert.are.same({}, short)
    n, short = V.Craftable(rec, counts({ [10] = 5, [20] = 1 }))        -- min(2, 1) = 1
    assert.are.equal(1, n)
    n, short = V.Craftable(rec, counts({ [10] = 1, [20] = 0 }))        -- 0 ; short 1 x 10 and 1 x 20
    assert.are.equal(0, n); assert.are.same({ { 10, 1 }, { 20, 1 } }, short)
  end)

  it("treats a recipe with no known reagent as not craftable", function()
    assert.are.equal(0, (V.Craftable({ id = 9, mats = {} }, counts({}))))
  end)

  it("filters to craftable recipes, keeps the sort by cost per point, values owned reagents at market price", function()
    local plan = V.Plan(prof(), ctx(), 5, counts({ [10] = 5, [20] = 1 })) -- A x1, B x5, C not craftable (3 x 20 > 1)
    assert.are.equal(2, plan.craftable)
    assert.are.equal(2, #plan.rows)
    -- B: 100 - 950 = -850 per point ; A: 230 - 950 = -720 per point -> B first (ascending)
    assert.are.equal(2, plan.best.rec.id); assert.are.equal(5, plan.best.times)
    assert.are.equal(-850, plan.best.perPoint)      -- cost is still the market price of the reagent even if owned
    assert.are.equal(1, plan.rows[2].rec.id); assert.are.equal(1, plan.rows[2].times)
  end)

  it("without a count function nothing is filtered", function()
    local plan = V.Plan(prof(), ctx(), 5)
    assert.are.equal(3, #plan.rows)
    assert.is_nil(plan.craftable); assert.is_nil(plan.almost)
  end)

  it("suggests the closest alternative: fewest reagents short, then fewest units", function()
    -- nothing craftable: A short 1 x 10 and 1 x 20 (2 reagents), B short 1 x 10 (1 reagent), C short 3 x 20 (1 reagent, 3 units)
    local plan = V.Plan(prof(), ctx(), 5, counts({}))
    assert.are.equal(0, plan.craftable)
    assert.is_nil(plan.best)
    assert.are.equal(2, plan.almost.rec.id)
    assert.are.same({ { 10, 1 } }, plan.almost.short)
  end)
end)
