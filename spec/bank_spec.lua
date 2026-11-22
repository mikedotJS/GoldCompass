-- The bank is counted: the snapshot (Bank.lua), the roadmap that counts bags + bank (Leveling.Roadmap), the shopping list sums
-- (Shopping.lua) and the reagent tooltip with its bank line (HowTo.lua). Every expected value was worked out by running the code.
dofile("spec/helper_wow_lua51.lua")

local function fresh()
  local ns = {}
  for _, f in ipairs({ "Strings", "Leveling", "Bank", "Shopping", "HowTo" }) do assert(loadfile(f .. ".lua"))("GoldCompass", ns) end
  return ns
end

describe("Bank snapshot", function()
  local ns = fresh()
  local B = ns.Bank
  -- bank container -1 holds 3 slots, bank bag 5 holds 2
  local contents = { [-1] = { { 10, 4 }, nil, { 20, 1 } }, [5] = { { 10, 8 }, { 30, 2 } } }
  local function api(over)
    local a = { containers = { -1, 5, 6 }, main = -1,
      slots = function(bag) return contents[bag] and (bag == -1 and 3 or 2) or 0 end,
      item = function(bag, slot) local s = contents[bag][slot]; if s then return s[1], s[2] end end }
    for k, v in pairs(over or {}) do a[k] = v end
    return a
  end

  it("adds up the stacks of every bank container by item", function()
    assert.are.same({ [10] = 12, [20] = 1, [30] = 2 }, B.Scan(api()))
  end)

  it("gives nil, never an empty snapshot, when the bank's own container reports no slot (the window is closing)", function()
    assert.is_nil(B.Scan(api({ slots = function() return 0 end })))
  end)

  it("counts a stack without a count as one", function()
    local one = B.Scan(api({ item = function(bag, slot) if bag == -1 and slot == 1 then return 77 end end }))
    assert.are.equal(1, one[77])
  end)

  it("counts what the snapshot holds and 0 for the rest or before the bank was ever seen", function()
    ns.char = nil
    assert.are.equal(0, B.Count(10))
    ns.char = {}
    assert.are.equal(0, B.Count(10))
    B.Save(ns.char, B.Scan(api()), 1000)
    assert.are.equal(12, B.Count(10))
    assert.are.equal(0, B.Count(99))
  end)

  it("tells how many whole days ago the bank was seen, nil when never", function()
    local char = {}
    assert.is_nil(B.AgeDays(char, 5 * 86400))
    B.Save(char, {}, 1000)
    assert.are.equal(0, B.AgeDays(char, 1000 + 86399))
    assert.are.equal(1, B.AgeDays(char, 1000 + 86400))
    assert.are.equal(3, B.AgeDays(char, 1000 + 3 * 86400 + 5))
    assert.are.equal(0, B.AgeDays(char, 500))      -- a clock that went back never gives a negative age
  end)
end)

