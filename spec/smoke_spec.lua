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
      if k == "RegisterEvent" or k == "RegisterUnitEvent" then self.events = self.events or {}; self.events[a] = true end
      if k == "SetText" then self.text = a end
      if k == "SetWidth" then self.width = a end
      if k == "Show" then self.shown = true end
      if k == "Hide" then self.shown = false end
      if k == "SetShown" then self.shown = a and true or false end
      if k == "IsShown" then return self.shown == true end
      if k == "SetVerticalScroll" then self.vscroll = a end
      if k == "GetVerticalScroll" then return self.vscroll or 0 end
      if k == "GetVerticalScrollRange" then return self.vrange or 0 end
      if k == "SetSize" then self.size = { a, b } end
      if k:match("^Create") then return proxy() end
      return self
    end
  end })
end


-- A stand-in for ns.ForeverDB (the vendored data accessor) built from Data/Recipes.lua, used by the "recipes to learn" tests
-- with opts.stubLib: the learn skill becomes requiredSkill, the Classic source becomes the source kinds.
local LINE = { [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering", [165] = "Leatherworking",
  [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [186] = "Mining", [356] = "Fishing", [182] = "Herbalism", [393] = "Skinning" }
local function libStub(opts)
  local data = {}
  assert(loadfile("Data/Recipes.lua"))("GoldCompass", data)
  local byProf, rowById = {}, {}
  for _, r in ipairs(data.RecipeRows) do
    local e = { name = r[8], craftedItemId = r[4], reagents = {}, teaches = r[1], requiredSkill = (opts.libOverrides and opts.libOverrides.skill and opts.libOverrides.skill[r[1]]) or r[11],
      difficulty = { r[11] or 1, r[12] or ((r[11] or 1) + 30), r[13] or ((r[11] or 1) + 45), r[14] or ((r[11] or 1) + 60) } }
    for mat, n in r[9]:gmatch("(%d+):(%d+)") do e.reagents[tonumber(mat)] = tonumber(n) end
    byProf[r[2]] = byProf[r[2]] or {}
    byProf[r[2]][r[1]] = e
    rowById[r[1]] = r
  end
  local DB = { overrides = opts.libOverrides or {} }
  function DB:BelongsTo(line, id)
    if byProf[LINE[line]] and byProf[LINE[line]][id] then return true end
    for _, recipes in pairs(byProf) do if recipes[id] then return false end end
  end
  function DB:IsReady() return true end
  function DB:GetVersion() return "v1.10.1", "1.60.1.70938" end
  function DB:HasProfession(id) return LINE[id] ~= nil end
  function DB:GetRecipes(id) return byProf[LINE[id]] or {} end
  function DB:IsHiddenRecipe(id) return self.overrides.hidden and self.overrides.hidden[id] or false end
  function DB:IsAutoTaughtRecipe(id) return self.overrides.auto and self.overrides.auto[id] or false end
  function DB:IsBorrowed(id, field) return self.overrides.borrowed and self.overrides.borrowed[id .. field] or nil end
  function DB:GetRecipeItem(id) return self.overrides.items and self.overrides.items[id] or nil end
  function DB:GetSourceFaction() return nil end
  function DB:GetRecipeSources(id)
    if self.overrides.sources and self.overrides.sources[id] ~= nil then return self.overrides.sources[id] or nil end
    local r = rowById[id]
    if not r or not r[11] then return nil end
    local kind = ({ v = "vendor", q = "quest", m = "drop", d = "drop" })[r[10] or ""] or "trainer"
    return { [kind] = { { id = 1, name = "Some NPC" }, total = 1 } }
  end
  function DB:Count() return 2516 end
  function DB:GetGameVersion() return "Forever" end
  function DB:ProfessionCount(id) local n = 0; for _ in pairs(byProf[LINE[id]] or {}) do n = n + 1 end; return n end
  return DB
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
  _G.stubDB = opts.stubLib and libStub(opts) or nil
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
    _G.GetProfessionInfo = function(i) local p = opts.profs[i]; return p[3] or "Prof", nil, p[2], p[4], nil, nil, p[1] end
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
  _G.UnitFactionGroup = function() return opts.faction or "Alliance" end
  _G.InCombatLockdown = function() return opts.combat or false end
  _G.IsShiftKeyDown = function() return false end
  _G.IsAddOnLoaded = function(name) return opts.ledger and name == "ForeverLedger" or false end
  _G.Enum = { TooltipDataType = { Item = 0 } }
  _G.C_Item = { GetItemCount = function(id) if opts.counts then return opts.counts[id] or 0 end return 4 end, GetItemInfoInstant = function() return 0, "", "", "", 0, 7 end,
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
  for _, f in ipairs({ "Strings", "Log", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/Locations", "Data/ForeverTrainers", "Data/ForeverRecipes", "Data/Npcs", "Data/ForeverNpcs", "Data/ForeverFixes", "Data/QuestItems", "ZoneRank", "Advice", "Here", "ForeverDB", "Leveling", "Where", "Format", "HowTo",
    "Prices", "Nodes", "Core", "Learned", "Trainers", "Spike", "Tooltip", "Window" }) do
    assert(loadfile(f .. ".lua"))("GoldCompass", ns)
  end
  if _G.stubDB then ns.ForeverDB = _G.stubDB end
  -- The older Métier tests describe the bag filter, the learn lists and the gold figures, which now belong to "Gagner de l'or": unless a test
  -- asks for the roadmap with goal = "level", the tab runs in that mode.
  ns.RealGoal = ns.Goal
  ns.Goal = function() return ns.char and ns.char.goal == "level" and "level" or "gold" end
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
    assertNoOverlap({ L.common, L.job }, L)             -- Métier tab: checkbox, "Voir sans filtre" and the scroll area
    assertNoOverlap({ L.common, L.panel, controls }, L)
  end)

  it("keeps the lines and the scroll bar inside the scroll slot", function()
    setup({})
    local W = loadAddon().Window
    for _, slot in ipairs({ W.Layout.list.lines, W.Layout.job.lines }) do
      assert.is_true(W.LineWide.r + 20 <= slot.r - slot.l)       -- 20 px left for the scroll bar
      assert.is_true(W.LineParts.right.r <= W.LineWide.r)
    end
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
    for _, name in ipairs({ "Strings", "Tooltip", "Window", "Here", "Format", "HowTo", "Where", "Log", "Core", "Advice", "Spike", "Learned", "Trainers", "Nodes", "Prices", "ZoneRank" }) do
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
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } }, pickupNoAh = true })
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

