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
  _G.Item = { CreateFromItemID = function() return { ContinueOnItemLoad = function(_, cb) if not opts.neverLoads then cb() end end } end }
  _G.GetItemInfo = function(id) return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, (not opts.noVendor) and 25 or nil end
  _G.C_Map = { GetMapInfo = function(id) return { name = "Zone" .. id } end,
    GetBestMapForUnit = function() return opts.zone or 1411 end }
  _G.UnitLevel = function() return 20 end
  _G.GetProfessions, _G.GetProfessionInfo = nil, nil
  if opts.alchemy then
    _G.GetProfessions = function() return 1 end
    _G.GetProfessionInfo = function() return "Alchemy", nil, 50, nil, nil, nil, 171 end
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
    Mining = { [1411] = {}, [1429] = {} }, ["Herb Gathering"] = { [1429] = {} },
  }
  for i = 1, 100 do db.Mining[1411][i] = 201; db["Herb Gathering"][1429][i] = 401 end
  db.Mining[1411][1000], db.Mining[1411][1001], db.Mining[1411][1002] = 99999, 99999, 99999
  _G.GatherMate2 = { GetNodesForZone = function(_, zone, t) return pairs(db[t][zone] or {}) end }
  _G.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id)
      if opts.aucFails then error("boom") end
      if opts.scanned then return id == 2770 and 40 or 35 end
    end,
    GetAuctionAgeByItemID = function() return 1 end,
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
    local rows = { { zone = 1411 }, { zone = 1449 }, { zone = 1 } }
    assert.are.equal(2, #ns.VisibleZones(rows, true))
    assert.are.equal(3, #ns.VisibleZones(rows, false))
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

  it("never prints 0 as a price", function()
    setup({ scanned = true })
    local ns = loadAddon()
    assert.are.equal("prix inconnu", ns.Money(0))
    assert.are.equal("prix inconnu", ns.Money(nil))
    assert.are.equal("5s", ns.Money(500))
  end)
end)
