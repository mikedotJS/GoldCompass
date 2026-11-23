-- Synergy.lua (pure) and the extra inputs of Shopping.Build: hints from fixtures, never from the game. Every expected number is worked out in
-- the comments below, then checked by running the code.
local ns = {}
for _, f in ipairs({ "Strings", "ZoneRank", "Route", "Synergy", "Shopping" }) do assert(loadfile(f .. ".lua"))("GoldCompass", ns) end
local SY, S = ns.Synergy, ns.S

local LIGHT_LEATHER, LIGHT_HIDE, PEACEBLOOM, COPPER_ORE, COPPER_BAR = 2318, 783, 2447, 2770, 2840
local BARRENS, DUROTAR, SILVERPINE, ASHENVALE = 1413, 1411, 1421, 1440

-- A beast: { npcID, name, lvMin, lvMax, skill, spots =, items = { { itemID, perSkin } } }
local function beast(id, skill, spots, items) return { id, "Beast" .. id, 10, 12, skill, spots = spots, items = items } end

-- Barrens: 100 spots, 0.75 Light Leather and 0.035 Light Hide a skin. Durotar: 100 spots, 1.0 Light Leather (a better zone: rate 60 against 45).
-- Silverpine: only 20 spots (pace 12 an hour). Ashenvale: needs skill 150 (out of reach at 110).
local function fixture()
  return {
    skinZones = {
      [BARRENS] = { beast(1, 1, 100, { { LIGHT_LEATHER, 0.75 }, { LIGHT_HIDE, 0.035 } }) },
      [DUROTAR] = { beast(2, 1, 100, { { LIGHT_LEATHER, 1.0 } }) },
      [SILVERPINE] = { beast(3, 1, 20, { { LIGHT_LEATHER, 1.0 } }) },
      [ASHENVALE] = { beast(4, 150, 100, { { LIGHT_LEATHER, 5 } }) },
    },
    nodes = {
      [401] = { type = "Herb Gathering", skill = 1, item = PEACEBLOOM, yield = 2 },
      [201] = { type = "Mining", skill = 1, item = COPPER_ORE, yield = 2 },
    },
    counts = function() return { [BARRENS] = { [401] = 100 }, [DUROTAR] = { [201] = 100 } } end,
    bar = function(item) return item == COPPER_BAR and { ore = COPPER_ORE, per = 1, out = 1 } or nil end,
    routeZone = function() return nil end,
    price = function() return nil end,
    now = function() return 1000 end,
  }
end
local SKILLS = { Skinning = 110, ["Herb Gathering"] = 50, Mining = 50 }

