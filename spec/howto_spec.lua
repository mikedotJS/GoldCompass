-- HowTo.lua: the hover tooltips of the roadmap ("comment l'obtenir"). Pure module: the game and the vendored data are given by the test.
-- string.format is strict here (spec/helper_wow_lua51.lua): a nil that reaches a "%s" raises, as in the game.
local function fresh()
  local ns = {}
  assert(loadfile("Strings.lua"))("GoldCompass", ns)
  assert(loadfile("HowTo.lua"))("GoldCompass", ns)
  ns.Fmt = { Source = function() return "butin" end, VendorPrice = function() return "240 Faveur du marchand" end }
  return ns
end

-- a small world: Kalimdor (K = 1) and the Eastern Kingdoms (E = 0); every map has its own origin, 100 units wide
local CONT = { [1411] = 1, [1412] = 1, [1413] = 1, [1414] = 1, [1430] = 1, [1438] = 1, [1429] = 0, [1433] = 0, [1434] = 0, [1436] = 0 }
local ORIGIN = { [1411] = 200, [1413] = 100, [1412] = 100, [1414] = 0, [1430] = 400, [1438] = -500, [1429] = 300, [1433] = 400, [1434] = 300, [1436] = 100 }
local function world(map, x, y) if CONT[map] then return CONT[map], (ORIGIN[map] or 0) + x, y end end

-- the game as the module sees it: Horde of level 60 standing in Durotar (1411) at x = 50
local function envOf(over)
  local env = {
    faction = "H", mapID = 1411, fr = false, level = 60,
    place = world, here = { 1, 250, 50 },
    itemName = function(id) return "Objet" .. id end, owned = function() return 2 end,
    price = function() return nil end,
    money = function(c) return tostring(c) .. "c" end, zone = function(m) return "Zone" .. m end,
    npcName = function(_, en) return en end, creature = function(en) return en, nil end,
    nodeCounts = function() return {} end, npc = function() return nil end,
  }
  for k, v in pairs(over or {}) do env[k] = v end
  return env
end