describe("recipes to learn without prices, footer and line slots", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local function start(opts)
    opts.scanned, opts.profs = true, { { 171, 50, "Alchimie", 75 } }
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy } }
    return ns
  end

  it("shows recipes to learn with 'prix inconnu' and the way to get prices, instead of dropping them", function()
    local ns = start({ pickupNoAh = true, noVendor = true })   -- no AH price, no vendor value for most reagents
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    assert.is_true(lr.unpriced > 0)
    assert.is_true(#lr.now + #lr.soon > 0)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("prix inconnu", text)
    assert.matches("lance un scan Auctionator", text)
    assert.is_nil(text:match("sans prix pour leurs composants"))
  end)

  it("values reagents without AH price at their vendor sell value (a floor), and levelling shows ingredients, not a gold figure", function()
    local ns = start({ pickupNoAh = true })                    -- vendor sell value 25 for every item
    ns.char.goal = "level"
    local res
    ns.RunLeveling(function(r) res = r end)
    local found
    for _, e in ipairs(res.profs[1].learn.now) do if e.floor then found = true end end
    assert.is_true(found)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.is_nil(lineTexts(ns):find("dès ~", 1, true))          -- levelling: no gold figure, no per-point figure
    assert.is_nil(lineTexts(ns):find("ingr%./pt"))
    assert.matches("Ton parcours", lineTexts(ns))
  end)

  it("keeps the footer within two lines of the footer slot (character budget), with and without the bag filter", function()
    -- the slot shows about 83 characters per line at the real font (photo): two lines = at most 160 here
    local ns = start({})
    assert.is_true(#ns.Window.JobFooter(false) <= 160)
    assert.is_true(#ns.Window.JobFooter(true) <= 160)
  end)

  it("draws every line of the tab on its own single-line slot: no wrapping text, no shared slot", function()
    local ns = start({ counts = { [2447] = 1 } })
    ns.char.onlyBag = true
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local slots = ns.Window.Layout.list.lines
    local used = 0
    for _, l in ipairs(ns.Window.Lines()) do
      local t = (l.left.text or "")
      assert.is_nil(t:find("\n"))                              -- a line never contains a line break
      if t ~= "" then used = used + 1 end
    end
    assert.is_true(used > 0)
    assert.is_true(used <= math.floor((slots.b - slots.t) / 17))
  end)
end)

describe("empty states of the recipes to learn say the real reason", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local function show(learn, filtered)
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, onlyBag = filtered, profs = { Alchimie = { skill = 50, max = 75, recipes = {
      [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } } } }
    ns.LearnFor = function() return learn end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return lineTexts(ns)
  end
  local function lr(t) return setmetatable(t, { __index = { now = {}, soon = {}, candidates = 0, unpriced = 0, nowTotal = 0, soonTotal = 0 } }) end

  it("nothing to learn", function()
    assert.matches("Aucune recette à apprendre pour ce métier", show(lr({})))
  end)
  it("everything in reach is gray", function()
    local grayRow = { gray = true, name = "Potion grise", chance = 0, rec = { id = 5, name = "Potion grise", learn = 10, d = 3 } }
    local text = show(lr({ nowTotal = 4, gray = { grayRow } }))
    assert.matches("ne font plus monter le métier", text)
    assert.matches("Déjà grises à ton niveau", text)             -- the gray recipes are listed, never ranked
    assert.matches("Potion grise", text)
    assert.is_nil(text:match("Aucune recette à apprendre"))
  end)
  it("hidden by the bag filter", function()
    local text = show(lr({ nowTotal = 4, candidates = 2 }), true)
    assert.matches("cache les recettes à apprendre", text)
    assert.is_nil(text:match("Aucune recette à apprendre"))
  end)
end)

describe("scrollable lists (bags, here, Métier)", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local function filled(ns)
    local n = 0
    for _, l in ipairs(ns.Window.Lines()) do if (l.left.text or "") ~= "" or (l.right.text or "") ~= "" then n = n + 1 end end
    return n
  end
  -- 30 known recipes, so the tab has far more rows than the 19 lines that used to fit
  local function big()
    local recipes = {}
    for i = 1, 30 do recipes[i] = { id = i, name = "Recette " .. i, d = 0, out = 118, oq = 1, mats = { { 2447, i } } } end
    return { skill = 50, max = 75, recipes = recipes }
  end
  local function start(data)
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = data }, goal = "level" }
    ns.Window.recipesOpen = true                                       -- the known-recipes list is the long one
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end

  it("produces every row (no cap, no 'et N autres') and the scroll content grows with them", function()
    local few = start({ skill = 50, max = 75, recipes = { [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } })
    local fewHeight, fewRows = few.Window.ContentHeight(), filled(few)
    local ns = start(big())
    assert.is_true(filled(ns) > 19)                                   -- more than the old fixed pool
    assert.is_true(ns.Window.ContentHeight() > fewHeight)
    assert.are.equal(filled(ns) * 17, ns.Window.ContentHeight())      -- one 17 px line per row
    assert.are.equal(fewRows * 17, fewHeight)
    assert.is_nil(lineTexts(ns):find("autres", 1, true))
    for i = 1, 30 do assert.matches("Recette " .. i .. " ", lineTexts(ns) .. " ") end -- every known recipe is listed
    assert.matches("Recettes connues", lineTexts(ns))
  end)

  it("recycles lines: shrinking the list empties the leftover lines completely", function()
    local ns = start(big())
    local many = #ns.Window.Lines()
    ns.char.profs.Alchimie = { skill = 50, max = 75, recipes = { [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
    ns.Window.recipesOpen = false
    ns.Window.Refresh()
    local lines = ns.Window.Lines()
    assert.are.equal(many, #lines)                                    -- lines are kept, not destroyed
    local used = filled(ns)
    assert.is_true(used < many)
    for i = used + 1, #lines do
      assert.are.equal("", lines[i].left.text); assert.are.equal("", lines[i].right.text)
    end
  end)

  it("scrolls with the mouse wheel, three lines a notch, clamped to the content", function()
    local ns = start(big())
    local frame
    for _, fr in ipairs(frames) do if fr.scripts.OnMouseWheel then frame = fr end end
    assert.is_not_nil(frame)
    frame.vrange = 100
    frame.scripts.OnMouseWheel(frame, -1)
    assert.are.equal(51, frame.vscroll)                               -- 3 x 17
    frame.scripts.OnMouseWheel(frame, -1); frame.scripts.OnMouseWheel(frame, -1)
    assert.are.equal(100, frame.vscroll)                              -- clamped to the range
    frame.scripts.OnMouseWheel(frame, 1)
    assert.are.equal(49, frame.vscroll)
    frame.vscroll = 0
    frame.scripts.OnMouseWheel(frame, 1)
    assert.are.equal(0, frame.vscroll)                                -- never above the top
  end)

  it("uses the classic scroll template, and a plain scroll frame when the template is missing", function()
    local ns = start(big())
    assert.are.equal("UIPanelScrollFrameTemplate", ns.Window.ScrollKind())
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local base = _G.CreateFrame
    _G.CreateFrame = function(kind, name, parent, template)
      if template == "UIPanelScrollFrameTemplate" then error("no such template") end
      return base(kind, name, parent, template)
    end
    ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = big() } }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.are.equal("plain ScrollFrame", ns.Window.ScrollKind())
    assert.is_true(filled(ns) > 19)
    local logged = {}
    for _, e in ipairs(ns.LogRecent(50)) do logged[#logged + 1] = e.text end
    assert.matches("scroll frame: plain ScrollFrame", table.concat(logged, "\n"))
  end)
end)

describe("Où l'apprendre (map button on recipes to learn)", function()
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local function start()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy } }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end
  local function goButtons()
    local out = {}
    for _, fr in ipairs(frames) do if fr.target and fr.shown then out[#out + 1] = fr end end
    return out
  end
  local pin = { name = "Mallory", zone = "Elwynn Forest", mapID = 1429, x = 32.8, y = 49 }

  it("puts a button with a target on rows to learn (and on the best one), nothing on the other rows", function()
    local ns = start()
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    assert.is_true(#lr.now > 0)
    for _, row in ipairs(lr.now) do assert.is_table(row.target) end
    local buttons = goButtons()
    assert.is_true(#buttons >= #lr.now)                      -- best line + rows (+ soon rows)
    local pins = 0
    for _, b in ipairs(buttons) do if b.target.mapID then pins = pins + 1 end end
    assert.is_true(pins > 0)
    -- a recycled line shows no button when its new content has no target
    ns.char.onlyBag = true
    _G.C_Item.GetItemCount = function() return 0 end
    ns.Window.Refresh()
    assert.are.equal(0, #goButtons())                         -- bag filter on, nothing carried: no learn rows left
  end)

  it("pins the NPC with a user waypoint, super tracks it and opens the map (out of combat)", function()
    local ns = start()
    local calls = {}
    _G.UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
    _G.C_Map.SetUserWaypoint = function(p) calls.pin = p end
    _G.C_Map.OpenWorldMap = function(id) calls.open = id end
    _G.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(on) calls.track = on end }
    ns.Window.GoTo(pin)
    assert.are.equal(1429, calls.pin.map)
    assert.is_near(0.328, calls.pin.x, 1e-9); assert.is_near(0.49, calls.pin.y, 1e-9)   -- percentages become 0..1
    assert.is_true(calls.track)
    assert.are.equal(1429, calls.open)
    assert.matches("Repère posé : Mallory", table.concat(printed, "\n"))
  end)

  it("pins a pfQuest NPC that has no zone name (spec/helper_wow_lua51.lua makes %s with nil raise, as in WoW)", function()
    local ns = start()
    local calls = {}
    _G.UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
    _G.C_Map.SetUserWaypoint = function(p) calls.pin = p end
    _G.C_Map.OpenWorldMap = function(id) calls.open = id end
    _G.C_Map.GetMapInfo = function() return nil end
    local ok, err = pcall(ns.Window.GoTo, { name = "Naal Mistrunner", mapID = 1412, x = 40.2, y = 27.5, kind = "pin" }, "Poisson-chat")
    assert.is_true(ok, tostring(err))
    assert.are.equal(1412, calls.pin.map); assert.are.equal(1412, calls.open)
    assert.matches("Naal Mistrunner", table.concat(printed, "\n"))
  end)

  it("in combat only writes the place in the chat: no pin, no map", function()
    local ns = start()
    local calls = {}
    _G.UiMapPoint = { CreateFromCoordinates = function() return {} end }
    _G.C_Map.SetUserWaypoint = function() calls.pin = true end
    _G.C_Map.OpenWorldMap = function() calls.open = true end
    _G.InCombatLockdown = function() return true end
    ns.Window.GoTo(pin)
    assert.is_nil(calls.pin); assert.is_nil(calls.open)
    assert.matches("Indisponible en combat : Mallory", table.concat(printed, "\n"))
  end)

  it("without SetUserWaypoint opens the map on the zone and prints the coordinates", function()
    local ns = start()
    local opened
    _G.C_Map.SetUserWaypoint = nil
    _G.C_Map.OpenWorldMap = function(id) opened = id end
    ns.Window.GoTo(pin)
    assert.are.equal(1429, opened)
    assert.matches("32.8, 49.0%) : repère indisponible", table.concat(printed, "\n"))
  end)

  it("with only a text: prints it with 'lieu non précis', opens nothing", function()
    local ns = start()
    local opened
    _G.C_Map.OpenWorldMap = function() opened = true end
    ns.Window.GoTo({ text = "World drop (level 15-25)" })
    ns.Window.GoTo({})
    assert.is_nil(opened)
    local chat = table.concat(printed, "\n")
    assert.matches("World drop %(level 15%-25%)", chat)
    assert.matches("lieu non précis", chat)
  end)

  it("builds the tooltip: NPC, zone (client language when known), coordinates, and the real source (no 'Données Classic')", function()
    local ns = start()
    _G.C_Map.GetMapInfo = function() return { name = "Forêt d'Elwynn" } end
    local function tip(t) return table.concat(ns.Window.TargetTooltipLines(t), "\n") end
    local base = { name = "Mallory", zone = "Elwynn Forest", mapID = 1429, x = 32.8, y = 49, kind = "pin" }
    local function with(source) local t = {}; for k, v in pairs(base) do t[k] = v end; t.source = source; return t end
    assert.matches("Mallory", tip(with("pfquest")))
    assert.matches("Forêt d'Elwynn : 32.8, 49.0", tip(with("pfquest")))
    assert.matches("Source : pfQuest %(positions Classic%)%.", tip(with("pfquest")))
    assert.matches("Source : observé en jeu%.", tip(with("recorded")))
    assert.matches("Source : wowforever%.be%.", tip({ kind = "zone", mapID = 1411, name = "Vayn", zone = "Durotar", source = "site", vendors = { { name = "Vayn", zone = "Durotar", mapID = 1411 } } }))
    for _, src in ipairs({ "pfquest", "recorded", "site", "classic" }) do
      assert.is_nil(tip(with(src)):find("Données Classic", 1, true)); assert.is_nil(tip(with(src)):find("à vérifier", 1, true))
    end
    local textual = tip({ text = "World drop" })
    assert.matches("World drop", textual); assert.matches("Lieu non précis", textual)
    assert.is_nil(textual:find("Classic", 1, true))
  end)

  it("clicking the button of a row calls GoTo with that row's target", function()
    local ns = start()
    local seen
    local real = ns.Window.GoTo
    ns.Window.GoTo = function(t) seen = t end
    local b
    for _, fr in ipairs(goButtons()) do b = b or fr end
    assert.is_not_nil(b)
    b.scripts.OnClick(b)
    assert.are.equal(b.target, seen)
    ns.Window.GoTo = real
  end)
end)

describe("Fabriquer (craft button on the recommended recipe)", function()
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local calls
  local function start(opts, tradeskill)
    opts = opts or {}
    opts.scanned, opts.profs = true, { { 171, 50, "Alchimie", 75 } }
    setup(opts)
    calls = { craft = {}, open = {} }
    _G.C_TradeSkillUI = {
      CraftRecipe = function(id, n) calls.craft[#calls.craft + 1] = { id, n } end,
      OpenTradeSkill = function(line) calls.open[#calls.open + 1] = line end,
    }
    for k, v in pairs(tradeskill or {}) do _G.C_TradeSkillUI[k] = v end
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, goal = "level" }   -- the roadmap carries the craft buttons
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end
  local function craftButton()
    for _, fr in ipairs(frames) do if fr.entry and fr.label and fr.shown then return fr end end
  end
  local function fire(event, ...)
    for _, fr in ipairs(frames) do
      if fr.events and fr.events[event] and fr.scripts.OnEvent and fr.events.UNIT_SPELLCAST_START then fr.scripts.OnEvent(fr, event, ...) end
    end
  end
  local openAlchemy = { IsTradeSkillReady = function() return true end,
    GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end }

  it("asks for the window first: 'Ouvrir <métier>', and opens it through OpenTradeSkill", function()
    local ns = start()
    local b = craftButton()
    assert.are.equal("Ouvrir Alchimie", b.label.text)
    assert.are.equal(2, b.entry.times)                       -- 4 carried, 2 needed each
    b.scripts.OnClick(b)
    assert.are.same({ 171 }, calls.open)
    assert.are.equal(0, #calls.craft)
    assert.matches("Ouverture de Alchimie", table.concat(printed, "\n"))
    assert.is_not_nil(ns)
  end)

  it("tells the user to open the window by hand when OpenTradeSkill does not exist or fails", function()
    local ns = start({}, { OpenTradeSkill = false })
    _G.C_TradeSkillUI.OpenTradeSkill = nil
    ns.Window.UpdateCraft()
    local b = craftButton()
    assert.matches("à la main", ns.Window.CraftState(b.entry).reason)
    b.scripts.OnClick(b)
    assert.matches("Impossible d'ouvrir Alchimie", table.concat(printed, "\n"))
    _G.C_TradeSkillUI.OpenTradeSkill = function() error("blocked") end
    printed = {}
    b.scripts.OnClick(b)
    assert.matches("Impossible d'ouvrir Alchimie", table.concat(printed, "\n"))
  end)

  it("crafts with the recipe id and the count the bags allow when the matching window is open", function()
    local ns = start({}, openAlchemy)
    local b = craftButton()
    assert.are.equal("Fabriquer ×2", b.label.text)
    b.scripts.OnClick(b)
    assert.are.same({ { 1, 2 } }, calls.craft)               -- CraftRecipe(recipeID, N)
    assert.are.equal("Fabrication en cours...", b.label.text)
    assert.is_false(b.enabled ~= false and ns.Window.CraftState(b.entry).enabled)
    b.scripts.OnClick(b)                                     -- a second click while busy does nothing
    assert.are.equal(1, #calls.craft)
  end)

  it("does not treat another profession's window as the right one", function()
    start({}, { IsTradeSkillReady = function() return true end,
      GetBaseProfessionInfo = function() return { professionName = "Forge", professionID = 164 } end })
    assert.are.equal("Ouvrir Alchimie", craftButton().label.text)
  end)

  it("ignores linked and guild windows, and a window that is not ready", function()
    start({}, { IsTradeSkillReady = function() return false end,
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end })
    assert.are.equal("Ouvrir Alchimie", craftButton().label.text)
    local ns = start({}, { IsTradeSkillReady = function() return true end, IsTradeSkillLinked = function() return true end,
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end })
    assert.is_nil(ns.OpenTradeSkill())
  end)

  it("is disabled with a reason in combat, and when nothing can be crafted", function()
    local ns = start({ combat = true }, openAlchemy)
    local st = ns.Window.CraftState(craftButton().entry)
    assert.is_false(st.enabled); assert.are.equal("Indisponible en combat.", st.reason)
    craftButton().scripts.OnClick(craftButton())
    assert.are.equal(0, #calls.craft)
    -- an empty bag: no step can be crafted now, so the roadmap offers no button, only what is missing
    ns = start({ counts = {} }, openAlchemy)
    assert.is_nil(craftButton())
    local all = {}
    for _, l in ipairs(ns.Window.Lines()) do all[#all + 1] = l.left.text or "" end
    assert.matches("il te manque", table.concat(all, "\n"))
  end)

  it("reports a failed CraftRecipe and stays usable", function()
    local ns = start({}, openAlchemy)
    _G.C_TradeSkillUI.CraftRecipe = function() error("blocked") end
    local b = craftButton()
    b.scripts.OnClick(b)
    assert.matches("Fabrication impossible", table.concat(printed, "\n"))
    assert.is_true(ns.Window.CraftState(b.entry).enabled)
  end)

  it("is disabled while the player casts, then released with the counts refreshed (no redraw in combat)", function()
    local ns = start({}, openAlchemy)
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    local recipe = craftButton().entry.id
    fire("UNIT_SPELLCAST_START", "player", "guid", recipe)
    local b = craftButton()
    assert.is_false(ns.Window.CraftState(b.entry).enabled)
    assert.are.equal("Fabrication en cours...", b.label.text)
    fire("UNIT_SPELLCAST_START", "someone", "guid", recipe)  -- other units are ignored (start already seen: still busy)
    timers = {}
    fire("UNIT_SPELLCAST_STOP", "player", "guid", recipe)
    for _, fn in ipairs(timers) do fn() end                  -- the release debounce, then the throttled refresh
    for _, fn in ipairs(timers) do fn() end
    assert.is_true(ns.Window.CraftState(craftButton().entry).enabled)
    assert.is_true(runs >= 1)                                -- quantities redrawn
  end)

  it("a cast that is not a craft (Hearthstone, mount) never disables the button nor redraws the tab", function()
    local ns = start({}, openAlchemy)
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    timers = {}
    for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED" }) do fire(event, "player", "guid", 8690) end
    assert.is_true(ns.Window.CraftState(craftButton().entry).enabled)
    for _, fn in ipairs(timers) do fn() end
    assert.are.equal(0, runs); assert.are.equal(0, #timers)
    assert.is_false(ns.Window.IsCraftSpell(nil))
    -- the recipe handed to CraftRecipe counts, even when the character has not recorded it
    ns.Window.Craft(craftButton().entry)
    assert.is_true(ns.Window.IsCraftSpell(craftButton().entry.id))
  end)

  it("a cast of another unit alone never disables the button", function()
    local ns = start({}, openAlchemy)
    fire("UNIT_SPELLCAST_START", "target")
    assert.is_true(ns.Window.CraftState(craftButton().entry).enabled)
  end)

  it("follows the window opening: TRADE_SKILL_SHOW turns 'Ouvrir' into 'Fabriquer'", function()
    local ready = false
    local ns = start({}, { IsTradeSkillReady = function() return ready end,
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end })
    assert.are.equal("Ouvrir Alchimie", craftButton().label.text)
    ready = true
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.TRADE_SKILL_SHOW and fr.events.UNIT_SPELLCAST_START then fr.scripts.OnEvent(fr, "TRADE_SKILL_SHOW") end
    end
    assert.are.equal("Fabriquer ×2", craftButton().label.text)
    assert.is_not_nil(ns)
  end)

  it("S8 spike line lists the APIs", function()
    local ns = start({}, openAlchemy)
    SlashCmdList.GOLDCOMPASS("spike")
    assert.matches("S8 APIs: C_Map.SetUserWaypoint.*CraftRecipe true.*OpenTradeSkill true.*IsTradeSkillReady true", table.concat(printed, "\n"))
  end)
end)

describe("trainer windows recorded in game (owner's case: Kamari, Travail du cuir 61)", function()
  local services = {
    { "Apprenti artisan du cuir", "used", 0, 0, nil },
    { "Petite giberne en cuir", "available", 25, 100, "|Hitem:7279::::::::|h[x]|h" },
    { "Bottes lueur-de-lune", "available", 35, 500, "|Hitem:252427::::::::|h[x]|h" },
    { "Chaussures en écailles de Murloc", "available", 35, 500, "|Hitem:252426::::::::|h[x]|h" },
    { "Mules de dragonnet noir", "available", 35, 500, "|Hitem:252424::::::::|h[x]|h" },
  }
  local function start()
    setup({ scanned = true, profs = { { 165, 61, "Travail du cuir", 75 } } })
    _G.GetNumTrainerServices = function() return #services end
    _G.GetTrainerServiceInfo = function(i) return services[i][1], "", services[i][2] end
    _G.GetTrainerServiceSkillReq = function(i) return "Travail du cuir", services[i][3] end
    _G.GetTrainerServiceCost = function(i) return services[i][4] end
    _G.GetTrainerServiceItemLink = function(i) return services[i][5] end
    _G.UnitName = function(unit) return unit == "npc" and "Kamari" or "Tester" end
    _G.C_Map.GetPlayerMapPosition = function() return { x = 0.5, y = 0.25 } end
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = { skill = 61, max = 75, recipes = {
      [2149] = { id = 2149, name = "Bottes en cuir cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 2 } } } } } } }
    return ns
  end
  local function visit()
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.TRAINER_SHOW then fr.scripts.OnEvent(fr, "TRAINER_SHOW") end
    end
    for _, fn in ipairs(timers) do fn() end
  end

  it("records the trainer: recipes by item, skill, cost, status, NPC, map, position, faction", function()
    local ns = start()
    visit()
    local t = ns.db.trainers["A|Kamari|Leatherworking"]
    assert.is_not_nil(t)
    assert.are.equal("Kamari", t.npc); assert.are.equal("A", t.f); assert.are.equal(1411, t.mapID)
    assert.are.equal(50, t.x); assert.are.equal(25, t.y)
    assert.are.same({ skill = 35, cost = 500, status = "available", name = "Bottes lueur-de-lune" }, t.offers[1255143])
    local logged = {}
    for _, e in ipairs(ns.LogRecent(50)) do logged[#logged + 1] = e.text end
    assert.matches("Kamari %(Leatherworking%)", table.concat(logged, "\n"))
    assert.matches("skipped %(no matching recipe%): Apprenti artisan du cuir", table.concat(logged, "\n"))   -- logged
  end)

  it("lists the four Forever recipes with the real fee and the recorded NPC, and writes 'chez Kamari'", function()
    local ns = start()
    visit()
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    local found = {}
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, e in ipairs(bucket) do found[e.rec.id] = e end
    end
    for id, skill in pairs({ [9062] = 25, [1255143] = 35, [1255144] = 35, [1255146] = 35 }) do
      assert.is_not_nil(found[id], "recipe " .. id)
      assert.are.equal(skill, found[id].rec.learn)                 -- the trainer's skill, not the Classic one
      assert.are.equal("Kamari", found[id].target.name)             -- pinned where the window was opened
      assert.is_true(found[id].target.recorded)
    end
    assert.are.equal(500, found[1255143].rec.fee)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") end
    assert.matches("chez Kamari", table.concat(out, "\n"))
  end)

  it("does not record anything for a window with no recipe of ours, and ignores class trainers", function()
    local ns = start()
    _G.GetTrainerServiceItemLink = function() return "|Hitem:999999::::|h[x]|h" end
    visit()
    assert.is_nil(ns.db.trainers)
    _G.IsTradeskillTrainer = function() return false end
    _G.GetTrainerServiceItemLink = function(i) return services[i][5] end
    visit()
    assert.is_nil(ns.db.trainers)
    _G.IsTradeskillTrainer = nil
  end)

  it("S9 spike line says which trainer APIs exist and how many trainers are recorded", function()
    local ns = start()
    visit()
    SlashCmdList.GOLDCOMPASS("spike")
    assert.matches("S9 trainer APIs: GetNumTrainerServices true.*GetTrainerServiceItemLink true.*trainers recorded: 1", table.concat(printed, "\n"))
    assert.is_not_nil(ns)
  end)
end)

describe("recipes to learn (stubbed recipe data)", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local cuir = { skill = 61, max = 75, recipes = {
    [2149] = { id = 2149, name = "Bottes en cuir cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 2 } } } } }
  local function start(opts)
    opts = opts or {}
    opts.scanned, opts.profs = true, { { 165, 61, "Travail du cuir", 75 } }
    if opts.stubLib == nil then opts.stubLib = true end
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = cuir } }
    return ns
  end

  it("Fine Leather Boots (drop) is listed as a drop, never as a trainer recipe, never recommended", function()
    local ns = start({ libOverrides = { skill = { [2158] = 60 }, sources = { [2158] = { drop = { { id = 2, name = "Mob" }, total = 951 } } } } })
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    local fine
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do for _, e in ipairs(bucket) do if e.rec.id == 2158 then fine = e end end end
    assert.is_not_nil(fine)
    assert.are.equal("d", fine.rec.src)
    assert.is_false(fine.recommend)
    if lr.best then assert.are_not.equal(2158, lr.best.rec.id) end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local line
    local all = ns.Window.Lines()
    for i, l in ipairs(all) do if (l.left.text or ""):find("Fine Leather Boots", 1, true) then line = l.left.text .. " " .. (all[i + 1].left.text or "") end end   -- name line + detail line
    assert.is_not_nil(line)
    assert.matches("butin", line)
    assert.is_nil(line:find("entraîneur", 1, true))
  end)

  it("Forever table: a trainer recipe shows its real fee and no 'non confirmé'; a trainer source absent from the table is dropped", function()
    local ns = start({ libOverrides = { borrowed = { ["9062requiredSkill"] = "Vanilla" } } })
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("Small Leather Ammo Pouch.-entraîneur · ", text)       -- 9062 (Small Leather Ammo Pouch) is in the table: 1s
    assert.is_nil(text:find("non confirmé", 1, true))
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, e in ipairs(bucket) do
        if e.rec.id == 2158 then assert.is_not.equal("trainer", e.rec.way.kind) end   -- Fine Leather Boots: no trainer on Forever
      end
    end
  end)

  it("unconfirmed trainer sources are labelled as such on the recommended line", function()
    local ns = start({ libOverrides = { borrowed = {} } })
    local res
    ns.RunLeveling(function(r) res = r end)
    local best = res.profs[1].learn.best
    assert.is_not_nil(best)
    -- a trainer recipe whose required skill is borrowed from Vanilla: "(non confirmé sur Forever)"
    assert.are.equal("entraîneur (non confirmé sur Forever)", ns.Fmt.Source({ src = nil, way = { kind = "trainer", confirmed = false } }, true))
    assert.are.equal("entraîneur", ns.Fmt.Source({ src = nil, way = { kind = "trainer", confirmed = true } }, true))
    assert.are.equal("objet d'apprentissage : Cuir", ns.Fmt.Source({ src = "i", itemName = "Cuir" }, true))
  end)

  it("/gc spike reports the vendored data: version, build, counts and the recipes of each profession", function()
    local ns = start({ stubLib = false })     -- the real vendored data
    ns.db = { buy = {} }
    SlashCmdList.GOLDCOMPASS("spike")
    local chat = table.concat(printed, "\n")
    assert.matches("S10 Forever recipe data %(LibProfessionDB v1%.10%.1%), build 1%.60%.1%.70938 recipes 2517 trainer table %d+", chat)
    assert.matches("S10 Travail du cuir %d+ recipes", chat)
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

describe("Où l'apprendre: every map button answers (real Forever data, Horde, Leatherworking 61)", function()
  local known = dofile("spec/fixtures/owner_profiles.lua")[1].known
  local function start()
    setup({ scanned = true, faction = "Horde", profs = { { 165, 61, "Travail du cuir", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    local recipes = {}
    for _, id in ipairs(known) do recipes[id] = { id = id, name = "known" .. id, d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } end
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = { skill = 61, max = 75, recipes = recipes } } }
    return ns
  end
  local function logged(ns)
    local out = {}
    for _, e in ipairs(ns.LogRecent(200)) do out[#out + 1] = e.text end
    return table.concat(out, "\n")
  end

  it("gives every learnable row a target of kind pin, zone or text, a Horde trainer for trainer rows", function()
    local ns = start()
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    local seen, kinds = 0, {}
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, row in ipairs(bucket) do
        seen = seen + 1
        local t = row.target
        assert.is_true(t.kind == "pin" or t.kind == "zone" or t.kind == "text", row.rec.name)
        assert.is_true(t.mapID ~= nil or t.text ~= nil, row.rec.name .. " has neither a map nor a text")
        kinds[row.rec.id] = t.kind
        if row.rec.way.kind == "trainer" then
          assert.are.equal("pin", t.kind, row.rec.name)
          for _, tr in ipairs(ns.Trainers.Leatherworking) do
            if tr[1] == t.name then assert.is_true(tr[5] == nil or tr[5] == "H", t.name .. " is not a Horde trainer") end
          end
        end
      end
    end
    assert.is_true(seen > 60)
    assert.are.equal("pin", kinds[3763])           -- Ceinture élégante: a Journeyman trainer
    assert.are.equal("pin", kinds[9062])           -- Petite giberne: a trainer
    assert.are.equal("pin", kinds[1301431])        -- Gustwoven (Vayn Moongaze, Zephras Isle): new to Forever, ForeverDB saw where she stands
  end)

  it("a click always answers: pin, zone or text in the chat, and one log line with the recipe and the decision", function()
    local ns = start()
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local n = 0
    for _, l in ipairs(ns.Window.Lines()) do
      if l.go.target then
        n = n + 1
        local before = #printed
        l.go.scripts.OnClick(l.go)
        assert.is_true(#printed > before, "no answer for " .. tostring(l.go.recipe))
        local kind = l.go.target.kind
        assert.matches("where click: " .. l.go.recipe:gsub("%p", "%%%0") .. " %-> " .. kind, logged(ns))
      end
    end
    assert.is_true(n > 10)
  end)

  it("a recycled line rebinds its own target: the click goes to the recipe now shown on that line", function()
    local ns = start()
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local function check()
      local checked = 0
      for _, l in ipairs(ns.Window.Lines()) do
        if l.go.target and l.left.text ~= "" then
          assert.is_not_nil(l.left.text:find(l.go.recipe, 1, true), l.left.text .. " is bound to " .. tostring(l.go.recipe))
          checked = checked + 1
        end
      end
      return checked
    end
    assert.is_true(check() > 10)
    ns.Window.SetGoal("gold")                      -- every line is recycled for another list
    assert.is_true(check() > 10)
    local line
    for _, l in ipairs(ns.Window.Lines()) do if l.go.target and not line then line = l end end
    local before = #printed
    line.go.scripts.OnClick(line.go)
    assert.is_true(#printed > before)
    assert.matches("where click: " .. line.go.recipe:gsub("%p", "%%%0"), logged(ns))
  end)
end)

describe("Où l'apprendre: the site's location text (real Forever data, Horde, Cooking 124)", function()
  it("a drop shows where it drops, a quest recipe the quest", function()
    setup({ scanned = true, faction = "Horde", profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr, by = res.profs[1].learn, {}
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do for _, row in ipairs(bucket) do by[row.rec.id] = row end end
    assert.is_not_nil(by[8238])
    -- Savory Deviate Delight: a pattern no vendor sells, with an auction price, pins the auction house; the site's drop zone stays on the line
    assert.is_true(by[8238].target.auction)
    assert.matches("Patron en vente à l'HV", by[8238].target.text)
    assert.matches("butin", by[8238].target.extra)                       -- the site says "drop" (and the zone when it names one)
    assert.is_not_nil(by[6417])
    assert.are.equal("quête : Dig Rat Stew (niv. 23)", by[6417].target.text)
  end)

  it("the map button of a priced pattern pins the Horde auction house: chat and tooltip give the price, its age, the site's sources", function()
    setup({ scanned = true, faction = "Horde", profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local row
    for _, bucket in ipairs({ res.profs[1].learn.now, res.profs[1].learn.soon, res.profs[1].learn.gray }) do
      for _, r in ipairs(bucket) do if r.rec.id == 8238 then row = r end end
    end
    assert.is_true(row.target.auction); assert.are.equal("pin", row.target.kind)
    assert.is_truthy(row.target.name:find("^Auctioneer"))
    local before = #printed
    ns.Window.GoTo(row.target, "Feu de camp")
    local chat = table.concat(printed, "\n", before + 1)
    assert.matches("Auctioneer", chat); assert.matches("Source : pfQuest", chat); assert.matches("Patron en vente à l'HV : ~", chat)
    local tip = table.concat(ns.Window.TargetTooltipLines(row.target), "\n")
    assert.matches("Patron en vente à l'HV : ~", tip); assert.matches("prix HV", tip); assert.matches("butin", tip)
    assert.matches("Source : pfQuest %(positions Classic%)%.", tip)
    assert.matches("position Classic, non confirmée sur Forever", tip)     -- pfQuest's auctioneer position: never shown as a sure one
    assert.matches("position Classic, non confirmée sur Forever", chat)
  end)
end)

describe("Où l'apprendre: vendors of the site, by faction (Cooking 124)", function()
  local function rows(faction)
    setup({ scanned = true, faction = faction, profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local by = {}
    for _, bucket in ipairs({ res.profs[1].learn.now, res.profs[1].learn.soon, res.profs[1].learn.gray }) do
      for _, row in ipairs(bucket) do by[row.rec.id] = row end
    end
    return ns, by
  end

  it("a Horde player gets the Horde vendors of the site, formatted '<NPC> (<Zone>) ; <NPC> (<Zone>) - position exacte inconnue'", function()
    local ns, by = rows("Horde")
    local row = by[7755]                                      -- Poisson-chat moustachu
    assert.is_not_nil(row)
    assert.are.equal("Derak Nightfall (Hillsbrad Foothills), Naal Mistrunner (Thunder Bluff)", row.rec.way.where)
    assert.are.equal("pin", row.target.kind)                  -- an exact pin on one of ForeverDB's vendors of the recipe, never Lindea (Alliance)
    local listed = false
    for _, id in ipairs(ns.FdbVendors[7755]) do listed = listed or id == row.target.id end
    assert.is_true(listed); assert.are_not.equal("A", ns.FdbNpcs[row.target.id][5]); assert.is_true(row.target.confirmed)
    local before = #printed
    ns.Window.GoTo(row.target, "Poisson-chat moustachu")
    assert.is_nil(table.concat(printed, "\n", before + 1):find("Lindea", 1, true))
  end)

  it("an Alliance player gets the Alliance list", function()
    local ns, by = rows("Alliance")
    assert.are.equal("Lindea Rabonne (Hillsbrad Foothills), Kilxx (The Barrens)", by[7755].rec.way.where)
    assert.is_not_nil(ns)
  end)

  it("zones with no known map are written as they are, without opening a map, and no stray parenthesis", function()
    local ns = rows("Horde")
    local before = #printed
    ns.Window.GoTo({ kind = "text", name = "Vayn Moongaze", zone = "Zephras Isle",
      vendors = { { name = "Vayn Moongaze", zone = "Zephras Isle" } } }, "Chausses")
    assert.matches("Où l'apprendre : Vayn Moongaze %(île de Zephras%) %- position exacte inconnue%.$", printed[before + 1])
  end)

  it("the vendor of another faction is filtered out when the Classic data knows its faction", function()
    local W = loadfile("Where.lua")
    local ns = {}
    W("GoldCompass", ns)
    local env = { trainers = {}, npcs = { ["Alli Vendor"] = { "Elwynn Forest", 0, 0, "A" }, ["Horde Vendor"] = { "Durotar", 0, 0, "H" } },
      where = {}, maps = { ["Elwynn Forest"] = { 1429, "E" }, Durotar = { 1411, "K" } }, faction = "H" }
    local t = ns.Where.Target({ id = 1, src = "v", way = { site = true, where = "Alli Vendor (Elwynn Forest), Horde Vendor (Durotar), Someone (Durotar)" } }, "Cooking", env)
    assert.are.equal(2, #t.vendors)
    assert.are.equal("Horde Vendor", t.vendors[1].name); assert.are.equal("Someone", t.vendors[2].name)
    assert.are.equal("zone", t.kind)
  end)
end)

describe("the craft button belongs to its own section (Travail du cuir vs Dépeçage, same leather)", function()
  local lw = { skill = 61, max = 75, recipes = {
    [2149] = { id = 2149, name = "Bottes en cuir cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 2 } } } } }
  -- the Skinning data holds its own recipe and, from an old capture, a Leatherworking one that uses the same leather
  local skin = { skill = 110, max = 150, recipes = {
    [1229517] = { id = 1229517, name = "Chaise du camp", d = 3, out = 2302, oq = 1, mats = { { 2318, 2 } } },
    [2152] = { id = 2152, name = "Cape cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 1 } } } } }
  local function start()
    setup({ scanned = true, counts = { [2318] = 10 }, profs = { { 165, 61, "Travail du cuir", 75 }, { 393, 110, "Dépeçage", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = lw, ["Dépeçage"] = skin }, onlyBag = true, goal = "level" }
    return ns
  end

  it("each section's craft entry carries its own profession and skill line; foreign recipes are not in the section", function()
    local ns = start()
    local res
    ns.RunLeveling(function(r) res = r end)
    local a, b = res.profs[1], res.profs[2]
    assert.are.equal("Travail du cuir", a.craft.prof); assert.are.equal(165, a.craft.line); assert.are.equal(2149, a.craft.id)
    assert.are.equal("Dépeçage", b.name)
    assert.is_nil(b.plan.best and b.plan.best.rec.id == 2152 and true)      -- the Leatherworking recipe is not Skinning's
    if b.craft then assert.are.equal("Dépeçage", b.craft.prof); assert.are.equal(393, b.craft.line) end
    local label = ns.Window.CraftState(a.craft).label
    assert.matches("Travail du cuir", label)                                  -- "Ouvrir Travail du cuir", never "Ouvrir Dépeçage"
    assert.is_nil(label:find("Dépeçage", 1, true))
  end)

  it("a profession window records only the recipes of its own skill line, and ignores an unnamed window", function()
    local ns = start()
    local function window(name, id, ids)
      return { GetBaseProfessionInfo = function() return { professionName = name, professionID = id, skillLevel = 5, maxSkillLevel = 75 } end,
        GetAllRecipeIDs = function() return ids end, GetRecipeInfo = function(i) return { learned = true, name = "r" .. i, relativeDifficulty = 2 } end }
    end
    local learned, profs = {}, {}
    ns.Learned.Capture(window("Dépeçage", 393, { 1229517, 2149 }), learned, profs)
    assert.is_not_nil(profs["Dépeçage"].recipes[1229517])
    assert.is_nil(profs["Dépeçage"].recipes[2149])                           -- a leather recipe is not Skinning's
    ns.Learned.Capture(window("", 165, { 2149 }), learned, profs)
    assert.is_nil(profs[""])                                                  -- no entry under an empty name
  end)
end)

describe("NPC positions recorded in game", function()
  it("reads the NPC id of a creature GUID, nothing else", function()
    setup({}); local ns = loadAddon()
    assert.are.equal(3497, ns.TrainerLog.NpcID("Creature-0-4379-1-76-3497-00001A2B3C"))
    assert.is_nil(ns.TrainerLog.NpcID("Player-4379-0123ABCD")); assert.is_nil(ns.TrainerLog.NpcID(nil))
  end)

  it("a merchant window records the vendor (id, name, map position) account-wide, a new visit replaces it", function()
    setup({}); local ns = loadAddon()
    ns.db = {}
    _G.UnitGUID = function() return "Creature-0-1-1-1-3497-0000000001" end
    _G.UnitName = function() return "Kilxx" end
    _G.C_Map.GetBestMapForUnit = function() return 1413 end
    _G.C_Map.GetMapInfo = function() return { name = "Les Tarides" } end
    _G.C_Map.GetPlayerMapPosition = function() return { x = 0.628, y = 0.382 } end
    ns.TrainerLog.ScanMerchant()
    local r = ns.db.npcs[3497]
    assert.are.equal("Kilxx", r.name); assert.are.equal(1413, r.mapID); assert.are.equal("Alliance" == nil and "" or "A", r.f)
    assert.is_true(math.abs(r.x - 62.8) < 0.01)
    _G.C_Map.GetPlayerMapPosition = function() return { x = 0.5, y = 0.5 } end
    ns.TrainerLog.ScanMerchant()
    assert.are.equal(50, ns.db.npcs[3497].x)
  end)
end)

-- Forever truth of "Où l'apprendre" (real data, the owner's Horde professions): a pin is confident only on a position seen on
-- Forever (ForeverDB.net) or recorded in game; everything else is flagged. GC_REPORT=1 busted prints the table recipe -> place -> evidence.
describe("Où l'apprendre: Forever-confirmed places (real data, Horde, Cooking 124 and Leatherworking 69)", function()
  local known = dofile("spec/fixtures/owner_profiles.lua")[1].known
  local function rows(line, skill, name, max, recipes)
    setup({ scanned = true, faction = "Horde", profs = { { line, skill, name, max } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { [name] = { skill = skill, max = max, recipes = recipes } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local by, list = {}, {}
    for _, bucket in ipairs({ res.profs[1].learn.now, res.profs[1].learn.soon, res.profs[1].learn.gray }) do
      for _, row in ipairs(bucket) do by[row.rec.id] = row; list[#list + 1] = row end
    end
    return ns, by, list, res.profs[1].learn
  end
  local function cooking()
    return rows(185, 124, "Cuisine", 150, { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } })
  end
  local function leather()
    local recipes = {}
    for _, id in ipairs(known) do recipes[id] = { id = id, name = "known" .. id, d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } end
    return rows(165, 69, "Travail du cuir", 75, recipes)
  end
  local function report(title, ns, list)
    if not os.getenv("GC_REPORT") then return end
    io.write("\n== " .. title .. "\n")
    table.sort(list, function(a, b) return a.rec.id < b.rec.id end)
    for _, row in ipairs(list) do
      local t = row.target
      local place = t.mapID and t.x and ("%s, map %d %.1f/%.1f"):format(tostring(t.name), t.mapID, t.x, t.y)
        or t.mapID and ("zone map %d (%s)"):format(t.mapID, tostring(t.name or t.text))
        or t.vendors and ns.Window.VendorText(t) or tostring(t.text)
      local evidence = t.mapID and t.x and ((t.confirmed and "CONFIRMED " or "UNCONFIRMED ") .. tostring(t.source))
        or t.unverified and ("NO FOREVER SOURCE" .. (t.hint and (" (Classic hint: " .. t.hint .. ")") or ""))
        or t.onlyFaction and ("only faction " .. t.onlyFaction) or tostring(t.source or "text")
      io.write(("%-8d %-38s %-9s %-7s %-52s %s\n"):format(row.rec.id, tostring(row.rec.name):sub(1, 38), tostring(row.rec.way and row.rec.way.kind),
        t.kind .. (t.auction and "/AH" or ""), place, evidence))
    end
  end

  it("the catfish recipe (7755) pins Naal Mistrunner IN Thunder Bluff (map 1456), a position seen on Forever, never Mulgore", function()
    local ns, by = cooking()
    local row = by[7755]                                      -- Poisson-chat moustachu
    assert.is_not_nil(row)
    assert.are.same({ 5494, 2397, 260487, 3497, 2383, 3027, 4553, 3029 }, ns.FdbVendors[7755])   -- ForeverDB: who sells it
    assert.are.same({ "Naal Mistrunner", 1456, 50.8, 52.2, "H", true }, ns.FdbNpcs[3027])
    -- a Tauren standing in Mulgore: the Thunder Bluff vendors are the nearest ones
    local env = { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs, faction = "H", db = ns.Npcs,
      byName = ns.NpcByName, ntrainers = ns.NpcTrainers, fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors, fdbTrainers = ns.FdbTrainers,
      contOf = { [1456] = "K", [1412] = "K", [1413] = "K", [1424] = "E", [1458] = "E" }, continent = "K",
      dist = function(m, x) return m == 1456 and (x == 50.8 and 10 or 20) or 900 end }
    local t = ns.Where.Target(row.rec, "Cooking", env)
    assert.are.equal("pin", t.kind); assert.are.equal("Naal Mistrunner", t.name); assert.are.equal(3027, t.id)
    assert.are.equal(1456, t.mapID); assert.are.equal(50.8, t.x); assert.are.equal(52.2, t.y)
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    local before = #printed
    ns.Window.GoTo(t, "Poisson-chat moustachu")
    local chat = table.concat(printed, "\n", before + 1)
    assert.matches("Source : ForeverDB.net %(vu en jeu sur Forever%)", chat)
    assert.is_nil(chat:find("non confirmée", 1, true)); assert.is_nil(chat:find("Lindea", 1, true))
    -- whoever the player is, no Horde answer is on the Mulgore map (the projection of the city) or an Alliance vendor
    for _, e in ipairs({ {}, { continent = "E" }, { continent = "K", dist = function() return 5 end } }) do
      local o = {}
      for k, v in pairs(env) do o[k] = v end
      o.continent, o.dist = e.continent, e.dist
      local any = ns.Where.Target(row.rec, "Cooking", o)
      assert.are.equal("pin", any.kind); assert.are_not.equal(1412, any.mapID); assert.is_true(any.confirmed)
      assert.is_true(any.id ~= 2383 and any.id ~= 5494)
    end
    -- without ForeverDB's place, pfQuest's Classic one is used on the city map and flagged as unconfirmed
    env.fdb, env.fdbVendors, env.fdbTrainers = nil, nil, nil
    local c = ns.Where.Target({ id = 7755, src = "v", way = { site = true, where = "Naal Mistrunner (Thunder Bluff)" } }, "Cooking", env)
    assert.are.equal(1456, c.mapID); assert.is_false(c.confirmed); assert.are.equal("pfquest", c.source)
    before = #printed
    ns.Window.GoTo(c, "Poisson-chat moustachu")
    assert.matches("position Classic, non confirmée sur Forever", table.concat(printed, "\n", before + 1))
    assert.matches("position Classic, non confirmée sur Forever", table.concat(ns.Window.TargetTooltipLines(c), "\n"))
  end)

  it("every Cooking and Leatherworking pin is confirmed on Forever or says it is not; nothing is pinned from Classic names alone", function()
    for _, p in ipairs({ { "Cooking 124 Horde", cooking }, { "Leatherworking 69 Horde", leather } }) do
      local ns, _, list = p[2]()
      assert.is_true(#list > 10)
      local confirmed = 0
      for _, row in ipairs(list) do
        local t = row.target
        if t.kind == "pin" then
          assert.is_true(t.confirmed == (t.source == "foreverdb" or t.source == "recorded"), row.rec.name)
          if t.confirmed then confirmed = confirmed + 1 end
          local tip = table.concat(ns.Window.TargetTooltipLines(t), "\n")
          assert.are.equal(not t.confirmed, tip:find("position Classic, non confirmée sur Forever", 1, true) ~= nil, row.rec.name)
          if row.rec.src == "v" and t.id and not t.auction and ns.FdbVendors[row.rec.id] then   -- a vendor: one a Forever source names for this recipe
            local listed = (row.rec.way.where or ""):find(t.name, 1, true) ~= nil      -- the site's list
            for _, id in ipairs(ns.FdbVendors[row.rec.id]) do listed = listed or id == t.id end
            assert.is_true(listed, row.rec.name .. ": " .. tostring(t.name))
          end
          if t.id and ns.FdbNpcs[t.id] then assert.are_not.equal("A", ns.FdbNpcs[t.id][5], row.rec.name) end
        end
      end
      assert.is_true(confirmed > 5, p[1])
      report(p[1], ns, list)
    end
  end)

  it("a vendor or a quest of the other faction is no way to learn a recipe: never the best pick, said as Alliance only", function()
    local ns, by, list = cooking()
    -- Crocolisk Steak: Kendor Kabonka (Stormwind) and the quest Crocolisk Hunting (Loch Modan) are the Alliance's
    local croc = by[3370]
    assert.is_not_nil(croc)
    assert.are.equal("A", croc.rec.way.onlyFaction); assert.are.equal("item", croc.rec.way.kind)
    assert.is_false(croc.recommend and croc.rec.fee == nil)          -- only an auction price could make it worth proposing
    assert.is_true(croc.target.auction or croc.target.onlyFaction == "A")
    assert.is_not_nil(ns.Fmt.SiteSources(croc.rec.way):find("Kendor Kabonka (Stormwind City) (côté Alliance uniquement)", 1, true))
    for _, row in ipairs(list) do
      local way = row.rec.way
      if way.kind == "vendor" or way.kind == "quest" then
        assert.is_nil(way.onlyFaction, row.rec.name)
        assert.are_not.equal("A", row.target.onlyFaction, row.rec.name .. " is proposed to the Horde but only the Alliance can get it")
      end
    end
    -- Cooking at 10: the Alliance quest Recipe of the Kaldorei (Zarrin, Teldrassil) is not offered to the Horde, nor the best pick
    local ns10, by10 = rows(185, 10, "Cuisine", 75, { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } })
    local kabob = by10[6412]                                  -- listed only as a pattern to buy at the auction house, when it has a price there
    if kabob then
      assert.are.equal("item", kabob.rec.way.kind); assert.are.equal("A", kabob.rec.way.onlyFaction)
      assert.is_true(kabob.target.auction); assert.is_not_nil(kabob.rec.fee)
    end
    local horde = ns10.Leveling.Way(ns10.ForeverDB, 6412, { requiredSkill = 10 }, "H", ns10.ForeverTrainers,
      ns10.Where.Who({ db = ns10.Npcs, byName = ns10.NpcByName, maps = ns10.MapIDs, fdb = ns10.FdbNpcs, fdbVendors = ns10.FdbVendors, fdbQuests = ns10.FdbQuests }))
    assert.are_not.equal("quest", horde.kind); assert.are.equal("A", horde.onlyFaction); assert.is_nil(horde.questID)
    assert.are.same({ { 4161, "A", 6286, "Zarrin", 1438, 57.1, 61.3, "Recipe of the Kaldorei", 7 } }, ns10.FdbQuests[6412])
    local way = ns10.Leveling.Way(ns10.ForeverDB, 6412, { requiredSkill = 10 }, "A", ns10.ForeverTrainers,
      ns10.Where.Who({ db = ns10.Npcs, byName = ns10.NpcByName, maps = ns10.MapIDs, fdb = ns10.FdbNpcs, fdbVendors = ns10.FdbVendors, fdbQuests = ns10.FdbQuests }))
    assert.are.equal("quest", way.kind); assert.are.equal(4161, way.questID); assert.is_nil(way.onlyFaction)
  end)

  it("a Horde quest recipe pins the quest giver where Forever players were offered the quest, with the quest named", function()
    local ns, by = cooking()
    local t = by[6417].target                                 -- Dig Rat Stew: Grub, east of the Crossroads
    assert.are.equal("pin", t.kind); assert.are.equal("Grub", t.name); assert.are.equal(1413, t.mapID)
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source); assert.are.equal("quête : Dig Rat Stew (niv. 23)", t.text)
    assert.are.equal(862, by[6417].rec.way.questID)
    _G.C_QuestLog = { GetTitleForQuestID = function(id) return id == 862 and "Ragoût de rat" or nil end }   -- the client's own title
    assert.are.equal("Ragoût de rat (niv. 23)", ns.Fmt.QuestName(by[6417].rec.way))
    _G.C_QuestLog = nil
    assert.are.equal("Dig Rat Stew (niv. 23)", ns.Fmt.QuestName(by[6417].rec.way))
  end)

  it("a Merchant's Favor vendor of the site is read as NPC, zone and price: Pawani (The Barrens), 30 Faveur du marchand", function()
    local ns, by = leather()
    local row = by[1255139]                                   -- Totemic Leather Belt
    assert.is_not_nil(row)
    assert.are.equal("vendor", row.rec.way.kind); assert.are.equal("Pawani (The Barrens)", row.rec.way.where)
    assert.are.same({ id = 3402, amount = 30 }, row.rec.way.currency)
    assert.are.equal("Pawani", row.target.name); assert.is_true(row.target.confirmed)
    assert.matches("30 Faveur du marchand", ns.Fmt.Source(row.rec, true))
    -- the site's text alone (no ForeverDB data) gives the same reading
    local way = ns.Leveling.Way(ns.ForeverDB, 1255139, { requiredSkill = 70 }, "H", ns.ForeverTrainers)
    assert.are.equal("Pawani (The Barrens)", way.where); assert.are.equal("Pawani", way.npcs[1])
    assert.are.same({ id = 3402, amount = 30 }, way.currency)
  end)

  it("the rank book pins its Forever vendor of the player's faction (Expert Cookbook: Wulan in Desolace, not Shandrina)", function()
    local ns, _, _, lr = cooking()
    local book
    for _, b in ipairs(lr.books or {}) do if b.rec.id == 3413 then book = b end end
    assert.is_not_nil(book)
    assert.are.same({ 3955, 12033 }, ns.FdbVendors[3413])
    local t = book.target
    assert.are.equal("pin", t.kind); assert.are.equal("Wulan", t.name); assert.are.same({ 1443, 26.1, 69.7 }, { t.mapID, t.x, t.y })
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    assert.are.equal(10000, book.rec.way.vendorCost)          -- 1 gold, ForeverDB's vendor price
  end)

  it("the Leatherworking trainer rows pin a Horde trainer ForeverDB lists, at the place it was seen on Forever", function()
    local ns, by = leather()
    local t = by[3763].target                                 -- Ceinture élégante en cuir: a trainer recipe
    assert.are.equal("pin", t.kind); assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    assert.is_true(ns.FdbTrainers.Leatherworking[t.id]); assert.are.equal("H", ns.FdbNpcs[t.id][5])
    assert.are.same({ ns.FdbNpcs[t.id][2], ns.FdbNpcs[t.id][3], ns.FdbNpcs[t.id][4] }, { t.mapID, t.x, t.y })
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
      for _, l in ipairs(ns.Window.Lines()) do
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
      for _, l in ipairs(ns.Window.Lines()) do all[#all + 1] = plain(l.left.text) end
      local text = table.concat(all, "\n")
      assert.matches("Au%-delà de 75 : il faut le rang Compagnon", text)
      assert.matches("Pour dépasser 150 : ", text)
      assert.is_nil(text:find("prix de la recette inconnu, niv. 125 grise", 1, true))
    end
  end)

  it("no recipe above the profession cap is listed under 'Bientôt' (Travail du cuir 61/75)", function()
    local ns = render(false)
    local lines = ns.Window.Lines()
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

describe("/gc pnj lists the NPCs recorded in game", function()
  it("says when nothing is recorded, then lists merchants and trainers with their place, one line per NPC", function()
    setup({ scanned = true, faction = "Horde", profs = {} })
    local ns = loadAddon()
    ns.db = {}
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("pnj")
    assert.matches("Aucun PNJ enregistré", table.concat(printed, "\n"))
    ns.db.npcs = { [3027] = { name = "Naal Mistrunner", mapID = 1456, x = 50.84, y = 52.21, f = "H" } }
    ns.db.trainers = {
      ["H|Kamari|Leatherworking"] = { npc = "Kamari", mapID = 1454, x = 63.16, y = 45.01, zone = "Orgrimmar", f = "H", prof = "Leatherworking", offers = {} },
      ["H|Naal Mistrunner|Cooking"] = { npc = "Naal Mistrunner", mapID = 1456, x = 50.8, y = 52.2, f = "H", prof = "Cooking", offers = {} },
    }
    assert.are.same({ "Kamari", "Naal Mistrunner" }, { ns.TrainerLog.Recorded(ns.db)[1].name, ns.TrainerLog.Recorded(ns.db)[2].name })
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("pnj")
    local text = table.concat(printed, "\n")
    assert.matches("2 PNJ enregistrés en jeu", text)
    assert.matches("Kamari · [^\n]- 63%.2, 45%.0", text); assert.matches("Naal Mistrunner · [^\n]- 50%.8, 52%.2", text)
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

describe("Métier tab, 'Monter le métier': no AH resale note, the chance is exact when thresholds are known", function()
  it("says 'coûte' and never 'rentable seulement si tu revends à l'HV'; the estimate label only without thresholds", function()
    setup({ scanned = true, profs = { { 165, 75, "Travail du cuir", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { goal = "level", learned = {}, profs = { ["Travail du cuir"] = { skill = 75, max = 150, recipes = {
      [2161] = { id = 2161, name = "Bottes", d = 0, out = 2309, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } } } } } }
    _G.GetLocale = function() return "frFR" end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local due = timers; timers = {}
    for _, fn in ipairs(due) do pcall(fn) end
    local text = {}
    for _, l in ipairs(ns.Window.Lines()) do text[#text + 1] = ((l.left.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local all = table.concat(text, "\n")
    assert.matches("Ton parcours", all)
    assert.matches("Apprendre", all)                                                -- a recipe to learn is a step of the roadmap
    assert.matches("il te manque %d+ ×", all)
    for _, word in ipairs({ "coût", "rentable seulement", "prix HV", "estimation", "Presque", "Bientôt", "Prix manquant", "ingr." }) do
      assert.is_nil(all:find(word, 1, true), word)                                  -- the roadmap talks effort, not gold or estimates
    end
  end)
end)

describe("Monter le métier shows effort everywhere (owner's data, Horde)", function()
  local function plain(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local function render(goal, bag)
    setup({ scanned = true, faction = "Horde", counts = bag and { [2318] = 10, [2320] = 10, [2308] = 10, [2309] = 10 } or nil,
      profs = { { 165, 61, "Travail du cuir", 75 }, { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, onlyBag = bag or false, goal = goal }
    for _, p in ipairs(dofile("spec/fixtures/owner_profiles.lua")) do
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

  it("no gold wording or coin icon in any line, except the learning price on a dim detail line", function()
    for _, bag in ipairs({ false, true }) do
      local ns = render("level", bag)
      for _, l in ipairs(ns.Window.Lines()) do
        local left, right = plain(l.left.text), plain(l.right.text)
        for _, word in ipairs({ "rapporte", "coût", "coûte" }) do
          assert.is_nil(left:find(word, 1, true), word .. " in: " .. left)
          assert.is_nil(right:find(word, 1, true), word .. " in: " .. right)
        end
        assert.is_nil((l.right.text or ""):find("Interface\\", 1, true), "coin icon in the figure: " .. tostring(l.right.text))
      end
    end
  end)

  it("the roadmap has none of the removed wording, hides the bag checkbox, and the known recipes open on demand", function()
    local ns = render("level", true)
    local function text()
      local out = {}
      for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = plain(l.lv and l.lv.text) .. " " .. plain(l.left.text) .. " " .. plain(l.right.text) end
      return table.concat(out, "\n")
    end
    assert.matches("Ton parcours", text())
    for _, word in ipairs({ "Presque", "Bientôt", "Réservé à l'Alliance", "Prix manquant", "estimation", "Meilleure à apprendre", "te ferait passer", "ingr." }) do
      assert.is_nil(text():find(word, 1, true), word)
    end
    assert.is_false(ns.Window.IsBagBoxShown())
    assert.matches("rochaine étape : rang", plain(ns.Window.Footer().text))
    assert.is_nil(text():find("Recettes connues", 1, true))                    -- collapsed by default
    ns.Window.recipesOpen = true
    ns.Window.SetTab("job")
    for _, fn in ipairs(timers) do pcall(fn) end
    assert.matches("Recettes connues", text())
  end)

  it("every profession has its own rank step or rank line", function()
    local ns = render("level", true)
    local all = {}
    for _, l in ipairs(ns.Window.Lines()) do all[#all + 1] = plain(l.lv and l.lv.text) .. " " .. plain(l.left.text) end
    local text = table.concat(all, "\n")
    assert.matches("Cuisine  124/150\n[^\n]*\n[^\n]*", text)
    assert.matches("Prochaine étape : rang Expert à 125", text)               -- Cooking 124: the rank is still ahead, in its own section
    assert.matches("Apprendre le rang Compagnon", text)                       -- Leatherworking 61 >= 50: the rank is the first step
    local first = text:find("Apprendre le rang Compagnon", 1, true)
    assert.is_true(first < (text:find("Ton parcours", 1, true) or 0) + 60)
  end)

  it("gold mode keeps its gold wording", function()
    local ns = render("gold", false)
    local all = {}
    for _, l in ipairs(ns.Window.Lines()) do all[#all + 1] = plain(l.left.text) .. " " .. plain(l.right.text) end
    assert.matches("par fabrication", table.concat(all, "\n"))
  end)

  it("the best recipe to learn follows the effort rule: nothing in the learn lists has fewer ingredients per point within the 15 % window with a better chance", function()
    local ns = render("level", false)
    local res
    ns.RunLeveling(function(r) res = r end)
    for _, p in ipairs(res.profs) do
      local lr = p.learn
      if lr and lr.best then
        local lean = math.huge
        for _, e in ipairs(lr.now) do
          if e.recommend and not e.unpriced and e.rankGated == lr.best.rankGated and e.priceKnown == lr.best.priceKnown then lean = math.min(lean, e.unitsPerPoint or math.huge) end
        end
        assert.is_true(lr.best.unitsPerPoint <= lean * 1.15 + 1e-9, p.name)
      end
    end
  end)
end)
