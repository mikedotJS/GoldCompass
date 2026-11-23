-- Smoke test core: loads every addon file in TOC order against a stubbed WoW API (shared stubs in spec/helper_smoke.lua), with fake GatherMate2
-- and Auctionator, and runs /gc map and the window. It proves the glue code runs; it proves nothing about the real game.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("addon glue (stubbed WoW API)", function()
  it("prints a ranking with estimates, tags and the footer", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    SlashCmdList["GOLDCOMPASS"]("map")
    local text = table.concat(printed, "\n")
    assert.matches("Zone1411", text)
    assert.matches("Zone1429", text)
    assert.matches("estimation", text)
    assert.matches("Item2770", text)
    -- Zone 1411: 100 Copper Veins, 40c: 2 x 40 x 0.95 = 76c per node; 60 x 76 = 4560c = 45.6s -> "46s" (the 3 unknown spots are ignored)
    -- Zone 1429: 100 Peacebloom, 35c: 2 x 35 x 0.95 = 66.5c per node; 60 x 66.5 = 3990c = 39.9s -> "40s"
    assert.matches("1%. Zone1411  ~46s/h", text)
    assert.matches("2%. Zone1429  ~40s/h", text)
  end)

  it("shows the empty states and the missing-addon errors", function()
    for _, case in ipairs({
      { { scanned = false }, "Pas encore de prix" },
      { { noGM = true }, "GatherMate2 n'est pas installé" },
      { { noAuc = true }, "Auctionator n'est pas installé" },
    }) do
      setup(case[1])
      local ns = loadAddon()
      ns.db = {}
      SlashCmdList["GOLDCOMPASS"]("map")
      assert.matches(case[2], table.concat(printed, "\n"))
    end
  end)

  it("adds the tooltip section under an item that is an ingredient, and nothing in combat", function()
    setup({ scanned = true, alchemy = true })
    loadAddon()
    handlers.item(GameTooltip, { id = 2449 }) -- Earthroot, an ingredient of the known Elixir of Minor Strength
    local text = table.concat(GameTooltip.lines, "\n")
    assert.matches("GOLD COMPASS", text)
    assert.matches("Elixir of Minor Strength", text)
    assert.matches("connue", text)
    assert.matches("estimation", text)
    setup({ scanned = true, alchemy = true, combat = true })
    loadAddon()
    handlers.item(GameTooltip, { id = 2449 })
    assert.are.equal(0, #GameTooltip.lines)
  end)

  it("runs the bags tab: groups, total, empty state and missing Auctionator", function()
    setup({ scanned = true, alchemy = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.RunBags(function(r) res = r end)
    assert.are.equal("ok", res.state)
    -- Earthroot x5 (3 + 2 merged) and Copper Ore x10: 2 items, a total above 0
    local n = 0
    for _, list in pairs(res.groups) do n = n + #list end
    assert.are.equal(2, n)
    assert.is_true(res.total > 0)
    assert.has_no.errors(function() ns.Window.Toggle(); ns.Window.SetTab("bags") end)
    setup({ scanned = true, emptyBags = true })
    ns = loadAddon()
    ns.RunBags(function(r) res = r end)
    assert.are.equal("empty", res.state)
    setup({ noAuc = true })
    ns = loadAddon()
    ns.RunBags(function(r) res = r end)
    assert.are.equal("no_auctionator_addon", res.state)
  end)

  it("runs the here tab for a ranked zone, an unranked zone, and with a missing profession hint", function()
    setup({ scanned = true, alchemy = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.RunHere(function(r) res = r end)
    assert.are.equal("ok", res.state)
    assert.are.equal(1411, res.cmp.row.zone)
    assert.is_true(res.cmp.best) -- zone 1411 (46s/h) beats zone 1429 (40s/h) in the stub data
    assert.is_true(res.cmp.ratio > 1)
    assert.is_true(#res.nodes >= 1)
    assert.has_no.errors(function() ns.Window.Toggle(); ns.Window.SetTab("here") end)
    setup({ scanned = true, zone = 9999 })
    ns = loadAddon()
    ns.RunHere(function(r) res = r end)
    assert.are.equal("here_nodata", res.state)
  end)

  it("applies the profession filter and the level filter", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end, { profession = "Mining" })
    assert.are.equal("ok", res.state)
    assert.are.equal(1, #res.all) -- only Zone1411 has Mining spots in the stub data
    assert.are.equal(100, res.supposed) -- no profession: supposed skill 5 x level 20
    ns.Run(function(r) res = r end, { profession = "Herb Gathering" })
    assert.are.equal(1429, res.all[1].zone)
    -- level filter: Durotar (1-10) stays at level 20; Un'Goro (48-55) is 28 above and goes
    local rows = { { zone = 1411 }, { zone = 1449 }, { zone = 1 }, { zone = 2482 } }
    local shown, hidden = ns.VisibleZones(rows, true)
    assert.are.equal(2, #shown)       -- 1411 and the zone missing from the table; 1449 is too high
    assert.are.equal(1, hidden)       -- 2482 has an unknown level: hidden, and counted
    shown, hidden = ns.VisibleZones(rows, false)
    assert.are.equal(4, #shown)
    assert.are.equal(0, hidden)
    assert.has_no.errors(function() ns.Window.Toggle() end)
  end)

  it("opens the window and renders without error", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    assert.has_no.errors(function() SlashCmdList["GOLDCOMPASS"]("") end)
    SlashCmdList["GOLDCOMPASS"]("spike")
    assert.matches("S2 Durotar", table.concat(printed, "\n"))
  end)

  it("spike prints every line when item data and merchant prices are missing (nothing returned, not nil)", function()
    setup({ scanned = true })
    _G.GetItemInfo = function() end
    _G.C_Item.GetItemInfo = nil
    _G.Auctionator.API.v1.GetVendorPriceByItemID = function() end
    local ns = loadAddon()
    ns.db = {}
    assert.has_no.errors(function() SlashCmdList["GOLDCOMPASS"]("spike") end)
    local out = table.concat(printed, "\n")
    assert.matches("S3 item 2447 vendor price from item data: nil", out)
    assert.matches("S5 profession window API", out)
  end)
end)

describe("review fixes (stubbed WoW API)", function()
  local function tooltipText(opts)
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    handlers.item(GameTooltip, { id = 2449 })
    return table.concat(GameTooltip.lines, "\n"), ns
  end

  it("gives up waiting for item data after 5 seconds, once, and names unknown items", function()
    setup({ scanned = true, neverLoads = true })
    local ns = loadAddon()
    local calls = 0
    ns.LoadItems({ 1, 2, 2 }, function() calls = calls + 1 end)
    assert.are.equal(0, calls)          -- still waiting: the items never load
    assert.are.equal(1, #timers)        -- the 5-second timer is armed
    timers[1]()
    assert.are.equal(1, calls)
    timers[1]()
    assert.are.equal(1, calls)          -- a late timer or load does not call back twice
    _G.GetItemInfo = function() end
    assert.are.equal("objet #99999", ns.ItemName(99999))
    -- the same wait inside /gc map: the ranking is still produced after the timeout
    local res
    ns.Run(function(r) res = r end)
    timers[#timers]()
    assert.are.equal("ok", res.state)
  end)

  it("shows the error state when Auctionator fails, and the empty state when it has no price", function()
    setup({ scanned = true, aucFails = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end)
    assert.are.equal("price_error", res.state)
    setup({ scanned = false })
    ns = loadAddon()
    ns.db = {}
    ns.Run(function(r) res = r end)
    assert.are.equal("noscan", res.state)
    -- the tooltip must not raise when Auctionator fails
    assert.has_no.errors(function() tooltipText({ scanned = true, aucFails = true }) end)
  end)

  it("adds the verdict line only when Forever Ledger is absent", function()
    local without = tooltipText({ scanned = true, alchemy = true })
    local with = tooltipText({ scanned = true, alchemy = true, ledger = true })
    assert.matches("Vendre à l'HV", without)
    assert.is_nil(with:find("Vendre", 1, true))
    assert.matches("Sert à", with) -- the recipes are still added
  end)

  it("never recommends the AH for a soulbound bag item, and the tooltip and Bags tab agree", function()
    local text, ns = tooltipText({ scanned = true, alchemy = true, bound = true })
    assert.matches("Vendre au marchand", text)
    assert.is_nil(text:find("Vendre à l'HV", 1, true))
    local res
    ns.RunBags(function(r) res = r end)
    local inVendor = {}
    for _, e in ipairs(res.groups.vendor) do inVendor[e.item.id] = true end
    assert.is_true(inVendor[2449]) -- Earthroot, bound: vendor group in the Bags tab as well
  end)

  it("a tooltip scans the bags only for an item the bags hold, once per change of the bags, and keeps the recipe uses for a few seconds", function()
    setup({ scanned = true, alchemy = true, bound = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local scans, uses, clock = 0, 0, 1000
    local realScan, realUses = ns.BagItems, ns.Advice.Uses
    ns.BagItems = function() scans = scans + 1; return realScan() end
    ns.Advice.Uses = function(...) uses = uses + 1; return realUses(...) end
    _G.time = function() return clock end
    local function hover() GameTooltip.lines = {}; handlers.item(GameTooltip, { id = 2449 }) end
    hover(); hover(); hover()
    assert.are.equal(1, scans)                                                      -- one scan for three looks at a bag item
    assert.are.equal(1, uses)                                                       -- and one price walk over its recipes
    assert.matches("Vendre au marchand", table.concat(GameTooltip.lines, "\n"))     -- still the soulbound verdict
    clock = clock + 6
    hover()
    assert.are.equal(2, uses)                                                       -- the uses expire
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.BAG_UPDATE_DELAYED and fr.events.MODIFIER_STATE_CHANGED then fr.scripts.OnEvent(fr, "BAG_UPDATE_DELAYED") end
    end
    hover()
    assert.are.equal(2, scans)                                                      -- the bags changed: scanned again
    _G.C_Item.GetItemCount = function() return 0 end                                -- an item the bags do not hold: no scan at all
    local before = scans
    handlers.item(GameTooltip, { id = 2449 })
    assert.are.equal(before, scans)
    _G.time = os.time
  end)

  it("shows the no-price verdict with the scan hint", function()
    setup({ scanned = false, noVendor = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    handlers.item(GameTooltip, { id = 4242 })
    local text = table.concat(GameTooltip.lines, "\n")
    assert.matches("Aucune valeur connue", text)
    assert.matches("scanne l'hôtel des ventes", text)
  end)

  it("warns that guessed recipe sources are not confirmed on Forever", function()
    local text = tooltipText({ scanned = true, alchemy = true, noSpell = true })
    assert.matches("source inconnue", text)
    assert.matches("non confirmées sur Forever", text)
  end)

  it("remembers learned recipes from the profession window and uses them", function()
    setup({ scanned = true, alchemy = true, noSpell = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local T = { GetAllRecipeIDs = function() return { 2329, 2331, 2332 } end,
      GetRecipeInfo = function(id) return { learned = id ~= 2331 } end }
    assert.are.equal(2, ns.Learned.Capture(T, ns.char.learned))
    assert.are.equal(0, ns.Learned.Capture(T, ns.char.learned)) -- nothing new the second time
    assert.is_true(ns.char.learned[2329])
    assert.is_nil(ns.char.learned[2331])
    -- another player's linked window is ignored
    T.IsTradeSkillLinked = function() return true end
    local other = {}
    assert.are.equal(0, ns.Learned.Capture(T, other))
    assert.is_nil(next(other))
    -- an API that raises does not break the capture
    assert.are.equal(0, ns.Learned.Capture({ GetAllRecipeIDs = function() error("x") end, GetRecipeInfo = function() end }, {}))
    -- IsPlayerSpell says no, the memory says yes: the recipe shows as known
    handlers.item(GameTooltip, { id = 2449 })
    assert.matches("connue", table.concat(GameTooltip.lines, "\n"))
    -- merchant prices: 20c for a stack of 5 = 4c each; a free item is not recorded
    local buy = {}
    ns.Learned.RecordMerchant({ count = function() return 2 end,
      item = function(i) if i == 1 then return 3371, 20, 5 end return 5, 0, 1 end }, buy)
    assert.are.equal(4, buy[3371])
    assert.is_nil(buy[5])
  end)

  it("redraws the tooltip on Shift only outside combat and only for item tooltips", function()
    local function press(opts)
      setup(opts)
      loadAddon()
      for _, fr in ipairs(frames) do
        if fr.events and fr.events.MODIFIER_STATE_CHANGED then fr.scripts.OnEvent(fr, "MODIFIER_STATE_CHANGED") end
      end
      return GameTooltip.refreshed
    end
    assert.are.equal(1, press({ scanned = true }))
    assert.are.equal(0, press({ scanned = true, combat = true }))
    assert.are.equal(0, press({ scanned = true, notItem = true }))
  end)

  it("says the bags are empty when only the Hearthstone is there", function()
    setup({ scanned = true, onlyHearth = true })
    local ns = loadAddon()
    local res
    ns.RunBags(function(r) res = r end)
    assert.are.equal("empty", res.state)
  end)

  it("takes ingredient buy prices from the merchant memory first, then from Auctionator", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = { buy = { [3372] = 90 } }
    local ctx = ns.Context()
    assert.are.equal(90, ctx.buy(3372))   -- recorded at a merchant
    assert.are.equal(40, ctx.buy(3371))   -- Auctionator's vendor price cache
    assert.is_nil(ctx.buy(5))
  end)

  it("never prints 0 as a price", function()
    setup({ scanned = true })
    local ns = loadAddon()
    assert.are.equal("prix inconnu", ns.Money(0))
    assert.are.equal("prix inconnu", ns.Money(nil))
    assert.are.equal("5s", ns.Money(500))
  end)
end)

describe("review fixes, group B", function()
  it("tells the cause of a partial estimate: stale, unseen or unpriced", function()
    setup({ scanned = true })
    local ns = loadAddon()
    local both = ns.PartialText({ { stale = true }, { unseen = true } })
    assert.matches("plus de 7 jours", both)
    assert.matches("jamais vus", both)
    assert.is_nil(both:find("sans aucun prix", 1, true))
    assert.matches("sans aucun prix", ns.PartialText({ { unpriced = true } }))
    assert.are.equal("", ns.PartialText({ {} }))
  end)

  it("loads quest items before pricing them in the Here tab, and never shows a 0 price", function()
    setup({ scanned = true, pickupNoAh = true, lazyItems = true, zone = 1429, level = 6 })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local res
    ns.RunHere(function(r) res = r end)
    assert.are.equal("ok", res.state)
    assert.is_true(#res.pickups > 0)
    for _, p in ipairs(res.pickups) do
      assert.are.equal(25, p.unit)        -- the vendor price of the loaded item (25 in the stub), not 0
      assert.is_false(p.name:find("objet #", 1, true) ~= nil)
    end
  end)

  it("guards opening the world map: combat, missing call, blocked call", function()
    setup({ scanned = true })
    local ns = loadAddon()
    local opened
    _G.OpenWorldMap = function() error("the FrameXML route must never be used") end
    _G.C_Map.OpenWorldMap = function(zone) opened = zone end
    ns.Window.OpenMap(1411)
    assert.are.equal(1411, opened)
    printed = {}
    _G.InCombatLockdown = function() return true end
    ns.Window.OpenMap(1412)
    assert.are.equal(1411, opened)                        -- not called in combat
    assert.matches("en combat", table.concat(printed, "\n"))
    _G.InCombatLockdown = function() return false end
    _G.C_Map.OpenWorldMap = nil
    printed = {}
    ns.Window.OpenMap(1411)
    assert.matches("Impossible d'ouvrir la carte", table.concat(printed, "\n"))
    _G.C_Map.OpenWorldMap = function() error("ADDON_ACTION_BLOCKED") end
    printed = {}
    ns.Window.OpenMap(1411)
    assert.matches("bloqué", table.concat(printed, "\n"))
    _G.C_Map.OpenWorldMap = nil
  end)

  it("the Forever-only zones: Zephras Isle (1-12) and 2548 (38-42) per ForeverDB, the two others still level unknown", function()
    setup({ scanned = true })
    local ns = loadAddon()
    for _, id in ipairs({ 2482, 2652 }) do
      assert.is_not_nil(ns.Zones[id])
      assert.is_nil(ns.Zones[id][2])
    end
    assert.are.same({ "Zephras Isle", 1, 12, true }, ns.Zones[2521]); assert.are.same({ "?", 38, 42, "d" }, ns.Zones[2548])
    -- 2548 is a Forever zone: its range is ForeverDB's estimate, not a Classic one
    local derived = table.concat(ns.Window.RowTooltipLines({ name = "?", zone = 2548, spots = 3, detail = {} }), "\n")
    assert.matches("niveau 38%-42 %(estimation, non vérifiée%)", derived); assert.is_nil(derived:find("Classic", 1, true))
    -- a range no Forever source gives is shown as the Classic one, Zephras Isle's (Blizzard's own) as it is
    local classic = table.concat(ns.Window.RowTooltipLines({ name = "Les Tarides", zone = 1413, spots = 3, detail = {} }), "\n")
    assert.matches("niveau 10%-25 %(Classic, non vérifié%)", classic)
    local forever = table.concat(ns.Window.RowTooltipLines({ name = "Zephras", zone = 2521, spots = 3, detail = {} }), "\n")
    assert.matches("niveau 1%-12", forever); assert.is_nil(forever:find("Classic", 1, true))
    -- what a node gives: a fishing pool's fish is not in ForeverDB's gathering data and is said to be unverified, copper ore is not
    assert.is_true(ns.ForeverFixes.gatherDoubt[6358]); assert.is_nil(ns.ForeverFixes.gatherDoubt[2770])
    local nodes = ns.Window.RowTooltipLines({ name = "Les Tarides", zone = 1413, spots = 3, detail = { { item = 6358, unit = 10 }, { item = 2770, unit = 10 } } })
    local marked = 0
    for _, line in ipairs(nodes) do if line:find("(non vérifié sur Forever)", 1, true) then marked = marked + 1 end end
    assert.are.equal(1, marked)
    assert.are.same({ 2521, "Z" }, ns.MapIDs["Zephras Isle"])
  end)
end)

describe("fishing", function()
  it("ranks fishing zones from recorded pools, with the supposed skill when the character cannot fish", function()
    setup({ scanned = true, pools = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end, { profession = "Fishing" })
    assert.are.equal("ok", res.state)
    assert.is_true(res.fishing)
    assert.are.equal(1, #res.all)
    assert.are.equal(1411, res.all[1].zone)
    assert.are.equal(100, res.supposed) -- "if you learn Fishing": 5 x level 20
    -- 20 pools of item 6358 at 35c: 2 x 35 x 0.95 = 66.5 per pool; pace 60 x 20/100 = 12; 12 x 66.5 = 798c
    assert.is_near(798, res.all[1].copperPerHour, 1e-6)
    assert.matches("estimation", ns.S.per_hour:format("x"))
  end)

  it("says plainly that no pool is recorded, and that it is not an error", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end, { profession = "Fishing" })
    assert.are.equal("nofishing", res.state)
    local title, body = ns.StateText(res)
    assert.matches("Aucun banc enregistré", title)
    assert.matches("GatherMate les mémorise", body)
    assert.has_no.errors(function() ns.Window.Toggle() end)
  end)

  it("keeps Mining and Herbalism zones in the All ranking when the character only has Fishing (owner bug)", function()
    -- the character has Fishing (skill line 356) but no gathering profession: the old code ranked Fishing only,
    -- found no pool and answered "GatherMate has no data" while the Mining filter worked
    setup({ scanned = true, onlyFishing = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end)
    assert.are.equal("ok", res.state)
    assert.is_true(#res.all >= 2)            -- Durotar (Mining) and Elwynn (Mining + Herbalism)
    assert.are.equal(100, res.supposed)      -- "if you learn" mode: no Mining or Herbalism yet
    ns.Run(function(r) res = r end, { profession = "Mining" })
    assert.are.equal("ok", res.state)        -- the Mining filter worked before and still does
  end)

  it("includes fishing in the All ranking for a character that fishes and has no gathering profession", function()
    setup({ scanned = true, pools = true, fishingSkill = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end)
    assert.are.equal("ok", res.state)
    local zones = {}
    for _, row in ipairs(res.all) do zones[row.zone] = true end
    assert.is_true(zones[1411] and zones[1429])  -- pools and mining zones together
    assert.are.equal(100, res.supposed)
    setup({ scanned = true, pools = true, alchemy = true })
    ns = loadAddon()
    ns.db = {}
    ns.Run(function(r) res = r end)
    assert.are.equal("ok", res.state)   -- Alchemy only: supposed gathering skills, pools of Fishing included in "All"
    assert.are.equal(100, res.supposed)
  end)

  it("keeps Auctionator failures on the fishing filter as an error state", function()
    setup({ scanned = true, pools = true, aucFails = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end, { profession = "Fishing" })
    assert.are.equal("price_error", res.state)
  end)
end)

describe("saved data kept small", function()
  local function loaded(db)
    setup({ scanned = true })
    local ns = loadAddon()
    _G.GoldCompassDB = db
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.ADDON_LOADED then fr.scripts.OnEvent(fr, "ADDON_LOADED", "GoldCompass") end
    end
    return ns
  end

  it("forgets a vendor price not seen for 90 days, keeps the fresh ones, dates the undated ones from today", function()
    local today = math.floor(os.time() / 86400)
    local ns = loaded({ buy = { [1] = 10, [2] = 20, [3] = 30 }, buyDay = { [1] = today - 10, [2] = today - 91, [9] = today } })
    assert.are.equal(10, ns.db.buy[1])
    assert.is_nil(ns.db.buy[2])
    assert.is_nil(ns.db.buyDay[2])
    assert.are.equal(30, ns.db.buy[3])                                              -- an old save without days: counted from today
    assert.are.equal(today, ns.db.buyDay[3])
    assert.is_nil(ns.db.buyDay[9])                                                  -- a day without a price goes too
  end)

  it("a merchant window dates the prices it records", function()
    setup({ scanned = true })
    local ns = loadAddon()
    local buy, days = {}, {}
    ns.Learned.RecordMerchant({ count = function() return 1 end, item = function() return 5, 300, 10 end }, buy, days)
    assert.are.equal(30, buy[5])
    assert.are.equal(math.floor(os.time() / 86400), days[5])
  end)

  it("drops a profession entry with an empty name at load, for every character", function()
    local ns = loaded({ chars = { ["A-R"] = { learned = {}, profs = { [""] = { recipes = { [1] = {} } }, Cuisine = { recipes = {} } } },
      ["B-R"] = { learned = {}, profs = { [""] = { recipes = {} } } } } })
    assert.is_nil(ns.db.chars["A-R"].profs[""])
    assert.is_not_nil(ns.db.chars["A-R"].profs.Cuisine)
    assert.is_nil(ns.db.chars["B-R"].profs[""])
  end)
end)

describe("skill profiles for the All ranking", function()
  local function rank(opts)
    opts.scanned, opts.level = true, 16
    setup(opts)
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end)
    return res, ns
  end

  it("owner profile: Fishing 150, no Mining or Herbalism, level 16, data present -> ranked zones", function()
    local res, ns = rank({ profs = { { 356, 150 } } })
    assert.are.equal("ok", res.state)
    assert.are.equal(80, res.supposed) -- 5 x 16
    assert.are.same({ "Mining", "Herb Gathering" }, res.supposedTypes)
    local zones = {}
    for _, row in ipairs(res.all) do zones[row.zone] = true end
    assert.is_true(zones[1411] and zones[1429]) -- Mining zones and the Mining/Herbalism zone
    assert.are.equal("Si tu apprends Minage / Herboristerie (niveau de métier supposé : 80)", ns.SupposedText(res))
  end)

  it("Mining only: Herbalism is supposed, Mining uses the real skill", function()
    local res = rank({ profs = { { 186, 40 } } })
    assert.are.equal("ok", res.state)
    assert.are.same({ "Herb Gathering" }, res.supposedTypes)
    assert.are.equal(80, res.supposed)
    local spots = {}
    for _, row in ipairs(res.all) do spots[row.zone] = row.spots end
    assert.are.equal(100, spots[1429]) -- zone 1429 only has Herbalism spots: it is ranked because Herbalism is supposed
    assert.are.equal(100, spots[1411]) -- and Durotar's Mining spots use the real skill (Copper needs skill 1)
  end)

  it("all three professions: nothing is supposed", function()
    local res = rank({ profs = { { 186, 40 }, { 182, 30 }, { 356, 20 } }, pools = true })
    assert.are.equal("ok", res.state)
    assert.is_nil(res.supposed)
    assert.are.same({}, res.supposedTypes)
    local zones = {}
    for _, row in ipairs(res.all) do zones[row.zone] = true end
    assert.is_true(zones[1411] and zones[1429])
  end)
end)

describe("text safety and localized recipe names", function()
  -- Characters the game font cannot draw show as empty boxes. Allowed: Latin-1 (accents, middle dot, multiplication sign).
  it("has no character outside Latin-1 in any file that holds user-visible text", function()
    local bad = {}
    for _, name in ipairs({ "Strings", "Tooltip", "Window", "Here", "Format", "HowTo", "Where", "Log", "Core", "Advice", "Spike", "Learned", "Trainers", "Nodes", "Prices", "ZoneRank", "Bank", "Shopping", "ShoppingList", "BankEvents" }) do
      local f = assert(io.open(name .. ".lua", "rb"))
      local src = f:read("a")
      f:close()
      local line = 1
      for pos, cp in utf8.codes(src) do
        if cp == 10 then line = line + 1 end
        if cp > 0xFF then bad[#bad + 1] = ("%s.lua:%d U+%04X"):format(name, line, cp) end
      end
    end
    assert.are.same({}, bad)
  end)

  it("shows the recipe name from the game when it has one, with C_Spell or the older GetSpellInfo", function()
    setup({ scanned = true, alchemy = true })
    local ns = loadAddon()
    local recipe = { id = 2329, name = "Elixir of Minor Strength" }
    _G.C_Spell = { GetSpellName = function(id) return id == 2329 and "Élixir de force mineure" or nil end }
    assert.are.equal("Élixir de force mineure", ns.Fmt.RecipeName(recipe))
    _G.C_Spell = nil
    _G.GetSpellInfo = function() return "Élixir (ancien API)" end
    assert.are.equal("Élixir (ancien API)", ns.Fmt.RecipeName(recipe))
    _G.GetSpellInfo = function() return { name = "Élixir (table)" } end
    assert.are.equal("Élixir (table)", ns.Fmt.RecipeName(recipe))
    -- the tooltip uses it
    _G.C_Spell = { GetSpellName = function() return "Élixir de force mineure" end }
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    handlers.item(GameTooltip, { id = 2449 })
    assert.matches("Élixir de force mineure", table.concat(GameTooltip.lines, "\n"))
    _G.C_Spell, _G.GetSpellInfo = nil, nil
  end)

  it("falls back to the English name from the data when the game returns nothing", function()
    setup({ scanned = true, alchemy = true })
    local ns = loadAddon()
    local recipe = { id = 2329, name = "Elixir of Minor Strength" }
    assert.are.equal("Elixir of Minor Strength", ns.Fmt.RecipeName(recipe))           -- no API at all
    _G.C_Spell = { GetSpellName = function() return nil end }
    assert.are.equal("Elixir of Minor Strength", ns.Fmt.RecipeName(recipe))           -- not cached yet
    _G.C_Spell = { GetSpellName = function() return "" end }
    assert.are.equal("Elixir of Minor Strength", ns.Fmt.RecipeName(recipe))           -- empty answer
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    handlers.item(GameTooltip, { id = 2449 })
    assert.matches("Elixir of Minor Strength", table.concat(GameTooltip.lines, "\n"))
    _G.C_Spell = nil
  end)
end)