local function texts(tip)
  local out = {}
  for _, l in ipairs(tip.lines) do out[#out + 1] = l.text .. (l.right and ("  |  " .. l.right) or "") end
  return table.concat(out, "\n")
end
local function lineIndex(tip, pattern)
  for i, l in ipairs(tip.lines) do if (l.text .. (l.right or "")):find(pattern) then return i end end
end
local function plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

describe("HowTo.Reagent: header", function()
  it("title is the item name, then 'Il t'en manque N · tu en as M'", function()
    local ns = fresh()
    local tip = ns.HowTo.Reagent(783, 6, envOf())
    assert.are.equal("Objet783", tip.title)
    assert.is_false(tip.loading)
    assert.are.equal("Il t'en manque 6 · tu en as 2", plain(tip.lines[1].text))
  end)

  it("an item the game has not cached says 'chargement...' and names the item to wait for", function()
    local ns = fresh()
    local tip = ns.HowTo.Reagent(783, 6, envOf({ itemName = function() return nil end }))
    assert.are.equal("chargement...", tip.title)
    assert.is_true(tip.loading)
    assert.are.equal(783, tip.item)
    local loaded = ns.HowTo.Reagent(783, 6, envOf())
    assert.is_false(loaded.loading)                           -- the same call once the item is cached
  end)
end)

describe("HowTo.Reagent: vendors", function()
  local function setup(vendors)
    local ns = fresh()
    ns.ReagentSources = { [2320] = { vendors = vendors } }
    return ns
  end
  -- { npcID, name, mapID, x, y, side, price, forever = }
  local V = {
    { 1, "Far Forever", 1414, 10, 10, "AH", 10, forever = true },
    { 2, "Near Forever", 1413, 52, 10, "AH", 10, forever = true },
    { 3, "Near Classic", 1411, 50, 10, "H", 10, forever = false },
    { 4, "Alliance Only", 1411, 50, 10, "A", 10, forever = true },
    { 5, "Mid Forever", 1412, 30, 10, "H", 10, forever = true },
    { 6, "Fourth Forever", 1430, 90, 10, "H", 10, forever = true },
  }

  it("header with the unit price, then at most 3 vendors with name, zone and x,y", function()
    local ns = setup(V)
    local tip = ns.HowTo.Reagent(2320, 12, envOf())
    local text = texts(tip)
    assert.matches("Chez un marchand · 10c l'unité", text)
    local n = 0
    for _, l in ipairs(tip.lines) do if l.style == "row" and l.text:find("Forever") then n = n + 1 end end
    assert.are.equal(3, n)
    assert.matches("Near Forever  |  52.0, 10.0", text)
    assert.matches("Zone1413", text)
  end)

  it("only vendors of the player's faction or neutral", function()
    local ns = setup(V)
    local horde = texts(ns.HowTo.Reagent(2320, 1, envOf({ faction = "H" })))
    assert.is_nil(horde:find("Alliance Only", 1, true))
    local alliance = texts(ns.HowTo.Reagent(2320, 1, envOf({ faction = "A", mapID = 1411 })))
    assert.matches("Alliance Only", alliance)
    assert.is_nil(alliance:find("Near Classic", 1, true))        -- a Horde vendor
  end)

  it("Forever-seen first, then the nearest: a nearer Classic vendor never beats a Forever-seen one", function()
    local ns = setup(V)
    local tip = ns.HowTo.Reagent(2320, 1, envOf())
    local first, second, third, classic = lineIndex(tip, "Near Forever"), lineIndex(tip, "Mid Forever"), lineIndex(tip, "Far Forever"), lineIndex(tip, "Near Classic")
    assert.is_true(first < second and second < third)
    assert.is_nil(classic)                                        -- 4 Forever-seen vendors fit the Horde: the Classic one is cut at 3
    assert.are.equal("Near Forever", tip.target.name)             -- the pin goes to the first
    assert.is_true(tip.target.confirmed)
  end)

  it("same map first when distances are unknown", function()
    local ns = setup({ { 1, "Elsewhere", 1414, 10, 10, "AH", 10, forever = true }, { 2, "Here", 1411, 90, 10, "AH", 10, forever = true } })
    local tip = ns.HowTo.Reagent(2320, 1, envOf({ here = false }))
    assert.is_true(lineIndex(tip, "Here") < lineIndex(tip, "Elsewhere"))
  end)

  it("a vendor that is not Forever-seen ends with a dim '(Classic)'; a Forever-seen one carries no label", function()
    local ns = setup({ { 1, "Seen", 1411, 50, 10, "AH", 10, forever = true }, { 2, "Guess", 1411, 60, 10, "AH", 10, forever = false } })
    local tip = ns.HowTo.Reagent(2320, 1, envOf())
    local seenAt, guessAt = lineIndex(tip, "Seen"), lineIndex(tip, "Guess")
    local function block(i) return tip.lines[i].text .. (tip.lines[i].right or "") .. (tip.lines[i + 1].text or "") .. (tip.lines[i + 1].right or "") end
    assert.is_nil(block(seenAt):find("Classic", 1, true))
    assert.matches("%(Classic%)$", plain(tip.lines[guessAt + 1].text .. (tip.lines[guessAt + 1].right or "")))
    assert.matches("cff9d9d9d", tip.lines[guessAt + 1].text)    -- dim
  end)

  it("the last line is green and names the vendor", function()
    local ns = setup(V)
    local tip = ns.HowTo.Reagent(2320, 1, envOf())
    local last = tip.lines[#tip.lines]
    assert.are.equal("click", last.style)
    assert.are.equal("Clic : repère sur le marchand le plus proche", last.text)
  end)

  it("a vendor of unknown place (map 0) is listed without coordinates and never pinned", function()
    local ns = setup({ { 0, "Somewhere", 0, 0, 0, "AH", 10 } })
    local tip = ns.HowTo.Reagent(2320, 1, envOf())
    assert.matches("Somewhere", texts(tip))
    assert.is_nil(tip.target)
    assert.is_nil(texts(tip):find("Clic", 1, true))
  end)
end)

describe("HowTo.Reagent: skinning", function()
  local function setup()
    local ns = fresh()
    ns.Skinning = { [783] = {
      { 10, "Far Beast", 20, 22, forever = true }, { 11, "Near Beast", 11, 13, forever = true },
      { 12, "Classic Beast", 14, 15, forever = false }, { 13, "Fourth", 30, 31, forever = true } } }
    ns.SkinSpots = {
      [10] = { { 1411, 5, 5, forever = true } },
      [11] = { { 1411, 90, 5, forever = false }, { 1411, 55, 5, forever = true } },   -- its best spot: the Forever-seen one, not the nearer Classic one
      [12] = { { 1411, 50, 5, forever = false } },
      [13] = { { 1411, 80, 5, forever = true } } }
    return ns
  end

  it("header gives the level range of the beasts shown; up to 3 beasts with level, zone and x,y of the best spot", function()
    local tip = setup().HowTo.Reagent(783, 6, envOf())
    local text = texts(tip)
    assert.matches("Dépeçage · bêtes de niveau 11 à 31", text)    -- the 3 shown: Near, Far then Fourth (Forever-seen first)
    assert.matches("Near Beast  |  niv. 11%-13", text)
    assert.matches("Zone1411  |  55.0, 5.0", text)
    assert.is_nil(text:find("Classic Beast", 1, true))
  end)

  it("Forever-seen beasts first, nearest first among them; the pin is the nearest spot", function()
    local tip = setup().HowTo.Reagent(783, 6, envOf())
    assert.is_true(lineIndex(tip, "Near Beast") < lineIndex(tip, "Fourth") and lineIndex(tip, "Fourth") < lineIndex(tip, "Far Beast"))
    assert.are.equal("Near Beast", tip.target.name)
    assert.are.equal(55, tip.target.x)
    assert.are.equal("Clic : repère sur le spot le plus proche", tip.lines[#tip.lines].text)
  end)

  it("a Classic beast and a Classic spot carry the '(Classic)' label, a Forever-seen beast with a Forever-seen spot none", function()
    local ns = setup()
    ns.Skinning[783] = { { 12, "Classic Beast", 14, 15, forever = false }, { 11, "Near Beast", 11, 13, forever = true }, { 14, "Seen Beast", 1, 2, forever = true } }
    ns.SkinSpots[14] = { { 1411, 40, 5, forever = false } }
    local tip = ns.HowTo.Reagent(783, 6, envOf())
    local function around(name) local i = lineIndex(tip, name); return plain(tip.lines[i].text .. (tip.lines[i].right or "") .. tip.lines[i + 1].text .. (tip.lines[i + 1].right or "")) end
    assert.is_nil(around("Near Beast"):find("Classic", 1, true))
    assert.matches("Classic Beast.*%(Classic%).*%(Classic%)", around("Classic Beast"):gsub("\n", ""))   -- the beast and its spot
    assert.is_nil(around("Seen Beast"):match("Seen Beast.*niv. 1%-2%(Classic%)"))            -- the beast is Forever-seen: no label on its name line
    assert.matches("%(Classic%)$", around("Seen Beast"))                                      -- its spot is Classic: the label ends the position line
  end)

  it("a beast with no spot at all is listed without position", function()
    local ns = fresh()
    ns.Skinning = { [783] = { { 10, "Lonely", 3, 3, forever = true } } }
    local tip = ns.HowTo.Reagent(783, 1, envOf())
    assert.matches("Dépeçage · bêtes de niveau 3", texts(tip))
    assert.matches("Lonely  |  niv. 3", texts(tip))
    assert.is_nil(tip.target)
  end)
end)

describe("HowTo.Reagent: herbalism and mining", function()
  local function setup()
    local ns = fresh()
    ns.GatherNodes = { [401] = { type = "Herb Gathering", item = 2447, skill = 1 }, [201] = { type = "Mining", item = 2770, skill = 1 } }
    ns.GatherSources = {
      [2447] = { nodes = { { "Peacebloom", 1, forever = true } },
        zones = { { 1413, 38, 85, best = { 45.1, 56.3 } }, { 1411, 14, 57, best = { 41.8, 81.4 } }, { 1412, 0, 40, best = { 10, 10 } }, { 1438, 0, 0, best = { 1, 1 } }, { 1439, 5, 1, best = { 2, 2 } } } },
      [2770] = { nodes = { { "Copper Vein", 1, forever = true } }, zones = { { 1429, 22, 110, best = { 40.6, 79.9 } } } } }
    return ns
  end

  it("'Herboristerie', the node and its skill, then the player's own zones before the Forever ones", function()
    local ns = setup()
    local tip = ns.HowTo.Reagent(2447, 5, envOf({ nodeCounts = function() return { [1412] = { [401] = 7 }, [1411] = { [401] = 100, [999] = 50 } } end }))
    local text = texts(tip)
    assert.matches("Herboristerie", text)
    assert.matches("Objet2447 · compétence 1", text)
    assert.is_true(lineIndex(tip, "Zone1411") < lineIndex(tip, "Zone1412") and lineIndex(tip, "Zone1412") < lineIndex(tip, "Zone1413"))
    assert.matches("Zone1411  |  100 points repérés", text)       -- only the nodes of this herb are counted
    assert.matches("Zone1412  |  7 points repérés", text)
    assert.matches("Zone1413  |  38 points vus sur Forever", text)
    assert.is_nil(text:find("Zone1439", 1, true))                  -- at most 3 zones
    assert.are.equal("Clic : repère sur la zone la plus riche", tip.lines[#tip.lines].text)
    assert.are.equal(1411, tip.target.mapID)
    assert.are.equal(41.8, tip.target.x)                           -- own zone that Forever also knows: its best spot
  end)

  it("without own spots: Forever zones by Forever points; a zone seen only in Classic ends with '(Classic)'", function()
    local ns = setup()
    ns.GatherSources[2447].zones = { { 1413, 38, 85, best = { 45, 56 } }, { 1412, 0, 40, best = { 10, 10 } }, { 1411, 3, 5, best = { 1, 1 } } }
    local tip = ns.HowTo.Reagent(2447, 5, envOf())
    local text = texts(tip)
    assert.is_true(lineIndex(tip, "Zone1413") < lineIndex(tip, "Zone1411") and lineIndex(tip, "Zone1411") < lineIndex(tip, "Zone1412"))
    assert.matches("Zone1412  |  40 points", plain(text))
    assert.matches("%(Classic%)$", plain(tip.lines[lineIndex(tip, "Zone1412")].right))
    assert.is_nil(plain(tip.lines[lineIndex(tip, "Zone1413")].right):find("Classic", 1, true))
    assert.are.equal(1413, tip.target.mapID)
    assert.is_true(tip.target.confirmed)
  end)

  it("'Minage' for an ore, and a zone with no best spot is pinned as a zone", function()
    local ns = setup()
    ns.GatherSources[2770].zones = { { 1429, 22, 110 } }
    local tip = ns.HowTo.Reagent(2770, 5, envOf())
    assert.matches("Minage", texts(tip))
    assert.matches("Copper Vein · compétence 1", texts(tip))      -- an ore: the node's own name
    assert.are.equal("zone", tip.target.kind)
  end)
end)

describe("HowTo.Reagent: drops, auction house, craft, nothing", function()
  it("'Butin': up to 3 sources with the chance, a Classic one labelled, the zone when known", function()
    local ns = fresh()
    ns.ReagentSources = { [731] = { drops = { { "Boar A", 50, true, 33 }, { "Boar B", 0, false, 44 }, { "Boar C", 0, true }, { "Boar D", 0, false, 10 } } } }
    local tip = ns.HowTo.Reagent(731, 2, envOf({ creature = function(en) return en, en == "Boar A" and 1411 or nil end }))
    local text = plain(texts(tip))
    assert.matches("Butin", text)
    assert.matches("Boar A · Zone1411  |  33 %%", text)
    assert.matches("Boar C", text)
    assert.is_nil(text:find("Boar D", 1, true))                    -- 3 at most, Forever-seen ones first
    assert.matches("Boar B  |  44 %% %(Classic%)", text)
  end)

  it("'Ou à l'hôtel des ventes': the unit price and the age of the scan", function()
    local ns = fresh()
    local function ah(age) return ns.HowTo.Reagent(5, 1, envOf({ price = function() return 1234, age end })) end
    assert.matches("Ou à l'hôtel des ventes", texts(ah(2 / 24)))
    assert.matches("~1234c l'unité  |  scan il y a 2 h", texts(ah(2 / 24)))
    assert.matches("scan il y a moins d'1 h", texts(ah(0.01)))
    assert.matches("scan il y a 3 j", texts(ah(3)))
    assert.matches("scan sans date", texts(ah(nil)))
  end)

  it("'Fabrique-le : recette (ingrédients)' when the character can craft it", function()
    local ns = fresh()
    local tip = ns.HowTo.Reagent(4231, 3, envOf(), { name = "Cuir léger traité", mats = { { 783, 1 }, { 4289, 2 } } })
    assert.matches("Fabrique%-le : Cuir léger traité %(1 × Objet783, 2 × Objet4289%)", texts(tip))
    assert.is_nil(texts(tip):find("Source inconnue", 1, true))
  end)

  it("'Source inconnue' when nothing is known, and no green line", function()
    local tip = fresh().HowTo.Reagent(4231, 3, envOf())
    assert.matches("Source inconnue", texts(tip))
    assert.is_nil(tip.target)
    assert.are.not_equal("click", tip.lines[#tip.lines].style)
  end)

  it("sections come in order: vendors, skinning, herbs / ore, drops, auction house, craft", function()
    local ns = fresh()
    ns.ReagentSources = { [9] = { vendors = { { 1, "V", 1411, 50, 5, "AH", 5, forever = true } }, drops = { { "D", 0, true } } } }
    ns.Skinning = { [9] = { { 2, "B", 1, 2, forever = true } } }
    ns.GatherNodes = { [1] = { type = "Mining", item = 9, skill = 1 } }
    ns.GatherSources = { [9] = { nodes = { { "Vein", 1, forever = true } }, zones = { { 1411, 3, 0, best = { 1, 1 } } } } }
    local tip = ns.HowTo.Reagent(9, 1, envOf({ price = function() return 100, 1 end }), { name = "R", mats = {} })
    local at = { lineIndex(tip, "Chez un marchand"), lineIndex(tip, "Dépeçage"), lineIndex(tip, "Minage"), lineIndex(tip, "Butin"),
      lineIndex(tip, "hôtel des ventes"), lineIndex(tip, "Fabrique") }
    assert.are.equal(6, #at)
    for i = 2, 6 do assert.is_true(at[i - 1] < at[i], i) end
    assert.are.equal("vendor", tip.clickKey)                      -- the click pins the first section that has a place
  end)
end)

describe("HowTo: no nil reaches string.format", function()
  it("sparse data in every section raises nothing", function()
    local ns = fresh()
    ns.ReagentSources = { [1] = { vendors = { { 0, "No place", 0, 0, 0 } }, drops = { { "Drop" } }, quest = { "Q" } } }
    ns.Skinning = { [1] = { { 5, "Beast", 1, 1 } } }
    ns.GatherNodes = { [1] = { type = "Herb Gathering", item = 1 } }
    ns.GatherSources = { [1] = { nodes = { { "Weed" } }, zones = { { 1411 } } } }
    local env = envOf({ itemName = function() return nil end, owned = function() return nil end, price = function() return 5 end, zone = function() return nil end,
      place = function() return nil end })
    local ok, err = pcall(ns.HowTo.Reagent, 1, nil, env, { name = "R", mats = { { 9, 1 } } })
    assert.is_true(ok, err)
    for _, kind in ipairs({ {}, { vendors = {} }, { nothing = true } }) do
      ns.ReagentSources = { [1] = kind }
      ns.Skinning, ns.GatherSources = {}, {}
      assert.is_true((pcall(ns.HowTo.Reagent, 1, 1, env)))
    end
  end)

  it("a step with no target, no price and no skill raises nothing", function()
    local ns = fresh()
    local tip = ns.HowTo.Step({ title = "Recette", kind = "other", head = "butin" }, envOf())
    assert.are.equal("Recette", tip.title)
    assert.is_nil(tip.target)
    assert.is_true((pcall(ns.HowTo.Step, { title = "R", kind = "trainer", target = { kind = "text", text = "lieu" } }, envOf())))
    assert.is_true((pcall(ns.HowTo.Step, { title = "R", kind = "vendor", target = { mapID = 1411 }, skill = 5 }, envOf({ zone = function() return nil end }))))
  end)
end)

describe("HowTo.Step: learn and rank steps", function()
  local TRAINER = { name = "Hahrana Ironhide", fr = "Hahrana Peau-de-fer", zone = "Durotar", mapID = 1411, x = 74.4, y = 43.1, kind = "pin", confirmed = true }

  it("trainer: name, zone and x,y, price, requirements, 'position confirmée sur Forever' then the green line", function()
    local ns = fresh()
    local spec = ns.HowTo.LearnSpec({ learn = 125, fee = 5000, way = { kind = "trainer" } }, "Petite giberne en cuir", TRAINER, "Travail du cuir")
    local tip = ns.HowTo.Step(spec, envOf())
    local text = texts(tip)
    assert.are.equal("Petite giberne en cuir", tip.title)
    assert.matches("Entraîneur · Hahrana Ironhide", text)
    assert.matches("Zone1411  |  74.4, 43.1", text)
    assert.matches("Prix  |  5000c", text)
    assert.matches("Requiert  |  Travail du cuir 125", text)
    assert.are.equal("position confirmée sur Forever", tip.lines[#tip.lines - 1].text)
    assert.are.equal("Clic : repère sur l'entraîneur", tip.lines[#tip.lines].text)
    assert.are.equal(TRAINER, tip.target)
    assert.matches("Hahrana Peau%-de%-fer", texts(ns.HowTo.Step(spec, envOf({ fr = true }))))   -- the client's language
  end)

  it("a Classic position says so, dim", function()
    local ns = fresh()
    local classic = { name = "Old", mapID = 1411, x = 1, y = 2, kind = "pin", confirmed = false }
    local tip = ns.HowTo.Step(ns.HowTo.LearnSpec({ learn = 1, way = { kind = "trainer" } }, "R", classic, "P"), envOf())
    assert.are.equal("position Classic", tip.lines[#tip.lines - 1].text)
    assert.are.equal("dim", tip.lines[#tip.lines - 1].style)
  end)

  it("a vendor recipe shows the vendor, its price and the reputation it asks", function()
    local ns = fresh()
    local v = { name = "Kilxx", mapID = 1413, x = 62.7, y = 38.2, kind = "pin", confirmed = true }
    local tip = ns.HowTo.Step(ns.HowTo.LearnSpec({ learn = 100, way = { kind = "vendor", vendorCost = 1200, standing = "Honored" } }, "Recette", v, "Cuisine"), envOf())
    local text = texts(tip)
    assert.matches("Marchand · Kilxx", text)
    assert.matches("Prix  |  240 Faveur du marchand", text)       -- ns.Fmt.VendorPrice words a vendor price
    assert.matches("Réputation  |  Honoré", text)
    assert.are.equal("Clic : repère sur le marchand", tip.lines[#tip.lines].text)
  end)

  it("a rank: requirements from the Forever rank table (skill and character level)", function()
    local ns = fresh()
    ns.Ranks = { [165] = { { "Apprentice", 1, 5, 75, way = { kind = "trainer", ids = {} } }, { "Expert", 125, 20, 225, way = { kind = "trainer", ids = {} } } } }
    local tip = ns.HowTo.Step(ns.HowTo.RankSpec(165, "Expert", envOf(), TRAINER, "Travail du cuir"), envOf())
    assert.are.equal("Rang Expert", tip.title)
    assert.matches("Requiert  |  Travail du cuir 125", texts(tip))
    assert.matches("Niveau requis  |  20", texts(tip))
    assert.are.equal(TRAINER, tip.target)
  end)

  it("a rank book: the vendor of the player's faction, the price, the pin", function()
    local ns = fresh()
    ns.Ranks = { [185] = { { "Expert", 125, 20, 225, way = { kind = "book", itemID = 16072, vendors = { { 100, 10000 }, { 200, 12000 }, { 300, 10000 } } } } } }
    local npcs = {
      [100] = { name = "Alliance Vendor", mapID = 1429, x = 40, y = 40, side = "A", seen = true },
      [200] = { name = "Horde Far", mapID = 1411, x = 90, y = 5, side = "H", seen = true },
      [300] = { name = "Horde Near", mapID = 1411, x = 52, y = 5, side = "H", seen = true } }
    local env = envOf({ npc = function(id) return npcs[id] end })
    local tip = ns.HowTo.Step(ns.HowTo.RankSpec(185, "Expert", env, TRAINER, "Cuisine"), env)
    local text = texts(tip)
    assert.matches("Marchand · Horde Near", text)
    assert.matches("Livre : Objet16072", text)
    assert.matches("Prix  |  10000c", text)
    assert.are.equal("Horde Near", tip.target.name)               -- the pin moves from the trainer to the book vendor
    local alliance = ns.HowTo.RankSpec(185, "Expert", envOf({ faction = "A", npc = env.npc }), TRAINER, "Cuisine")
    assert.are.equal("Alliance Vendor", alliance.who)
  end)

  it("a book no vendor of the faction sells keeps the trainer's pin", function()
    local ns = fresh()
    ns.Ranks = { [185] = { { "Expert", 125, 20, 225, way = { kind = "book", itemID = 1, vendors = { { 100, 1 } } } } } }
    local spec = ns.HowTo.RankSpec(185, "Expert", envOf({ npc = function() return { name = "A", mapID = 1, x = 1, y = 1, side = "A" } end }), TRAINER, "P")
    assert.are.equal(TRAINER, spec.target)
  end)

  it("a rank quest: the quest giver, with the quest's name", function()
    local ns = fresh()
    ns.Ranks = { [185] = { { "Artisan", 200, 35, 300, way = { kind = "quest", quest = "Clamlette Surprise", npc = 8125 } } } }
    local env = envOf({ npc = function() return { name = "Giver", mapID = 1411, x = 20, y = 30, side = "AH", seen = false } end })
    local tip = ns.HowTo.Step(ns.HowTo.RankSpec(185, "Artisan", env, nil, "Cuisine"), env)
    assert.matches("Quête · Giver", texts(tip))
    assert.matches("Clamlette Surprise", texts(tip))
    assert.matches("position Classic", texts(tip))
    assert.are.equal(20, tip.target.x)
  end)
end)

describe("HowTo: nearest means nearest in the world, continent first", function()
  -- the real vendored data, and the real continent of every map of Data/Zones.lua (K = Kalimdor, E = Eastern Kingdoms)
  local function real()
    local ns = fresh()
    for _, f in ipairs({ "Data/Zones", "Data/ForeverSkinning", "Data/ForeverReagentSources" }) do assert(loadfile(f .. ".lua"))("GoldCompass", ns) end
    local cont = { [1414] = 1, [1415] = 0 }
    for _, m in pairs(ns.MapIDs) do cont[m[1]] = m[2] == "K" and 1 or 0 end
    return ns, function(map, x, y) if cont[map] then return cont[map], x, y end end, cont
  end
  local function at(cont, map, faction, level, place)
    return envOf({ faction = faction, mapID = map, level = level, place = place, here = { cont[map], 50, 50 } })
  end

  it("a Durotar player gets the Barrens beasts first for Light Hide (Kalimdor before the Eastern Kingdoms)", function()
    local ns, place, cont = real()
    local tip = ns.HowTo.Reagent(783, 6, at(cont, 1411, "H", 16, place))
    for _, name in ipairs({ "Thunderhead", "Silithid Swarmer", "Zhevra Charger" }) do assert.matches(name, texts(tip)) end
    for _, name in ipairs({ "Black Dragon Whelp", "Young Goretusk", "Great Goretusk" }) do assert.is_nil(texts(tip):find(name, 1, true), name) end
    assert.are.equal(1413, tip.target.mapID)
  end)

  it("an Elwynn player gets Westfall and Redridge first", function()
    local ns, place, cont = real()
    local tip = ns.HowTo.Reagent(783, 6, at(cont, 1429, "A", 16, place))
    assert.are.equal(0, cont[tip.target.mapID])
    assert.is_true(tip.target.mapID == 1436 or tip.target.mapID == 1433)
    assert.is_nil(texts(tip):find("Zhevra Charger", 1, true))
  end)

  it("Forever-seen ranks ahead of Classic only on the player's continent: a Classic Barrens beast beats a Forever-seen Redridge one", function()
    local ns = fresh()
    ns.Skinning = { [783] = { { 1, "Redridge Forever", 10, 12, forever = true }, { 2, "Barrens Classic", 10, 12, forever = false } } }
    ns.SkinSpots = { [1] = { { 1433, 50, 50, forever = true } }, [2] = { { 1413, 50, 50, forever = true } } }
    local tip = ns.HowTo.Reagent(783, 1, envOf())
    assert.is_true(lineIndex(tip, "Barrens Classic") < lineIndex(tip, "Redridge Forever"))
    assert.are.equal("Barrens Classic", tip.target.name)
    local function around(name) local i = lineIndex(tip, name); return plain(tip.lines[i].text .. (tip.lines[i].right or "")) end
    assert.matches("%(Classic%)", around("Barrens Classic"))        -- the label stays
    -- on the same continent Forever-seen still wins
    ns.SkinSpots[1][1][1] = 1412
    tip = ns.HowTo.Reagent(783, 1, envOf())
    assert.is_true(lineIndex(tip, "Redridge Forever") < lineIndex(tip, "Barrens Classic"))
  end)

  it("a beast above the player's level + 5 goes last on the same continent, whatever its label", function()
    local ns = fresh()
    ns.Skinning = { [783] = { { 1, "Too Strong", 40, 41, forever = true }, { 2, "Right Level", 10, 12, forever = false }, { 3, "Slightly High", 17, 18, forever = true } } }
    ns.SkinSpots = { [1] = { { 1411, 50, 50, forever = true } }, [2] = { { 1411, 90, 50, forever = true } }, [3] = { { 1411, 60, 50, forever = true } } }
    local tip = ns.HowTo.Reagent(783, 1, envOf({ level = 12 }))
    assert.is_true(lineIndex(tip, "Slightly High") < lineIndex(tip, "Right Level"))   -- 17 <= 12 + 5: fine, Forever-seen first
    assert.is_true(lineIndex(tip, "Right Level") < lineIndex(tip, "Too Strong"))
  end)

  it("Coarse Thread: vendors nearest first, by faction, on the player's continent", function()
    local ns, place, cont = real()
    local horde = ns.HowTo.Reagent(2320, 12, at(cont, 1411, "H", 16, place))
    assert.are.equal(1, cont[horde.target.mapID])
    assert.is_nil(texts(horde):find("Tharynn Bouden", 1, true))                     -- an Alliance vendor
    local alliance = ns.HowTo.Reagent(2320, 12, at(cont, 1429, "A", 16, place))
    assert.are.equal(0, cont[alliance.target.mapID])
    local first = alliance.lines[lineIndex(alliance, "Chez un marchand") + 1].text
    assert.are.equal(alliance.target.name, first)
    -- nearest in the world: two Forever-seen vendors of the same continent, the closer one first
    ns.ReagentSources = { [2320] = { vendors = { { 1, "Far", 1411, 90, 50, "AH", 10, forever = true }, { 2, "Close", 1411, 55, 50, "AH", 10, forever = true } } } }
    local tip = ns.HowTo.Reagent(2320, 1, at(cont, 1411, "H", 16, place))
    assert.is_true(lineIndex(tip, "Close") < lineIndex(tip, "Far"))
  end)

  it("without the player's position (instance, API missing) the old order is kept", function()
    local ns = fresh()
    ns.ReagentSources = { [2320] = { vendors = { { 1, "Classic far", 1429, 50, 50, "AH", 10, forever = false }, { 2, "Forever far", 1433, 50, 50, "AH", 10, forever = true } } } }
    local tip = ns.HowTo.Reagent(2320, 1, envOf({ here = false, place = false }))
    assert.is_true(lineIndex(tip, "Forever far") < lineIndex(tip, "Classic far"))
  end)
end)

describe("HowTo.Reagent: distance beats the Forever flag", function()
  it("a Classic vendor in town comes before a Forever-seen vendor more than 500 yards farther (Moonglade case)", function()
    local ns = fresh()
    ns.ReagentSources = { [2320] = { vendors = {
      { 1, "Moonglade Forever", 1414, 10, 10, "AH", 10, forever = true },
      { 2, "Town Classic", 1411, 52, 50, "H", 10, forever = false } } } }
    local env = envOf({ place = function(map, x, y) if map == 1411 then return 1, 200 + x, y end return 1, 2000 + x, y end })
    local tip = ns.HowTo.Reagent(2320, 1, env)
    assert.is_true(lineIndex(tip, "Town Classic") < lineIndex(tip, "Moonglade Forever"))
    assert.are.equal("Town Classic", tip.target.name)
  end)
end)
