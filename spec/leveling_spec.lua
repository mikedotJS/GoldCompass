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

describe("Leveling recipes to learn", function()
  -- reagent 10: AH 100c; output 30: AH 1000c (950 net). Skill 50, so "now" = learn <= 50 and "soon" = learn <= 75.
  -- Without thresholds the colour is estimated: yellow = learn + 30, green = learn + 45, gray = learn + 60.
  local crafts = {
    { id = 101, learn = 40, y = 45, g = 70, gr = 90, out = 30, oq = 1, mats = { { 10, 1 } } },  -- yellow at 50 (thresholds)
    { id = 102, learn = 50, src = "v", out = 30, oq = 1, mats = { { 10, 2 } } },
    { id = 103, learn = 60, src = "q", out = 30, oq = 1, mats = { { 10, 1 } } },
    { id = 104, learn = 10, out = 30, oq = 1, mats = { { 10, 1 } } },                           -- known
    { id = 105, learn = 10, y = 20, g = 30, gr = 45, out = 30, oq = 1, mats = { { 10, 1 } } },  -- gray at 50
    { id = 106, learn = 70, out = 30, oq = 1, mats = { { 99, 1 } } },                           -- reagent without price
    { id = 107, learn = 90, out = 30, oq = 1, mats = { { 10, 1 } } },                           -- out of reach
    { id = 108, out = 30, oq = 1, mats = { { 10, 1 } } },                                       -- learn skill unknown: not listed
  }
  local function learnCtx()
    local c = ctx()
    c.known = function(id) return id == 104 end
    return c
  end
  local function ids(list) local out = {} for i, e in ipairs(list) do out[i] = e.rec.id end return out end

  it("estimates the colour: data thresholds when present, else yellow +30, green +45, gray +60 from the learn skill", function()
    -- estimated spacing, learn skill 30: yellow 60, green 75, gray 90
    assert.are.equal(0, V.EstimateColor(30, 30))
    assert.are.equal(0, V.EstimateColor(59, 30))
    assert.are.equal(1, V.EstimateColor(60, 30))
    assert.are.equal(1, V.EstimateColor(74, 30))
    assert.are.equal(2, V.EstimateColor(75, 30))
    assert.are.equal(2, V.EstimateColor(89, 30))
    assert.are.equal(3, V.EstimateColor(90, 30))
    assert.are.equal(0, V.EstimateColor(10, 30))   -- below the learn skill counts as orange
    -- thresholds from the data win: yellow 45, green 50, gray 55
    assert.are.equal(0, V.EstimateColor(44, 30, 45, 50, 55))
    assert.are.equal(1, V.EstimateColor(45, 30, 45, 50, 55))
    assert.are.equal(2, V.EstimateColor(50, 30, 45, 50, 55))
    assert.are.equal(3, V.EstimateColor(55, 30, 45, 50, 55))
  end)

  it("builds crafts from the data rows of one profession, with learn skill and thresholds", function()
    local rows = {
      { 2329, "Alchemy", 1, 2454, 1, 3, 20, "Elixir", "2449:1,765:2", "v", 10, 20, 30, 40 },
      { 2330, "Alchemy", 1, 2454, 1, 1, 20, "Elixir 2", "2449:1" },
      { 1, "Tailoring", 1, 2, 1, 1, 1, "Other", "5:1" },
    }
    local out = V.Crafts(rows, "Alchemy")
    assert.are.equal(2, #out)
    assert.are.same({ { 2449, 1 }, { 765, 2 } }, out[1].mats)
    assert.are.equal(2, out[1].oq)      -- average of 1 and 3
    assert.are.equal("v", out[1].src); assert.are.equal(10, out[1].learn)
    assert.are.same({ 20, 30, 40 }, { out[1].y, out[1].g, out[1].gr })
    assert.is_nil(out[2].learn)         -- unknown learn skill
  end)

  it("labels the source and flags trainer recipes that may need a higher rank", function()
    assert.are.equal("trainer", V.Source({}))
    assert.are.equal("q", V.Source({ src = "q" }))
    assert.is_true(V.MayNeedRank({ learn = 50 }))
    assert.is_false(V.MayNeedRank({ learn = 30 }))
    assert.is_false(V.MayNeedRank({ learn = 80, src = "v" }))
  end)

  it("splits learnable now / soon, skips known, gray, unknown-skill and out-of-reach recipes", function()
    local r = V.Learnable(crafts, 50, learnCtx())
    -- 101: yellow (threshold 45) 0.75 ; net 100 - 950 = -850 ; -850 / 0.75
    -- 102: orange ; net 200 - 950 = -750 ; 103 (soon): learned at 60, orange then -> -850
    assert.are.same({ 101, 102 }, ids(r.now))
    assert.is_near(-1133.33, r.now[1].perPoint, 0.01)
    assert.are.equal(-750, r.now[2].perPoint)
    assert.are.same({ 103, 106 }, ids(r.soon))   -- 106 has an unknown reagent price: listed after the priced one
    assert.are.equal(-850, r.soon[1].perPoint)
    assert.is_true(r.soon[2].unpriced); assert.is_nil(r.soon[2].perPoint)
    assert.are.equal(101, r.best.rec.id)
    assert.are.equal(3, r.nowTotal)      -- 101, 102, 105 (104 is known, 108 has no learn skill)
    assert.are.equal(2, r.soonTotal)     -- 103, 106
    assert.are.equal(3, r.candidates)    -- priced and above gray: 101, 102, 103
    assert.are.equal(1, r.unpriced)      -- 106
  end)

  it("says so when the best recipe to learn beats the best known one, and by how much", function()
    assert.is_near(133.33, V.Learnable(crafts, 50, learnCtx(), nil, nil, -1000).gain, 0.01)
    assert.is_nil(V.Learnable(crafts, 50, learnCtx(), nil, nil, -2000).gain)
    assert.is_nil(V.Learnable(crafts, 50, learnCtx()).gain)
  end)

  it("trims each list to its limit", function()
    local r = V.Learnable(crafts, 50, learnCtx(), nil, { now = 1, soon = 0 })
    assert.are.same({ 101 }, ids(r.now)); assert.are.same({}, r.soon)
  end)

  it("lists every learnable recipe: no cap unless a limit is given", function()
    local many = {}
    for i = 1, 12 do many[i] = { id = i, learn = 10 + i, out = 30, oq = 1, mats = { { 10, 1 } } } end
    local r = V.Learnable(many, 50, learnCtx())
    assert.are.equal(12, #r.now)
    local soonMany = {}
    for i = 1, 12 do soonMany[i] = { id = i, learn = 60 + i, out = 30, oq = 1, mats = { { 10, 1 } } } end
    assert.are.equal(12, #V.Learnable(soonMany, 50, learnCtx()).soon)  -- learn 61..72, all within 25 points
    assert.are.equal(3, #V.Learnable(many, 50, learnCtx(), nil, { now = 3 }).now)
  end)

  it("uses the vendor sale value of the data when the output has no price", function()
    local c = { { id = 201, learn = 50, out = 40, oq = 1, sell = 500, mats = { { 10, 1 } } } }
    local r = V.Learnable(c, 50, learnCtx())
    assert.are.equal(100 - 500, r.now[1].net)
  end)

  it("keeps only recipes whose reagents are carried with the bag filter, and still counts the candidates", function()
    local r = V.Learnable(crafts, 50, learnCtx(), function(id) return id == 10 and 1 or 0 end)
    assert.are.same({ 101 }, ids(r.now))    -- 102 needs 2 x 10
    assert.are.same({ 103 }, ids(r.soon))   -- 106 needs reagent 99, not carried
    assert.are.equal(1, r.now[1].times)
    assert.are.equal(3, r.candidates)
    local none = V.Learnable(crafts, 50, learnCtx(), function() return 0 end)
    assert.are.equal(0, #none.now + #none.soon)
    assert.are.equal(3, none.candidates)    -- there was something to learn, just nothing craftable now
  end)

  it("tells the three empty cases apart: nothing to learn, everything gray, hidden by the bag filter", function()
    local none = V.Learnable({}, 50, learnCtx())
    assert.are.equal(0, none.nowTotal + none.soonTotal)                         -- really nothing
    local gray = V.Learnable({ crafts[5] }, 50, learnCtx())
    assert.is_true(gray.nowTotal > 0)
    assert.are.equal(0, gray.candidates + gray.unpriced + #gray.now)            -- all gray
    local hidden = V.Learnable({ crafts[1] }, 50, learnCtx(), function() return 0 end)
    assert.are.equal(0, #hidden.now + #hidden.soon)
    assert.is_true(hidden.candidates > 0)                                       -- hidden by the filter
  end)

  it("regression: the owner's real profiles (Travail du cuir 61, Cuisine 124, Pêche 150) have recipes to learn", function()
    local zr = {}
    assert(loadfile("ZoneRank.lua"))("GoldCompass", zr)
    local data = {}
    assert(loadfile("Data/Recipes.lua"))("GoldCompass", data)
    for _, p in ipairs(dofile("spec/fixtures/owner_profiles.lua")) do
      local known = {}
      for _, id in ipairs(p.known) do known[id] = true end
      local function run(price)
        local c = { known = function(id) return known[id] or false end, price = price, vendor = function() return 5 end,
          buy = function() end, ageKnown = false }
        return V.Learnable(V.Crafts(data.RecipeRows, p.english), p.skill, c, nil, { now = 4, soon = 3 })
      end
      local priced = run(function() return 100, 0 end)
      local unpriced = run(function() end)
      if p.english ~= "Fishing" then
        assert.is_true(#priced.now + #priced.soon > 0, p.english .. " (priced)")
        assert.is_true(#unpriced.now + #unpriced.soon > 0, p.english .. " (no prices)")
      end
    end
  end)

  it("lists unpriced recipes after the priced ones, by required skill, and never makes one the best", function()
    local c = {
      { id = 301, skill = 30, learn = 30, out = 30, oq = 1, mats = { { 99, 1 } } },      -- unknown reagent price
      { id = 302, skill = 20, learn = 20, out = 30, oq = 1, mats = { { 99, 1 } } },      -- unknown, lower skill: first of the unpriced
      { id = 303, skill = 40, learn = 40, out = 30, oq = 1, mats = { { 10, 2 } } },      -- priced: -750 at orange
    }
    -- at skill 45 the priced recipe 303 is orange (gap 5), 301 and 302 are only unpriced
    local r = V.Learnable(c, 45, learnCtx())
    assert.are.same({ 303, 302, 301 }, ids(r.now))
    assert.are.equal(303, r.best.rec.id)
    assert.are.equal(2, r.unpriced)
    -- with only unpriced recipes there is no best one
    local only = V.Learnable({ c[1], c[2] }, 45, learnCtx())
    assert.are.same({ 302, 301 }, ids(only.now))
    assert.is_nil(only.best); assert.is_nil(only.gain)
  end)

  it("prices a reagent: AH, then vendor buy price, then vendor sell value as a floor, then unknown", function()
    local function cost(id, ctxOver)
      local c = learnCtx()
      for k, f in pairs(ctxOver or {}) do c[k] = f end
      local r = V.Learnable({ { id = 1, skill = 50, learn = 50, out = 30, oq = 1, mats = { { id, 1 } } } }, 50, c)
      return r.now[1]
    end
    local e = cost(10)                                      -- AH 100
    assert.are.equal(100, e.cost); assert.is_falsy(e.floor)
    e = cost(20)                                            -- no AH, vendor buy 30
    assert.are.equal(30, e.cost); assert.is_falsy(e.floor)
    e = cost(31)                                            -- no AH, no buy price, vendor sell 200: a floor
    assert.are.equal(200, e.cost); assert.is_true(e.floor); assert.is_falsy(e.unpriced)
    e = cost(99)                                            -- nothing known
    assert.is_true(e.unpriced); assert.is_nil(e.perPoint)
    -- the vendor sell value never beats a real price
    e = cost(30)                                            -- AH 1000 and vendor 50: AH wins
    assert.are.equal(1000, e.cost); assert.is_falsy(e.floor)
  end)

  it("gives no 'beats the best known' gain when the best recipe is valued with a floor", function()
    local c = { { id = 1, skill = 50, learn = 50, out = 30, oq = 1, mats = { { 31, 1 } } } }
    local r = V.Learnable(c, 50, learnCtx(), nil, nil, 0)
    assert.is_true(r.best.floor)
    assert.is_nil(r.gain)
  end)
end)
