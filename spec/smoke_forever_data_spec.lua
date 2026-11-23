-- Smoke: Forever client data (ForeverFixes, vendor and quest facts, Cooking 124).
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

-- The Forever client's own recipe values (Data/ForeverFixes.lua, ForeverDB.net) correct the other sources where they differ.
describe("recipes follow the Forever client data where the other sources differ (ForeverFixes)", function()
  local function crafts(line, fixes)
    setup({ scanned = true, faction = "Horde", profs = {} })
    local ns = loadAddon()
    local by = {}
    for _, c in ipairs(ns.Leveling.LibCrafts(ns.ForeverDB, line, "H", nil, ns.ForeverTrainers, nil, fixes and ns.ForeverFixes or nil)) do by[c.id] = c end
    return by, ns
  end

  it("the skill a pattern asks, the colour thresholds and the crafted quantity are the client's", function()
    local before, ns = crafts(164, false)
    local after = crafts(164, true)
    assert.are.equal(265, before[16646].learn); assert.are.equal(240, after[16646].learn)       -- Imperial Plate Shoulders
    assert.are.equal(240, ns.ForeverFixes.learn[16646])
    local eng = crafts(202, true)
    assert.are.equal(2, eng[8339].oq)                                                            -- EZ-Thro Dynamite: 1 to 3, 2 on average
    assert.are.same({ 185, 205, 225 }, { eng[8243].y, eng[8243].g, eng[8243].gr })               -- Flash Bomb: yellow as soon as learned
    for id, th in pairs(ns.ForeverFixes.th) do assert.is_true(th[1] <= th[2] and th[2] <= th[3], tostring(id)) end
  end)

  it("Alchemy camp recipes show the colours the site saw in game, not ForeverDB's flat yellow = green = gray", function()
    -- Mana Well and Fermenter: ForeverDB 20/20/20 and 140/140/140, wowforever.be (observed) 20/22/25 and 140/142/145
    local alchemy, ns = crafts(171, true)
    assert.are.same({ 20, 22, 25 }, { alchemy[1230564].y, alchemy[1230564].g, alchemy[1230564].gr })
    assert.are.same({ 140, 142, 145 }, { alchemy[1263005].y, alchemy[1263005].g, alchemy[1263005].gr })
    assert.is_nil(ns.ForeverFixes.th[1230564]); assert.is_nil(ns.ForeverFixes.th[1263005])
    -- a flat ForeverDB value stays where the site has no real colours either (Alchemy Laboratory 300/300/300)
    assert.are.same({ 300, 300, 300 }, { alchemy[1263078].y, alchemy[1263078].g, alchemy[1263078].gr })
  end)

  it("a recipe that is not in the Forever client is never listed, the rank books stay", function()
    local n = 0
    for _, line in ipairs({ 171, 164, 333, 202, 165, 197, 185, 129, 356 }) do
      local by, ns = crafts(line, true)
      for id in pairs(ns.ForeverFixes.gone) do assert.is_nil(by[id], tostring(id)); n = n + 1 end
      if line == 185 then assert.is_not_nil(by[3413]) end                                        -- Cooking's Expert book
    end
    assert.is_true(n > 100)
  end)

  it("a trainer fee is the full price: the higher of what the two sources observed (a 10 % reputation discount apart)", function()
    local n = 0
    for _, line in ipairs({ 171, 164, 333, 202, 165, 197 }) do
      local by, ns = crafts(line, true)
      for id, fee in pairs(ns.ForeverFixes.fee) do
        local c = by[id]
        if c then
          n = n + 1
          assert.are.equal("trainer", c.how.kind); assert.are.equal(fee, c.how.cost)
          local seen = ns.ForeverTrainers[id].cost
          assert.is_true(fee > seen, id .. ": " .. seen .. " vs " .. fee)
          -- 10 % apart is the Honored discount: stated as the price; any other gap is said to be unverified
          assert.are.equal(math.abs(seen / fee - 0.9) > 0.002, c.how.costDoubt == true, id .. ": " .. seen .. " vs " .. fee)
        end
      end
    end
    assert.is_true(n > 10)
    -- a gap no discount explains: the higher of the two fees is shown and said to be unverified
    local by, ns = crafts(197, true)
    local doubts = 0
    for id in pairs(ns.ForeverFixes.feeDoubt) do
      if by[id] then
        doubts = doubts + 1
        assert.is_true(by[id].how.costDoubt)
        assert.are.equal(math.max(ns.ForeverTrainers[id].cost, ns.ForeverFixes.fee[id] or 0), by[id].how.cost)
        assert.matches("%(prix non vérifié%)", ns.Fmt.Source({ id = id, way = by[id].how }, true))
      end
    end
    assert.is_true(doubts > 0)
    -- White Swashbuckler's Shirt: the site saw 4s 50c with the discount, the full price is 5s, stated plainly
    assert.are.equal(450, ns.ForeverTrainers[8483].cost); assert.are.equal(500, by[8483].how.cost); assert.is_nil(by[8483].how.costDoubt)
  end)
end)

