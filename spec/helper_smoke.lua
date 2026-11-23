-- Shared by the spec/smoke_*_spec.lua files: the stubbed WoW API (proxy frames, ForeverDB stand-in, setup) and the addon loader.
-- Every spec file keeps its own printed / handlers / frames / timers locals and passes a state() function to setup (see each file's top).
local H = {}

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
      if k == "UnregisterEvent" and self.events then self.events[a] = nil end
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

-- state() returns the calling spec file's current printed, handlers, frames, timers. Each spec file keeps these as its own locals
-- (tests reassign them: "printed = {}", "timers = {}"), so the stubs read them at call time, as the shared upvalues were read before.
local function setup(opts, state)
  local loaded = {}
  _G.print = function(...) local printed = state(); printed[#printed + 1] = table.concat({ ... }, " ") end
  _G.GoldCompassDB = nil
  _G.SlashCmdList = {}
  _G.UISpecialFrames = {}
  _G.tinsert = table.insert
  _G.UIParent = proxy()
  UIParent.GetWidth = function() return opts.screenW or 1366 end
  UIParent.GetHeight = function() return opts.screenH or 768 end
  _G.CreateFrame = function() local _, _, frames = state(); local p = proxy(); frames[#frames + 1] = p; return p end
  _G.C_Timer = { After = function(_, fn) local _, _, _, timers = state(); timers[#timers + 1] = fn end }
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
  _G.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) local _, handlers = state(); handlers.item = fn end }
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
  for _, f in ipairs({ "Strings", "Log", "Data/GatherNodes", "Data/Zones", "Data/Recipes", "Data/Locations", "Data/ForeverTrainers", "Data/ForeverRecipes", "Data/Npcs", "Data/ForeverNpcs", "Data/ForeverFixes", "Data/QuestItems", "ZoneRank", "Route", "Synergy", "SkinLoot", "Advice", "Here", "ForeverDB", "Effort", "Leveling", "Where", "Format", "HowTo",
    "Prices", "Nodes", "Bank", "Shopping", "Core", "Learned", "Trainers", "Spike", "Tooltip", "RouteMap", "Window", "ShoppingList", "BankEvents" }) do
    assert(loadfile(f .. ".lua"))("GoldCompass", ns)
  end
  if _G.stubDB then ns.ForeverDB = _G.stubDB end
  ns.FrameBudget = math.huge   -- the whole refresh in one call, whatever the machine's speed (the frame split has its own specs)
  -- The older Métier tests describe the bag filter, the learn lists and the gold figures, which now belong to "Gagner de l'or": unless a test
  -- asks for the roadmap with goal = "level", the tab runs in that mode.
  ns.RealGoal = ns.Goal
  ns.Goal = function() return ns.char and ns.char.goal == "level" and "level" or "gold" end
  return ns
end

H.proxy, H.libStub, H.setup, H.loadAddon, H.LINE = proxy, libStub, setup, loadAddon, LINE

-- The Métier tab shows one profession at a time: the lines (and footers) of every profession tab, in tab order.
function _G.allJobLines(ns)
  local out, footers = {}, {}
  for _, b in ipairs(ns.Window.ProfTabs()) do
    if b:IsShown() then
      b.scripts.OnClick(b)
      for _, l in ipairs(ns.Window.Lines()) do   -- lines are recycled by the next tab: keep a copy of what they show now
        out[#out + 1] = { left = { text = l.left.text, width = l.left.width }, right = { text = l.right.text },
          lv = l.lv and { text = l.lv.text } or nil }
      end
      footers[#footers + 1] = ns.Window.Footer().text or ""
    end
  end
  return out, table.concat(footers, "\n")
end

return H
