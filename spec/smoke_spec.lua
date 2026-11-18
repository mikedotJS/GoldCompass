-- Smoke test: loads every addon file in TOC order against a stubbed WoW API, with fake GatherMate2 and Auctionator,
-- and runs /gc map and the window. It proves the glue code runs; it proves nothing about the real game.
local printed, handlers, frames, timers

local function proxy()
  local p = { scripts = {} }
  return setmetatable(p, { __index = function(t, k)
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    return function(self, a, b, c, d)
      if k == "SetScript" then self.scripts[a] = b end
      if k == "CreateTexture" or k == "CreateFontString" then
        local child = proxy()
        child.layer, child.sublevel, child.kind = b, d or 0, k
        self.children = self.children or {}
        self.children[#self.children + 1] = child
        return child
      end
      if k == "RegisterEvent" then self.events = self.events or {}; self.events[a] = true end
      if k == "SetText" then self.text = a end
      if k == "Show" then self.shown = true end
      if k == "Hide" then self.shown = false end
      if k == "SetShown" then self.shown = a and true or false end
      if k == "IsShown" then return self.shown == true end
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
  UIParent.GetWidth = function() return opts.screenW or 1366 end
  UIParent.GetHeight = function() return opts.screenH or 768 end
  _G.CreateFrame = function() local p = proxy(); frames[#frames + 1] = p; return p end
  _G.C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
  _G.date = os.date
  _G.debugstack = function() return "stack line 1\nstack line 2" end
  _G.GetBuildInfo = function() return "1.60.1", "70938", "Nov 14 2026", 16001 end
  _G.errorHandler = function() end
  _G.geterrorhandler = function() return _G.errorHandler end
  _G.seterrorhandler = function(fn) _G.errorHandler = fn end
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
  if opts.profs then -- { { skillLine, skill }, ... } in slot order
    _G.GetProfessions = function() local t = {}; for i = 1, #opts.profs do t[i] = i end; return table.unpack(t) end
    _G.GetProfessionInfo = function(i) local p = opts.profs[i]; return "Prof", nil, p[2], nil, nil, nil, p[1] end
  end
  if opts.onlyFishing then
    _G.GetProfessions = function() return nil, nil, nil, 1 end
    _G.GetProfessionInfo = function() return "Fishing", nil, 30, nil, nil, nil, 356 end
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
  GameTooltip.GetItem = function() if not opts.notItem then return "Name", opts.hoverLink or "|cffffffff|Hitem:2449::::::::|h[x]|h|r" end end
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
  for _, f in ipairs({ "Strings", "Log", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/QuestItems", "ZoneRank", "Advice", "Here", "Format",
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

describe("diagnostic log", function()
  local function fire(event, ...)
    for _, fr in ipairs(frames) do
      if fr.events and fr.events[event] then fr.scripts.OnEvent(fr, event, ...) end
    end
  end
  local function start(opts)
    setup(opts or {})
    local ns = loadAddon()
    fire("ADDON_LOADED", "GoldCompass")
    return ns
  end

  it("keeps at most 300 entries and drops the oldest", function()
    local ns = start()
    for i = 1, 350 do ns.Log("test", "entry " .. i) end
    assert.are.equal(300, #ns.db.log)
    assert.are.equal("entry 51", ns.db.log[1].text)
    assert.are.equal("entry 350", ns.db.log[300].text)
    assert.matches("^%d%d:%d%d:%d%d$", ns.db.log[1].time)
  end)

  it("logs what was printed before the saved variables existed, without color codes", function()
    setup({})
    local ns = loadAddon()
    ns.Print("avant le chargement")
    fire("ADDON_LOADED", "GoldCompass")
    local found
    for _, e in ipairs(ns.db.log) do
      if e.kind == "chat" and e.text:find("avant le chargement", 1, true) then found = e end
    end
    assert.is_not_nil(found)
    assert.is_nil(found.text:find("|c", 1, true))
  end)

  it("routes the spike and map output through the log", function()
    local ns = start({ scanned = true })
    SlashCmdList["GOLDCOMPASS"]("spike")
    SlashCmdList["GOLDCOMPASS"]("map")
    local kinds = {}
    for _, e in ipairs(ns.db.log) do kinds[e.text:match("^%[spike%]") and "spike" or e.kind] = true end
    assert.is_true(kinds.chat)
    local spike = false
    for _, e in ipairs(ns.db.log) do spike = spike or e.text:find("[spike] S2", 1, true) ~= nil end
    assert.is_true(spike)
  end)

  it("chains the error handler: ours logs, the previous one is still called with the message", function()
    setup({})
    local received
    _G.errorHandler = function(m) received = m; return "prev-result" end
    local ns = loadAddon()
    fire("ADDON_LOADED", "GoldCompass")
    fire("PLAYER_LOGIN")
    assert.are_not.equal(_G.errorHandler, nil)
    local result = _G.errorHandler("Interface\\AddOns\\Other\\x.lua:1: boom")
    assert.are.equal("Interface\\AddOns\\Other\\x.lua:1: boom", received)
    assert.are.equal("prev-result", result)
    local last = ns.db.log[#ns.db.log]
    assert.are.equal("lua-error", last.kind)
    assert.matches("boom", last.text)
    -- installing twice does not stack a second wrapper
    local handler = _G.errorHandler
    ns.LogChainErrorHandler()
    assert.are.equal(handler, _G.errorHandler)
  end)

  it("writes the login header with the client build, the TOC and the addon versions", function()
    setup({})
    _G.C_AddOns = { GetAddOnMetadata = function(name, field)
      return ({ ["GoldCompass:X-TocFile"] = "plain", ["GoldCompass:Version"] = "0.1.0", ["GatherMate2:Version"] = "1.52.7", ["Auctionator:Version"] = "347" })[name .. ":" .. field] end }
    local ns = loadAddon()
    fire("ADDON_LOADED", "GoldCompass")
    fire("PLAYER_LOGIN")
    local h
    for _, e in ipairs(ns.db.log) do if e.kind == "login" then h = e.text end end
    assert.matches("build 70938", h)
    assert.matches("TOC used: plain", h)
    assert.matches("GatherMate2 1.52.7", h)
    assert.matches("Auctionator 347", h)
    _G.C_AddOns = nil
  end)

  it("logs blocked and forbidden actions with the addon, the function and a short stack", function()
    local ns = start()
    fire("ADDON_ACTION_BLOCKED", "Auctionator", "C_AuctionHouse.PostItem")
    fire("ADDON_ACTION_FORBIDDEN", "Other", "UseAction")
    local blocked, forbidden = ns.db.log[#ns.db.log - 1], ns.db.log[#ns.db.log]
    assert.are.equal("blocked", blocked.kind)
    assert.matches("Auctionator", blocked.text)
    assert.matches("C_AuctionHouse.PostItem", blocked.text)
    assert.matches("stack line 1 < stack line 2", blocked.text)
    assert.are.equal("forbidden", forbidden.kind)
  end)

  it("prints the last 20 entries with /gc log and empties the log with /gc log clear", function()
    local ns = start()
    for i = 1, 30 do ns.Log("test", "line " .. i) end
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("log")
    local text = table.concat(printed, "\n")
    assert.matches("line 30", text)
    assert.matches("line 11", text)
    assert.is_nil(text:find("line 10\n", 1, true))   -- only the last 20
    local before = #ns.db.log
    SlashCmdList["GOLDCOMPASS"]("log") -- showing the log does not add to it
    assert.are.equal(before, #ns.db.log)
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("log clear")
    assert.are.equal(0, #ns.db.log)
    assert.matches("journal vidé", table.concat(printed, "\n"))
  end)

  it("never raises and never recurses when logging itself fails", function()
    local ns = start()
    local calls = 0
    local received
    _G.errorHandler = function(m) received = m end
    ns.db = ns.db -- keep the saved table
    fire("PLAYER_LOGIN")
    -- logging fails (date raises) and, while it runs, an error reaches the handler: no recursion, previous handler called
    _G.date = function()
      calls = calls + 1
      if calls == 1 then _G.errorHandler("inner error") end
      error("date broke")
    end
    assert.has_no.errors(function() ns.Log("test", "x") end)
    assert.has_no.errors(function() _G.errorHandler("later error") end)
    assert.are.equal("later error", received)
    assert.is_true(calls < 10)
    -- the log works again afterwards
    _G.date = os.date
    ns.Log("test", "back")
    assert.are.equal("back", ns.db.log[#ns.db.log].text)
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

describe("window layout and drawing", function()
  local ORDER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
  local function overlap(a, b) return a.l < b.r and b.l < a.r and a.t < b.b and b.t < a.b end

  local function assertNoOverlap(groups, L)
    local all = {}
    for _, g in ipairs(groups) do
      for name, r in pairs(g) do
        assert.is_true(r.l >= L.frame.l and r.t >= L.frame.t and r.r <= L.frame.r and r.b <= L.frame.b, name .. " leaves the frame")
        all[#all + 1] = { name = name, r = r }
      end
    end
    for i = 1, #all do
      for j = i + 1, #all do
        assert.is_false(overlap(all[i].r, all[j].r), all[i].name .. " overlaps " .. all[j].name)
      end
    end
  end

  it("keeps every slot inside the frame and never over another, for each group that can be visible together", function()
    setup({})
    local L = loadAddon().Window.Layout
    assert.is_true(L.frame.r <= 460 and L.frame.b <= 520) -- about 460 wide, at most about 520 tall
    local controls = { levelBox = L.map.levelBox, profBtn = L.map.profBtn, toMap = L.map.toMap, note = L.map.note }
    assertNoOverlap({ L.common, L.map }, L)
    assertNoOverlap({ L.common, L.list }, L)
    assertNoOverlap({ L.common, L.panel, controls }, L)
  end)

  it("keeps the parts of a row and of a list line apart and inside their slot", function()
    setup({})
    local W = loadAddon().Window
    local row = { l = 0, t = 0, r = 432, b = 30 }
    assertNoOverlap({ W.RowParts }, { frame = row })
    assertNoOverlap({ W.LineParts }, { frame = { l = 0, t = 0, r = 432, b = 17 } })
  end)

  it("fits the frame on screen whatever the UI scale makes of UIParent's size", function()
    setup({})
    local W = loadAddon().Window
    for _, size in ipairs({ { 1366, 768 }, { 1138, 640 }, { 1707, 960 }, { 800, 480 }, { 640, 400 } }) do
      -- UI scale 1.0, 1.2 and 0.8 on a 768 high screen give 768, 640 and 960; the smaller ones are small screens
      local s = W.FitScale(size[1], size[2])
      assert.is_true(s <= 1)
      assert.is_true(500 * s <= size[2] * 0.9 + 1e-9, "taller than the screen at " .. size[2])
      assert.is_true(460 * s <= size[1] * 0.9 + 1e-9)
    end
    assert.are.equal(1, W.FitScale(1366, 768))
  end)

  it("draws row decorations (selection, hover, bar) below every font string of the row", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    ns.Window.Toggle()
    local rows = ns.Window.Rows()
    assert.are.equal(10, #rows)
    for _, row in ipairs(rows) do
      local textRank
      for _, child in ipairs(row.children) do
        if child.kind == "CreateFontString" then
          assert.are.equal("OVERLAY", child.layer)
          textRank = ORDER[child.layer]
        end
      end
      assert.is_not_nil(textRank)
      for _, tex in ipairs({ row.sel, row.hover, row.bar }) do
        assert.is_true(ORDER[tex.layer] < textRank, "decoration layer " .. tostring(tex.layer) .. " is not below the text")
      end
      assert.is_true(ORDER[row.hover.layer] < ORDER["HIGHLIGHT"]) -- not the HIGHLIGHT layer, which draws over the text
    end
  end)

  it("shows a clean figure and a separate price freshness, and builds the details tooltip", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    ns.Window.Toggle()
    local row = ns.Window.Rows()[1]
    assert.matches("^~%d+s/h", row.gph.text)
    assert.matches("%(estimation%)", row.gph.text)
    assert.is_nil(row.gph.text:find("prix", 1, true))
    assert.matches("prix", row.age.text)
    assert.are.equal("prix d'aujourd'hui", ns.PriceAgeText(0))
    assert.are.equal("prix de 3 j", ns.PriceAgeText(3))
    assert.are.equal("âge du prix inconnu", ns.PriceAgeText(nil))
    local tip = table.concat(ns.Window.RowTooltipLines({ zone = 1411, name = "Durotar", spots = 100, maxAge = 1,
      detail = { { item = 2770, unit = 38 } } }), "\n")
    assert.matches("Durotar", tip)
    assert.matches("Item2770 : ~", tip)
    assert.matches("prix de 1 j", tip)
    assert.matches("60 points de récolte par heure, 2 objets chacun, taxe HV de 5 %%.", tip)
  end)
end)

describe("text safety and localized recipe names", function()
  -- Characters the game font cannot draw show as empty boxes. Allowed: Latin-1 (accents, middle dot, multiplication sign).
  it("has no character outside Latin-1 in any file that holds user-visible text", function()
    local bad = {}
    for _, name in ipairs({ "Strings", "Tooltip", "Window", "Here", "Format", "Log", "Core", "Advice", "Spike", "Learned", "Nodes", "Prices", "ZoneRank" }) do
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

describe("coins, tooltip rows and spell data loading", function()
  it("formats every amount through one function: coin icons when the game has them, plain text otherwise", function()
    setup({ scanned = true })
    local ns = loadAddon()
    assert.are.equal("1g 24s", ns.Money(12449))                    -- no coin API: the plain formatter
    _G.GetCoinTextureString = function(c) return "[global " .. c .. "]" end
    assert.are.equal("[global 12400]", ns.Money(12449))            -- rounded to the silver, then icons
    _G.C_CurrencyInfo = { GetCoinTextureString = function(c) return "[currency " .. c .. "]" end }
    assert.are.equal("[currency 1230000]", ns.Money(1234567))      -- 123.4567g -> 123g
    assert.are.equal("[currency 40]", ns.Money(40))                -- under 1s: exact copper
    assert.are.equal("prix inconnu", ns.Money(0))
    _G.C_CurrencyInfo, _G.GetCoinTextureString = nil, nil
  end)

  it("uses coin icons in the per-hour figure and keeps it inside its slot", function()
    setup({ scanned = true })
    _G.GetCoinTextureString = function(c) return "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" .. c end
    local ns = loadAddon()
    ns.db = {}
    ns.Window.Toggle()
    assert.matches("^~.*UI%-SilverIcon.*/h", ns.Window.Rows()[1].gph.text)
    -- the figure slot is wide enough for icons: at least 180 px, and still clear of the zone and bar slots
    local P = ns.Window.RowParts
    assert.is_true(P.gph.r - P.gph.l >= 180)
    assert.is_true(P.zone.r <= P.gph.l and P.sub.r <= P.gph.l)
    _G.GetCoinTextureString = nil
  end)

  it("puts each recipe and its result price on one row, the status on the line below", function()
    setup({ scanned = true, alchemy = true, noSpell = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local doubles, singles = {}, {}
    GameTooltip.AddDoubleLine = function(_, l, r) doubles[#doubles + 1] = { l, r }; GameTooltip.lines[#GameTooltip.lines + 1] = l .. " | " .. r end
    GameTooltip.AddLine = function(_, t) singles[#singles + 1] = t; GameTooltip.lines[#GameTooltip.lines + 1] = t end
    handlers.item(GameTooltip, { id = 2449 })
    local recipeRows = 0
    for _, d in ipairs(doubles) do
      if d[1]:find("Elixir", 1, true) then
        recipeRows = recipeRows + 1
        assert.is_nil(d[1]:find("apprendre", 1, true)) -- no status in the left text
        assert.is_nil(d[1]:find("  ", 1, true))
      end
    end
    assert.is_true(recipeRows >= 1)
    local status = false
    for _, t in ipairs(singles) do status = status or t:find("^  .*apprendre") ~= nil end
    assert.is_true(status)
  end)

  it("asks for spell data once, keeps the English name meanwhile, and redraws on arrival for the same item only", function()
    setup({ scanned = true, alchemy = true, noSpell = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local loaded, requests = {}, {}
    _G.C_Spell = {
      GetSpellName = function(id) return loaded[id] and ("Nom FR " .. id) or nil end,
      RequestLoadSpellData = function(id) requests[#requests + 1] = id end,
    }
    handlers.item(GameTooltip, { id = 2449 })
    local first = table.concat(GameTooltip.lines, "\n")
    assert.matches("Elixir of Minor Fortitude", first)         -- English fallback while the name is not cached
    local n = #requests
    assert.is_true(n >= 1)
    GameTooltip.lines = {}
    handlers.item(GameTooltip, { id = 2449 })
    assert.are.equal(n, #requests)                             -- once per spell, not per hover
    local function fire(event, id)
      for _, fr in ipairs(frames) do
        if fr.events and fr.events[event] then fr.scripts.OnEvent(fr, event, id) end
      end
    end
    local id = requests[1]
    loaded[id] = true
    fire("SPELL_DATA_LOAD_RESULT", id)
    assert.are.equal(1, GameTooltip.refreshed)                 -- the data arrived: redraw once
    fire("SPELL_DATA_LOAD_RESULT", id)
    assert.are.equal(1, GameTooltip.refreshed)                 -- not twice for the same spell
    GameTooltip.lines = {}
    handlers.item(GameTooltip, { id = 2449 })
    assert.matches("Nom FR " .. id, table.concat(GameTooltip.lines, "\n"))
    -- another item under the mouse: no redraw
    GameTooltip.lines = {}
    handlers.item(GameTooltip, { id = 2449 })
    local other = requests[#requests]
    _G.GetItemInfo = _G.GetItemInfo
    local shown = GameTooltip.refreshed
    GameTooltip.GetItem = function() return "Name", "|Hitem:9999::::|h[y]|h" end
    loaded[other] = true
    fire("SPELL_DATA_LOAD_RESULT", other)
    assert.are.equal(shown, GameTooltip.refreshed)
    _G.C_Spell = nil
  end)

  it("does not redraw for spell data in combat", function()
    setup({ scanned = true, alchemy = true, noSpell = true, combat = true })
    loadAddon()
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.SPELL_DATA_LOAD_RESULT then fr.scripts.OnEvent(fr, "SPELL_DATA_LOAD_RESULT", 1) end
    end
    assert.are.equal(0, GameTooltip.refreshed)
  end)
end)