describe("Synergy.Hint", function()
  it("skin: the roadmap's zone is kept while its rate is at least half of the best (45 against 60), 26 Light Leather = 35 beasts", function()
    local data = fixture()
    data.routeZone = function(prof) return prof == "Skinning" and BARRENS or nil end
    local h = SY.Hint(LIGHT_LEATHER, 26, SKILLS, data)
    assert.are.equal("skin", h.kind)
    assert.are.equal(BARRENS, h.zone)
    assert.is_true(h.here)
    assert.are.equal(35, h.count)               -- ceil(26 / 0.75) = 35
    assert.are.equal(35 / 60, h.hours)          -- 60 actions an hour with 100 spots
    assert.is_false(h.rare)
    assert.is_nil(h.ore)
  end)

  it("takes the best rate when the roadmap sends nowhere, or when its zone gives less than half (12 an hour against 60)", function()
    local data = fixture()
    assert.are.equal(DUROTAR, SY.Hint(LIGHT_LEATHER, 26, SKILLS, data).zone)
    data.routeZone = function() return SILVERPINE end    -- pace 12 x 1.0 = 12 < 30
    local h = SY.Hint(LIGHT_LEATHER, 26, SKILLS, data)
    assert.are.equal(DUROTAR, h.zone)
    assert.is_false(h.here)
    assert.are.equal(26, h.count)                        -- 1.0 a skin
  end)

  it("a zone the skill does not reach is no candidate", function()
    local data = fixture()
    data.routeZone = function() return ASHENVALE end
    local h = SY.Hint(LIGHT_LEATHER, 26, SKILLS, data)
    assert.are_not.equal(ASHENVALE, h.zone)
    assert.is_nil(SY.Hint(LIGHT_LEATHER, 26, { Skinning = 0 }, data))   -- a skill below every beast
  end)

  it("says 'rare' above 2 hours: 14 Light Hide at 0.035 is 400 beasts, 6.7 hours, no itinerary data needed", function()
    local data = fixture()
    data.routeZone = function() return BARRENS end
    local h = SY.Hint(LIGHT_HIDE, 14, SKILLS, data)
    assert.is_true(h.rare)
    assert.are.equal(400, h.count)              -- ceil(14 / 0.035) = 400
    assert.is_true(h.hours > 6.6 and h.hours < 6.7)
    assert.is_false(h.ah)
    data.price = function() return 150 end
    data.now = function() return 5000 end        -- past the cache of the first answer
    assert.is_true(SY.Hint(LIGHT_HIDE, 14, SKILLS, data).ah)
  end)

  it("herb: 20 Peacebloom at 2 a plant = 10 plants; ore: 12 copper bars = 12 ore = 6 veins; no profession, no hint", function()
    local data = fixture()
    local herb = SY.Hint(PEACEBLOOM, 20, SKILLS, data)
    assert.are.equal("herb", herb.kind); assert.are.equal(BARRENS, herb.zone); assert.are.equal(10, herb.count)
    local bar = SY.Hint(COPPER_BAR, 12, SKILLS, data)
    assert.are.equal("bar", bar.kind); assert.are.equal(DUROTAR, bar.zone); assert.are.equal(6, bar.count)
    assert.are.same({ item = COPPER_ORE, n = 12 }, bar.ore)
    assert.are.equal("ore", SY.Hint(COPPER_ORE, 4, SKILLS, data).kind)
    assert.is_nil(SY.Hint(COPPER_BAR, 12, { Skinning = 110 }, data))      -- no Mining
    assert.is_nil(SY.Hint(PEACEBLOOM, 20, { Skinning = 110 }, data))      -- no Herbalism
    assert.is_nil(SY.Hint(LIGHT_LEATHER, 26, { Mining = 50 }, data))      -- no Skinning
  end)

  it("a bar made of two ingredients, an item nothing gives, a node below the skill: no hint", function()
    local data = fixture()
    assert.is_nil(SY.Hint(9999, 5, SKILLS, data))
    data.bar = function() return nil end                                   -- bronze, steel: two ingredients, left out
    assert.is_nil(SY.Hint(COPPER_BAR, 12, SKILLS, data))
    assert.is_nil(SY.Hint(PEACEBLOOM, 20, { ["Herb Gathering"] = 0 }, fixture()))
    assert.is_nil(SY.Hint(LIGHT_LEATHER, 0, SKILLS, fixture()))            -- nothing short
  end)

  it("a measured beast (data.yields) replaces the Classic yield", function()
    local data = fixture()
    data.yields = function(b) return b[1] == 1 and { { LIGHT_LEATHER, 0.5 } } or b.items end
    data.routeZone = function() return BARRENS end
    assert.are.equal(52, SY.Hint(LIGHT_LEATHER, 26, SKILLS, data).count)   -- 26 / 0.5
  end)

  it("keeps the answer per (item, skill, routeZone) and asks the counts only once", function()
    local data = fixture()
    local calls = 0
    local counts = data.counts
    data.counts = function() calls = calls + 1; return counts() end
    SY.Hint(PEACEBLOOM, 20, SKILLS, data)
    SY.Hint(PEACEBLOOM, 40, SKILLS, data)                                  -- same key, another quantity
    assert.are.equal(1, calls)
    SY.Hint(PEACEBLOOM, 20, { ["Herb Gathering"] = 51 }, data)             -- another skill
    assert.are.equal(2, calls)
    data.routeZone = function() return BARRENS end                         -- another zone to stay in
    SY.Hint(PEACEBLOOM, 20, SKILLS, data)
    assert.are.equal(3, calls)
    data.now = function() return 1000 + SY.TTL + 1 end                     -- expired
    SY.Hint(PEACEBLOOM, 20, SKILLS, data)
    assert.are.equal(4, calls)
  end)

  it("orders the zones that give about the same as the roadmap does: a zone far above the player's level goes last", function()
    local data = fixture()
    data.skinZones[SILVERPINE][1].spots = 100         -- same rate as Durotar
    data.order = function() return { level = 10, lowest = function(zone) return zone == DUROTAR and 30 or 10 end } end
    assert.are.equal(SILVERPINE, SY.Hint(LIGHT_LEATHER, 26, SKILLS, data).zone)
  end)

  it("never writes ns.char.routeZone: it is only read", function()
    local data = fixture()
    ns.char = { routeZone = { Skinning = BARRENS } }
    data.routeZone = function(prof) return ns.char.routeZone[prof] end
    SY.Hint(LIGHT_LEATHER, 26, SKILLS, data)
    SY.Build({}, SKILLS, data).hint(PEACEBLOOM, 20)
    assert.are.same({ Skinning = BARRENS }, ns.char.routeZone)
    ns.char = nil
  end)
end)