describe("vendor, quest and quest-item facts say what is and is not confirmed on Forever", function()
  local function start()
    setup({ scanned = true, faction = "Horde", profs = {} })
    local ns = loadAddon()
    local who = ns.Where.Who({ db = ns.Npcs, byName = ns.NpcByName, maps = ns.MapIDs, fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors,
      fdbQuests = ns.FdbQuests, fdbPrice = ns.FdbPrice, fdbFavor = ns.FdbFavor })
    return ns, who
  end

  it("a Merchant's Favor vendor that asks a standing says so: 240 Faveur du marchand, Honoré requis", function()
    local ns, who = start()
    local way = ns.Leveling.Way(ns.ForeverDB, 1219579, { requiredSkill = 300 }, "H", ns.ForeverTrainers, who)
    assert.are.equal("vendor", way.kind); assert.are.equal("Honored", way.standing); assert.are.equal("Beneris (The Barrens)", way.where)
    assert.are.equal("240 Faveur du marchand, Honoré requis", ns.Fmt.VendorPrice(way))
  end)

  it("a vendor's gold price is the full one: ForeverDB's when the library captured it with a reputation discount", function()
    local ns, who = start()
    assert.are.equal(500, ns.FdbPrice[1255123])                                  -- the library saw 450 at an Alliance vendor (10 % off)
    local way = ns.Leveling.Way(ns.ForeverDB, 1255123, { requiredSkill = 60 }, "A", ns.ForeverTrainers, who)
    assert.are.equal("vendor", way.kind); assert.are.equal(500, way.vendorCost)
    local horde = ns.Leveling.Way(ns.ForeverDB, 7755, { requiredSkill = 100 }, "H", ns.ForeverTrainers, who)
    assert.are.equal(1200, horde.vendorCost)                                     -- the catfish recipe: 12 silver
  end)

  it("an item kept for a quest Forever's quest list does not have says the quest is not confirmed", function()
    local ns = start()
    assert.are.equal(12, ns.FdbQuestSeen["Goretusk Liver Pie"])                    -- Forever's quest level, same as the Classic one
    -- Stranglethorn Fever: level 45 on Forever (35 in the Classic table): kept for it at 44, no longer at 33
    assert.are.equal(45, ns.FdbQuestSeen["Stranglethorn Fever"])
    local fever = ns.QuestItems[2799][1]
    assert.are.equal(35, fever.level)
    assert.is_true(ns.Advice.QuestRelevant(fever, { level = 44, faction = "H" }))
    assert.is_false(ns.Advice.QuestRelevant(fever, { level = 33, faction = "H" }))
    assert.are.equal("Goretusk Liver Pie", ns.Fmt.QuestLabel("Goretusk Liver Pie"))
    assert.are.equal("Items of Power (quête Classic, non confirmée sur Forever)", ns.Fmt.QuestLabel("Items of Power"))
    local seen, all = 0, 0
    for _, list in pairs(ns.QuestItems) do for _, q in ipairs(list) do all = all + 1; if ns.FdbQuestSeen[q.quest] then seen = seen + 1 end end end
    assert.is_true(seen >= 55 and seen < all)
  end)
end)

describe("Cooking 124 for a Horde player (real Forever data)", function()
  local function learn()
    setup({ scanned = true, faction = "Horde", profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    -- no pattern is sold at the auction house here (an AH price would give the Horde a way to an Alliance vendor's recipe)
    local teach = {}
    for id in pairs(ns.ForeverDB:GetRecipes(185)) do local it = ns.ForeverDB:GetRecipeItem(id); if it then teach[it] = true end end
    _G.Auctionator.API.v1.GetAuctionPriceByItemID = function(_, id) if not teach[id] then return 35 end end
    local res
    ns.RunLeveling(function(r) res = r end)
    return ns, res.profs[1].learn
  end

  it("Alliance-only recipes (Crocolisk Gumbo, Crocolisk Steak) are never listed nor best: one dim line names them", function()
    local ns, lr = learn()
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, e in ipairs(bucket) do assert.is_nil(e.target.onlyFaction, e.rec.name) end
    end
    local seen = {}
    for _, o in ipairs(lr.otherFaction) do seen[o.rec.id] = o end
    local ids = {}
    for id in pairs(seen) do ids[#ids + 1] = id end
    table.sort(ids)
    assert.is_not_nil(seen[3373], table.concat(ids, ","))
    assert.is_not_nil(seen[3370])             -- Crocolisk Gumbo, Crocolisk Steak: Kendor Kabonka / Stormwind quests only
    assert.is_not_nil(lr.best, ("now %d unpriced %d candidates %d"):format(#lr.now, lr.unpriced, lr.candidates)); assert.are_not.equal(3373, lr.best.rec.id); assert.is_nil(lr.best.target.onlyFaction)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = {}
    for _, l in ipairs(ns.Window.Lines()) do text[#text + 1] = (l.left.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
    local all = table.concat(text, "\n")
    assert.matches("Réservé à l'Alliance : ", all)
    local count = 0
    for _, t in ipairs(text) do if t:find("Réservé à l'Alliance", 1, true) then count = count + 1 end end
    assert.are.equal(1, count)
  end)

  it("the best recipe to learn has a place we can pin when one exists", function()
    local _, lr = learn()
    assert.is_not.equal("text", lr.best.target.kind)
  end)

  it("rank books are named by the book: the cached item name, else its English name; with price and place", function()
    local ns, lr = learn()
    assert.are.equal(1, #lr.books)
    assert.are.equal("Item16072", lr.books[1].name)                          -- the stub client has every item cached
    _G.GetItemInfo = function() end
    assert.are.equal("Expert Cookbook", ns.BookName(lr.books[1].rec))
    assert.is_not_nil(lr.books[1].target)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = {}
    for _, l in ipairs(ns.Window.Lines()) do text[#text + 1] = (l.left.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
    assert.matches("Pour dépasser 150 : Expert Cookbook", table.concat(text, "\n"))     -- the item is not cached any more: the English name
    assert.matches("vendeur · 1g", table.concat(text, "\n"))                          -- its price
    assert.is_nil(table.concat(text, "\n"):find("Pour dépasser 150 : Cooking", 1, true))
  end)
end)
