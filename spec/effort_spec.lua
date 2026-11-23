-- Static effort of one reagent unit (Effort.lua). Every expected value is worked out in the comments, then checked by running the code.
local ns = {}
assert(loadfile("Effort.lua"))("GoldCompass", ns)

local function vendor(price, limited) return { { 1, "V", 1, 0, 0, "AH", price, limited = limited } } end
local function E(static) return ns.Effort.Reagents(static) end

describe("Effort.Reagents", function()
  it("weighs a vendor item from 0.25 (10c) to 0.5 (50s), never more", function()
    -- 0.25 + 0.25 * ln(p / 10) / ln(500): p = 10 -> 0.25; p = 100 -> 0.25 + 0.25 * ln(10) / ln(500) = 0.3426; p = 5000 -> 0.5
    local e = E({ sources = { [1] = { vendors = vendor(10) }, [2] = { vendors = vendor(100) }, [3] = { vendors = vendor(5000) },
      [4] = { vendors = vendor(900000) }, [5] = { vendors = vendor(1) } } })
    assert.is_near(0.25, e(1), 1e-9)
    assert.is_near(0.3426, e(2), 1e-3)
    assert.are.equal(0.5, e(3))
    assert.are.equal(0.5, e(4))
    assert.is_near(0.25, e(5), 1e-9)   -- under 10c counts as 10c
  end)

  it("does not take a vendor with a limited stock for a vendor", function()
    assert.are.equal(1, E({ sources = { [1] = { vendors = vendor(10, true) } } })(1))
    assert.is_near(0.25, E({ sources = { [1] = { vendors = { vendor(10, true)[1], vendor(10)[1] } } } })(1), 1e-9)
  end)

  it("weighs a gathered item by the zone with the most points, 10 at the most", function()
    -- 0.5 / min(1, points / 100): 159 points -> 0.5; 50 -> 1; none -> 0.5 / 0.05 = 10
    local e = E({ gather = { [1] = { zones = { { 1, 159, 20 }, { 2, 3, 40 } } }, [2] = { zones = { { 1, 0, 50 } } }, [3] = { zones = { { 1, 0, 0 } } } } })
    assert.are.equal(0.5, e(1))
    assert.are.equal(1, e(2))
    assert.are.equal(10, e(3))
  end)

  it("weighs a skinned item by what a skin gives in the best zone", function()
    -- zone 1: 100 spawns of a beast that gives 0.64 per skin -> 0.64 -> 1 / 0.64 = 1.5625
    -- zone 2: 50 spawns, 1 per skin, but half the pace (50 / 100) -> 0.5: the first zone is the best
    local e = E({ skin = { [1] = { { 1, "A", 1, 2, 1, spots = 100, items = { { 10, 0.64 } } } },
      [2] = { { 2, "B", 1, 2, 1, spots = 50, items = { { 10, 1 } } } } } })
    assert.is_near(1.5625, e(10), 1e-9)
    assert.are.equal(10, E({ skin = { [1] = { { 1, "A", 1, 2, 1, spots = 100, items = { { 10, 0.01 } } } } } })(10))   -- 100: capped
  end)

  it("takes the lowest of several sources: a cloth that is also a rare skin loot stays cheap", function()
    -- skinned 1.2% (weight 10 by cap) but a vendor sells it at 10c: 0.25
    local e = E({ sources = { [1] = { vendors = vendor(10) } },
      skin = { [1] = { { 1, "A", 1, 2, 1, spots = 100, items = { { 1, 0.012 } } } } } })
    assert.are.equal(0.25, e(1))
  end)

  it("weighs a crafted item by its reagents divided by what one craft makes, the cheapest recipe", function()
    -- item 5 = 2 x item 1 (0.25) + 1 x item 2 (0.5) = 1, made 2 at a time: 0.5; the second recipe costs 4 x 0.5 = 2
    local e = E({ sources = { [1] = { vendors = vendor(10) }, [2] = { vendors = vendor(5000) } },
      recipes = { [5] = { { mats = { { 1, 2 }, { 2, 1 } }, oq = 2 }, { mats = { { 2, 4 } }, oq = 1 } } } })
    assert.is_near(0.5, e(5), 1e-9)
  end)

  it("ends when two recipes make each other, and always returns a number", function()
    local e = E({ sources = { [3] = { vendors = vendor(10) } },
      recipes = { [1] = { { mats = { { 2, 1 }, { 3, 1 } }, oq = 1 } }, [2] = { { mats = { { 1, 1 } }, oq = 1 } } } })
    assert.are.equal("number", type(e(1)))
    assert.are.equal("number", type(e(2)))
    assert.are.equal(e(1), E({ sources = { [3] = { vendors = vendor(10) } },
      recipes = { [1] = { { mats = { { 2, 1 }, { 3, 1 } }, oq = 1 } }, [2] = { { mats = { { 1, 1 } }, oq = 1 } } } })(1))
  end)

  it("weighs a drop by 100 / its chance (best chance), 10 at the most", function()
    -- 25% -> 4; 50% and 20% -> 2 (the best); 5% -> 20, capped at 10
    local e = E({ sources = { [1] = { drops = { { "Boar", 0, true, 25 } } }, [2] = { drops = { { "A", 0, true, 20 }, { "B", 0, true, 50 } } },
      [3] = { drops = { { "C", 0, true, 5 } } } } })
    assert.are.equal(4, e(1))
    assert.are.equal(2, e(2))
    assert.are.equal(10, e(3))
  end)

  it("gives a drop without a chance the median chance, only when nothing else is known", function()
    -- known chances 10, 40, 50: median 40 -> 2.5. Item 9 has a drop with no chance AND a recipe at 0.5: the recipe wins.
    local e = E({ sources = { [1] = { drops = { { "A", 0, true, 10 } } }, [2] = { drops = { { "B", 0, true, 40 } } },
      [3] = { drops = { { "C", 0, true, 50 } } }, [4] = { drops = { { "D", 0, true } } }, [5] = { vendors = vendor(5000) },
      [9] = { drops = { { "E", 0, true } } } },
      recipes = { [9] = { { mats = { { 5, 1 } }, oq = 1 } }, [20] = { { mats = { { 4, 1 }, { 1, 1 } }, oq = 1 } } } })
    assert.are.equal(2.5, e(4))
    assert.are.equal(0.5, e(9))
  end)

  it("counts 1 for an item nothing is known about, and needs no WoW API", function()
    local e = E({})
    assert.are.equal(1, e(12345))
    assert.are.equal(1, E({ sources = { [1] = {} }, gather = {}, skin = {}, recipes = {} })(1))
  end)

  it("does not depend on the order the items are asked in", function()
    local static = { sources = { [3] = { vendors = vendor(10) } },
      recipes = { [1] = { { mats = { { 2, 1 }, { 3, 1 } }, oq = 1 } }, [2] = { { mats = { { 1, 1 } }, oq = 1 } } } }
    local a, b = E(static), E(static)
    local a1, a2 = a(1), a(2)
    local b2, b1 = b(2), b(1)
    assert.are.equal(a1, b1)
    assert.are.equal(a2, b2)
  end)
end)