describe("Synergy.Build", function()
  local function road(missing, subs)
    return { steps = { { kind = "craft", missing = missing or {}, subs = subs or {} } } }
  end
  local profs = {
    { name = "Travail du cuir", road = road({ { item = LIGHT_LEATHER, n = 26, name = "Cuir léger" }, { item = LIGHT_HIDE, n = 14, name = "Peau légère" } }) },
    { name = "Ingénierie", road = road({ { item = LIGHT_LEATHER, n = 12, name = "Cuir léger" } }) },
    { name = "Couture", road = road({ { item = 2996, n = 40, name = "Toile" } }) },
    { name = "Minage", road = { gathering = true, steps = { { kind = "craft", missing = { { item = COPPER_ORE, n = 9, name = "Minerai" } }, subs = {} } } } },
  }

  it("sums what each gathering profession feeds: units per consumer, the biggest first; the item with no zone and the smelting ore are left out", function()
    local syn = SY.Build(profs, SKILLS, fixture())
    local f = syn.feeds[393]
    assert.are.equal(2, #f)
    assert.are.equal("Travail du cuir", f[1].prof); assert.are.equal(40, f[1].units)
    assert.are.equal("Ingénierie", f[2].prof); assert.are.equal(12, f[2].units)
    assert.are.same({ LIGHT_LEATHER, LIGHT_HIDE }, { f[1].items[1].item, f[1].items[2].item })   -- 26 before 14
    assert.is_nil(syn.feeds[186])                                                                 -- Mining's own ore: not a feed
    assert.are.equal("Sert pour Travail du cuir (40) et Ingénierie (12)", SY.FeedsText(f, S))
    assert.are.equal("Sert pour Travail du cuir : 26 × Cuir léger, 14 × Peau légère", SY.FeedsText({ f[1] }, S))
  end)

  it("nothing needs the profession: no feeds line", function()
    local syn = SY.Build({ profs[3] }, SKILLS, fixture())
    assert.are.same({}, syn.feeds)
    assert.is_nil(SY.FeedsText(syn.feeds[393], S))
  end)

  it("an error inside the hints is reported once through data.log and answers nil", function()
    local data = fixture()
    local seen = {}
    data.log = function(text) seen[#seen + 1] = text end
    data.counts = function() error("counts down") end
    local syn = SY.Build({}, SKILLS, data)
    assert.is_nil(syn.hint(PEACEBLOOM, 20))
    assert.matches("counts down", seen[1])
  end)
end)

describe("Synergy texts", function()
  local names = { zone = function(z) return "Zone" .. z end, item = function(i) return "Item" .. i end }
  local function hint(extra)
    local h = { kind = "skin", zone = BARRENS, count = 35, hours = 0.58, rare = false, here = true, ah = false }
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
  end

  it("writes the lines of the mockup", function()
    assert.are.equal("ton Dépeçage : ~35 bêtes, Zone1413 (ta zone)", SY.Line(hint(), S, names))
    assert.are.equal("ton Dépeçage : ~35 bêtes, Zone1413", SY.Line(hint({ here = false }), S, names))
    assert.are.equal("ton Herboristerie : ~10 plantes, Zone1413", SY.Line(hint({ kind = "herb", count = 10, here = false }), S, names))
    assert.are.equal("ta Fonte : 12 × Item2770, ~6 filons, Zone1411", SY.Line(hint({ kind = "bar", count = 6, zone = DUROTAR, here = false, ore = { item = COPPER_ORE, n = 12 } }), S, names))
    assert.are.equal("ton Minage : ~6 filons, Zone1411", SY.Line(hint({ kind = "ore", count = 6, zone = DUROTAR, here = false }), S, names))
  end)

  it("says 'rare' with the hours, and 'plutôt à l'HV' only when an auction price is known", function()
    local rare = hint({ rare = true, count = 400, hours = 6.7 })
    assert.are.equal("rare au dépeçage (~400 bêtes, ~7 h)", SY.Line(rare, S, names))
    rare.ah = true
    assert.are.equal("rare au dépeçage (~400 bêtes, ~7 h) · plutôt à l'HV", SY.Line(rare, S, names))
  end)

  it("short forms of the shopping list and the farm note", function()
    assert.are.equal("ton Dépeçage · Zone1413 · ~35 bêtes", SY.Short(hint(), S, names))
    assert.are.equal("rare au dépeçage (~7 h)", SY.Short(hint({ rare = true, hours = 6.7 }), S, names))
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~35 min)", SY.FarmText({ zone = BARRENS, prof = "Skinning", hours = 0.58, units = 26 }, S, names))
  end)

  it("is singular for one beast, plant or vein (and plural otherwise)", function()
    assert.are.equal("ton Dépeçage : ~1 bête, Zone1413", SY.Line(hint({ count = 1, here = false }), S, names))
    assert.are.equal("ton Herboristerie : ~1 plante, Zone1413", SY.Line(hint({ kind = "herb", count = 1, here = false }), S, names))
    assert.are.equal("ton Minage : ~1 filon, Zone1413", SY.Line(hint({ kind = "ore", count = 1, here = false }), S, names))
    assert.are.equal("ta Fonte : 2 × Item2770, ~1 filon, Zone1413", SY.Line(hint({ kind = "bar", count = 1, here = false, ore = { item = COPPER_ORE, n = 2 } }), S, names))
    assert.are.equal("rare au dépeçage (~1 bête, ~7 h)", SY.Line(hint({ rare = true, count = 1, hours = 6.7 }), S, names))
    assert.are.equal("ton Dépeçage · Zone1413 · ~1 bête", SY.Short(hint({ count = 1 }), S, names))
    assert.are.equal("ton Dépeçage · Zone1413 · ~2 bêtes", SY.Short(hint({ count = 2 }), S, names))
    assert.are.equal("ton Dépeçage · Zone1413 · ~0 bêtes", SY.Short(hint({ count = 0 }), S, names))
  end)

  it("shows minutes under an hour and rounded hours above, on the rare lines and the farm note", function()
    local function farm(hours) return SY.FarmText({ zone = BARRENS, prof = "Skinning", hours = hours, units = 1 }, S, names) end
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~5 min)", farm(5 / 60))
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~1 min)", farm(0.001))
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~59 min)", farm(59 / 60))
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~1 h)", farm(0.999))       -- never "~60 min"
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~1 h)", farm(1.4))
    assert.are.equal("À farmer d'abord : Zone1413 (Dépeçage, ~2 h)", farm(1.6))
    assert.are.equal("rare au dépeçage (~2 h)", SY.Short(hint({ rare = true, hours = 2.2 }), S, names))
    assert.are.equal("rare au dépeçage (~3 h)", SY.Short(hint({ rare = true, hours = 2.6 }), S, names))
    assert.are.equal("rare au dépeçage (~400 bêtes, ~2 h)", SY.Line(hint({ rare = true, count = 400, hours = 2.1 }), S, names))
  end)

  it("the 2 h 'rare' threshold is on the raw hours: 2.4 h is rare, 1.9 h is not, whatever the text says", function()
    local data = fixture()                                   -- Barrens: 60 actions an hour, 0.035 Light Hide each
    local rare = SY.Hint(LIGHT_HIDE, 1, SKILLS, data)        -- ceil(1 / 0.035) = 29 beasts, under 1 hour: not rare
    assert.is_false(rare.rare)
    assert.is_false(SY.Hint(LIGHT_HIDE, 4, SKILLS, data).rare)   -- ceil(4 / 0.035) = 115 beasts = 1.9 hours
    local h = SY.Hint(LIGHT_HIDE, 5, SKILLS, data)           -- ceil(5 / 0.035) = 143 beasts = 2.4 hours
    assert.is_true(h.hours > 2 and h.hours < 2.5)
    assert.is_true(h.rare)
    assert.are.equal("rare au dépeçage (~2 h)", SY.Short(h, S, names))
  end)

  it("every new string stays in the Latin-1 font: no check mark, arrow or ellipsis", function()
    local function check(key, v)
      if type(v) == "table" then for k, x in pairs(v) do check(key .. "." .. k, x) end return end
      for _, c in utf8.codes(v) do assert.is_true(c <= 0xFF, key .. " has U+" .. ("%04X"):format(c)) end
    end
    local n = 0
    for k, v in pairs(S) do
      if k:match("^syn_") or k == "shop_farm" then check(k, v); n = n + 1 end
    end
    assert.is_true(n >= 8)
  end)
