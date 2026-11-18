-- Smoke test: loads every addon file in TOC order against a stubbed WoW API, with fake GatherMate2 and Auctionator,
-- and runs /gc map and the window. It proves the glue code runs; it proves nothing about the real game.
local printed, handlers, frames, timers

local function proxy()
  local p = { scripts = {} }
  return setmetatable(p, { __index = function(t, k)
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    return function(self, a, b)
      if k == "SetScript" then self.scripts[a] = b end
      if k == "RegisterEvent" then self.events = self.events or {}; self.events[a] = true end
      if k == "SetText" then self.text = a end
      if k:match("^Create") then return proxy() end
      return self
    end
  end })
end

local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  local loaded = {}
  _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
  _G.GoldCompassDB = nil
  _G.SlashCmdList = {}
  _G.UISpecialFrames = {}
  _G.tinsert = table.insert
  _G.UIParent = proxy()
  _G.CreateFrame = function() local p = proxy(); frames[#frames + 1] = p; return p end
  _G.C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
  _G.UnitName = function() return "Tester" end
  _G.GetRealmName = function() return "Realm" end
  _G.Item = { CreateFromItemID = function(_, id) return { ContinueOnItemLoad = function(_, cb) if not opts.neverLoads then loaded[id] = true; cb() end end } end }
  _G.GetItemInfo = function(id)
    if opts.lazyItems and not loaded[id] then return nil end
    return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, (not opts.noVendor) and 25 or nil
  end
  _G.C_Map = { GetMapInfo = function(id) return { name = "Zone" .. id } end,
    GetBestMapForUnit = function() return opts.zone or 1411 end }
  _G.UnitLevel = function() return opts.level or 20 end
  _G.GetProfessions, _G.GetProfessionInfo = nil, nil
  if opts.alchemy then
    _G.GetProfessions = function() return 1 end
    _G.GetProfessionInfo = function() return "Alchemy", nil, 50, nil, nil, nil, 171 end
  end
  if opts.fishingSkill then
    _G.GetProfessions = function() return 1, 2 end
    _G.GetProfessionInfo = function(i)
      if i == 1 then return "Alchemy", nil, 50, nil, nil, nil, 171 end
      return "Fishing", nil, 75, nil, nil, nil, 356
    end
  end
  _G.IsPlayerSpell = function(id) return not opts.noSpell and id == 2329 end -- Elixir of Minor Strength
  _G.UnitFactionGroup = function() return "Alliance" end
  _G.InCombatLockdown = function() return opts.combat or false end
  _G.IsShiftKeyDown = function() return false end
  _G.IsAddOnLoaded = function(name) return opts.ledger and name == "ForeverLedger" or false end
  _G.Enum = { TooltipDataType = { Item = 0 } }
  _G.C_Item = { GetItemCount = function() return 4 end, GetItemInfoInstant = function() return 0, "", "", "", 0, 7 end,
    GetItemQualityByID = function() return 1 end }
  _G.C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
    GetContainerItemInfo = function(_, slot)
      if opts.emptyBags then return nil end
      if opts.onlyHearth then return slot == 1 and { itemID = 6948, stackCount = 1, hasNoValue = true } or nil end
      return ({ { itemID = 2449, stackCount = 3, isBound = opts.bound }, { itemID = 2449, stackCount = 2, isBound = opts.bound }, { itemID = 2770, stackCount = 10, isBound = true }, { itemID = 6948, stackCount = 1, hasNoValue = true } })[slot]
    end,
  }
  _G.GameTooltip = { lines = {} }
  GameTooltip.AddLine = function(self, t) self.lines[#self.lines + 1] = t end
  GameTooltip.AddDoubleLine = function(self, l, r) self.lines[#self.lines + 1] = l .. " | " .. r end
  GameTooltip.IsShown = function() return true end
  GameTooltip.GetItem = function() if not opts.notItem then return "item" end end
  GameTooltip.refreshed = 0
  GameTooltip.RefreshData = function(self) self.refreshed = self.refreshed + 1 end
  _G.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) handlers.item = fn end }
  _G.time = os.time
  -- 100 Copper Veins (201) in zone 1411, 100 Peacebloom (401) in zone 1429; 3 spots of an unknown node
  local db = {
    Mining = { [1411] = {}, [1429] = {} }, ["Herb Gathering"] = { [1429] = {} }, Fishing = {},
  }
  if opts.pools then
    db.Fishing[1411] = {}
    for i = 1, 20 do db.Fishing[1411][i] = 107 end -- 20 Oily Blackmouth School spots in Durotar
  end
  for i = 1, 100 do db.Mining[1411][i] = 201; db["Herb Gathering"][1429][i] = 401 end
  db.Mining[1411][1000], db.Mining[1411][1001], db.Mining[1411][1002] = 99999, 99999, 99999
  _G.GatherMate2 = { GetNodesForZone = function(_, zone, t) return pairs(db[t][zone] or {}) end }
  _G.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id)
      if opts.aucFails then error("boom") end
      if opts.pickupNoAh and id ~= 2770 and id ~= 2447 then return nil end
      if opts.scanned then return id == 2770 and 40 or 35 end
    end,
    GetAuctionAgeByItemID = function() return 1 end,
    GetVendorPriceByItemID = function(_, id) if id == 3371 then return 40 end end,
  } } }
  if opts.noGM then _G.GatherMate2 = nil end
  if opts.noAuc then _G.Auctionator = nil end
end

local function loadAddon()
  local ns = {}
  for _, f in ipairs({ "Strings", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/QuestItems", "ZoneRank", "Advice", "Here", "Format",
    "Prices", "Nodes", "Core", "Learned", "Spike", "Tooltip", "Window" }) do
    assert(loadfile(f .. ".lua"))("GoldCompass", ns)
  end
  return ns
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
    _G.OpenWorldMap = function(zone) opened = zone end
    ns.Window.OpenMap(1411)
    assert.are.equal(1411, opened)
    printed = {}
    _G.InCombatLockdown = function() return true end
    ns.Window.OpenMap(1412)
    assert.are.equal(1411, opened)                        -- not called in combat
    assert.matches("en combat", table.concat(printed, "\n"))
    _G.InCombatLockdown = function() return false end
    _G.OpenWorldMap = nil
    printed = {}
    ns.Window.OpenMap(1411)
    assert.matches("Impossible d'ouvrir la carte", table.concat(printed, "\n"))
    _G.OpenWorldMap = function() error("ADDON_ACTION_BLOCKED") end
    printed = {}
    ns.Window.OpenMap(1411)
    assert.matches("bloqué", table.concat(printed, "\n"))
    _G.OpenWorldMap = nil
  end)

  it("marks the four Forever-only zones as level unknown", function()
    setup({ scanned = true })
    local ns = loadAddon()
    for _, id in ipairs({ 2482, 2521, 2548, 2652 }) do
      assert.is_not_nil(ns.Zones[id])
      assert.is_nil(ns.Zones[id][2])
    end
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

  it("includes fishing in the All ranking only for a character that fishes", function()
    setup({ scanned = true, pools = true, fishingSkill = true })
    local ns = loadAddon()
    ns.db = {}
    local res
    ns.Run(function(r) res = r end)
    assert.are.equal("ok", res.state)
    assert.are.equal(1411, res.all[1].zone)
    assert.is_nil(res.supposed) -- real Fishing skill 75
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
