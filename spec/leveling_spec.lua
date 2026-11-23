-- Pure tests of the leveling advisor. Every expected value is worked out in the comments.
local ns = {}
assert(loadfile("ZoneRank.lua"))("GoldCompass", ns)
assert(loadfile("Leveling.lua"))("GoldCompass", ns)
assert(loadfile("Data/ForeverTrainers.lua"))("GoldCompass", ns)
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
  it("ranks by ingredients per point (a vendor-sold reagent counts half, over the chance); gray and unpriced recipes left out", function()
    -- A: 10 x reagent 20 (30c) = 300, out 31 sells 200 -> net 100, orange -> 100 per point
    -- B: 8 x 30 = 240, out 32 sells 180 -> net 60, yellow -> 60 / 0.75 = 80
    -- reagent 20 is sold by a vendor (half a unit): A 5 units / 1 = 5, B 4 / 0.75 = 5.33, C 2.5 / 0.25 = 10
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
    assert.are.same({ 1, 2, 3 }, order)
    assert.are.equal(5, plan.rows[1].unitsPerPoint); assert.are.equal(100, plan.rows[1].perPoint)
    assert.is_near(5.33, plan.rows[2].unitsPerPoint, 0.01); assert.are.equal(10, plan.rows[3].unitsPerPoint)
    assert.are.equal(1, plan.best.rec.id)
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
    -- B: 100 - 50 (the vendor sale of the output) = 50 per point ; A: 230 - 50 = 180 per point -> B first (ascending)
    assert.are.equal(2, plan.best.rec.id); assert.are.equal(5, plan.best.times)
    assert.are.equal(50, plan.best.perPoint)        -- cost is still the market price of the reagent even if owned
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
    -- the recovery is the vendor sale of the output (50); the AH resale is not counted when levelling
    -- 101: yellow (thresholds 45 / 70 / 90), chance (90 - 50) / (90 - 45) = 0.889 ; net 100 - 50 = 50 ; 50 / 0.889 = 56.25
    -- 102: orange ; net 200 - 50 = 150 ; 103 (soon): learned at 60, orange then, net 100 - 50 = 50
    assert.are.same({ 101, 102 }, ids(r.now))
    assert.is_near(56.25, r.now[1].perPoint, 0.01)
    assert.are.equal(150, r.now[2].perPoint)
    assert.are.same({ 103, 106 }, ids(r.soon))   -- 106 has an unknown reagent price: listed after the priced one
    assert.are.equal(50, r.soon[1].perPoint)
    assert.is_true(r.soon[2].unpriced); assert.is_nil(r.soon[2].perPoint)
    assert.are.equal(101, r.best.rec.id)         -- 1 ingredient / 0.889 = 1.125 per point against 2 for 102 (orange, 2 reagents)
    assert.are.equal(3, r.nowTotal)      -- 101, 102, 105 (104 is known, 108 has no learn skill)
    assert.are.equal(2, r.soonTotal)     -- 103, 106
    assert.are.equal(3, r.candidates)    -- priced and above gray: 101, 102, 103
    assert.are.equal(1, r.unpriced)      -- 106
  end)

  it("says so when the best recipe to learn beats the best known one, and by how much", function()
    local g = V.Learnable(crafts, 50, learnCtx(), nil, nil, 3)                            -- best 101: 1.125 ingredients per point vs 3
    assert.is_near(1.875, g.gain, 1e-9); assert.are.equal(3, g.gainFrom); assert.is_near(1.125, g.gainTo, 1e-9)
    assert.is_nil(V.Learnable(crafts, 50, learnCtx(), nil, nil, 1).gain)
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
     if not p.recordedOnly then
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

describe("Leveling.CraftButton", function()
  it("is busy, then combat, then nothing to craft, then closed (opens the window), then ready (crafts)", function()
    local function st(over)
      local s = { times = 3, open = true, combat = false, crafting = false }
      for k, v in pairs(over) do s[k] = v end
      return V.CraftButton(s)
    end
    assert.are.same({ state = "ready", enabled = true, action = "craft" }, st({}))
    assert.are.same({ state = "closed", enabled = true, action = "open" }, st({ open = false }))
    assert.are.same({ state = "none", enabled = false }, st({ times = 0 }))
    assert.are.same({ state = "combat", enabled = false }, st({ combat = true }))
    assert.are.same({ state = "busy", enabled = false }, st({ crafting = true, combat = true }))   -- busy wins
    assert.are.same({ state = "none", enabled = false }, st({ times = 0, open = false }))            -- nothing to craft, whatever the window
  end)
end)

describe("Leveling recipes offered by a recorded trainer", function()
  -- skill 61, reagent 10: AH 100, output 30: vendor 50 (the AH resale is not counted when levelling): an orange recipe costs 50 per point.
  -- Default colour spacing from the skill needed: yellow +30, green +45, gray +60, so a recipe taught at 35 is orange at 61
  -- (yellow from 65) and turns gray at 95: it can give 95 - 61 = 34 points.
  local function mk(over)
    local c = { id = 401, learn = 60, out = 30, oq = 1, mats = { { 10, 1 } } }
    for k, v in pairs(over or {}) do c[k] = v end
    if c.learn == false then c.learn = nil end         -- `learn = false`: a craft the Classic data does not teach
    return c
  end
  local function lctx(offers)
    local c = ctx()
    c.known = function() return false end
    c.offer = function(id) return offers[id] end
    return c
  end
  local kamari = { npc = "Kamari", mapID = 1411, x = 50, y = 25, zone = "Durotar" }
  local function offer(skill, cost, status)
    return { skill = skill, cost = cost, status = status or "available", npc = "Kamari", mapID = 1411, x = 50, y = 25, zone = "Durotar" }
  end

  it("takes the real skill and the real fee from the trainer, over the Classic data", function()
    local r = V.Learnable({ mk() }, 61, lctx({ [401] = offer(35, 500) }))
    local e = r.now[1]
    assert.are.equal(35, e.rec.learn)                  -- the Classic data said 60
    assert.are.equal(500, e.rec.fee)
    assert.is_nil(e.rec.src)                           -- a trainer teaches it
    assert.are.equal("Kamari", e.rec.trainer.npc)
    assert.are.equal(50, e.perPoint)                   -- the crafting figure alone
  end)

  it("spreads the fee over the points the recipe can still give: gray at learn + 60", function()
    local e = V.Learnable({ mk() }, 61, lctx({ [401] = offer(35, 500) })).now[1]
    assert.are.equal(34, e.points)                     -- 95 - 61
    assert.is_near(50 + 500 / 34, e.amortised, 1e-9)
    -- the data's gray threshold wins when there is one, and a recipe nearly gray still counts at least 1 point
    e = V.Learnable({ mk({ gr = 63 }) }, 61, lctx({ [401] = offer(35, 500) })).now[1]
    assert.are.equal(2, e.points)
    e = V.Learnable({ mk({ gr = 61 }) }, 61, lctx({ [401] = offer(35, 500) }))
    assert.are.equal(0, #e.now)                        -- already gray: nothing to gain, not listed
    assert.is_nil(V.Learnable({ mk() }, 61, lctx({ [401] = offer(35, 0) })).now[1].amortised)  -- free: no fee to spread
  end)

  it("ranks by the amortised value and compares it with the best known recipe", function()
    local crafts = { mk({ id = 401 }), mk({ id = 402, learn = false }) }
    local r = V.Learnable(crafts, 61, lctx({ [401] = offer(35, 500), [402] = offer(35, 100) }), nil, nil, 60)
    assert.are.same({ 402, 401 }, { r.now[1].rec.id, r.now[2].rec.id })     -- fee 100 beats fee 500 (52.94 < 64.71)
    assert.are.equal(402, r.best.rec.id)
    assert.is_near(60 - 1, r.gain, 1e-9)                                   -- 1 ingredient per point against 60 for the best known one
  end)

  it("lists a Forever recipe the data does not teach, and hides one the trainer lists as already known", function()
    local crafts = { mk({ id = 402, learn = false }), mk({ id = 403, learn = 30 }) }
    local r = V.Learnable(crafts, 61, lctx({ [402] = offer(35, 500), [403] = offer(30, 500, "used") }))
    assert.are.equal(1, #r.now)
    assert.are.equal(402, r.now[1].rec.id)
    -- without the trainer, 402 is unknown to the data and 403 is learnable
    r = V.Learnable(crafts, 61, lctx({}))
    assert.are.equal(1, #r.now); assert.are.equal(403, r.now[1].rec.id)
  end)

  it("keeps the data ranking untouched when no trainer was recorded (no gating on visits)", function()
    local r = V.Learnable({ mk() }, 61, lctx({}))
    assert.are.equal(60, r.now[1].rec.learn); assert.is_nil(r.now[1].rec.trainer)
    assert.are.equal(r.now[1].perPoint, r.now[1].rec.fee and r.now[1].amortised or r.now[1].perPoint)
  end)
end)

-- A stand-in for LibProfessionDB with the owner's Leatherworking case
local function fakeLib(extra)
  local recipes = {
    [9062] = { name = "Petite giberne en cuir", craftedItemId = 7279, reagents = { [2318] = 3, [2320] = 4 }, requiredSkill = 25, difficulty = { 25, 55, 70, 85 } },
    [1255143] = { name = "Bottes lueur-de-lune", craftedItemId = 252427, reagents = { [2318] = 12 }, requiredSkill = 35, difficulty = { 35, 40, 40, 40 } },
    [1255144] = { name = "Chaussures en écailles de Murloc", craftedItemId = 252426, reagents = { [2318] = 12 }, requiredSkill = 35, difficulty = { 35, 40, 40, 40 } },
    [1255146] = { name = "Mules de dragonnet noir", craftedItemId = 252424, reagents = { [2318] = 12 }, requiredSkill = 35, difficulty = { 35, 40, 40, 40 } },
    [2158] = { name = "Bottes élégantes en cuir", craftedItemId = 2307, reagents = { [2318] = 7 }, requiredSkill = 60, difficulty = { 60, 85, 100, 115 } },
    [2149] = { name = "Bottes cousu main", craftedItemId = 2302, reagents = { [2318] = 2 }, requiredSkill = 1, difficulty = { 1, 25, 40, 55 } },
    [9999] = { name = "Jamais obtenable", craftedItemId = 1, reagents = { [2318] = 1 }, requiredSkill = 30, difficulty = { 30, 60, 75, 90 } },
  }
  local DB = {
    sources = { [9062] = { trainer = { { id = 1, name = "Kamari" }, total = 29 } },
      [2158] = { drop = { { id = 2, name = "Some mob" }, total = 951 } } },
    items = { [1255143] = 252764, [1255144] = 252763, [1255146] = 252761 },
    hidden = { [9999] = true }, auto = { [2149] = true }, borrowed = {},
  }
  for k, v in pairs(extra or {}) do DB[k] = v end
  function DB:GetRecipes() return recipes end
  function DB:IsHiddenRecipe(id) return self.hidden[id] or false end
  function DB:IsAutoTaughtRecipe(id) return self.auto[id] or false end
  function DB:IsBorrowed(id, field) return self.borrowed[id .. field] end
  function DB:GetRecipeSources(id) return self.sources[id] end
  function DB:GetRecipeItem(id) return self.items[id] end
  return DB, recipes
end

describe("Leveling.Way (how a recipe is obtained, from the library)", function()
  local function way(sources, over, entry)
    local DB = fakeLib({ sources = { [1] = sources }, items = over and over.items or {}, borrowed = over and over.borrowed or {} })
    function DB:GetVendorCost(id, npc) return over and over.cost and over.cost[npc] end
    function DB:GetSourceFaction(npc) return over and over.faction and over.faction[npc] end
    return V.Way(DB, 1, entry or { requiredSkill = 40 }, "A")
  end

  it("a trainer is confirmed only when its required skill is the client's own", function()
    local w = way({ trainer = { { id = 5, name = "Kamari" }, total = 1 } })
    assert.are.equal("trainer", w.kind); assert.is_true(w.confirmed)
    w = way({ trainer = { { id = 5, name = "Kamari" }, total = 1 } }, { borrowed = { ["1requiredSkill"] = "Vanilla" } })
    assert.are.equal("trainer", w.kind); assert.is_false(w.confirmed)        -- "entraîneur (non confirmé sur Forever)"
    w = way({ trainer = { { id = 5, name = "Kamari" }, total = 1 } }, nil, {})
    assert.is_false(w.confirmed)                                             -- no required skill at all
  end)

  it("a drop or container is never a trainer; the source with the best priority wins", function()
    assert.are.equal("drop", way({ drop = { { id = 2, name = "Mob" }, total = 951 } }).kind)
    assert.are.equal("container", way({ container = { { id = 2, name = "Chest" }, total = 1 }, drop = { { id = 3, name = "Mob" }, total = 12 } }).kind)
    assert.are.equal("quest", way({ quest = { { id = 4, name = "Giver" }, total = 1 }, drop = { { id = 3, name = "Mob" }, total = 12 } }).kind)
    assert.are.equal("trainer", way({ trainer = { { id = 5, name = "T" }, total = 1 }, vendor = { { id = 6, name = "V" }, total = 1 } }).kind)
  end)

  it("a vendor: its NPC of the player's faction and its gold price (a currency price has no gold figure)", function()
    local sources = { vendor = { { id = 6, name = "Alliance vendor" }, { id = 7, name = "Horde vendor" }, total = 2 } }
    local w = way(sources, { cost = { [6] = { { copper = 500 }, { copper = 250 } }, [7] = { { copper = 100 } } }, faction = { [6] = "Alliance", [7] = "Horde" } })
    assert.are.equal("vendor", w.kind)
    assert.are.same({ "Alliance vendor" }, w.npcs)              -- the Horde vendor is not for us
    assert.are.equal(750, w.vendorCost)                          -- 500 + 250 copper
    w = way(sources, { cost = { [6] = { { currencyID = 3402, amount = 40 } } }, faction = { [6] = "Alliance", [7] = "Horde" } })
    assert.is_nil(w.vendorCost)                                  -- Merchant's Favor: no gold price
    assert.are.same({ id = 3402, amount = 40 }, w.currency)
  end)

  it("a teaching item and no source is an item recipe; nothing at all is unknown unless the skill is the client's own", function()
    local w = way(nil, { items = { [1] = 252764 } })
    assert.are.equal("item", w.kind); assert.are.equal(252764, w.itemID)
    assert.are.equal("unknown", way(nil, nil, {}).kind)
    local captured = way(nil)                                    -- own requiredSkill, no source: captured at a Forever trainer
    assert.are.equal("trainer", captured.kind); assert.is_true(captured.confirmed)
  end)
end)

describe("Leveling.LibCrafts", function()
  it("leaves out never-implemented and auto-granted recipes", function()
    local crafts = V.LibCrafts(fakeLib(), 165, "A")
    local ids = {}
    for _, c in ipairs(crafts) do ids[c.id] = true end
    assert.is_nil(ids[9999]); assert.is_nil(ids[2149])
    assert.is_true(ids[9062] and ids[2158])
  end)

  it("takes the library's yellow / green / gray thresholds unless its tiers are unanchored", function()
    local DB, recipes = fakeLib({ borrowed = { ["7requiredSkill"] = "Vanilla" } })
    recipes[5] = { name = "a", reagents = {}, requiredSkill = 40, difficulty = { 40, 60, 80, 100 } }
    recipes[6] = { name = "b", reagents = {}, difficulty = { 1, 10, 20, 30 } }                     -- no required skill, placeholder 1
    recipes[7] = { name = "c", reagents = {}, requiredSkill = 70, difficulty = { 1, 10, 20, 30 } } -- borrowed skill, placeholder 1
    recipes[8] = { name = "d", reagents = {}, difficulty = { 20, 40, 60, 80 } }                    -- no required skill but anchored
    local by = {}
    for _, c in ipairs(V.LibCrafts(DB, 165, "A")) do by[c.id] = c end
    assert.are.same({ 60, 80, 100 }, { by[5].y, by[5].g, by[5].gr })
    assert.is_nil(by[6].y); assert.is_nil(by[7].gr)                                                 -- estimate applies
    assert.are.same({ 40, 60, 80 }, { by[8].y, by[8].g, by[8].gr })
    assert.is_true(by[7].borrowed)
  end)
end)

describe("Leveling.Learnable with library crafts: the owner's Leatherworking case at skill 61", function()
  -- reagent 2318 and the outputs are worth money; the teaching item 252764 has an auction price, 252763 and 252761 have none
  local function lcx(over)
    local prices = { [2318] = 100, [2320] = 100, [7279] = 1000, [252427] = 1000, [252426] = 1000, [252424] = 1000, [2307] = 60000, [252764] = 700 }
    for k, v in pairs(over or {}) do prices[k] = v end
    local c = {
      price = function(id) if prices[id] then return prices[id], 0 end end,
      vendor = function() return 0 end, buy = function() end, ageKnown = false,
      known = function() return false end,
    }
    return c
  end
  local function ids(list) local out = {} for i, e in ipairs(list) do out[i] = e.rec.id end return out end
  local DB = fakeLib()
  local crafts = V.LibCrafts(DB, 165, "A")

  it("lists the trainer recipe, the teaching-item recipes and the drop; excludes hidden and auto-granted", function()
    local r = V.Learnable(crafts, 61, lcx())
    local all = {}
    for _, bucket in ipairs({ r.now, r.soon, r.gray }) do for _, e in ipairs(bucket) do all[e.rec.id] = e end end
    assert.is_not_nil(all[9062]); assert.is_not_nil(all[2158])
    for _, id in ipairs({ 1255143, 1255144, 1255146 }) do assert.is_not_nil(all[id], tostring(id)) end   -- the three Forever recipes
    assert.is_nil(all[9999]); assert.is_nil(all[2149])
    assert.are.equal(5, r.nowTotal + r.soonTotal)                   -- 9062, 2158 and the three Forever recipes
  end)

  it("Fine Leather Boots is a drop: listed, never recommended and never labelled trainer, even when it is the cheapest", function()
    local r = V.Learnable(crafts, 61, lcx())
    local fine
    for _, e in ipairs(r.now) do if e.rec.id == 2158 then fine = e end end
    assert.is_not_nil(fine)
    assert.are.equal("d", fine.rec.src); assert.are.equal("drop", fine.rec.way.kind)
    assert.is_false(fine.recommend)
    assert.is_true(fine.perPoint < r.best.perPoint)                 -- cheaper per point than the recommendation...
    assert.are.equal(9062, r.best.rec.id)                           -- ...but the best is the trainer recipe
  end)

  it("uses the library's real thresholds: Petite giberne is yellow at 61, the Forever boots are gray", function()
    local r = V.Learnable(crafts, 61, lcx())
    assert.are.equal(9062, r.best.rec.id)
    assert.are.equal(1, r.best.rec.d)                              -- yellow: 55 <= 61 < 70
    assert.are.same({ 1255143, 1255144, 1255146 }, ids(r.gray))    -- 40 / 40 / 40: gray at 61, listed apart and never ranked
    for _, e in ipairs(r.gray) do assert.is_true(e.gray); assert.is_nil(e.perPoint) end
  end)

  it("a teaching item with an auction price is the learning fee and makes the recipe recommendable", function()
    local gray = V.Learnable(crafts, 61, lcx()).gray
    local by = {}
    for _, e in ipairs(gray) do by[e.rec.id] = e end
    assert.are.equal("item", by[1255143].rec.way.kind)
    assert.are.equal(700, by[1255143].rec.fee); assert.is_true(by[1255143].recommend)    -- 252764 has an AH price
    assert.is_nil(by[1255144].rec.fee); assert.is_false(by[1255144].recommend)           -- no AH price: not recommendable
    assert.are.equal("i", by[1255143].rec.src)
    assert.are.equal(252764, by[1255143].rec.teachItem)
  end)

  it("the library's thresholds beat the estimate (orange here, yellow by the estimate)", function()
    local DB2, recipes = fakeLib()
    recipes[20] = { name = "x", craftedItemId = 7279, reagents = { [2318] = 1 }, requiredSkill = 20, difficulty = { 20, 62, 63, 64 } }
    DB2.sources[20] = { trainer = { { id = 1, name = "T" }, total = 1 } }
    local cs = V.LibCrafts(DB2, 165, "A")
    local r = V.Learnable(cs, 61, lcx())
    for _, e in ipairs(r.now) do if e.rec.id == 20 then assert.are.equal(0, e.rec.d) end end   -- 61 < 62: still orange
    assert.are.equal(1, V.EstimateColor(61, 20))                                               -- the estimate would say yellow (50)
  end)

  it("the recorded trainer window beats the library: real skill and fee, confirmed", function()
    local c = lcx()
    c.offer = function(id) if id == 1255144 then return { skill = 35, cost = 500, status = "available", npc = "Kamari", mapID = 1411, x = 50, y = 25 } end end
    local r = V.Learnable(crafts, 61, c)
    local e
    for _, bucket in ipairs({ r.now, r.soon, r.gray }) do for _, x in ipairs(bucket) do if x.rec.id == 1255144 then e = x end end end
    assert.are.equal(500, e.rec.fee); assert.are.equal("Kamari", e.rec.trainer.npc)
    assert.is_true(e.rec.way.confirmed); assert.is_nil(e.rec.src)
  end)

  it("a recipe the library has no way to get is not listed", function()
    local DB2, recipes = fakeLib()
    recipes[30] = { name = "?", reagents = { [2318] = 1 }, difficulty = { 30, 60, 75, 90 } }       -- no skill, no source, no item
    local cs = V.LibCrafts(DB2, 165, "A")
    local r = V.Learnable(cs, 61, lcx())
    for _, bucket in ipairs({ r.now, r.soon, r.gray }) do for _, e in ipairs(bucket) do assert.are_not.equal(30, e.rec.id) end end
  end)
end)


describe("Forever trainer table (wowforever.be, in-game observed)", function()
  local FT = ns.ForeverTrainers
  local DB = fakeLib()
  local crafts, by = V.LibCrafts(DB, 165, "A", nil, FT), {}
  for _, c in ipairs(crafts) do by[c.id] = c end
  local function lcx()
    local prices = { [2318] = 100, [2320] = 100, [7279] = 1000, [252427] = 1000, [252426] = 1000, [252424] = 1000, [2307] = 60000 }
    return { price = function(id) if prices[id] then return prices[id], 0 end end, vendor = function() return 0 end,
      buy = function() end, ageKnown = false, known = function() return false end }
  end

  it("the owner's Kamari recipes are trainer-taught: Petite giberne for 1s, the Forever boots for 5s", function()
    assert.are.equal("trainer", by[9062].how.kind); assert.are.equal(100, by[9062].how.cost)
    for _, id in ipairs({ 1255143, 1255144, 1255146 }) do
      assert.are.equal("trainer", by[id].how.kind, tostring(id))
      assert.are.equal(500, by[id].how.cost); assert.are.equal("Apprentice", by[id].how.rank)
      assert.is_true(by[id].how.confirmed)
    end
    assert.are.equal(35, by[1255143].learn)                      -- the table's learn skill, not the library's
  end)

  it("Fine Leather Boots is not trainer-taught on Forever (not in the table): still a drop", function()
    assert.is_nil(FT[2158].cost)                                  -- the site lists it (drop, fishing, pickpocket) but no trainer fee
    assert.are.equal("drop", by[2158].how.kind)
  end)

  it("Fine Leather Belt (learn 55) is taught by a Journeyman trainer, for 3s", function()
    assert.are.equal("Journeyman", FT[3763].rank); assert.are.equal(300, FT[3763].cost); assert.are.equal(55, FT[3763].learn)
    local DB2 = fakeLib({ sources = { [1] = { trainer = { { id = 5, name = "Kamari" }, total = 1 } } } })
    local w = V.Way(DB2, 1, { requiredSkill = 55 }, "A", { [1] = FT[3763] })
    assert.are.equal("trainer", w.kind); assert.are.equal("Journeyman", w.rank)
    assert.are.equal(300, w.cost)
  end)

  it("a library trainer source that is not in the table is dropped; the other sources stay", function()
    local trainer = { trainer = { { id = 5, name = "Kamari" }, total = 1 } }
    local DB2 = fakeLib({ sources = { [1] = trainer, [2] = { trainer = trainer.trainer, vendor = { { id = 6, name = "Some vendor" }, total = 1 } } } })
    assert.are.equal("unknown", V.Way(DB2, 1, { requiredSkill = 40 }, "A", {}).kind)       -- nothing else: not listed
    assert.are.equal("vendor", V.Way(DB2, 2, { requiredSkill = 40 }, "A", {}).kind)        -- the vendor stays
    assert.are.equal("trainer", V.Way(DB2, 1, { requiredSkill = 40 }, "A").kind)           -- without the table: as before
    local r = V.Learnable({ { id = 1, name = "x", learn = 40, mats = { { 2318, 1 } }, out = 7279, oq = 1, how = V.Way(DB2, 1, { requiredSkill = 40 }, "A", {}) } }, 61, lcx())
    assert.are.equal(0, r.nowTotal + r.soonTotal)
  end)

  it("recipes known from the start are left out; a vendor of the table is used when the library has none", function()
    local DB2 = fakeLib()
    function DB2:GetRecipes() return { [10] = { name = "A", requiredSkill = 1, difficulty = { 1, 2, 3, 4 }, reagents = {} },
      [11] = { name = "B", requiredSkill = 30, difficulty = { 30, 50, 60, 70 }, reagents = {} } } end
    local list = V.LibCrafts(DB2, 165, "A", nil, { [10] = { learn = 1, start = true }, [11] = { learn = 30, vendor = "Granny Finespindle (Ironforge)" } })
    assert.are.equal(1, #list)
    assert.are.equal("vendor", list[1].how.kind); assert.are.same({ "Granny Finespindle" }, list[1].how.npcs)
  end)

  it("the real fee goes into the learning-cost amortisation", function()
    local r = V.Learnable(crafts, 61, lcx())
    local e
    for _, o in ipairs(r.now) do if o.rec.id == 9062 then e = o end end
    assert.are.equal(100, e.rec.fee)
    assert.is_true(e.amortised > e.perPoint)
    -- 100c spread over the points left: gray 85 - skill 61 = 24
    assert.is_near(e.perPoint + 100 / 24, e.amortised, 1e-9)
  end)

  it("source labels: cost for Apprentice, rank and cost above", function()
    assert(loadfile("Strings.lua"))("GoldCompass", ns)
    ns.Money = function(c) return (c // 100) .. "s" end
    assert(loadfile("Format.lua"))("GoldCompass", ns)
    assert.are.equal("entraîneur · 1s", ns.Fmt.Source({ way = by[9062].how }, true))
    assert.are.equal("chez un entraîneur Compagnon · 3s", ns.Fmt.Source({ way = { kind = "trainer", cost = 300, rank = "Journeyman" } }, true))
    assert.are.equal("entraîneur Expert · 8s", ns.Fmt.Source({ way = { kind = "trainer", cost = 800, rank = "Expert" } }, false))
  end)

  it("best prefers a recipe at a rank the character has trained, over a cheaper one that needs a rank first", function()
    local function craft(id, learn, rank, out)
      return { id = id, name = "r" .. id, learn = learn, mats = { { 2318, 1 } }, out = out, oq = 1, y = learn + 20, g = learn + 35, gr = learn + 50,
        how = { kind = "trainer", confirmed = true, cost = 100, rank = rank, npcs = {} } }
    end
    local cs = { craft(1, 55, "Journeyman", 2307), craft(2, 40, "Apprentice", 7279) }   -- 2307 sells high: recipe 1 is cheaper per point
    local c = lcx()
    c.maxSkill = 75
    assert.are.equal(2, V.Learnable(cs, 61, c).best.rec.id)       -- Apprentice cap: Journeyman not trained yet
    c.maxSkill = 150
    assert.are.equal(1, V.Learnable(cs, 61, c).best.rec.id)       -- Journeyman trained: the cheapest wins
    c.maxSkill = nil
    assert.are.equal(1, V.Learnable(cs, 61, c).best.rec.id)
  end)
end)

describe("Leveling: the effort rule, with and without the bag (the owner's Leatherworking 61)", function()
  local function counts(t) return function(id) return t[id] or 0 end end
  -- reagent 10: AH 100c; reagent 20: vendor 30c; output 30: AH 1000c (950 net); output 32: vendor 180c
  -- Brassards (id 1): green, 2 x reagent 10 (200c) -> sells 950: profit 750 per craft; 2 ingredients / 0.25 = 8 per point
  -- Gants (id 2): orange, 10 x reagent 20 (300c) -> sells 180: costs 120 per craft and per point
  local function prof()
    return { skill = 61, max = 75, recipes = {
      [1] = { id = 1, d = 2, out = 30, oq = 1, mats = { { 10, 2 } } },
      [2] = { id = 2, d = 0, out = 32, oq = 1, mats = { { 20, 10 } } },
    } }
  end
  local bag = counts({ [10] = 10, [20] = 70 })   -- Brassards x5, Gants x7

  it("with the bag the same effort rule applies: the Gants (5 ingredients per point, orange) beat the Brassards (8, green)", function()
    local plan = V.Plan(prof(), ctx(), nil, bag)
    assert.are.equal(2, plan.best.rec.id)
    assert.are.equal(7, plan.best.times); assert.are.equal(7, plan.best.points)
    assert.are.equal(1, plan.rows[2].rec.id); assert.are.equal(1.25, plan.rows[2].points)   -- 5 x 0.25
    assert.are.equal(120, plan.best.perPoint)                                                -- costs money, still wins
    assert.are.equal(600, plan.rows[2].perPoint)                                             -- green: (200 - 50) / 0.25
  end)

  it("the bag changes only the list (what is craftable) and the quantities, not the rule: orange Gants first in both modes", function()
    -- B (the Peau légère traitée case): green, 4.46 ingredients per point, 2.2 crafts per point; A (the Gants): orange, 5 per point, 1 craft
    local th = function(id) return id == 2 and { 20, 45, 60, 74 } or { 40, 70, 85, 100 } end
    local p = { skill = 61, recipes = {
      [1] = { id = 1, d = 0, out = 32, oq = 1, mats = { { 20, 10 } } },
      [2] = { id = 2, d = 2, out = 32, oq = 1, mats = { { 10, 2 } } },
    } }
    local c = ctx(); c.owned = function(id) return id == 20 and 70 or (id == 10 and 20 or 0) end
    local free = V.Plan(p, c, nil, nil, th, "level")
    assert.is_near(4.46, free.rows[2].unitsPerPoint, 0.01); assert.are.equal(5, free.best.unitsPerPoint)
    assert.are.equal(1, free.best.rec.id)
    local bagged = V.Plan(p, c, nil, function(id) return c.owned(id) end, th, "level")
    assert.are.equal(1, bagged.best.rec.id)
    assert.are.equal(7, bagged.best.times); assert.are.equal(7, bagged.best.points)           -- the bag still says how many points it gives
  end)

  it("cost per point only breaks a tie of expected points", function()
    local p = { skill = 61, recipes = {
      [1] = { id = 1, d = 0, out = 32, oq = 1, mats = { { 20, 10 } } },   -- 120 per point
      [2] = { id = 2, d = 0, out = 30, oq = 1, mats = { { 10, 1 } } },    -- costs 50 per point
    } }
    local plan = V.Plan(p, ctx(), nil, counts({ [10] = 7, [20] = 70 }))   -- both x7 = 7 points
    assert.are.equal(2, plan.best.rec.id)
  end)

  it("without the bag the ingredients per point decide, not the colour: gray never, an unpriced recipe last", function()
    local p = { skill = 61, recipes = {
      [1] = { id = 1, d = 2, out = 30, oq = 1, mats = { { 10, 1 } } },    -- green: 1 unit / 0.25 = 4 per point
      [2] = { id = 2, d = 1, out = 32, oq = 1, mats = { { 20, 10 } } },   -- yellow: 10 x 0.5 (vendor-sold) / 0.75 = 6.67
      [3] = { id = 3, d = 0, out = 32, oq = 1, mats = { { 20, 20 } } },   -- orange, more units: 10
      [4] = { id = 4, d = 3, out = 30, oq = 1, mats = { { 10, 1 } } },    -- gray
    } }
    local order = {}
    for i, e in ipairs(V.Plan(p, ctx()).rows) do order[i] = e.rec.id end
    assert.are.same({ 1, 2, 3 }, order)
    p.recipes[2].mats, p.recipes[3].mats = { { 99, 1 } }, { { 99, 1 } }
    assert.are.equal(1, V.Plan(p, ctx()).best.rec.id)
  end)

  it("shows the second-best ('puis') when the best gives fewer points than the gap to its next colour change", function()
    -- Gants turn yellow at 70: 9 points from skill 61; Brassards (green at 61): chance (65 - 61) / (65 - 49) = 0.25
    local th = function(id) return id == 1 and { 40, 49, 57, 65 } or { 40, 70, 85, 100 } end
    local plan = V.Plan(prof(), ctx(), nil, bag, th)
    assert.are.equal(1, plan.second.e.rec.id); assert.are.equal(5, plan.second.times); assert.are.equal(1.25, plan.second.points)
    -- 7 points >= a gap of 5: the best covers the stretch, no second line
    assert.is_nil(V.Plan(prof(), ctx(), nil, bag, function(id) return id == 1 and { 40, 49, 57, 65 } or { 40, 66, 85, 100 } end).second)
    -- the second one only gets what the best leaves in the bag: the shared reagent 20 is used up by the best
    local p = prof()
    p.recipes[1] = { id = 1, d = 2, out = 30, oq = 1, mats = { { 20, 7 } } }       -- 7 x 0.5 / 0.25 = 14 ingredients per point
    plan = V.Plan(p, ctx(), nil, counts({ [20] = 77 }), th)           -- Gants x7 (7 points) use 70, 7 left: Brassards x1
    assert.are.equal(2, plan.best.rec.id); assert.are.equal(1, plan.second.times)
    -- no second recipe when the bag has nothing left for it
    assert.is_nil(V.Plan(p, ctx(), nil, counts({ [20] = 70 }), th).second)
    -- without the bag filter there is no second line
    assert.is_nil(V.Plan(prof(), ctx(), nil, nil, th).second)
  end)

  it("flags a profit that exists only by selling at the auction house", function()
    local e = V.Evaluate(prof().recipes[1], ctx())
    assert.is_true(e.net < 0); assert.is_true(e.resale)
    assert.is_false(V.Evaluate(prof().recipes[2], ctx()).resale)       -- costs money: nothing to flag
    local vendorSale = V.Evaluate({ id = 3, d = 0, out = 31, oq = 1, mats = { { 20, 1 } } }, ctx())   -- vendor value 200 > cost 30
    assert.is_true(vendorSale.net < 0); assert.is_false(vendorSale.resale)
  end)

  it("recipes to learn follow the effort rule: fewest ingredients per point, then chance, then the one that stays useful longest", function()
    local function craft(id, learn, y, g, gr, mats)
      return { id = id, learn = learn, y = y, g = g, gr = gr, src = "v", out = 30, oq = 1, mats = mats or { { 10, 1 } } }
    end
    local lc = ctx()
    lc.known = function() return false end
    -- skill 61, one ingredient each: 1 green (chance 0.74: 1.36 per point), 2 orange gray at 75 (1.0, useful 14),
    -- 3 yellow (0.87: 1.15), 4 orange but 2 ingredients (2.0), 5 orange like 2 but gray at 100 (1.0, useful 39)
    local crafts = { craft(1, 30, 40, 50, 120), craft(2, 40, 62, 70, 75), craft(3, 50, 55, 80, 100), craft(4, 50, 70, 80, 100, { { 10, 2 } }),
      craft(5, 45, 62, 70, 100) }
    local r = V.Learnable(crafts, 61, lc)
    assert.are.equal(5, r.best.rec.id)       -- 2 and 5 tie on ingredients and chance: 5 stays useful for 39 points
    assert.are.equal(39, r.best.useful)
    assert.are.equal(5, r.now[1].rec.id); assert.are.equal(2, r.now[2].rec.id)       -- the list follows the same rule
    assert.are.equal(4, r.now[#r.now].rec.id)                                         -- 2 ingredients per point: last
    assert.is_near(1.36, V.Learnable({ crafts[1] }, 61, lc).now[1].unitsPerPoint, 0.01)
    local only = V.Learnable({ crafts[1], crafts[2] }, 61, lc)
    assert.are.equal(2, only.best.rec.id)    -- orange (1.0 per point) beats green (1.36) even if the green stays useful for longer (59)
  end)
end)

describe("Leveling: Gagner de l'or (goal gold)", function()
  local function counts(t) return function(id) return t[id] or 0 end end
  -- same case as above: Brassards (id 1, green, 1 x reagent 10 = 100c, sells 950 at the AH: profit 850 per craft),
  -- Gants (id 2, orange, 10 x reagent 20 = 300c, sells 180 at the vendor: costs 120), Cape (id 3, gray, 1 x reagent 10, sells 180
  -- at the vendor: profit 80 per craft; gray recipes still sell)
  local function prof()
    return { skill = 61, max = 75, recipes = {
      [1] = { id = 1, d = 2, out = 30, oq = 1, mats = { { 10, 1 } } },
      [2] = { id = 2, d = 0, out = 32, oq = 1, mats = { { 20, 10 } } },
      [3] = { id = 3, d = 3, out = 32, oq = 1, mats = { { 10, 1 } } },
    } }
  end
  local bag = counts({ [10] = 5, [20] = 70 })

  it("ranks by profit per craft (skill chance ignored) and includes gray recipes; the levelling view leaves gray out", function()
    local gold = V.Plan(prof(), ctx(), nil, nil, nil, "gold")
    assert.are.equal(1, gold.best.rec.id); assert.are.equal(850, gold.best.profit)         -- 950 - 100
    local order = {}
    for i, e in ipairs(gold.rows) do order[i] = e.rec.id end
    assert.are.same({ 1, 3, 2 }, order)                                                      -- 850, 80, -120
    assert.are.equal("gold", gold.goal)
    local level = V.Plan(prof(), ctx())
    assert.are.equal(2, #level.rows)                                                        -- the gray Cape is not there
    assert.are.equal(1, level.best.rec.id)                                                  -- 1 ingredient / 0.25 = 4 per point beats 5
  end)

  it("with the bag: total profit = times x profit per craft", function()
    local gold = V.Plan(prof(), ctx(), nil, bag, nil, "gold")
    assert.are.equal(1, gold.best.rec.id); assert.are.equal(5, gold.best.times); assert.are.equal(4250, gold.best.total)  -- 5 x 850
    local p = prof()
    p.recipes[2] = { id = 2, d = 0, out = 30, oq = 1, mats = { { 20, 1 } } }                 -- Gants earn 920 per craft, x70
    assert.are.equal(2, V.Plan(p, ctx(), nil, bag, nil, "gold").best.rec.id)                 -- 70 x 920 beats 5 x 850
  end)

  it("recommends nothing when no recipe earns money, and never a profit priced from an undated AH price", function()
    local p = { skill = 61, recipes = { [2] = prof().recipes[2] } }
    assert.is_nil(V.Plan(p, ctx(), nil, nil, nil, "gold").best)                              -- costs 120: nothing earns
    local c = ctx(); c.ageKnown = false                                                      -- the price addon cannot date prices
    local plan = V.Plan({ skill = 61, recipes = { [1] = prof().recipes[1] } }, c, nil, nil, nil, "gold")
    assert.is_true(plan.rows[1].noAge); assert.is_nil(plan.best)
  end)

  it("tells the AH resale, the age of its price, and an old AH price (vendor value used)", function()
    local c = ctx()
    local ah = { [30] = { 1000, 3 } }                                                        -- 3 days old: still used
    c.price = function(id) local p = ah[id] or ({ [10] = { 100, 0 } })[id]; if p then return p[1], p[2] end end
    local e = V.Evaluate({ id = 1, d = 0, out = 30, oq = 1, mats = { { 10, 1 } } }, c)
    assert.is_true(e.ahSale); assert.are.equal(3, e.saleAge); assert.is_false(e.oldAh)
    ah[30] = { 1000, 30 }                                                                    -- 30 days: older than the old days
    e = V.Evaluate({ id = 1, d = 0, out = 30, oq = 1, mats = { { 10, 1 } } }, c)
    assert.is_true(e.oldAh); assert.is_false(e.ahSale); assert.are.equal(-50, e.profit)   -- vendor value 50 - cost 100
  end)

  it("recipes to learn: profit per craft minus the learning fee spread over 10 crafts, gray recipes included", function()
    local lc = ctx(); lc.known = function() return false end; lc.goal = "gold"
    -- all sell output 30 (950 net). A: reagent 10 (100c) -> profit 850, fee 1000 -> score 850 - 100 = 750.
    -- B: 2 x reagent 10 -> profit 750, fee unknown -> 750 (ties with A; A's price is known, so A wins).
    -- C: gray at 61, profit 850, fee 3000 -> 850 - 300 = 550
    local function craft(id, mats, gr, vendorCost)
      return { id = id, learn = 40, y = 45, g = 50, gr = gr, out = 30, oq = 1, mats = mats,
        how = { kind = "vendor", confirmed = true, npcs = {}, vendorCost = vendorCost } }
    end
    local crafts = { craft(1, { { 10, 1 } }, 100, 1000), craft(2, { { 10, 2 } }, 100, nil), craft(3, { { 10, 1 } }, 55, 3000) }
    local r = V.Learnable(crafts, 61, lc)
    local by = {}
    for _, e in ipairs(r.now) do by[e.rec.id] = e end
    assert.are.equal(750, by[1].score)          -- 850 - 1000 / 10
    assert.are.equal(750, by[2].score)          -- 950 - 200, no known fee
    assert.are.equal(550, by[3].score)          -- gray at 61 (gr 55): still counted; 850 - 3000 / 10
    assert.are.equal(0, #r.gray)
    -- tie on score: the recipe whose price is KNOWN wins over the unknown-price one
    assert.are.equal(1, r.best.rec.id)
  end)
end)

describe("Leveling: faction of vendors and the learning price of vendor recipes", function()
  local function way(sources, over, forever, entry)
    local DB = fakeLib({ sources = { [1] = sources }, items = {}, borrowed = {} })
    function DB:GetVendorCost(_, npc) return over and over.cost and over.cost[npc] end
    function DB:GetSourceFaction(npc) return over and over.faction and over.faction[npc] end
    return function(faction) return V.Way(DB, 1, entry or { requiredSkill = 40 }, faction, forever) end
  end
  local alliance = { vendor = { { id = 6, name = "Alliance vendor" }, total = 1 } }

  it("a vendor recipe whose vendors are all the other faction is not a vendor recipe for this player", function()
    local w = way(alliance, { faction = { [6] = "Alliance" } }, nil, {})
    assert.are.equal("vendor", w("A").kind)
    assert.are.equal("unknown", w("H").kind)                                   -- Horde player: nothing else to fall through to
    local drop = way({ vendor = alliance.vendor, drop = { { id = 2, name = "Mob" }, total = 9 } }, { faction = { [6] = "Alliance" } }, nil, {})
    assert.are.equal("drop", drop("H").kind)                                   -- falls through to the next source kind
    local mixed = way({ vendor = { { id = 6, name = "Alliance vendor" }, { id = 7, name = "Neutral vendor" }, total = 2 } }, { faction = { [6] = "Alliance" } })
    assert.are.equal("vendor", mixed("H").kind); assert.are.same({ "Neutral vendor" }, mixed("H").npcs)
  end)

  it("the Gustwoven recipes (Alliance vendors in the library) are Vayn Moongaze's for a Horde player", function()
    local w = way(alliance, { faction = { [6] = "Alliance" } }, { [1] = { learn = 40, vendor = "Vayn Moongaze (Zephras Isle)" } })("H")
    assert.are.equal("vendor", w.kind); assert.are.same({ "Vayn Moongaze" }, w.npcs); assert.are.equal("Vayn Moongaze (Zephras Isle)", w.where)
    assert.is_nil(w.vendorCost); assert.is_nil(w.currency)                    -- price unknown
  end)

  it("learning price: unknown or a currency is not a gold price; a known gold price is preferred for the best recipe", function()
    local lc = ctx(); lc.known = function() return false end
    local function craft(id, mats, how)
      return { id = id, learn = 40, y = 45, g = 80, gr = 100, out = 30, oq = 1, mats = mats, how = how }
    end
    local unknownCheap = craft(1, { { 10, 1 } }, { kind = "vendor", confirmed = true, npcs = {} })
    local currency = craft(2, { { 10, 1 } }, { kind = "vendor", confirmed = true, npcs = {}, currency = { id = 3402, amount = 240 } })
    local priced = craft(3, { { 10, 2 } }, { kind = "vendor", confirmed = true, npcs = {}, vendorCost = 500 })
    local r = V.Learnable({ unknownCheap, currency, priced }, 61, lc)
    local by = {}
    for _, e in ipairs(r.now) do by[e.rec.id] = e end
    assert.is_false(by[1].priceKnown); assert.is_false(by[2].priceKnown); assert.is_true(by[3].priceKnown)
    assert.are.equal(3, r.best.rec.id)                                         -- dearer per point, but its price is known
    r = V.Learnable({ unknownCheap, currency }, 61, lc)
    assert.are.equal(1, r.best.rec.id)                                         -- nothing priced: an unknown price may still be best
  end)
end)

describe("Leveling.Learnable: the best is learnable now, AH figures can be uncertain", function()
  local function lc(ah)
    local c = ctx()
    c.known = function() return false end
    c.price = function(id) local p = ah[id]; if p then return p[1], p[2] end end
    return c
  end
  local function craft(id, learn, out, over)
    local c = { id = id, learn = learn, y = learn + 30, g = learn + 45, gr = learn + 60, out = out, oq = 1, mats = { { 10, 1 } },
      how = { kind = "trainer", cost = 0, npcs = {} } }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end

  it("a recipe of level 65 is never the best at skill 61, nor in the 'now' list; the best is among the recipes learnable now", function()
    -- 3 (learn 65, soon) is far cheaper per point than 1 (learn 55, now)
    local r = V.Learnable({ craft(1, 55, 31), craft(3, 65, 30) }, 61, lc({ [10] = { 100, 0 }, [30] = { 5000, 0 } }))
    assert.are.equal(1, r.best.rec.id)
    for _, e in ipairs(r.now) do assert.is_true(e.rec.learn <= 61) end
    assert.are.equal(3, r.soon[1].rec.id)
    -- only a soon recipe: no best at all (never promoted to 'now')
    r = V.Learnable({ craft(3, 65, 30) }, 61, lc({ [10] = { 100, 0 }, [30] = { 5000, 0 } }))
    assert.is_nil(r.best); assert.are.equal(0, #r.now); assert.are.equal(1, #r.soon)
  end)

  local function gold(c) c.goal = "gold"; return c end        -- levelling counts only the vendor sale; the AH resale is for "Gagner de l'or"
  it("when earning gold, a crafted-item price older than the fresh days (or undated) is uncertain: sorted after reliable figures and never the best", function()
    local ah = { [10] = { 100, 0 }, [30] = { 9000, 5 }, [32] = { 1000, 0 } }     -- 30 sells for a lot, but its price is 5 days old
    local r = V.Learnable({ craft(1, 50, 30), craft(2, 50, 32) }, 61, gold(lc(ah)))
    assert.is_true(r.now[2].uncertain or r.now[1].uncertain)
    assert.are.equal(2, r.now[1].rec.id)                          -- the reliable one first although it earns less per point
    assert.is_false(r.now[1].uncertain); assert.is_true(r.now[2].uncertain)
    assert.are.equal(2, r.best.rec.id)
    assert.are.equal(5, r.now[2].saleAge)
    -- an undated price (the price addon cannot tell the age) is uncertain too
    local c = gold(lc(ah)); c.ageKnown = false
    assert.is_true(V.Learnable({ craft(1, 50, 30) }, 61, c).now[1].uncertain)
    -- a fresh price is not
    assert.is_false(V.Learnable({ craft(1, 50, 32) }, 61, gold(lc(ah))).now[1].uncertain)
  end)

  it("keeps the price age of a priced teaching item", function()
    local c = craft(5, 50, 31, { how = { kind = "item", itemID = 555, npcs = {} } })
    local e = V.Learnable({ c }, 61, lc({ [10] = { 100, 0 }, [555] = { 20000, 3 }, [31] = { 500, 0 } })).now[1]
    assert.are.equal(20000, e.rec.fee); assert.are.equal(3, e.rec.feeAge)
  end)
end)

describe("Leveling.Learnable: ranks, caps and rank books", function()
  local function lc(extra)
    local c = ctx()
    c.known = function() return false end
    c.price = function(id) local p = ({ [10] = { 100, 0 }, [30] = { 5000, 0 } })[id]; if p then return p[1], p[2] end end
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
  end
  local function craft(id, learn, over)
    local c = { id = id, learn = learn, y = learn + 30, g = learn + 45, gr = learn + 60, out = 30, oq = 1, mats = { { 10, 1 } },
      how = { kind = "trainer", cost = 100, rank = "Apprentice", npcs = {} } }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end
  local function offer(skill, cost, status) return { skill = skill, cost = cost, status = status or "available", npc = "Kamari", mapID = 1411, x = 1, y = 1 } end

  it("a recorded trainer offer keeps the rank of the Forever table: a Journeyman recipe is gated at cap 75, an Apprentice one is not", function()
    local journeyman = craft(3761, 50, { how = { kind = "trainer", cost = 900, rank = "Journeyman", npcs = {} } })
    local apprentice = craft(2149, 55)
    local c = lc({ maxSkill = 75, offer = function(id) return ({ [3761] = offer(50, 900), [2149] = offer(55, 100) })[id] end })
    local r = V.Learnable({ journeyman, apprentice }, 61, c)
    for _, e in ipairs(r.now) do assert.are.equal(e.rec.id == 3761, e.rankGated) end
    assert.are.equal("Journeyman", r.now[1].rec.way.rank == "Journeyman" and "Journeyman" or r.now[2].rec.way.rank)
    assert.are.equal(2149, r.best.rec.id)       -- the recipe the character can really learn, not the Journeyman tunic
  end)

  it("an offer the trainer window lists as unavailable although the skill was enough is gated too", function()
    local function seen(at) local o = offer(50, 100, "unavailable"); o.seenAt = at; return o end
    local c = lc({ maxSkill = 75, offer = function(id) return id == 7 and seen(61) or nil end })
    local r = V.Learnable({ craft(7, 50) }, 61, c)
    assert.is_true(r.now[1].rankGated)
    r = V.Learnable({ craft(7, 50), craft(8, 52) }, 61, c)
    assert.are.equal(8, r.best.rec.id)
    -- the window was seen at a lower skill (or by nobody we know): "unavailable" was the skill then, it proves nothing now
    for _, at in ipairs({ 40, false }) do
      c = lc({ maxSkill = 75, offer = function(id) return id == 7 and seen(at or nil) or nil end })
      assert.is_false(V.Learnable({ craft(7, 50) }, 61, c).now[1].rankGated)
    end
  end)

  it("'soon' stops at the profession cap: recipes at 80-85 are not listed at 61/75, one 'beyond' line says which rank is needed", function()
    local r = V.Learnable({ craft(1, 70), craft(2, 80), craft(3, 85) }, 61, lc({ maxSkill = 75 }))
    assert.are.same({ 1 }, { r.soon[1].rec.id }); assert.are.equal(1, #r.soon)
    assert.are.equal(1, r.soonTotal)
    assert.are.equal(75, r.beyond.max); assert.are.equal("Journeyman", r.beyond.rank); assert.are.equal(2, r.beyond.count)
    assert.is_nil(V.Learnable({ craft(1, 70) }, 61, lc({ maxSkill = 75 })).beyond)
    assert.are.equal(2, #V.Learnable({ craft(1, 70), craft(2, 80) }, 61, lc()).soon)       -- no cap known: unchanged
  end)

  it("rank books (no crafted item, no reagents) are never gray crafts: they get their own list, near the cap, with the bag filter on", function()
    local book = craft(7732, 125, { out = false, mats = {}, how = { kind = "vendor", npcs = {} }, src = "v" })
    local r = V.Learnable({ craft(1, 100), book }, 124, lc({ maxSkill = 150 }))
    assert.are.equal(1, #r.books); assert.are.equal(7732, r.books[1].rec.id)
    for _, bucket in ipairs({ r.now, r.soon, r.gray }) do for _, e in ipairs(bucket) do assert.are_not.equal(7732, e.rec.id) end end
    assert.are.equal(1, r.nowTotal + r.soonTotal)
    -- the bag filter hides crafts, not the books
    local bagged = V.Learnable({ book }, 124, lc({ maxSkill = 150 }), function() return 0 end)
    assert.are.equal(1, #bagged.books)
    -- far from the cap: not shown
    assert.are.equal(0, #V.Learnable({ book }, 124, lc({ maxSkill = 300 })).books)
  end)
end)

describe("Leveling.Learnable: the place decides (ctx.place)", function()
  local function lc(places)
    local c = ctx()
    c.known = function() return false end
    c.price = function(id) local p = ({ [10] = { 100, 0 }, [30] = { 5000, 0 } })[id]; if p then return p[1], p[2] end end
    c.place = function(rec) return places[rec.id] end
    return c
  end
  local function craft(id, learn, over)
    local c = { id = id, learn = learn, y = learn + 30, g = learn + 45, gr = learn + 60, out = 30, oq = 1, mats = { { 10, 1 } },
      how = { kind = "trainer", cost = 100, rank = "Apprentice", npcs = {} } }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end

  it("a recipe whose every way is the other faction's is no recipe to learn: not listed, not best, counted apart", function()
    local places = { [1] = { kind = "text", onlyFaction = "A" }, [2] = { kind = "pin", confirmed = true } }
    local r = V.Learnable({ craft(1, 50), craft(2, 60) }, 100, lc(places))
    assert.are.equal(1, #r.now); assert.are.equal(2, r.now[1].rec.id); assert.are.equal(2, r.best.rec.id)
    assert.are.equal(1, r.nowTotal)
    assert.are.equal(1, #r.otherFaction); assert.are.equal(1, r.otherFaction[1].rec.id); assert.are.equal("A", r.otherFaction[1].faction)
    -- nothing else: nothing to learn at all
    r = V.Learnable({ craft(1, 50) }, 100, lc(places))
    assert.is_nil(r.best); assert.are.equal(0, r.nowTotal + r.soonTotal)
  end)

  it("at the same colour a recipe with a confirmed place beats a text-only one, though the text-only one is cheaper", function()
    local places = { [1] = { kind = "text" }, [2] = { kind = "pin", confirmed = false }, [3] = { kind = "pin", confirmed = true } }
    local r = V.Learnable({ craft(1, 50, { out = 30 }), craft(2, 50, { how = { kind = "trainer", cost = 100, npcs = {} } }), craft(3, 50) }, 100, lc(places))
    assert.are.equal(3, r.best.rec.id)
    r = V.Learnable({ craft(1, 50), craft(2, 50) }, 100, lc(places))
    assert.are.equal(2, r.best.rec.id)         -- a hint (unconfirmed pin) still beats a text
  end)
end)

describe("Leveling: how 'Monter le métier' reasons (the owner's belt and pants, Leatherworking 75/150)", function()
  -- Light Leather 2318: 20c, Coarse Thread 2320: 31c, Cured Light Hide 4231: AH 224c (the pants need one). The game window shows the belt at
  -- 1s82 (6 Light Leather + 2 Coarse Thread) and the pants at 4s06.
  local PRICES = { [2318] = 20, [2320] = 31, [4231] = 224, [7001] = 100, [7002] = 1500 }     -- 7001 belt, 7002 pants (AH resale)
  local VENDOR = { [7001] = 8, [7002] = 25, [4231] = 10 }
  local function market(over)
    local c = { price = function(id) local p = (over or PRICES)[id]; if p then return p, 0 end end,
      vendor = function(id) return VENDOR[id] end, buy = function() end }
    return c
  end
  local belt = { id = 1, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }
  local pants = { id = 2, d = 0, out = 7002, oq = 1, mats = { { 4231, 1 }, { 2318, 6 }, { 2320, 2 } } }
  local function plan(goal, recipes, ctx, thresholds)
    return V.Plan({ skill = 75, max = 150, recipes = recipes or { [1] = belt, [2] = pants } }, ctx or market(), nil, nil, thresholds, goal)
  end

  it("the Classic chance formula: orange 1, gray 0, between yellow and gray (gray - skill) / (gray - yellow)", function()
    assert.are.equal(0.5, (V.Chance(1, 70, 55, 85)))
    assert.are.equal(1, (V.Chance(0, 40, 55, 85)))
    assert.are.equal(0, (V.Chance(3, 90, 55, 85)))
    assert.are.equal(1, (V.Chance(1, 50, 55, 85)))                  -- clamped to 1 below yellow
    assert.are.equal(0, (V.Chance(2, 90, 55, 85)))                  -- clamped to 0 above gray
    local flat, exact = V.Chance(1, 70)                              -- no thresholds: the flat estimate
    assert.are.equal(0.75, flat); assert.is_false(exact)
    assert.is_true(select(2, V.Chance(1, 70, 55, 85)))
  end)

  it("levelling: the belt (1s82) is recommended over the pants (4s06), the AH resale of the pants does not count", function()
    local p = plan("level")
    assert.are.equal(1, p.best.rec.id)
    assert.are.equal(182, p.best.cost); assert.are.equal(406, p.rows[2].cost)
    assert.are.equal(174, p.best.perPoint)                           -- 182 - 8 (the vendor sale) over a chance of 1
    assert.are.equal(381, p.rows[2].perPoint)                        -- 406 - 25
    assert.is_false(p.rows[2].ahSale); assert.is_false(p.rows[2].resale)     -- no "rentable seulement si tu revends à l'HV"
  end)

  it("earning gold: the pants win with their AH resale, the belt does not", function()
    local p = plan("gold")
    assert.are.equal(2, p.best.rec.id)
    assert.is_true(p.best.ahSale)
    assert.is_true(p.best.profit > 0)
  end)

  it("the real chance from the thresholds ranks recipes: a yellow one near gray costs more per point", function()
    local a = { id = 1, d = 1, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }     -- yellow at 55, gray 85: chance 0.5 at 70
    local b = { id = 2, d = 1, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }     -- the same cost but gray at 140: chance 0.82
    local th = function(id) return id == 1 and { 40, 55, 70, 85 } or { 40, 55, 100, 140 } end
    local p = V.Plan({ skill = 70, recipes = { [1] = a, [2] = b } }, market(), nil, nil, th, "level")
    assert.are.equal(2, p.best.rec.id)
    assert.are.equal(0.5, p.rows[2].chance); assert.is_true(p.rows[1].chance > 0.8)
    assert.is_true(p.best.exact)
    -- no thresholds: the flat estimate, flagged as such
    local q = V.Plan({ skill = 70, recipes = { [1] = a } }, market(), nil, nil, nil, "level")
    assert.is_false(q.best.exact); assert.are.equal(0.75, q.best.chance)
  end)

  it("a reagent the player lacks and can make is valued by the cheaper of its price and its crafting cost, and said", function()
    -- Cured Light Hide (4231) is made from 2 Light Hide (4232) at 40c: 80c, cheaper than the 224c of the AH
    local hide = { id = 9, d = 3, out = 4231, oq = 1, mats = { { 4232, 2 } } }
    local c = market(); local base = c.price
    c.price = function(id) if id == 4232 then return 40, 0 end return base(id) end
    local p = plan("level", { [2] = pants, [9] = hide }, c)
    local e
    for _, row in ipairs(p.rows) do if row.rec.id == 2 then e = row end end
    assert.are.equal(182 + 80, e.cost)
    assert.are.equal(1, #e.subs); assert.are.equal(4231, e.subs[1].item); assert.are.equal(1, e.subs[1].need)
    -- carried: nothing to make first
    c.owned = function(id) return id == 4231 and 1 or 0 end
    e = nil
    for _, row in ipairs(plan("level", { [2] = pants, [9] = hide }, c).rows) do if row.rec.id == 2 then e = row end end
    assert.are.equal(0, #e.subs)
    -- no crafting recipe known: the market price
    for _, row in ipairs(plan("level", { [2] = pants }, market()).rows) do assert.are.equal(406, row.cost) end
  end)

  it("a recipe craftable now wins within 15 % of the fewest ingredients per point", function()
    local a = { id = 1, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }        -- 8 ingredients per point, no thread carried
    local b = { id = 2, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 }, { 9999, 3 } } }        -- 9 (+12.5 %), craftable now
    local c = market()
    c.price = function(id) if id == 9999 then return 65, 0 end local p = PRICES[id]; if p then return p, 0 end end
    c.owned = function(id) return (id == 2318 and 6) or (id == 9999 and 3) or 0 end
    local p = V.Plan({ skill = 75, recipes = { [1] = a, [2] = b } }, c, nil, nil, nil, "level")
    assert.are.equal(2, p.best.rec.id); assert.are.equal(2, p.rows[1].rec.id); assert.is_true(p.best.craftNow)
    -- more than 15 % more ingredients: the leaner recipe stays best although it cannot be crafted now
    b.mats = { { 2318, 6 }, { 9999, 4 } }                                                        -- 10 (+25 %)
    c.owned = function(id) return (id == 2318 and 6) or (id == 9999 and 4) or 0 end
    p = V.Plan({ skill = 75, recipes = { [1] = a, [2] = b } }, c, nil, nil, nil, "level")
    assert.are.equal(1, p.best.rec.id)
  end)

  it("equal cost per point: the higher chance first, then the one craftable now, then the cheaper craft", function()
    local c = market(); c.owned = function(id) return id == 2318 and 6 or 0 end
    local x = { id = 5, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 } } }
    local y = { id = 4, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 } } }
    local p = V.Plan({ skill = 75, recipes = { [5] = x, [4] = y } }, c, nil, nil, nil, "level")
    assert.are.equal(4, p.rows[1].rec.id)                          -- all equal: the lower id keeps the order stable
  end)
end)

describe("Leveling: 'Monter le métier' = the fewest ingredients and the least effort", function()
  local PRICES = { [2318] = 20, [2320] = 31, [4231] = 224 }
  local function ctx(over)
    local c = { price = function(id) local p = PRICES[id]; if p then return p, 0 end end,
      vendor = function() return 5 end, buy = function() end }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end
  local belt = { id = 1, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }
  local pants = { id = 2, d = 0, out = 7002, oq = 1, mats = { { 4231, 1 }, { 2318, 6 }, { 2320, 2 } } }
  local function plan(recipes, c, th, count)
    return V.Plan({ skill = 75, max = 150, recipes = recipes }, c or ctx(), nil, count, th, "level")
  end

  it("the owner's photo: the belt (8 ingredients) beats the pants (9), though both are orange and priced", function()
    local p = plan({ [1] = belt, [2] = pants })
    assert.are.equal(1, p.best.rec.id)
    assert.are.equal(8, p.best.unitsPerPoint); assert.are.equal(9, p.rows[2].unitsPerPoint)
    assert.are.equal(1, p.best.craftsPerPoint)
  end)

  it("an orange recipe with the same ingredients beats a green one", function()
    local green = { id = 3, d = 2, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }
    local p = plan({ [1] = belt, [3] = green })
    assert.are.equal(1, p.best.rec.id)
    assert.are.equal(4, p.rows[2].craftsPerPoint)                    -- 1 / 0.25: four crafts for a point
    assert.are.equal(32, p.rows[2].unitsPerPoint)
  end)

  it("a reagent a vendor sells counts half a unit", function()
    local c = ctx({ buy = function(id) if id == 2320 then return 31 end end })
    local e = plan({ [1] = belt }, c).best
    assert.are.equal(7, e.units)                                     -- 6 Light Leather + 2 thread x 0.5
    assert.are.equal(7, e.unitsPerPoint)
  end)

  it("an intermediate reagent the player lacks and can make counts as its own reagents, and is said", function()
    local hide = { id = 9, d = 3, out = 4231, oq = 1, mats = { { 4232, 2 }, { 4233, 1 } } }
    local p = plan({ [2] = pants, [9] = hide })
    local e
    for _, row in ipairs(p.rows) do if row.rec.id == 2 then e = row end end
    assert.are.equal(8 + 3, e.units)                                 -- 6 + 2 + the 3 units of the Cured Light Hide
    assert.are.equal(1, #e.subs); assert.are.equal(4231, e.subs[1].item); assert.are.equal(1, e.subs[1].need)
    -- carried: counts as one unit and nothing is to be made
    e = nil
    for _, row in ipairs(plan({ [2] = pants, [9] = hide }, ctx({ owned = function(id) return id == 4231 and 1 or 0 end })).rows) do
      if row.rec.id == 2 then e = row end
    end
    assert.are.equal(9, e.units); assert.are.equal(0, #e.subs)
  end)

  it("a recipe needing no intermediate craft comes first at equal ingredients; gold is the last tie-break", function()
    local hide = { id = 9, d = 3, out = 4231, oq = 1, mats = { { 4232, 1 } } }
    local a = { id = 1, d = 0, out = 7001, oq = 1, mats = { { 2318, 2 } } }                -- 2 ingredients
    local b = { id = 2, d = 0, out = 7001, oq = 1, mats = { { 4231, 2 } } }                -- 2 units of the hide, each made from 1: 2 as well
    local p = plan({ [1] = a, [2] = b, [9] = hide })
    assert.are.equal(1, p.best.rec.id)
    local c1 = { id = 5, d = 0, out = 7001, oq = 1, mats = { { 2318, 3 } } }              -- same ingredients, same chance, no sub:
    local c2 = { id = 4, d = 0, out = 7001, oq = 1, mats = { { 2320, 3 } } }              -- thread is dearer (31 vs 20): gold decides
    p = plan({ [5] = c1, [4] = c2 })
    assert.are.equal(5, p.best.rec.id)
  end)

  it("the bag: ingredients already carried are not left to gather; the figure says what is still missing", function()
    local owned = function(id) return id == 2318 and 6 or 0 end
    local e = plan({ [1] = belt }, ctx({ owned = owned })).best
    assert.are.equal(8, e.units)                                     -- the recipe itself still takes 8
    assert.are.equal(2, e.gather)                                    -- only the 2 threads are to gather
    assert.are.equal(2, e.gatherPerPoint)
  end)

  it("recipes craftable from the bags come first within 15 % of the fewest ingredients", function()
    local lean = { id = 1, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } }     -- 8
    local near = { id = 2, d = 0, out = 7001, oq = 1, mats = { { 2318, 7 }, { 2320, 2 } } }     -- 9 (+12.5 %)
    local far = { id = 3, d = 0, out = 7001, oq = 1, mats = { { 2318, 9 }, { 2320, 2 } } }      -- 11 (+37 %)
    local c = ctx({ owned = function(id) return (id == 2318 and 9) or (id == 2320 and 2) or 0 end })
    -- everything craftable: the leanest
    assert.are.equal(1, plan({ [1] = lean, [2] = near, [3] = far }, c).best.rec.id)
    -- only `near` and `far` craftable (7 and 9 leather carried, `lean` lacks thread): near wins, far is out of the 15 %
    c = ctx({ owned = function(id) return (id == 2318 and 9) or (id == 2320 and 2) or 0 end })
    local lack = { id = 1, d = 0, out = 7001, oq = 1, mats = { { 2318, 6 }, { 2320, 3 } } }     -- 9 units here: needs 3 thread, 2 carried
    assert.are.equal(2, plan({ [1] = lack, [2] = near, [3] = far }, c).best.rec.id)
  end)
end)

describe("Leveling.Roadmap", function()
  -- Items: 10 light leather, 20 thread (a vendor sells it: half an ingredient). Recipes (thresholds orange / yellow / green / gray):
  --   belt   (1)  3 leather + 1 thread, th 50 / 76 / 77 / 78: orange at 75, gray from 78
  --   gloves (2)  3 leather + 2 thread, th 50 / 70 / 85 / 100: yellow from 70
  --   pouch  (3)  2 leather, learnable at 80, th 80 / 95 / 110 / 125
  local BELT = { id = 1, name = "Belt", d = 0, out = 101, oq = 1, mats = { { 10, 3 }, { 20, 1 } } }
  local GLOVES = { id = 2, name = "Gloves", d = 1, out = 102, oq = 1, mats = { { 10, 3 }, { 20, 2 } } }
  local POUCH = { id = 3, name = "Pouch", d = 0, out = 103, oq = 1, mats = { { 10, 2 } }, learn = 80, th = { 80, 95, 110, 125 } }
  local TH = { [1] = { 50, 76, 77, 78 }, [2] = { 50, 70, 85, 100 } }
  local function setup(bag, over)
    over = over or {}
    local c = { price = function() end, vendor = function() end, buy = function(id) return id == 20 and 30 or nil end,
      owned = function(id) return bag[id] or 0 end, how = function(id) return id == 10 and "skin" or nil end }
    local prof = { skill = over.skill or 75, max = over.max or 150, recipes = over.recipes or { [1] = BELT, [2] = GLOVES } }
    return prof, c, { thresholds = function(id) return TH[id] end, learn = over.learn }
  end
  local function names(r)
    local out = {}
    for i, s in ipairs(r.steps) do
      out[i] = s.kind == "learn" and ("learn " .. s.rec.name .. " @" .. s.at)
        or ("%s x%d %d>%d %s"):format(s.rec.name, s.times, s.from, s.to, s.state)
    end
    return out
  end

  it("the owner's case: the first step is the belt x2 from the bag, then the gloves", function()
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }))
    assert.are.equal("Belt x2 75>77 bag", names(r)[1])
    assert.are.equal("Gloves", r.steps[2].rec.name)
    assert.are.equal(0, r.steps[1].d)                       -- the belt is orange at the start
    assert.are.equal(1, r.steps[2].d)                       -- the gloves are yellow
  end)

  it("C: the bag part and the part with missing reagents of one recipe are one step, with the bag part counted", function()
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }))
    assert.are.equal(2, r.steps[2].bagTimes)                -- the 2 gloves the leather left allows
    assert.is_true(r.steps[2].times > 2)                    -- then more with what is missing
    assert.are.equal("missing", r.steps[2].state)
    for i = 2, #r.steps do
      assert.is_false(r.steps[i].kind == "craft" and r.steps[i - 1].kind == "craft" and r.steps[i].rec == r.steps[i - 1].rec)
    end
  end)

  it("A: a step must move the skill range; a craft worth less than one point is dropped", function()
    -- gold craft G: 3 leather, chance 0.25 at 130; the bag holds one craft (0.25 point, rounds to nothing); K is leaner but needs thread
    local G = { id = 11, name = "G", d = 2, out = 111, oq = 1, mats = { { 10, 3 } } }
    local K = { id = 12, name = "K", d = 2, out = 112, oq = 1, mats = { { 20, 1 } } }
    local thr = { [11] = { 50, 100, 115, 140 }, [12] = { 50, 90, 140, 150 } }
    local prof, c, o = setup({ [10] = 3 }, { skill = 130, max = 300, recipes = { [11] = G, [12] = K } })
    o.thresholds = function(id) return thr[id] end
    local r = V.Roadmap(prof, c, o)
    assert.is_true(#r.steps >= 1)
    assert.are.equal("K", r.steps[1].rec.name)
    for _, st in ipairs(r.steps) do assert.is_true(st.kind ~= "craft" or st.to > st.from) end
  end)

  it("B: the skill allows the next rank and it is not learned: the first step is the rank, and the roadmap goes on past the old cap", function()
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }, { skill = 61, max = 75 }))
    assert.are.equal("rank", r.steps[1].kind)
    assert.are.equal("Journeyman", r.steps[1].rank)
    assert.is_true(r.rankNow)
    assert.is_true(r.steps[#r.steps].to == nil or r.steps[#r.steps].to > 75 or #r.steps >= 2)
  end)

  it("B: below the rank's skill the rank is not the first step: it comes in the plan at the skill it can be trained from", function()
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }, { skill = 40, max = 75 }))
    assert.is_nil(r.rankNow)
    assert.are.equal("Journeyman", r.nextRank)
    assert.are.equal(50, r.rankAt)
    assert.are_not.equal("rank", r.steps[1].kind)
    local rank
    for _, st in ipairs(r.steps) do if st.kind == "rank" then rank = st end end
    assert.are.equal(50, rank.at)
    assert.are.equal("Journeyman", rank.rank)
    for _, st in ipairs(r.steps) do assert.is_true(st.kind ~= "craft" or st.to <= 50 or st.from >= 50) end   -- a craft stops where the rank is trained
  end)

  it("the bag is consumed across steps: what the belt took is not there for the gloves", function()
    -- 12 leather: the belts take 6, so only 2 gloves (3 each) fit; without that sharing the gloves would be x4
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }))
    assert.are.equal(2, r.steps[2].bagTimes)
  end)

  it("when the bag runs out the step is the best recipe overall with what is missing, and says where to get it", function()
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }))
    local s = r.steps[2]
    assert.are.equal("missing", s.state)
    assert.are.equal("Gloves", s.rec.name)
    assert.are.equal(10, s.missing[1].item)
    assert.are.equal("skin", s.missing[1].how)
    assert.is_true(s.missing[1].n >= 3)
  end)

  it("a recipe to learn gets its own step when it beats the best known one, then counts as known", function()
    local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }, { learn = { { rec = POUCH, recommend = true } } }))
    local learn
    for i, s in ipairs(r.steps) do if s.kind == "learn" then learn = i end end
    assert.is_truthy(learn)
    assert.are.equal("Pouch", r.steps[learn].rec.name)
    assert.is_true(r.steps[learn].at >= 80)                 -- not before the skill it needs
    assert.are.equal("Pouch", r.steps[learn + 1].rec.name)  -- and the next step crafts it
  end)

  it("never offers a recipe to learn that is unusable (other faction, rank not trained, no way to get it, gray)", function()
    for _, flag in ipairs({ { recommend = false }, { rankGated = true }, { unpriced = true }, { gray = true } }) do
      flag.rec = POUCH
      local r = V.Roadmap(setup({ [10] = 12, [20] = 12 }, { learn = { flag } }))
      for _, s in ipairs(r.steps) do assert.are_not.equal("learn", s.kind) end
    end
  end)

  it("stops at 5 steps", function()
    local prof, c, o = setup({ [10] = 500, [20] = 500 }, { learn = { { rec = POUCH, recommend = true } }, max = 300 })
    o.steps = 2
    local r = V.Roadmap(prof, c, o)
    assert.are.equal(2, #r.steps)
    assert.are.equal("steps", r.stopped)
  end)

  it("stops at the rank cap", function()
    local r = V.Roadmap(setup({ [10] = 500, [20] = 500 }, { max = 78 }))
    assert.are.equal("cap", r.stopped)
    assert.is_true(r.steps[#r.steps].to <= 78)
  end)

  it("a capped profession has no step, and names the rank to train", function()
    local r = V.Roadmap(setup({}, { skill = 150, max = 150 }))
    assert.is_true(r.capped)
    assert.are.equal(0, #r.steps)
    assert.are.equal("Expert", r.nextRank)
    assert.are.equal(125, r.rankAt)
  end)

  it("no useful recipe and nothing to learn: no step", function()
    local r = V.Roadmap(setup({}, { skill = 140, max = 300 }))        -- belt and gloves are gray
    assert.are.equal(0, #r.steps)
    assert.are.equal("none", r.stopped)
  end)

  it("an intermediate reagent to make first is listed as a craft to do, not as a missing item", function()
    local CURED = { id = 7, name = "Cured", d = 0, out = 700, oq = 1, mats = { { 10, 1 } } }
    local SHOE = { id = 8, name = "Shoe", d = 0, out = 800, oq = 1, mats = { { 700, 1 } } }
    local prof, c, o = setup({ [10] = 0 }, { recipes = { [7] = CURED, [8] = SHOE } })
    o.thresholds = function(id) return id == 7 and { 10, 20, 30, 40 } or { 50, 90, 100, 110 } end   -- the cured leather is gray, the shoe orange
    local r = V.Roadmap(prof, c, o)
    local sub
    for _, s in ipairs(r.steps) do if s.rec.name == "Shoe" then sub = s end end
    assert.is_truthy(sub)
    assert.are.equal(700, sub.subs[1].item)
  end)
end)

describe("Leveling.Cheapest: switching cost, one walk, and the learn rules of the roadmap", function()
  local function entry(id, units, lo, eS, entryCost)   -- chance 1 on lo..eS (gray far above)
    return { id = id, th = { lo, 500, 500, 600 }, units = units, lo = lo, eS = eS, eA = eS, entry = entryCost or 0 }
  end
  local function names(plan, from)
    local out = {}
    for i, sg in ipairs(plan.path(from)) do out[i] = ("%d:%d>%d"):format(sg.r.id, sg.from, sg.to) end
    return table.concat(out, " ")
  end

  it("no A, B, A for a few units: a recipe a little leaner on 5 points is not worth two switches", function()
    local list = { entry(1, 2, 1, 100), entry(2, 1, 50, 55) }   -- B saves 5 units on 50..55, two switches cost 2 x V.SWITCH
    assert.are.equal("1:10>100", names(V.Cheapest(list, 10, 100, 1), 10))
    local save, stint = V.SWITCH, V.MIN_STINT
    V.SWITCH, V.MIN_STINT = 0, 1
    assert.are.equal("1:10>50 2:50>55 1:55>100", names(V.Cheapest(list, 10, 100, 1), 10))
    V.SWITCH, V.MIN_STINT = save, stint
  end)

  it("no A, B, A either when B saves a lot on a few points: a recipe taken is kept V.MIN_STINT points", function()
    local list = { entry(1, 10, 1, 100), entry(2, 1, 50, 55) }   -- B saves 45 units on 50..55, far more than two switches
    assert.are.equal("1:10>100", names(V.Cheapest(list, 10, 100, 1), 10))
    local stint = V.MIN_STINT
    V.MIN_STINT = 1
    assert.are.equal("1:10>50 2:50>55 1:55>100", names(V.Cheapest(list, 10, 100, 1), 10))
    V.MIN_STINT = stint
    -- a recipe that lasts the stint is taken
    list = { entry(1, 10, 1, 100), entry(2, 1, 50, 100) }
    assert.are.equal("1:10>50 2:50>100", names(V.Cheapest(list, 10, 100, 1), 10))
  end)

  it("a switch that saves more than its cost is made", function()
    local list = { entry(1, 3, 1, 100), entry(2, 1, 50, 100) }
    assert.are.equal("1:10>50 2:50>100", names(V.Cheapest(list, 10, 100, 1), 10))
  end)

  it("one walk: asked from a skill in the middle of a step, the plan is the end of the plan asked from the start", function()
    -- at 40 a recipe 1 unit leaner appears: from scratch at 41 it would win, but the walk is already on recipe 1 (switch > 1 unit x ...)
    local list = { entry(1, 2, 1, 60), entry(2, 1.9, 40, 60), entry(3, 1, 60, 100) }
    local early = V.Cheapest(list, 30, 100, 1)
    local mid = V.Cheapest(list, 45, 100, 1)
    assert.are.equal(early.first(45).id, mid.first(45).id)
    assert.are.equal(names(early, 45), names(mid, 45))
  end)

  local BASE = { id = 1, name = "Base", d = 1, out = 101, oq = 1, mats = { { 10, 4 } } }
  local function roadmap(cand)
    local prof = { skill = 100, max = 300, recipes = { [1] = BASE } }
    local c = { buy = function() end, owned = function() return 0 end }
    local o = { thresholds = function() return { 1, 300, 300, 301 } end, candidates = { cand } }
    return V.Roadmap(prof, c, o)
  end
  local function learned(r)
    for _, st in ipairs(r.path) do if st.kind == "learn" then return st.rec.name end end
  end

  it("a recipe to learn is kept V.MIN_STINT points: a lean one useful on 10 points only is not learned", function()
    local short = { id = 2, name = "Short", learn = 120, mats = { { 10, 1 } }, th = { 120, 125, 128, 130 } }
    assert.is_nil(learned(roadmap({ rec = short, recommend = true, effort = 12 })))
    local long = { id = 3, name = "Long", learn = 120, mats = { { 10, 1 } }, th = { 120, 150, 170, 190 } }
    assert.are.equal("Long", learned(roadmap({ rec = long, recommend = true, effort = 12 })))
  end)

  it("mid-profession: a recipe to learn that was best below the skill only is not kept on (its cost is paid from the skill)", function()
    -- at 140, Early (1 unit, until 152) saves 12 units on Later (2 units, to 300): less than its learn and the switch after it.
    -- Below 140 Early would win by far; the character never learned it there, so the plan from 140 goes to Later directly.
    local early = { id = 2, name = "Early", learn = 95, mats = { { 10, 1 } }, th = { 95, 150, 151, 152 } }
    local later = { id = 3, name = "Later", learn = 135, mats = { { 10, 2 } }, th = { 135, 300, 300, 301 } }
    local prof = { skill = 140, max = 300, recipes = { [1] = BASE } }
    local c = { buy = function() end, owned = function() return 0 end }
    local o = { thresholds = function() return { 1, 300, 300, 301 } end,
      candidates = { { rec = early, recommend = true, effort = 12 }, { rec = later, recommend = true, effort = 12 } } }
    local r = V.Roadmap(prof, c, o)
    local learns = {}
    for _, st in ipairs(r.path) do if st.kind == "learn" then learns[#learns + 1] = st.rec.name end end
    assert.are.equal("Later", table.concat(learns, " "))
    assert.are.equal("learn", r.steps[1].kind)
    assert.are.equal("Later", r.steps[1].rec.name)
    -- the same plan asked from 100 does learn Early (it saves 50 points of 3 units there)
    prof.skill = 100
    learns = {}
    for _, st in ipairs(V.Roadmap(prof, c, o).path) do if st.kind == "learn" then learns[#learns + 1] = st.rec.name end end
    assert.are.equal("Early Later", table.concat(learns, " "))
  end)

  it("a craft that ends exactly at the cap stops where the rank can be trained (the rank is a step, not the cap banner)", function()
    local a = { id = 1, name = "A", d = 1, out = 101, oq = 1, mats = { { 10, 1 } } }   -- used up to 150 exactly
    local b = { id = 2, name = "B", d = 1, out = 102, oq = 1, mats = { { 10, 2 } } }
    local th = { [1] = { 1, 149, 149, 150 }, [2] = { 1, 300, 300, 301 } }
    local r = V.Roadmap({ skill = 100, max = 150, recipes = { [1] = a, [2] = b } }, { buy = function() end, owned = function() return 0 end },
      { thresholds = function(id) return th[id] end })
    assert.are.same({ "craft", 100, 125 }, { r.path[1].kind, r.path[1].from, r.path[1].to })
    assert.are.same({ "rank", 125 }, { r.path[2].kind, r.path[2].at })
    assert.are.same({ "craft", "A", 125, 150 }, { r.path[3].kind, r.path[3].rec.name, r.path[3].from, r.path[3].to })
  end)

  it("never offers a recipe only the other faction's vendor teaches (way.onlyFaction), unless a recorded trainer window offers it", function()
    local crafts = {
      { id = 5, name = "Both", learn = 100, mats = { { 10, 1 } }, how = { kind = "trainer" } },
      { id = 6, name = "OtherSide", learn = 100, mats = { { 10, 1 } }, how = { kind = "trainer", onlyFaction = "A" } },
    }
    local ctx = { known = function() return false end, place = function() return { kind = "pin", mapID = 1, x = 0.5, y = 0.5 } end }
    local names = {}
    for _, row in ipairs(V.Candidates(crafts, 100, ctx)) do names[#names + 1] = row.rec.name end
    assert.are.same({ "Both" }, names)
    ctx.offer = function(id) return id == 6 and { skill = 100, status = "available", cost = 5 } or nil end
    names = {}
    for _, row in ipairs(V.Candidates(crafts, 100, ctx)) do names[#names + 1] = row.rec.name end
    assert.are.same({ "Both", "OtherSide" }, names)
  end)

  it("a learn with no place on the map costs V.LEARN_EFFORT.unknown", function()
    local crafts = {
      { id = 5, name = "Pinned", learn = 100, mats = { { 10, 1 } }, how = { kind = "trainer" } },
      { id = 6, name = "TextOnly", learn = 100, mats = { { 10, 1 } }, how = { kind = "trainer" } },
      { id = 7, name = "VendorNoPrice", learn = 100, mats = { { 10, 1 } }, how = { kind = "vendor" } },
    }
    local ctx = { known = function() return false end,
      place = function(rec) return rec.id ~= 6 and { kind = "pin", mapID = 1, x = 0.5, y = 0.5 } or { kind = "text" } end }
    local by = {}
    for _, row in ipairs(V.Candidates(crafts, 100, ctx)) do by[row.rec.name] = row.effort end
    assert.are.equal(V.LEARN_EFFORT.trainer, by.Pinned)
    assert.are.equal(V.LEARN_EFFORT.unknown, by.TextOnly)
    assert.are.equal(V.LEARN_EFFORT.other, by.VendorNoPrice)       -- on the map: a trip whose price is not known, not a search
    assert.is_true(V.LEARN_EFFORT.unknown > V.LEARN_EFFORT.other)
  end)
end)

describe("Leveling.Roadmap: the effort of the reagents (ctx.effort), and nothing else, decides the plan", function()
  -- items: 20 thread (effort 0.25), 30 a rare drop (effort 4), 40 and 41 plain ones (no effort known: 1)
  local EFFORT = { [20] = 0.25, [30] = 4 }
  local THREAD = { id = 1, name = "Thread", d = 0, out = 101, oq = 1, mats = { { 20, 3 } } }   -- 3 x 0.25 = 0.75 per craft
  local RARE = { id = 2, name = "Rare", d = 0, out = 102, oq = 1, mats = { { 30, 3 } } }       -- 3 x 4 = 12 per craft: same units, 16 times the effort
  local TH = { [1] = { 50, 100, 110, 120 }, [2] = { 50, 100, 110, 120 } }
  local function plan(ctx, recipes)
    if ctx.effort == nil then ctx.effort = function(id) return EFFORT[id] end elseif ctx.effort == false then ctx.effort = nil end
    local r = V.Roadmap({ skill = 100, max = 150, recipes = recipes or { [1] = THREAD, [2] = RARE } }, ctx,
      { thresholds = function(id) return TH[id] end })
    local out = {}
    for i, p in ipairs(r.path) do out[i] = (p.rec and p.rec.name or p.kind) .. " " .. (p.from or p.at) .. ">" .. (p.to or "") end
    return table.concat(out, ","), r
  end

  it("a recipe with the same number of units but easy reagents beats a rare-drop one", function()
    local sig = plan({ owned = function() return 0 end })
    assert.matches("^Thread ", sig)
    assert.is_nil(sig:find("Rare", 1, true))
  end)

  it("weighs a reagent by its effort: the other way round when the thread is the hard one", function()
    local sig = plan({ owned = function() return 0 end, effort = function(id) return ({ [20] = 9, [30] = 1 })[id] end })
    assert.matches("^Rare ", sig)
  end)

  it("counts every unit 1 without ctx.effort: fewer units win", function()
    local FEW = { id = 3, name = "Few", d = 0, out = 103, oq = 1, mats = { { 20, 2 } } }
    local sig = plan({ owned = function() return 0 end, effort = false }, { [1] = THREAD, [3] = FEW })
    assert.matches("^Few ", sig)
  end)

  it("is the same plan whatever the prices, the bags and the bank hold (a pure function of the static data)", function()
    local empty = plan({ owned = function() return 0 end, buy = function() end, price = function() end })
    local rich = plan({ owned = function(id) return id == 30 and 2 or 1 end, bagOwned = function() return 1 end,
      buy = function(id) return id == 30 and 10 or 100000 end, price = function() return 1, 0 end,
      how = function() return "skin" end })
    assert.are.equal(empty, rich)
  end)

  it("says the effort per point in `why`: the units of the learned recipe against the best known one", function()
    local LEARN = { id = 5, name = "Learn", d = 0, out = 105, oq = 1, mats = { { 20, 2 } }, learn = 100, th = { 100, 125, 140, 160 }, way = { kind = "trainer" } }
    local KNOWN = { id = 1, name = "Known", d = 0, out = 101, oq = 1, mats = { { 30, 1 } } }   -- 4 per craft
    local r = V.Roadmap({ skill = 100, max = 300, recipes = { [1] = KNOWN } }, { owned = function() return 0 end, effort = function(id) return EFFORT[id] end },
      { thresholds = function() return { 50, 100, 110, 120 } end, learn = { { rec = LEARN, recommend = true } } })
    local why
    for _, s in ipairs(r.steps) do if s.kind == "learn" then why = s.why end end
    assert.is_truthy(why)
    assert.are.equal("Known", why.alt.name)
    assert.is_near(2 * 0.25, why.perPoint, 1e-9)                      -- 0.5 per craft, chance 1 until its yellow at 125
    assert.is_near(4, why.altPerPoint, 1e-9)                          -- one drop at 4, chance 1 (orange) at 100
  end)
end)
