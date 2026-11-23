-- Smoke: the Metier tab (profession tabs, bag filter, objective toggle, owner professions).
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("profession leveling tab", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } },
    [2] = { id = 2, name = "Elixir vert", d = 2, greenAt = 41, out = 118, oq = 1, mats = { { 2447, 1 } } },
  } }

  it("renders the whole tab: the roadmap (level) and the learn lists with the Classic caveat (gold), remembered data", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, goal = "level" }
    assert.has_no.errors(function() ns.Window.Toggle(); ns.Window.SetTab("job") end)
    local text = lineTexts(ns)
    assert.matches("Alchimie  50/75", text)
    assert.matches("Ton parcours", text)
    assert.matches("Apprendre le rang Compagnon", text)              -- skill 50 allows it: the first step, not a footer line
    assert.are.equal("", ns.Window.Footer().text)
    ns.char.goal = "gold"
    ns.Window.SetTab("job")
    text = lineTexts(ns)
    assert.matches("À apprendre maintenant", text)
    assert.matches("Meilleure à apprendre", text)
    assert.matches("entraîneur", text)
    assert.is_nil(text:match("bientôt|r"))                          -- the placeholder is gone
    local footer = ns.Window.Footer().text
    assert.matches("wowforever.be %(observé en jeu%)", footer)
  end)

  it("lists the recipes to learn per profession, never a known one, and leaves Fishing and Herbalism alone", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 }, { 182, 80, "Herboristerie", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    local known = {}
    for _, r in ipairs(ns.RecipeRows) do if r[2] == "Alchemy" and (r[11] or r[3]) <= 75 then known[r[1]] = true end end
    local function run()
      local res
      ns.RunLeveling(function(r) res = r end)
      return res
    end
    ns.char = { learned = {}, profs = { Alchimie = alchemy } }
    local res = run()
    local alch, herb = res.profs[1], res.profs[2]
    assert.is_true(#alch.learn.now > 0 and alch.learn.nowTotal > 0)
    assert.is_nil(herb.learn)
    assert.are.equal("unseen", herb.status)   -- nothing remembered yet: "open the window once", whatever the profession
    -- everything learnable in reach is already known: the empty message
    ns.char.learned = known
    alch = run().profs[1]
    assert.are.equal(0, alch.learn.nowTotal + alch.learn.soonTotal)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.matches("Aucune recette à apprendre pour ce métier", lineTexts(ns))
  end)

  it("applies the bag filter to the recipes to learn, with an empty state and the way out", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } }, counts = {} })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, onlyBag = true }
    local res
    ns.RunLeveling(function(r) res = r end)
    local p = res.profs[1]
    assert.are.equal(0, #p.learn.now + #p.learn.soon)
    assert.is_true(p.learn.candidates > 0)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.matches("cache les recettes à apprendre", lineTexts(ns))
  end)

  it("prints how many learnable recipes /gc spike found per remembered profession", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy } }
    SlashCmdList.GOLDCOMPASS("spike")
    assert.matches("S7 learnable recipes Alchimie %(skill 50%): %d+ now, %d+ soon", table.concat(printed, "\n"))
  end)

  it("says to open the profession window once when it has not been read", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, goal = "level" }
    local res
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal("unseen", res.profs[1].status)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.matches("Ouvre ta fenêtre de Alchimie une fois", lineTexts(ns))
  end)

  it("says no recipes only when the window was read and the game listed none; Fishing with a recipe is planned", function()
    setup({ scanned = true, profs = { { 356, 150, "Pêche", 300 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, goal = "level" }
    local res
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal("unseen", res.profs[1].status)               -- never read: open the window once (Fishing included)
    ns.char.profs["Pêche"] = { skill = 150, max = 300, recipes = {} } -- window read, the game listed no recipe
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal("norecipes", res.profs[1].status)
    -- a Fishing window with one known recipe (Fish Bowl), read through the capture path
    local T = {
      GetBaseProfessionInfo = function() return { professionName = "Pêche", skillLevel = 150, maxSkillLevel = 300 } end,
      GetAllRecipeIDs = function() return { 7620 } end,
      GetRecipeInfo = function() return { learned = true, name = "Bocal à poisson", relativeDifficulty = 0 } end,
      GetRecipeSchematic = function() return { outputItemID = 6256, quantityMin = 1, quantityMax = 1,
        reagentSlotSchematics = { { reagents = { { itemID = 6291 } }, quantityRequired = 1 }, { reagents = { { itemID = 6458 } }, quantityRequired = 1 } } } end,
    }
    ns.char.profs["Pêche"] = nil
    assert.are.equal(1, ns.Learned.Capture(T, ns.char.learned, ns.char.profs))
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal("plan", res.profs[1].status)
    assert.are.equal(7620, res.profs[1].plan.best.rec.id)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.is_nil(lineTexts(ns):find("Plus de recette utile", 1, true))   -- Fishing: a gathering profession, no craft line
    assert.matches("Pêche  150/300", lineTexts(ns))
    setup({ scanned = true })
    ns = loadAddon()
    ns.char = { learned = {}, profs = {} }
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal("empty_prof", res.state)
    setup({ noAuc = true, profs = { { 171, 50, "Alchimie", 75 } } })
    ns = loadAddon()
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal("no_auctionator_addon", res.state)
  end)

  it("names the reagents that have no price instead of showing a number", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } }, pickupNoAh = true, noSpell = true })   -- the game knows no other recipe
    local ns = loadAddon()
    ns.db = { buy = {} }
    -- reagent 9999 has no AH price, no buy price (the stub gives AH prices to everything but pickup items)
    ns.char = { learned = {}, profs = { Alchimie = { skill = 50, max = 75, recipes = {
      [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 9999, 2 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local p = res.profs[1]
    assert.is_nil(p.plan.best)
    assert.are.same({ "Item9999" }, p.missingNames)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.matches("Prix manquant : Item9999", lineTexts(ns))
  end)

  it("uses the game's recipe name and falls back to the remembered one", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, goal = "level" }
    local res
    ns.RunLeveling(function(r) res = r end)
    local nameNoApi = res.profs[1].plan.best.name
    assert.is_true(nameNoApi == "Potion de soins" or nameNoApi == "Elixir vert")  -- the remembered (window) name
    _G.C_Spell = { GetSpellName = function(id) return "Nom du jeu " .. id end }
    ns.RunLeveling(function(r) res = r end)
    assert.are.equal(nameNoApi, res.profs[1].plan.best.name)      -- nothing changed as far as the addon knows: the same answer
    ns.ForgetProfessions()                                         -- the game's spell data arrives (SPELL_DATA_LOAD_RESULT)
    ns.RunLeveling(function(r) res = r end)
    assert.matches("^Nom du jeu", res.profs[1].plan.best.name)
    _G.C_Spell = nil
  end)

  it("remembers a profession window: skill, difficulty, reagents; lowers greenAt; reads each schematic once", function()
    setup({ scanned = true })
    local ns = loadAddon()
    local reads, skill = 0, 50
    local T = {
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", skillLevel = skill, maxSkillLevel = 75 } end,
      GetAllRecipeIDs = function() return { 1, 2 } end,
      GetRecipeInfo = function(id) return { learned = true, name = "Recette " .. id, relativeDifficulty = id == 1 and 0 or 2 } end,
      GetRecipeSchematic = function() reads = reads + 1
        return { outputItemID = 30, quantityMin = 1, quantityMax = 3, reagentSlotSchematics = { { reagents = { { itemID = 10 } }, quantityRequired = 2 } } } end,
    }
    local learned, profs = {}, {}
    assert.are.equal(2, ns.Learned.Capture(T, learned, profs))
    local rec = profs.Alchimie.recipes[2]
    assert.are.equal(50, profs.Alchimie.skill)
    assert.are.same({ { 10, 2 } }, rec.mats)
    assert.are.equal(30, rec.out)
    assert.are.equal(2, rec.oq)               -- (1 + 3) / 2
    assert.are.equal(50, rec.greenAt)         -- green when first seen at skill 50
    skill = 42
    ns.Learned.Capture(T, learned, profs)
    assert.are.equal(42, profs.Alchimie.recipes[2].greenAt) -- seen green earlier: lowered
    assert.is_nil(profs.Alchimie.recipes[1].greenAt)        -- orange: unknown
    assert.are.equal(2, reads)                -- schematics read once per recipe
  end)
end)

describe("Avec mon sac (bag filter on the leveling tab)", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  -- recipe 1 needs 2 x 2447 (orange), recipe 2 needs 1 x 2447 and 3 x 2448 (green)
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } },
    [2] = { id = 2, name = "Elixir vert", d = 2, greenAt = 41, out = 118, oq = 1, mats = { { 2447, 1 }, { 2448, 3 } } },
  } }
  local function start(opts)
    opts.scanned, opts.profs = true, { { 171, 50, "Alchimie", 75 } }
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, onlyBag = opts.on }
    return ns
  end
  local function bagEvent()
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.BAG_UPDATE_DELAYED and fr.scripts.OnEvent and fr.events.ZONE_CHANGED_NEW_AREA then
        fr.scripts.OnEvent(fr, "BAG_UPDATE_DELAYED")
      end
    end
  end

  it("the roadmap uses the bag first: the first step is what the bags can craft, with its quantity, and the checkbox is hidden", function()
    local ns = start({ on = true, counts = { [2447] = 5 } }) -- recipe 1: floor(5/2) = 2 ; recipe 2 lacks 2448
    ns.char.goal = "level"
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("Potion de soins ×%d+", text)
    local entry, left
    for _, l in ipairs(ns.Window.Lines()) do if l.craft and l.craft.entry then entry, left = l.craft.entry, l.left.text end end
    assert.are.equal(2, entry.times)                                 -- the button covers the 2 crafts the bag allows
    assert.matches("2 avec ton sac", entry.sub)
    assert.matches("2 avec ton sac", left)                           -- D: the dim line stays, the stub's "ouvre la fenêtre à la main" does not replace it
    assert.is_false(ns.Window.IsBagBoxShown())
    ns.char.goal = "gold"
    ns.Window.SetTab("job")
    assert.is_true(ns.Window.IsBagBoxShown())
  end)

  it("keeps the full list with the filter off, and remembers the checkbox per character", function()
    local ns = start({ counts = {} })
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.is_nil(lineTexts(ns):match("%(avec ton sac"))
    ns.char.onlyBag = true
    ns.Window.Refresh()
    assert.matches("Rien à fabriquer avec ton sac", lineTexts(ns))
    assert.is_true(ns.char.onlyBag)
  end)

  it("says plainly that nothing can be crafted and suggests the closest recipe with what is missing", function()
    local ns = start({ on = true, counts = { [2447] = 1, [2448] = 1 } }) -- recipe 1 lacks 1 x 2447 ; recipe 2 lacks 2 x 2448
    local res
    ns.RunLeveling(function(r) res = r end)
    local p = res.profs[1]
    assert.is_nil(p.plan.best)
    assert.are.equal(0, p.plan.craftable)
    assert.are.same({ { "Item2447", 1 } }, p.almost.missing) -- fewest reagents short (1), then fewest units
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("Rien à fabriquer avec ton sac pour ce métier", text)
    assert.matches("Presque : Potion de soins, il manque 1 × Item2447", text)
  end)

  it("counts bags only: no bank, no reagent bank", function()
    local calls = {}
    local ns = start({ on = true })
    _G.C_Item.GetItemCount = function(id, ...) calls[#calls + 1] = { id, ... }; return 9 end
    ns.RunLeveling(function() end)
    assert.is_true(#calls > 0)
    for _, c in ipairs(calls) do assert.are.same({ false, false, false }, { c[2], c[3], c[4] }) end
  end)

  it("keeps 'Ouvre la fenêtre' when the profession was not read, filter on", function()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, onlyBag = true }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.matches("Ouvre la fenêtre de Alchimie une fois", lineTexts(ns))
  end)

  it("refreshes once on repeated BAG_UPDATE_DELAYED, never in combat, never on another tab", function()
    local ns = start({ on = true, counts = { [2447] = 5 } })
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    local function flush() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end
    timers = {}
    for _ = 1, 20 do bagEvent() end
    assert.are.equal(1, #timers)                    -- one redraw scheduled, not twenty
    flush()
    assert.are.equal(1, runs)
    _G.InCombatLockdown = function() return true end
    for _ = 1, 3 do bagEvent() end
    flush()
    assert.are.equal(1, runs)                       -- nothing in combat
    _G.InCombatLockdown = function() return false end
    ns.Window.SetTab("map")
    runs = 0
    bagEvent(); flush()
    assert.are.equal(0, runs)                       -- not on the Carte tab
  end)

  it("draws nothing when the timer fires in combat", function()
    local ns = start({ on = true, counts = { [2447] = 5 } })
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    timers = {}
    bagEvent()                                       -- scheduled out of combat...
    _G.InCombatLockdown = function() return true end
    for _, fn in ipairs(timers) do fn() end          -- ...but fires in combat
    assert.are.equal(0, runs)
  end)

  it("the checkbox turns the filter on and remembers it; the empty-state button turns it off", function()
    local ns = start({ counts = {} })
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local function click(label)
      for _, fr in ipairs(frames) do
        if fr.label and fr.label.text == label and fr.scripts.OnClick then fr.scripts.OnClick(fr); return fr end
      end
      error("no control " .. label)
    end
    click("Avec mon sac")
    assert.is_true(ns.char.onlyBag)
    assert.matches("Rien à fabriquer avec ton sac", lineTexts(ns))
    click("Voir sans filtre")
    assert.is_false(ns.char.onlyBag)
    assert.is_nil(lineTexts(ns):match("Rien à fabriquer avec ton sac pour ce métier"))
  end)
end)

describe("Métier tab: objective toggle", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  -- Potion (id 1): orange, 2 x 2447 (35c each = 70c), sells 33c -> costs money.
  -- Elixir vert (id 2): green, 1 x 2447, output 2770 sells 38c at the AH -> earns 3c per craft.
  -- Vieille potion (id 3): gray, same as the Elixir -> earns, but only the money view lists it.
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } },
    [2] = { id = 2, name = "Elixir vert", d = 2, out = 2770, oq = 1, mats = { { 2447, 1 } } },
    [3] = { id = 3, name = "Vieille potion", d = 3, out = 2770, oq = 1, mats = { { 2447, 1 } } },
  } }
  local function start(opts)
    opts = opts or {}
    opts.scanned, opts.profs, opts.counts = true, { { 171, 50, "Alchimie", 75 } }, { [2447] = 5 }
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, onlyBag = true }
    ns.Goal = ns.RealGoal                                           -- this describe tests the real default
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end

  it("defaults to Monter le métier and remembers the choice per character", function()
    local ns = start()
    assert.are.equal("level", ns.Goal())
    assert.matches("Potion de soins ×%d+", lineTexts(ns))                                      -- 2 orange crafts beat 5 green ones (1.25)
    ns.Window.SetGoal("gold")
    assert.are.equal("gold", ns.char.goal)                                                     -- saved with the character
    assert.are.equal("gold", ns.Goal())
    ns.Window.Toggle(); ns.Window.Toggle()                                                     -- close and reopen
    assert.are.equal("gold", ns.Goal())
    assert.matches("Objectif : gagner de l'or", ns.Window.Footer().text)
    ns.Window.SetGoal("level")
    assert.are.equal("level", ns.char.goal)
  end)

  it("Gagner de l'or ranks by profit per craft with the total, the AH note and its age, and lists the gray recipe", function()
    local ns = start()
    local level = lineTexts(ns)
    assert.is_nil(level:find("Vieille potion", 1, true))                                       -- gray: only in the money view
    ns.Window.SetGoal("gold")
    local text = lineTexts(ns)
    assert.matches("Fabrique Elixir vert ×5 : rapporte ~[^\n]* par fabrication %(~[^\n]* au total%)", text)
    assert.matches("rentable seulement si tu revends à l'HV · prix HV de 1 j", text)
    assert.matches("Vieille potion", text)
    assert.matches("Potion de soins[^\n]* coûte ~[^\n]*/fab%.", text)
  end)

  it("the footer explains the active objective and stays within two lines", function()
    local ns = start()
    for _, goal in ipairs({ "level", "gold" }) do
      assert.is_true(#ns.Window.JobFooter(false, goal) <= 160)
      assert.is_true(#ns.Window.JobFooter(true, goal) <= 160)
    end
  end)

  it("the learning price of a vendor recipe is said on its line: gold, a currency or unknown", function()
    local ns = start()
    ns.Money = function(c) return c .. "c" end
    assert.are.equal("vendeur · 500c", ns.Fmt.Source({ src = "v", way = { kind = "vendor", vendorCost = 500 } }))
    assert.are.equal("vendeur · prix de la recette inconnu", ns.Fmt.Source({ src = "v", way = { kind = "vendor" } }))
    assert.are.equal("vendeur · 240 Faveur du marchand", ns.Fmt.Source({ src = "v", way = { kind = "vendor", currency = { id = 3402, amount = 240 } } }))
    _G.C_CurrencyInfo = { GetCurrencyInfo = function(id) return { name = "Faveur (jeu) " .. id } end }
    assert.are.equal("vendeur · 240 Faveur (jeu) 3402", ns.Fmt.Source({ src = "v", way = { kind = "vendor", currency = { id = 3402, amount = 240 } } }))
    _G.C_CurrencyInfo = nil
  end)
end)

describe("clients without GetBaseProfessionInfo (GetTradeSkillLine returns several values)", function()
  it("Learned.Capture records the window by its GetTradeSkillLine name, skill and maximum", function()
    setup({}); local ns = loadAddon()
    local window = { GetTradeSkillLine = function() return 165, "Travail du cuir", 61, 75 end,
      GetAllRecipeIDs = function() return { 2149 } end,
      GetRecipeInfo = function(id) return { learned = true, name = "r" .. id, relativeDifficulty = 2 } end }
    local learned, profs = {}, {}
    ns.Learned.Capture(window, learned, profs)
    assert.is_not_nil(profs["Travail du cuir"])
    assert.are.equal(61, profs["Travail du cuir"].skill); assert.are.equal(75, profs["Travail du cuir"].max)
  end)

  it("ns.OpenTradeSkill returns the profession name from GetTradeSkillLine", function()
    setup({}); local ns = loadAddon()
    _G.C_TradeSkillUI = { GetTradeSkillLine = function() return 165, "Travail du cuir", 61, 75 end }
    assert.are.equal("Travail du cuir", (ns.OpenTradeSkill()))
  end)
end)

describe("Métier tab with the owner's professions (real Forever data, Horde)", function()
  local function plain(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local function render(bag)
    setup({ scanned = true, faction = "Horde", counts = bag and { [2318] = 10 } or nil,
      profs = { { 165, 61, "Travail du cuir", 75 }, { 356, 150, "Pêche", 150 }, { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, onlyBag = bag or false }
    for _, p in ipairs(dofile("spec/fixtures/owner_profiles.lua")) do      -- the owner's known recipes (every profession of the fixture)
      local recipes = {}
      for _, id in ipairs(p.known) do recipes[id] = { id = id, name = "r" .. id, d = 2, out = 2302, oq = 1, mats = { { 2318, 1 } } } end
      ns.char.profs[p.name] = { skill = p.skill, max = p.skill > 100 and 150 or 75, recipes = recipes }
    end
    _G.GetLocale = function() return "frFR" end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local due = timers; timers = {}
    for _, fn in ipairs(due) do pcall(fn) end
    return ns
  end

  it("no line is cut: its text fits its slot (about 5.5 px a character), with and without the bag filter", function()
    for _, bag in ipairs({ false, true }) do
      local ns = render(bag)
      local P = ns.Window.LineParts
      local n, cut = 0, {}
      for _, l in ipairs(allJobLines(ns)) do
        local text = plain(l.left.text)
        if text ~= "" then
          n = n + 1
          local slotRight = l.left.width or P.left.r      -- the width given by setLines
          local cap = math.floor(slotRight / 5.5)
          if utf8.len(text) > cap then cut[#cut + 1] = ("%d > %d: %s"):format(utf8.len(text), cap, text) end
        end
      end
      assert.is_true(n > 10)
      assert.are.same({}, cut)
    end
  end)

  it("the Métier tab shows the cap lines: 'Au-delà de 75' for Travail du cuir, rank books near the cap, no gray rank book", function()
    for _, bag in ipairs({ false, true }) do
      local ns = render(bag)
      local all = {}
      for _, l in ipairs(allJobLines(ns)) do all[#all + 1] = plain(l.left.text) end
      local text = table.concat(all, "\n")
      assert.matches("Au%-delà de 75 : il faut le rang Compagnon", text)
      assert.matches("Pour dépasser 150 : ", text)
      assert.is_nil(text:find("prix de la recette inconnu, niv. 125 grise", 1, true))
    end
  end)

  it("no recipe above the profession cap is listed under 'Bientôt' (Travail du cuir 61/75)", function()
    local ns = render(false)
    local lines = allJobLines(ns)
    local inLeather, soon = false, false
    for i, l in ipairs(lines) do
      local t = plain(l.left.text)
      if t:find("^Travail du cuir") then inLeather = true elseif t:find("^Pêche") or t:find("^Cuisine") then inLeather = false end
      if inLeather then
        if t:find("^Bientôt") then soon = true elseif t:find("^À apprendre") or t:find("^Déjà grises") then soon = false end
        local level = soon and t:match("niv%. (%d+)")
        if level then assert.is_true(tonumber(level) <= 75, t) end
      end
    end
  end)
end)