describe("Roadmap counts the bank", function()
  local V = fresh().Leveling
  local BELT = { id = 1, name = "Belt", d = 0, out = 101, oq = 1, mats = { { 10, 3 }, { 20, 1 } } }
  local GLOVES = { id = 2, name = "Gloves", d = 1, out = 102, oq = 1, mats = { { 10, 3 }, { 20, 2 } } }
  local TH = { [1] = { 50, 76, 77, 78 }, [2] = { 50, 70, 85, 100 } }
  local function road(bag, bank)
    local c = { price = function() end, vendor = function() end, buy = function(id) return id == 20 and 30 or nil end,
      owned = function(id) return (bag[id] or 0) + (bank[id] or 0) end, bagOwned = function(id) return bag[id] or 0 end,
      how = function(id) return id == 10 and "skin" or nil end }
    return V.Roadmap({ skill = 75, max = 150, recipes = { [1] = BELT, [2] = GLOVES } }, c, { thresholds = function(id) return TH[id] end })
  end
  local function banked(step)
    local out = {}
    for i, b in ipairs(step.banked) do out[i] = b.item .. "x" .. b.n end
    return table.concat(out, ",")
  end

  it("takes the bags first: 3 leather in the bags and 9 in the bank feed the belt twice, one craft from the bags alone", function()
    local r = road({ [10] = 3, [20] = 12 }, { [10] = 9 })
    local belt = r.steps[1]
    assert.are.equal("bag", belt.state)                  -- complete, thanks to the bank
    assert.are.equal(2, belt.times)
    assert.are.equal(1, belt.inBag)
    assert.are.equal("10x3", banked(belt))
    assert.are.same({ [10] = 6, [20] = 2 }, belt.used)
    assert.are.equal(0, #belt.missing)
  end)

  it("keeps what is truly missing apart from what waits in the bank", function()
    local gloves = road({ [10] = 3, [20] = 12 }, { [10] = 9 }).steps[2]
    assert.are.equal("missing", gloves.state)
    assert.are.equal("10x6", banked(gloves))
    assert.are.equal(2, gloves.bagTimes)
    assert.are.equal(0, gloves.inBag)
    assert.are.equal("10", tostring(gloves.missing[1].item))
    -- gloves from 77 to 95 (their chance is under 0.2 from there): 30 / (100 - s) crafts per point, 44 crafts in all
    assert.are.equal(44, gloves.times)
    assert.are.equal(126, gloves.missing[1].n)           -- 3 x 44 leather, 6 owned after the belts
    assert.are.equal(78, gloves.missing[2].n)            -- 2 x 44 thread, 10 owned after the belts
  end)

  it("says nothing about the bank when everything is in the bags: the old behaviour", function()
    local r = road({ [10] = 12, [20] = 12 }, {})
    assert.are.equal(2, r.steps[1].inBag)
    assert.are.equal(2, r.steps[1].bagTimes)
    assert.are.equal(0, #r.steps[1].banked)
    assert.are.equal(0, #r.steps[2].banked)
  end)

  it("treats everything as in the bags when the caller gives no bag count", function()
    local c = { price = function() end, vendor = function() end, buy = function() end, owned = function(id) return id == 10 and 12 or 12 end,
      how = function() end }
    local r = V.Roadmap({ skill = 75, max = 150, recipes = { [1] = BELT, [2] = GLOVES } }, c, { thresholds = function(id) return TH[id] end })
    assert.are.equal(r.steps[1].times, r.steps[1].inBag)
    assert.are.equal(0, #r.steps[1].banked)
  end)

  it("a bank holding only some of the reagents leaves the rest missing", function()
    local belt = road({}, { [10] = 6, [20] = 1 }).steps[1]
    assert.are.equal("missing", belt.state)
    assert.are.equal("10x6,20x1", banked(belt))
    assert.are.equal(1, belt.missing[1].n)
    assert.are.equal(20, belt.missing[1].item)
  end)
end)

describe("Shopping.Build", function()
  local ns = fresh()
  local Sh = ns.Shopping
  local function env(bag, bank)
    return { bag = function(id) return bag[id] or 0 end, bank = function(id) return bank[id] or 0 end, name = function(id) return "Item" .. id end }
  end
  local function craft(used, missing, banked)
    local s = { kind = "craft", used = used, missing = {}, banked = {} }
    for _, m in ipairs(missing or {}) do s.missing[#s.missing + 1] = { item = m[1], n = m[2], tip = function() return "tip" .. m[1] end } end
    for _, m in ipairs(banked or {}) do s.banked[#s.banked + 1] = { item = m[1], n = m[2] } end
    return s
  end
  local profs = { { name = "Cuir", road = { skillEnd = 88, steps = {
    craft({ [10] = 6, [20] = 2 }, {}, { { 10, 3 } }),
    { kind = "learn" },
    craft({ [10] = 5 }, { { 10, 13 }, { 30, 12 } }, { { 10, 12 } }) } } } }

  it("sums what the steps use and lack, counts the bag and the bank, and lists the distinct items still short", function()
    local b = Sh.Build(profs, env({ [10] = 1, [20] = 2 }, { [10] = 12 }))
    assert.are.equal(2, b.missing)                       -- item 10 (13 of 24) and item 30 (0 of 12)
    local by = {}
    for _, r in ipairs(b.rows) do by[r.item] = r end
    assert.are.equal(24, by[10].need)
    assert.are.equal(13, by[10].have)
    assert.are.equal(12, by[10].bank)
    assert.are.equal(15, by[10].fetch)
    assert.is_false(by[10].ok)
    assert.are.equal(2, by[20].need)
    assert.is_true(by[20].ok)
    assert.are.equal(12, by[30].need)
    assert.are.equal(0, by[30].have)
  end)

  it("sorts the items still short first (the most short first), then the ones to fetch, then the complete ones", function()
    local b = Sh.Build(profs, env({ [10] = 1, [20] = 2 }, { [10] = 12 }))
    local order = {}
    for i, r in ipairs(b.rows) do order[i] = r.item end
    assert.are.same({ 30, 10, 20 }, order)
  end)

  it("says what to take at the bank, the biggest quantity first, and where each roadmap ends", function()
    local b = Sh.Build(profs, env({}, { [10] = 12 }))
    assert.are.equal("15 × Item10", Sh.FetchText(b.fetch))
    assert.are.same({ { name = "Cuir", skill = 88 } }, b.upTo)
  end)

  it("a roadmap that is complete thanks to the bank has no missing item but something to fetch", function()
    local only = { { name = "Cuir", road = { skillEnd = 77, steps = { craft({ [10] = 6 }, {}, { { 10, 6 } }) } } } }
    local b = Sh.Build(only, env({}, { [10] = 6 }))
    assert.are.equal(0, b.missing)
    assert.are.equal("6 × Item10", Sh.FetchText(b.fetch))
    assert.is_true(b.rows[1].ok)
  end)

  it("ignores a capped profession, a profession without roadmap and the steps that craft nothing", function()
    local b = Sh.Build({ { name = "A", road = { capped = true, steps = { craft({ [10] = 1 }) } } }, { name = "B" },
      { name = "C", road = { skillEnd = 80, steps = { { kind = "learn" } } } } }, env({}, {}))
    assert.are.equal(0, #b.rows)
    assert.are.equal(0, #b.upTo)
  end)

  it("sums the same item over two professions", function()
    local two = { { name = "A", road = { skillEnd = 80, steps = { craft({ [10] = 4 }) } } }, { name = "B", road = { skillEnd = 60, steps = { craft({}, { { 10, 3 } }) } } } }
    local b = Sh.Build(two, env({ [10] = 4 }, {}))
    assert.are.equal(7, b.rows[1].need)
    assert.are.equal(1, b.missing)
  end)
end)

describe("HowTo.Reagent with the bank", function()
  local ns = fresh()
  local env = { faction = "H", fr = false, level = 60, place = function() end, itemName = function(id) return "Objet" .. id end,
    owned = function() return 1 end, banked = function() return 12 end, price = function() return nil end, money = tostring, zone = function(m) return "Zone" .. m end,
    npcName = function(_, en) return en end, creature = function(en) return en, nil end, nodeCounts = function() return {} end, npc = function() return nil end }

  it("says how many are in the bags and in the bank on the first line", function()
    assert.are.equal("Il t'en manque |cffffd1005|r · 1 dans ton sac, 12 à la banque", ns.HowTo.Reagent(10, 5, env).lines[1].text)
  end)

  it("an item that only waits in the bank says so instead of a shortage of 0", function()
    assert.are.equal("12 à la banque · 1 dans ton sac", ns.HowTo.Reagent(10, 0, env).lines[1].text)
  end)

  it("keeps the old first line when the bank holds none or the game gives no bank count", function()
    env.banked = function() return 0 end
    assert.are.equal("Il t'en manque |cffffd1005|r · tu en as 1", ns.HowTo.Reagent(10, 5, env).lines[1].text)
    env.banked = nil
    assert.are.equal("Il t'en manque |cffffd1005|r · tu en as 1", ns.HowTo.Reagent(10, 5, env).lines[1].text)
  end)

  it("gives the first way to get the item in a few words", function()
    ns.ReagentSources = { [10] = { vendors = { { 1, "Flakk", 1411, 52.9, 42, "AH", 25 } } } }
    assert.are.equal("marchand · Flakk, Zone1411", ns.HowTo.Reagent(10, 5, env).source)
    ns.ReagentSources = {}
    ns.Skinning = { [10] = { { 5, "Boar", 10, 20 } } }
    ns.SkinSpots = {}
    assert.are.equal("dépeçage, bêtes niv. 10 à 20", ns.HowTo.Reagent(10, 5, env).source)
    ns.Skinning = {}
    assert.is_nil(ns.HowTo.Reagent(10, 5, env).source)
  end)
end)
