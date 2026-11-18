-- Smoke test: loads every addon file in TOC order against a stubbed WoW API, with fake GatherMate2 and Auctionator,
-- and runs /gc map and the window. It proves the glue code runs; it proves nothing about the real game.
local printed, handlers

local function proxy()
  local p = { scripts = {} }
  return setmetatable(p, { __index = function(t, k)
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    return function(self, a)
      if k == "SetScript" then self.scripts[a] = select(1, nil) end
      if k == "SetText" then self.text = a end
      if k:match("^Create") then return proxy() end
      return self
    end
  end })
end

local function setup(opts)
  printed, handlers = {}, {}
  _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
  _G.GoldCompassDB = nil
  _G.SlashCmdList = {}
  _G.UISpecialFrames = {}
  _G.tinsert = table.insert
  _G.UIParent = proxy()
  _G.CreateFrame = function() return proxy() end
  _G.C_Timer = { After = function() end }
  _G.Item = { CreateFromItemID = function() return { ContinueOnItemLoad = function(_, cb) cb() end } end }
  _G.GetItemInfo = function(id) return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, 25 end
  _G.C_Map = { GetMapInfo = function(id) return { name = "Zone" .. id } end }
  _G.UnitLevel = function() return 20 end
  _G.GetProfessions, _G.GetProfessionInfo = nil, nil
  if opts.alchemy then
    _G.GetProfessions = function() return 1 end
    _G.GetProfessionInfo = function() return "Alchemy", nil, 50, nil, nil, nil, 171 end
  end
  _G.IsPlayerSpell = function(id) return id == 2329 end -- Elixir of Minor Strength
  _G.UnitFactionGroup = function() return "Alliance" end
  _G.InCombatLockdown = function() return opts.combat or false end
  _G.IsShiftKeyDown = function() return false end
  _G.IsAddOnLoaded = function() return false end
  _G.Enum = { TooltipDataType = { Item = 0 } }
  _G.C_Item = { GetItemCount = function() return 4 end, GetItemInfoInstant = function() return 0, "", "", "", 0, 7 end,
    GetItemQualityByID = function() return 1 end }
  _G.GameTooltip = { lines = {} }
  GameTooltip.AddLine = function(self, t) self.lines[#self.lines + 1] = t end
  GameTooltip.AddDoubleLine = function(self, l, r) self.lines[#self.lines + 1] = l .. " | " .. r end
  GameTooltip.IsShown = function() return false end
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
    GetAuctionPriceByItemID = function(_, id) if opts.scanned then return id == 2770 and 40 or 35 end end,
    GetAuctionAgeByItemID = function() return 1 end,
  } } }
  if opts.noGM then _G.GatherMate2 = nil end
  if opts.noAuc then _G.Auctionator = nil end
end

local function loadAddon()
  local ns = {}
  for _, f in ipairs({ "Strings", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/QuestItems", "ZoneRank", "Advice", "Here", "Format",
    "Prices", "Nodes", "Core", "Spike", "Tooltip", "Window" }) do
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

  it("opens the window and renders without error", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    assert.has_no.errors(function() SlashCmdList["GOLDCOMPASS"]("") end)
    SlashCmdList["GOLDCOMPASS"]("spike")
    assert.matches("S2 Durotar", table.concat(printed, "\n"))
  end)
end)