end)

describe("Shopping.Build with hints", function()
  local function profs(...)
    local missing = {}
    for i, m in ipairs({ ... }) do missing[i] = { item = m[1], n = m[2], tip = nil } end
    return { { name = "Travail du cuir", road = { steps = { { kind = "craft", missing = missing, used = {}, banked = {} } } } } }
  end
  local function env(extra)
    local e = { bag = function() return 0 end, bank = function() return 0 end, name = function(id) return "N" .. id end }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
  end
  local function order(list) local t = {} for i, r in ipairs(list.rows) do t[i] = r.item end return t end
  local P = profs({ 1, 50 }, { 2, 30 }, { 3, 20 }, { 4, 10 }, { 5, 5 })

  it("without a hint the order is today's: the most missing first, then the name", function()
    local plain = ns.Shopping.Build(P, env())
    assert.are.same({ 1, 2, 3, 4, 5 }, order(plain))
    assert.is_nil(plain.farm)
    local none = ns.Shopping.Build(P, env({ hint = function() return nil end, vendor = function() return true end }))
    assert.are.same(order(plain), order(none))                       -- a hint function that finds nothing changes nothing
    assert.is_nil(none.farm)
  end)

  it("own gathering in the roadmap's zone, then elsewhere (fewest hours), then the merchant, then the rest, whatever the counts", function()
    local hints = {
      [5] = { zone = BARRENS, prof = "Skinning", hours = 0.5, rare = false, here = true },
      [4] = { zone = DUROTAR, prof = "Skinning", hours = 1.5, rare = false, here = false },
      [3] = { zone = DUROTAR, prof = "Skinning", hours = 0.5, rare = false, here = false },
      [2] = { zone = BARRENS, prof = "Skinning", hours = 9, rare = true, here = true },   -- rare: counts as the rest
    }
    local list = ns.Shopping.Build(P, env({ hint = function(id) return hints[id] end, vendor = function(id) return id == 1 end }))
    assert.are.same({ 5, 3, 4, 1, 2 }, order(list))
    assert.are.equal(hints[5], list.rows[1].hint)
    -- the farm note: Barrens covers 5 units, Durotar 30 (20 + 10)
    assert.are.equal(DUROTAR, list.farm.zone)
    assert.are.equal("Skinning", list.farm.prof)
    assert.are.equal(30, list.farm.units)
    assert.are.equal(1.5, list.farm.hours)
  end)

  it("a hint is looked up with what is still short, and never for a complete row", function()
    local asked = {}
    local list = ns.Shopping.Build(P, env({ bag = function(id) return id == 5 and 5 or 4 end, hint = function(id, n) asked[id] = n end }))
    assert.are.same({ [1] = 46, [2] = 26, [3] = 16, [4] = 6 }, asked)
    assert.are.equal(4, list.missing)
  end)
end)
